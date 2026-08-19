`timescale 1ns/1ps

// INT4 x float AWQ PCU with a shared post-MAC dequantization datapath.
//
// The existing int4float_pcu is instantiated unchanged and still drains raw
// signed INT32 accumulators.  On top of it sits one shared floating-point
// engine: at each weight-group boundary the NUM_PES integer accumulators are
// copied into one of two snapshot slots and serialized at one PE per cycle
// through a fixed32 x float16 multiplier and a binary32 adder.  The logical
// FP32 accumulator stays spatial (one register per PE); only the arithmetic is
// shared.  On the last group of a dot product the FP32 values are packed to the
// activation format and presented as one vector.
//
// Numeric contract, for PE p and weight group g:
//
//   prod32[p]   = RNE32(acc_int32[p] * scale16[p,g] * 2**(ref_exp - GUARD))
//   fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])       // across groups
//   out16[p]    = RNE16(fp_acc32[p])                   // once, at dot_last
//
// Three things this does not do, and why.
//
//   * The integer accumulator stays 32 bits.  Narrowing it is a different axis
//     (see rtl/*_acc16); this one prices dequantization, so everything ahead of
//     the group boundary must stay bit-identical to the base build.
//   * The cross-group sum is held as FP32 state inside the PCU and rounded to
//     the output format exactly once, at dot_last_i.  Emitting a partial result
//     per group would increase the traffic this design exists to reduce.
//   * There is no requantization stage and no second scale.  AWQ activations
//     are already bfloat16/binary16, so the output format is the input format
//     of the next layer and the weight group scale is the only scale.
//
// Assumption on i_ref_exp: software holds the block exponent constant across a
// weight group, so one value sampled on the accepted group_last_i transfer
// describes every tile in that group.  Software already chooses i_ref_exp per
// block; this narrows that to "per block, and the block does not straddle a
// group boundary".
//
// Throughput.  The engine is one lane at II=1.  With group size 128 and four
// lanes per PE a group boundary arrives every 32 accepted tiles, while a batch
// costs NUM_PES issue cycles: 8 or 16.  Two snapshot slots decouple the
// non-stallable raw pipeline from the engine, exactly as
// rtl/3_p3llm_dequant_rne/p3llm_pcu_dequant.sv does.
//
// The raw o_acc bus is retained, as rtl/4_rabit_dequant_rne retains its raw
// drain: the row is meant to be comparable against the base build.
module int4float_pcu_dq #(
    parameter integer EXP_W   = 8,   // activation/scale format: 8 = bfloat16
    parameter integer MANT_W  = 7,   //                          7 = bfloat16
    parameter integer GUARD   = 8,
    parameter integer NUM_PES = 8
) (
    input  logic         clk,
    input  logic         rst_n,

    // ---- raw PCU port -------------------------------------------------
    input  logic         i_valid,
    output logic         i_ready,
    input  logic         i_acc_clear,
    input  logic         i_acc_enable,
    input  logic [63:0]  i_act,
    input  logic signed [9:0] i_ref_exp,
    input  logic [NUM_PES*16-1:0] i_weight_q,
    input  logic [NUM_PES*4-1:0]  i_weight_zp,

    output logic         o_valid,
    output logic [NUM_PES*32-1:0] o_acc,
    output logic         o_saturate,
    output logic         o_invalid,

    // ---- dequantization port ------------------------------------------
    // Sampled only on an accepted transfer with i_group_last asserted.
    input  logic         i_group_last,
    input  logic [NUM_PES*16-1:0] i_scale,
    input  logic         i_fp_acc_clear,
    input  logic         i_dot_last,

    output logic         o_result_valid,
    input  logic         i_result_ready,
    output logic [NUM_PES*16-1:0] o_result,

    output logic         o_busy,
    // [0] invalid  [1] overflow  [2] underflow  [3] protocol error
    output logic [3:0]   o_status_sticky
);

    localparam int unsigned NUM_SLOTS      = 2;
    localparam int unsigned RAW_TAG_DEPTH  = 8;
    localparam int unsigned PIPE_TAG_DEPTH = 32;

    localparam int unsigned PE_W  = (NUM_PES > 1) ? $clog2(NUM_PES) : 1;
    localparam int unsigned CNT_W = $clog2(NUM_PES) + 1;

    localparam logic [1:0] SLOT_FREE     = 2'b00;
    localparam logic [1:0] SLOT_RESERVED = 2'b01;
    localparam logic [1:0] SLOT_FULL     = 2'b10;
    localparam logic [1:0] SLOT_ACTIVE   = 2'b11;

    // ------------------------------------------------------------------------
    // Unmodified integer PCU
    // ------------------------------------------------------------------------
    logic                     raw_pcu_in_ready;
    logic                     raw_pcu_out_valid;
    logic [NUM_PES*32-1:0]    raw_pcu_acc_out;
    logic                     accepted_fire;

    int4float_pcu #(
        .EXP_W   (EXP_W),
        .MANT_W  (MANT_W),
        .GUARD   (GUARD),
        .NUM_PES (NUM_PES)
    ) u_raw_pcu (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_valid      (accepted_fire),
        .i_ready      (raw_pcu_in_ready),
        .i_acc_clear  (i_acc_clear),
        .i_acc_enable (i_acc_enable),
        .i_act        (i_act),
        .i_ref_exp    (i_ref_exp),
        .i_weight_q   (i_weight_q),
        .i_weight_zp  (i_weight_zp),
        .o_valid      (raw_pcu_out_valid),
        .o_acc        (raw_pcu_acc_out),
        .o_saturate   (o_saturate),
        .o_invalid    (o_invalid)
    );

    always_comb begin
        o_valid = raw_pcu_out_valid;
        o_acc   = raw_pcu_acc_out;
    end

    // ------------------------------------------------------------------------
    // Two reserved/full/active group snapshots and their in-order slot FIFO
    // ------------------------------------------------------------------------
    logic [1:0]         slot_state_q [0:NUM_SLOTS-1];
    logic signed [31:0] snapshot_fixed_q [0:NUM_SLOTS-1][0:NUM_PES-1];
    logic [NUM_PES*16-1:0] snapshot_scale_q [0:NUM_SLOTS-1];
    logic signed [11:0] snapshot_exp_off_q [0:NUM_SLOTS-1];
    logic               snapshot_fp_clear_q [0:NUM_SLOTS-1];
    logic               snapshot_dot_last_q [0:NUM_SLOTS-1];

    logic       slot_fifo_mem_q [0:NUM_SLOTS-1];
    logic       slot_fifo_rd_ptr_q;
    logic       slot_fifo_wr_ptr_q;
    logic [1:0] slot_fifo_count_q;
    logic       alloc_prefer_q;
    logic       alloc_available;
    logic       alloc_slot;
    logic       reserve_fire;

    // The block exponent scales the integer accumulator by 2**(ref_exp - GUARD);
    // int4float_align.v states that contract.
    logic signed [11:0] exp_offset_c;
    always_comb begin
        exp_offset_c = $signed({{2{i_ref_exp[9]}}, i_ref_exp}) -
                       $signed(12'(GUARD));
    end

    always_comb begin
        alloc_available = 1'b0;
        alloc_slot      = alloc_prefer_q;
        if (slot_state_q[alloc_prefer_q] == SLOT_FREE) begin
            alloc_available = 1'b1;
            alloc_slot      = alloc_prefer_q;
        end else if (slot_state_q[~alloc_prefer_q] == SLOT_FREE) begin
            alloc_available = 1'b1;
            alloc_slot      = ~alloc_prefer_q;
        end
    end

    // ------------------------------------------------------------------------
    // Raw-PCU tag FIFO.  Every accepted tile receives a tag; only a group-last
    // tag owns a snapshot slot.  Capture happens directly on
    // raw_pcu_out_valid: the raw pipeline cannot be stalled, and inserting a
    // pending register would sample one accumulation late for back-to-back
    // groups.
    // ------------------------------------------------------------------------
    logic       raw_tag_group_q [0:RAW_TAG_DEPTH-1];
    logic       raw_tag_slot_q  [0:RAW_TAG_DEPTH-1];
    logic [2:0] raw_tag_rd_ptr_q;
    logic [2:0] raw_tag_wr_ptr_q;
    logic [3:0] raw_tag_count_q;
    logic       raw_tag_pop;
    logic       raw_tag_space;
    logic       snapshot_capture;
    logic       capture_slot;

    always_comb begin
        raw_tag_pop   = raw_pcu_out_valid && (raw_tag_count_q != 4'd0);
        raw_tag_space = (raw_tag_count_q < 4'd8) || raw_tag_pop;

        // A non-group tile needs only raw-tag capacity.  A group-ending tile
        // also reserves its snapshot at input acceptance, before it enters a
        // pipeline that cannot subsequently be stalled.
        i_ready = raw_pcu_in_ready && raw_tag_space &&
                  (!(i_valid && i_group_last) || alloc_available);
        accepted_fire = i_valid && i_ready;
        reserve_fire  = accepted_fire && i_group_last;

        snapshot_capture = raw_tag_pop && raw_tag_group_q[raw_tag_rd_ptr_q];
        capture_slot     = raw_tag_slot_q[raw_tag_rd_ptr_q];
    end

    // ------------------------------------------------------------------------
    // Shared fixed32 x float16 pipeline and its output-tag FIFO
    // ------------------------------------------------------------------------
    logic             batch_active_q;
    logic             active_slot_q;
    logic [CNT_W-1:0] issue_pe_q;
    logic [CNT_W-1:0] add_return_count_q;
    logic             start_batch;
    logic             batch_done;
    logic             head_slot;

    logic               mul_in_valid;
    logic signed [31:0] mul_fixed;
    logic [15:0]        mul_scale;
    logic signed [11:0] mul_exp_offset;
    logic               mul_out_valid;
    logic [31:0]        mul_fp32;
    logic               mul_invalid;
    logic               mul_overflow;
    logic               mul_underflow;

    logic [PE_W-1:0] mul_tag_pe_q       [0:PIPE_TAG_DEPTH-1];
    logic            mul_tag_clear_q    [0:PIPE_TAG_DEPTH-1];
    logic            mul_tag_dot_last_q [0:PIPE_TAG_DEPTH-1];
    logic [4:0]      mul_tag_rd_ptr_q;
    logic [4:0]      mul_tag_wr_ptr_q;
    logic [5:0]      mul_tag_count_q;
    logic            mul_tag_pop;
    logic            mul_tag_space;

    logic pack_batch_busy_q;

    always_comb begin
        head_slot = slot_fifo_mem_q[slot_fifo_rd_ptr_q];
        // A dot-last batch may not start while a result vector is still
        // unclaimed, because the pack stage writes into that vector.
        start_batch = !batch_active_q && (slot_fifo_count_q != 2'd0) &&
                      (slot_state_q[head_slot] == SLOT_FULL) &&
                      (!snapshot_dot_last_q[head_slot] ||
                       (!o_result_valid && !pack_batch_busy_q));

        mul_tag_pop   = mul_out_valid && (mul_tag_count_q != 6'd0);
        mul_tag_space = (mul_tag_count_q < 6'd32) || mul_tag_pop;
        mul_in_valid  = batch_active_q &&
                        (issue_pe_q < CNT_W'(NUM_PES)) && mul_tag_space;
        mul_fixed      = snapshot_fixed_q[active_slot_q][issue_pe_q[PE_W-1:0]];
        mul_scale      = snapshot_scale_q[active_slot_q]
                            [issue_pe_q[PE_W-1:0]*16 +: 16];
        mul_exp_offset = snapshot_exp_off_q[active_slot_q];
    end

    awq_dq_fixed32_float16_mul_pipe #(
        .SCALE_EXP_W  (EXP_W),
        .SCALE_MANT_W (MANT_W)
    ) u_scale_mul (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid_i   (mul_in_valid),
        .fixed_i      (mul_fixed),
        .scale_i      (mul_scale),
        .exp_offset_i (mul_exp_offset),
        .out_valid_o  (mul_out_valid),
        .fp32_o       (mul_fp32),
        .invalid_o    (mul_invalid),
        .overflow_o   (mul_overflow),
        .underflow_o  (mul_underflow)
    );

    // ------------------------------------------------------------------------
    // Shared FP32 adder and its tag FIFO.  i_fp_acc_clear selects +0.0 as the
    // first operand, overwriting every logical accumulator lane.
    // ------------------------------------------------------------------------
    logic [31:0] fp_acc_q [0:NUM_PES-1];
    logic        add_in_valid;
    logic [31:0] add_a;
    logic [31:0] add_b;
    logic        add_out_valid;
    logic [31:0] add_result;
    logic        add_invalid;
    logic        add_overflow;
    logic        add_underflow;

    logic [PE_W-1:0] add_tag_pe_q       [0:PIPE_TAG_DEPTH-1];
    logic            add_tag_dot_last_q [0:PIPE_TAG_DEPTH-1];
    logic [4:0]      add_tag_rd_ptr_q;
    logic [4:0]      add_tag_wr_ptr_q;
    logic [5:0]      add_tag_count_q;
    logic            add_tag_pop;

    always_comb begin
        add_in_valid = mul_out_valid && (mul_tag_count_q != 6'd0);
        add_a = mul_tag_clear_q[mul_tag_rd_ptr_q]
              ? 32'h0000_0000
              : fp_acc_q[mul_tag_pe_q[mul_tag_rd_ptr_q]];
        add_b = mul_fp32;
        add_tag_pop = add_out_valid && (add_tag_count_q != 6'd0);
        batch_done  = add_tag_pop &&
                      (add_return_count_q == CNT_W'(NUM_PES - 1));
    end

    awq_dq_fp32_add_pipe u_fp_acc_add (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid_i  (add_in_valid),
        .a_i         (add_a),
        .b_i         (add_b),
        .out_valid_o (add_out_valid),
        .result_o    (add_result),
        .invalid_o   (add_invalid),
        .overflow_o  (add_overflow),
        .underflow_o (add_underflow)
    );

    // ------------------------------------------------------------------------
    // Shared final RNE pack pipeline
    // ------------------------------------------------------------------------
    logic [CNT_W-1:0] pack_return_count_q;
    logic             pack_in_valid;
    logic [31:0]      pack_fp32;
    logic             pack_out_valid;
    logic [15:0]      pack_float16;
    logic             pack_invalid;
    logic             pack_overflow;
    logic             pack_underflow;

    logic [PE_W-1:0] pack_tag_pe_q [0:PIPE_TAG_DEPTH-1];
    logic [4:0]      pack_tag_rd_ptr_q;
    logic [4:0]      pack_tag_wr_ptr_q;
    logic [5:0]      pack_tag_count_q;
    logic            pack_tag_pop;

    always_comb begin
        pack_in_valid = add_out_valid && (add_tag_count_q != 6'd0) &&
                        add_tag_dot_last_q[add_tag_rd_ptr_q];
        pack_fp32     = add_result;
        pack_tag_pop  = pack_out_valid && (pack_tag_count_q != 6'd0);
    end

    awq_dq_fp32_pack_pipe #(
        .EXP_W  (EXP_W),
        .MANT_W (MANT_W)
    ) u_final_pack (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid_i  (pack_in_valid),
        .fp32_i      (pack_fp32),
        .out_valid_o (pack_out_valid),
        .float16_o   (pack_float16),
        .invalid_o   (pack_invalid),
        .overflow_o  (pack_overflow),
        .underflow_o (pack_underflow)
    );

    logic [NUM_PES*16-1:0] result_q;

    always_comb begin
        o_result = result_q;
        o_busy   = (slot_fifo_count_q != 2'd0) || batch_active_q ||
                   (raw_tag_count_q != 4'd0) ||
                   (mul_tag_count_q != 6'd0) ||
                   (add_tag_count_q != 6'd0) ||
                   pack_batch_busy_q || (pack_tag_count_q != 6'd0) ||
                   o_result_valid;
    end

    // ------------------------------------------------------------------------
    // Sequential state
    // ------------------------------------------------------------------------
    integer slot_index;
    integer pe_index;
    integer raw_tag_index;
    integer fp_acc_index;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot_fifo_rd_ptr_q <= 1'b0;
            slot_fifo_wr_ptr_q <= 1'b0;
            slot_fifo_count_q  <= 2'd0;
            alloc_prefer_q     <= 1'b0;
            for (slot_index = 0;
                 slot_index < NUM_SLOTS;
                 slot_index = slot_index + 1) begin
                slot_state_q[slot_index]        <= SLOT_FREE;
                snapshot_scale_q[slot_index]    <= {(NUM_PES*16){1'b0}};
                snapshot_exp_off_q[slot_index]  <= 12'sd0;
                snapshot_fp_clear_q[slot_index] <= 1'b0;
                snapshot_dot_last_q[slot_index] <= 1'b0;
                slot_fifo_mem_q[slot_index]     <= 1'b0;
                for (pe_index = 0;
                     pe_index < NUM_PES;
                     pe_index = pe_index + 1) begin
                    snapshot_fixed_q[slot_index][pe_index] <= 32'sd0;
                end
            end
        end else begin
            if (reserve_fire) begin
                slot_state_q[alloc_slot]        <= SLOT_RESERVED;
                snapshot_scale_q[alloc_slot]    <= i_scale;
                snapshot_exp_off_q[alloc_slot]  <= exp_offset_c;
                snapshot_fp_clear_q[alloc_slot] <= i_fp_acc_clear;
                snapshot_dot_last_q[alloc_slot] <= i_dot_last;
                slot_fifo_mem_q[slot_fifo_wr_ptr_q] <= alloc_slot;
                slot_fifo_wr_ptr_q              <= slot_fifo_wr_ptr_q + 1'b1;
                alloc_prefer_q                  <= ~alloc_slot;
            end

            if (snapshot_capture) begin
                slot_state_q[capture_slot] <= SLOT_FULL;
                for (pe_index = 0;
                     pe_index < NUM_PES;
                     pe_index = pe_index + 1) begin
                    snapshot_fixed_q[capture_slot][pe_index] <=
                        $signed(raw_pcu_acc_out[pe_index*32 +: 32]);
                end
            end

            if (start_batch) begin
                slot_state_q[head_slot] <= SLOT_ACTIVE;
            end

            if (batch_done) begin
                slot_state_q[active_slot_q] <= SLOT_FREE;
                slot_fifo_rd_ptr_q <= slot_fifo_rd_ptr_q + 1'b1;
            end

            case ({reserve_fire, batch_done})
                2'b10:   slot_fifo_count_q <= slot_fifo_count_q + 2'd1;
                2'b01:   slot_fifo_count_q <= slot_fifo_count_q - 2'd1;
                default: slot_fifo_count_q <= slot_fifo_count_q;
            endcase
        end
    end

    // Raw-PCU input/output tag FIFO.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            raw_tag_rd_ptr_q <= 3'd0;
            raw_tag_wr_ptr_q <= 3'd0;
            raw_tag_count_q  <= 4'd0;
            for (raw_tag_index = 0;
                 raw_tag_index < RAW_TAG_DEPTH;
                 raw_tag_index = raw_tag_index + 1) begin
                raw_tag_group_q[raw_tag_index] <= 1'b0;
                raw_tag_slot_q[raw_tag_index]  <= 1'b0;
            end
        end else begin
            if (accepted_fire) begin
                raw_tag_group_q[raw_tag_wr_ptr_q] <= i_group_last;
                raw_tag_slot_q[raw_tag_wr_ptr_q]  <= alloc_slot;
                raw_tag_wr_ptr_q <= raw_tag_wr_ptr_q + 3'd1;
            end
            if (raw_tag_pop) begin
                raw_tag_rd_ptr_q <= raw_tag_rd_ptr_q + 3'd1;
            end
            case ({accepted_fire, raw_tag_pop})
                2'b10:   raw_tag_count_q <= raw_tag_count_q + 4'd1;
                2'b01:   raw_tag_count_q <= raw_tag_count_q - 4'd1;
                default: raw_tag_count_q <= raw_tag_count_q;
            endcase
        end
    end

    // Batch issue and completion accounting.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            batch_active_q     <= 1'b0;
            active_slot_q      <= 1'b0;
            issue_pe_q         <= {CNT_W{1'b0}};
            add_return_count_q <= {CNT_W{1'b0}};
        end else begin
            if (start_batch) begin
                batch_active_q     <= 1'b1;
                active_slot_q      <= head_slot;
                issue_pe_q         <= {CNT_W{1'b0}};
                add_return_count_q <= {CNT_W{1'b0}};
            end
            if (mul_in_valid) begin
                issue_pe_q <= issue_pe_q + CNT_W'(1);
            end
            if (add_tag_pop) begin
                if (add_return_count_q == CNT_W'(NUM_PES - 1)) begin
                    add_return_count_q <= {CNT_W{1'b0}};
                    batch_active_q     <= 1'b0;
                end else begin
                    add_return_count_q <= add_return_count_q + CNT_W'(1);
                end
            end
        end
    end

    // Multiplier output tags.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mul_tag_rd_ptr_q <= 5'd0;
            mul_tag_wr_ptr_q <= 5'd0;
            mul_tag_count_q  <= 6'd0;
        end else begin
            if (mul_in_valid) begin
                mul_tag_pe_q[mul_tag_wr_ptr_q] <= issue_pe_q[PE_W-1:0];
                mul_tag_clear_q[mul_tag_wr_ptr_q] <=
                    snapshot_fp_clear_q[active_slot_q];
                mul_tag_dot_last_q[mul_tag_wr_ptr_q] <=
                    snapshot_dot_last_q[active_slot_q];
                mul_tag_wr_ptr_q <= mul_tag_wr_ptr_q + 5'd1;
            end
            if (mul_tag_pop) begin
                mul_tag_rd_ptr_q <= mul_tag_rd_ptr_q + 5'd1;
            end
            case ({mul_in_valid, mul_tag_pop})
                2'b10:   mul_tag_count_q <= mul_tag_count_q + 6'd1;
                2'b01:   mul_tag_count_q <= mul_tag_count_q - 6'd1;
                default: mul_tag_count_q <= mul_tag_count_q;
            endcase
        end
    end

    // Adder output tags and logical FP32 accumulator writes.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            add_tag_rd_ptr_q <= 5'd0;
            add_tag_wr_ptr_q <= 5'd0;
            add_tag_count_q  <= 6'd0;
            for (fp_acc_index = 0;
                 fp_acc_index < NUM_PES;
                 fp_acc_index = fp_acc_index + 1) begin
                fp_acc_q[fp_acc_index] <= 32'd0;
            end
        end else begin
            if (add_in_valid) begin
                add_tag_pe_q[add_tag_wr_ptr_q] <=
                    mul_tag_pe_q[mul_tag_rd_ptr_q];
                add_tag_dot_last_q[add_tag_wr_ptr_q] <=
                    mul_tag_dot_last_q[mul_tag_rd_ptr_q];
                add_tag_wr_ptr_q <= add_tag_wr_ptr_q + 5'd1;
            end
            if (add_tag_pop) begin
                fp_acc_q[add_tag_pe_q[add_tag_rd_ptr_q]] <= add_result;
                add_tag_rd_ptr_q <= add_tag_rd_ptr_q + 5'd1;
            end
            case ({add_in_valid, add_tag_pop})
                2'b10:   add_tag_count_q <= add_tag_count_q + 6'd1;
                2'b01:   add_tag_count_q <= add_tag_count_q - 6'd1;
                default: add_tag_count_q <= add_tag_count_q;
            endcase
        end
    end

    // Final-pack tags, output vector, and ready/valid retention.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pack_tag_rd_ptr_q   <= 5'd0;
            pack_tag_wr_ptr_q   <= 5'd0;
            pack_tag_count_q    <= 6'd0;
            pack_batch_busy_q   <= 1'b0;
            pack_return_count_q <= {CNT_W{1'b0}};
            result_q            <= {(NUM_PES*16){1'b0}};
            o_result_valid      <= 1'b0;
        end else begin
            if (o_result_valid && i_result_ready) begin
                o_result_valid <= 1'b0;
            end

            if (start_batch && snapshot_dot_last_q[head_slot]) begin
                pack_batch_busy_q   <= 1'b1;
                pack_return_count_q <= {CNT_W{1'b0}};
                result_q            <= {(NUM_PES*16){1'b0}};
            end

            if (pack_in_valid) begin
                pack_tag_pe_q[pack_tag_wr_ptr_q] <=
                    add_tag_pe_q[add_tag_rd_ptr_q];
                pack_tag_wr_ptr_q <= pack_tag_wr_ptr_q + 5'd1;
            end

            if (pack_tag_pop) begin
                result_q[pack_tag_pe_q[pack_tag_rd_ptr_q]*16 +: 16] <=
                    pack_float16;
                pack_tag_rd_ptr_q <= pack_tag_rd_ptr_q + 5'd1;
                if (pack_return_count_q == CNT_W'(NUM_PES - 1)) begin
                    pack_return_count_q <= {CNT_W{1'b0}};
                    pack_batch_busy_q   <= 1'b0;
                    o_result_valid      <= 1'b1;
                end else begin
                    pack_return_count_q <= pack_return_count_q + CNT_W'(1);
                end
            end

            case ({pack_in_valid, pack_tag_pop})
                2'b10:   pack_tag_count_q <= pack_tag_count_q + 6'd1;
                2'b01:   pack_tag_count_q <= pack_tag_count_q - 6'd1;
                default: pack_tag_count_q <= pack_tag_count_q;
            endcase
        end
    end

    // Sticky status.  Arithmetic exceptions are qualified by the corresponding
    // pipeline valid.  Protocol errors should be unreachable in legal
    // ready/valid use, but remain visible in silicon experiments.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            o_status_sticky <= 4'b0000;
        end else begin
            if ((mul_out_valid  && mul_invalid) ||
                (add_out_valid  && add_invalid) ||
                (pack_out_valid && pack_invalid)) begin
                o_status_sticky[0] <= 1'b1;
            end
            if ((mul_out_valid  && mul_overflow) ||
                (add_out_valid  && add_overflow) ||
                (pack_out_valid && pack_overflow)) begin
                o_status_sticky[1] <= 1'b1;
            end
            if ((mul_out_valid  && mul_underflow) ||
                (add_out_valid  && add_underflow) ||
                (pack_out_valid && pack_underflow)) begin
                o_status_sticky[2] <= 1'b1;
            end
            if ((raw_pcu_out_valid && (raw_tag_count_q == 4'd0)) ||
                (snapshot_capture &&
                 (slot_state_q[capture_slot] != SLOT_RESERVED)) ||
                (mul_out_valid  && (mul_tag_count_q  == 6'd0)) ||
                (add_out_valid  && (add_tag_count_q  == 6'd0)) ||
                (pack_out_valid && (pack_tag_count_q == 6'd0)) ||
                (reserve_fire && !alloc_available) ||
                (slot_fifo_count_q > 2'd2) ||
                (mul_tag_count_q  > 6'd32) ||
                (add_tag_count_q  > 6'd32) ||
                (pack_tag_count_q > 6'd32)) begin
                o_status_sticky[3] <= 1'b1;
            end
        end
    end

`ifdef AWQ_DQ_ASSERTIONS
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(accepted_fire && i_group_last && !alloc_available))
                else $error("int4float_pcu_dq: group end accepted without slot");
            assert (!(raw_pcu_out_valid && (raw_tag_count_q == 4'd0)))
                else $error("int4float_pcu_dq: raw output tag underflow");
            assert (!(mul_out_valid && (mul_tag_count_q == 6'd0)))
                else $error("int4float_pcu_dq: multiplier tag underflow");
            assert (!(add_out_valid && (add_tag_count_q == 6'd0)))
                else $error("int4float_pcu_dq: adder tag underflow");
            assert (!(pack_out_valid && (pack_tag_count_q == 6'd0)))
                else $error("int4float_pcu_dq: pack tag underflow");
            if (snapshot_capture) begin
                assert (slot_state_q[capture_slot] == SLOT_RESERVED)
                    else $error("int4float_pcu_dq: snapshot slot state mismatch");
            end
        end
    end

    logic                  result_stalled_q;
    logic [NUM_PES*16-1:0] result_hold_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_stalled_q <= 1'b0;
            result_hold_q    <= {(NUM_PES*16){1'b0}};
        end else begin
            if (result_stalled_q) begin
                assert (result_q == result_hold_q)
                    else $error("int4float_pcu_dq: result changed while stalled");
            end
            result_stalled_q <= o_result_valid && !i_result_ready;
            result_hold_q    <= result_q;
        end
    end
`endif
`endif

endmodule
