// P3-LLM PCU with a shared post-MAC dequantization datapath.
//
// The existing 16-PE integer PCU remains unchanged.  A group-ending integer
// vector is copied into one of two snapshot slots, then serialized at one PE
// per cycle through a shared fixed32*FP16 multiplier and FP32 adder.  The
// logical FP32 accumulator remains spatial (one register per PE), while the
// arithmetic is shared.  On the last group of a dot product, the updated FP32
// values are multiplied by a common FP16 scale and packed to FP16.
//
// All scale and group controls are sampled only on an accepted group_last_i
// transfer.  The raw-PCU and floating-point pipeline tags use FIFOs, rather
// than hard-coded latency constants, so they follow the corresponding
// out_valid signals.
module p3llm_pcu_dequant (
  input  logic          clk,
  input  logic          rst_n,

  input  logic          in_valid_i,
  output logic          in_ready_o,
  input  logic [1:0]    op_mode_i,
  input  logic          acc_clear_i,
  input  logic          acc_enable_i,
  input  logic [31:0]   input_fp8_i,
  input  logic [255:0]  rhs_q4_i,
  input  logic [31:0]   bitmod_special_sel_i,
  input  logic [63:0]   zp_by_pe_i,
  input  logic [15:0]   zp_by_lane_i,

  // These controls and scales are meaningful on an accepted group_last_i.
  input  logic          group_last_i,
  input  logic          fp_acc_clear_i,
  input  logic          dot_last_i,
  input  logic [255:0]  vector_scale_by_pe_i,
  input  logic [15:0]   final_scale_i,

  output logic          raw_out_valid_o,
  output logic [511:0]  raw_acc_out_o,

  output logic          result_valid_o,
  input  logic          result_ready_i,
  output logic [255:0]  fp16_out_o,

  // Observability and sticky arithmetic/protocol status.
  output logic [511:0]  fp32_acc_debug_o,
  output logic          busy_o,
  output logic          status_invalid_o,
  output logic          status_overflow_o,
  output logic          status_underflow_o,
  output logic          status_protocol_error_o
);

  import p3llm_pkg::*;

  localparam int unsigned NUM_PES        = 16;
  localparam int unsigned NUM_SLOTS      = 2;
  localparam int unsigned RAW_TAG_DEPTH  = 8;
  localparam int unsigned PIPE_TAG_DEPTH = 32;

  localparam logic [1:0] SLOT_FREE     = 2'b00;
  localparam logic [1:0] SLOT_RESERVED = 2'b01;
  localparam logic [1:0] SLOT_FULL     = 2'b10;
  localparam logic [1:0] SLOT_ACTIVE   = 2'b11;

  function automatic logic signed [6:0] binary_exponent_for_mode(
    input logic [1:0] mode
  );
    case (mode)
      OP_LINEAR: binary_exponent_for_mode = -7'sd12;
      OP_QK:     binary_exponent_for_mode = -7'sd11;
      OP_PV:     binary_exponent_for_mode = -7'sd19;
      default:   binary_exponent_for_mode =  7'sd0;
    endcase
  endfunction

  // ------------------------------------------------------------------------
  // Unmodified integer PCU
  // ------------------------------------------------------------------------
  logic         raw_pcu_in_ready;
  logic         raw_pcu_out_valid;
  logic [511:0] raw_pcu_acc_out;
  logic         accepted_fire;

  p3llm_pcu u_raw_pcu (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .in_valid               (accepted_fire),
    .in_ready               (raw_pcu_in_ready),
    .op_mode                (op_mode_i),
    .acc_clear              (acc_clear_i),
    .acc_enable             (acc_enable_i),
    .input_fp8              (input_fp8_i),
    .rhs_q4                 (rhs_q4_i),
    .bitmod_special_sel     (bitmod_special_sel_i),
    .zp_by_pe               (zp_by_pe_i),
    .zp_by_lane             (zp_by_lane_i),
    .out_valid              (raw_pcu_out_valid),
    .acc_out                (raw_pcu_acc_out)
  );

  always_comb begin
    raw_out_valid_o = raw_pcu_out_valid;
    raw_acc_out_o   = raw_pcu_acc_out;
  end

  // ------------------------------------------------------------------------
  // Two reserved/full/active group snapshots and their in-order slot FIFO
  // ------------------------------------------------------------------------
  logic [1:0] slot_state_q [0:NUM_SLOTS-1];
  logic signed [31:0] snapshot_fixed_q
    [0:NUM_SLOTS-1][0:NUM_PES-1];
  logic [255:0] snapshot_vector_scale_q [0:NUM_SLOTS-1];
  logic [15:0]  snapshot_final_scale_q  [0:NUM_SLOTS-1];
  logic [1:0]   snapshot_mode_q         [0:NUM_SLOTS-1];
  logic         snapshot_fp_clear_q     [0:NUM_SLOTS-1];
  logic         snapshot_dot_last_q     [0:NUM_SLOTS-1];

  logic slot_fifo_mem_q [0:NUM_SLOTS-1];
  logic slot_fifo_rd_ptr_q;
  logic slot_fifo_wr_ptr_q;
  logic [1:0] slot_fifo_count_q;
  logic alloc_prefer_q;
  logic alloc_available;
  logic alloc_slot;
  logic reserve_fire;

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
  // tag owns a snapshot slot.  Direct capture on raw_pcu_out_valid is
  // intentional: adding a capture_pending register would sample one integer
  // accumulation later for back-to-back groups.
  // ------------------------------------------------------------------------
  logic raw_tag_group_q [0:RAW_TAG_DEPTH-1];
  logic raw_tag_slot_q  [0:RAW_TAG_DEPTH-1];
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

    // A non-group tile needs only raw-tag capacity.  A group-ending tile also
    // reserves its snapshot at input acceptance, before it enters a pipeline
    // that cannot subsequently be stalled.
    in_ready_o = raw_pcu_in_ready && raw_tag_space &&
                 (!(in_valid_i && group_last_i) || alloc_available);
    accepted_fire = in_valid_i && in_ready_o;
    reserve_fire  = accepted_fire && group_last_i;

    snapshot_capture = raw_tag_pop &&
                       raw_tag_group_q[raw_tag_rd_ptr_q];
    capture_slot = raw_tag_slot_q[raw_tag_rd_ptr_q];
  end

  // ------------------------------------------------------------------------
  // Shared fixed32 * FP16 pipeline and output-tag FIFO
  // ------------------------------------------------------------------------
  logic         batch_active_q;
  logic         active_slot_q;
  logic [4:0]   issue_pe_q;
  logic [4:0]   add_return_count_q;
  logic         start_batch;
  logic         batch_done;
  logic         head_slot;

  logic                       mul_in_valid;
  logic signed [31:0]         mul_fixed;
  logic [15:0]                mul_scale;
  logic signed [6:0]          mul_binary_exp;
  logic                       mul_out_valid;
  logic [31:0]                mul_fp32;
  logic                       mul_invalid;
  logic                       mul_overflow;
  logic                       mul_underflow;

  logic [3:0]  mul_tag_pe_q          [0:PIPE_TAG_DEPTH-1];
  logic        mul_tag_clear_q       [0:PIPE_TAG_DEPTH-1];
  logic        mul_tag_dot_last_q    [0:PIPE_TAG_DEPTH-1];
  logic [15:0] mul_tag_final_scale_q [0:PIPE_TAG_DEPTH-1];
  logic [4:0]  mul_tag_rd_ptr_q;
  logic [4:0]  mul_tag_wr_ptr_q;
  logic [5:0]  mul_tag_count_q;
  logic        mul_tag_pop;
  logic        mul_tag_space;

  always_comb begin
    head_slot = slot_fifo_mem_q[slot_fifo_rd_ptr_q];
    start_batch = !batch_active_q && (slot_fifo_count_q != 2'd0) &&
                  (slot_state_q[head_slot] == SLOT_FULL) &&
                  (!snapshot_dot_last_q[head_slot] ||
                   (!result_valid_o && !pack_batch_busy_q));

    mul_tag_pop   = mul_out_valid && (mul_tag_count_q != 6'd0);
    mul_tag_space = (mul_tag_count_q < 6'd32) || mul_tag_pop;
    mul_in_valid  = batch_active_q && (issue_pe_q < 5'd16) &&
                    mul_tag_space;
    mul_fixed = snapshot_fixed_q[active_slot_q][issue_pe_q[3:0]];
    mul_scale = snapshot_vector_scale_q[active_slot_q]
      [issue_pe_q[3:0]*16 +: 16];
    mul_binary_exp = binary_exponent_for_mode(
      snapshot_mode_q[active_slot_q]
    );
  end

  p3llm_dequant_fixed32_fp16_mul_pipe u_fixed_scale_mul (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid_i   (mul_in_valid),
    .fixed_i      (mul_fixed),
    .scale_i      (mul_scale),
    .binary_exp_i (mul_binary_exp),
    .out_valid_o  (mul_out_valid),
    .fp32_o       (mul_fp32),
    .invalid_o    (mul_invalid),
    .overflow_o   (mul_overflow),
    .underflow_o  (mul_underflow)
  );

  // ------------------------------------------------------------------------
  // Shared FP32 adder and its tag FIFO.  fp_acc_clear_i selects +0.0 as the
  // first operand, overwriting all sixteen logical accumulator lanes.
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

  logic [3:0]  add_tag_pe_q          [0:PIPE_TAG_DEPTH-1];
  logic        add_tag_dot_last_q    [0:PIPE_TAG_DEPTH-1];
  logic [15:0] add_tag_final_scale_q [0:PIPE_TAG_DEPTH-1];
  logic [4:0]  add_tag_rd_ptr_q;
  logic [4:0]  add_tag_wr_ptr_q;
  logic [5:0]  add_tag_count_q;
  logic        add_tag_pop;

  always_comb begin
    add_in_valid = mul_out_valid && (mul_tag_count_q != 6'd0);
    add_a = mul_tag_clear_q[mul_tag_rd_ptr_q]
      ? 32'h0000_0000
      : fp_acc_q[mul_tag_pe_q[mul_tag_rd_ptr_q]];
    add_b = mul_fp32;
    add_tag_pop = add_out_valid && (add_tag_count_q != 6'd0);
    batch_done = add_tag_pop && (add_return_count_q == 5'd15);
  end

  p3llm_dequant_fp32_add_pipe u_fp_acc_add (
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
  // Shared final FP32 * FP16 scale and RNE FP16 pack pipeline
  // ------------------------------------------------------------------------
  logic        pack_batch_busy_q;
  logic [4:0]  pack_return_count_q;
  logic        pack_in_valid;
  logic [31:0] pack_fp32;
  logic [15:0] pack_scale;
  logic        pack_out_valid;
  logic [15:0] pack_fp16;
  logic        pack_invalid;
  logic        pack_overflow;
  logic        pack_underflow;

  logic [3:0] pack_tag_pe_q [0:PIPE_TAG_DEPTH-1];
  logic [4:0] pack_tag_rd_ptr_q;
  logic [4:0] pack_tag_wr_ptr_q;
  logic [5:0] pack_tag_count_q;
  logic       pack_tag_pop;

  always_comb begin
    pack_in_valid = add_out_valid && (add_tag_count_q != 6'd0) &&
                    add_tag_dot_last_q[add_tag_rd_ptr_q];
    pack_fp32 = add_result;
    pack_scale = add_tag_final_scale_q[add_tag_rd_ptr_q];
    pack_tag_pop = pack_out_valid && (pack_tag_count_q != 6'd0);
  end

  p3llm_dequant_fp32_fp16_mul_pack_pipe u_final_scale_pack (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_valid_i  (pack_in_valid),
    .fp32_i      (pack_fp32),
    .scale_i     (pack_scale),
    .out_valid_o (pack_out_valid),
    .fp16_o      (pack_fp16),
    .invalid_o   (pack_invalid),
    .overflow_o  (pack_overflow),
    .underflow_o (pack_underflow)
  );

  // Debug flattening and external state.
  integer debug_pe;
  always_comb begin
    for (debug_pe = 0; debug_pe < NUM_PES; debug_pe = debug_pe + 1) begin
      fp32_acc_debug_o[debug_pe*32 +: 32] = fp_acc_q[debug_pe];
    end
    fp16_out_o = fp16_result_q;
    busy_o = (slot_fifo_count_q != 2'd0) || batch_active_q ||
             (raw_tag_count_q != 4'd0) ||
             (mul_tag_count_q != 6'd0) ||
             (add_tag_count_q != 6'd0) ||
             pack_batch_busy_q || (pack_tag_count_q != 6'd0) ||
             result_valid_o;
  end

  logic [255:0] fp16_result_q;

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
        slot_state_q[slot_index]             <= SLOT_FREE;
        snapshot_vector_scale_q[slot_index]  <= 256'd0;
        snapshot_final_scale_q[slot_index]   <= 16'd0;
        snapshot_mode_q[slot_index]          <= OP_LINEAR;
        snapshot_fp_clear_q[slot_index]      <= 1'b0;
        snapshot_dot_last_q[slot_index]      <= 1'b0;
        slot_fifo_mem_q[slot_index]          <= 1'b0;
        for (pe_index = 0;
             pe_index < NUM_PES;
             pe_index = pe_index + 1) begin
          snapshot_fixed_q[slot_index][pe_index] <= 32'sd0;
        end
      end
    end else begin
      if (reserve_fire) begin
        slot_state_q[alloc_slot]            <= SLOT_RESERVED;
        snapshot_vector_scale_q[alloc_slot] <= vector_scale_by_pe_i;
        snapshot_final_scale_q[alloc_slot]  <= final_scale_i;
        snapshot_mode_q[alloc_slot]         <= op_mode_i;
        snapshot_fp_clear_q[alloc_slot]     <= fp_acc_clear_i;
        snapshot_dot_last_q[alloc_slot]     <= dot_last_i;
        slot_fifo_mem_q[slot_fifo_wr_ptr_q] <= alloc_slot;
        slot_fifo_wr_ptr_q                  <= slot_fifo_wr_ptr_q + 1'b1;
        alloc_prefer_q                      <= ~alloc_slot;
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
        2'b10: slot_fifo_count_q <= slot_fifo_count_q + 2'd1;
        2'b01: slot_fifo_count_q <= slot_fifo_count_q - 2'd1;
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
        raw_tag_group_q[raw_tag_wr_ptr_q] <= group_last_i;
        raw_tag_slot_q[raw_tag_wr_ptr_q]  <= alloc_slot;
        raw_tag_wr_ptr_q <= raw_tag_wr_ptr_q + 3'd1;
      end
      if (raw_tag_pop) begin
        raw_tag_rd_ptr_q <= raw_tag_rd_ptr_q + 3'd1;
      end
      case ({accepted_fire, raw_tag_pop})
        2'b10: raw_tag_count_q <= raw_tag_count_q + 4'd1;
        2'b01: raw_tag_count_q <= raw_tag_count_q - 4'd1;
        default: raw_tag_count_q <= raw_tag_count_q;
      endcase
    end
  end

  // Batch issue and completion accounting.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      batch_active_q      <= 1'b0;
      active_slot_q       <= 1'b0;
      issue_pe_q          <= 5'd0;
      add_return_count_q  <= 5'd0;
    end else begin
      if (start_batch) begin
        batch_active_q     <= 1'b1;
        active_slot_q      <= head_slot;
        issue_pe_q         <= 5'd0;
        add_return_count_q <= 5'd0;
      end
      if (mul_in_valid) begin
        issue_pe_q <= issue_pe_q + 5'd1;
      end
      if (add_tag_pop) begin
        if (add_return_count_q == 5'd15) begin
          add_return_count_q <= 5'd0;
          batch_active_q     <= 1'b0;
        end else begin
          add_return_count_q <= add_return_count_q + 5'd1;
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
        mul_tag_pe_q[mul_tag_wr_ptr_q] <= issue_pe_q[3:0];
        mul_tag_clear_q[mul_tag_wr_ptr_q] <=
          snapshot_fp_clear_q[active_slot_q];
        mul_tag_dot_last_q[mul_tag_wr_ptr_q] <=
          snapshot_dot_last_q[active_slot_q];
        mul_tag_final_scale_q[mul_tag_wr_ptr_q] <=
          snapshot_final_scale_q[active_slot_q];
        mul_tag_wr_ptr_q <= mul_tag_wr_ptr_q + 5'd1;
      end
      if (mul_tag_pop) begin
        mul_tag_rd_ptr_q <= mul_tag_rd_ptr_q + 5'd1;
      end
      case ({mul_in_valid, mul_tag_pop})
        2'b10: mul_tag_count_q <= mul_tag_count_q + 6'd1;
        2'b01: mul_tag_count_q <= mul_tag_count_q - 6'd1;
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
        add_tag_final_scale_q[add_tag_wr_ptr_q] <=
          mul_tag_final_scale_q[mul_tag_rd_ptr_q];
        add_tag_wr_ptr_q <= add_tag_wr_ptr_q + 5'd1;
      end
      if (add_tag_pop) begin
        fp_acc_q[add_tag_pe_q[add_tag_rd_ptr_q]] <= add_result;
        add_tag_rd_ptr_q <= add_tag_rd_ptr_q + 5'd1;
      end
      case ({add_in_valid, add_tag_pop})
        2'b10: add_tag_count_q <= add_tag_count_q + 6'd1;
        2'b01: add_tag_count_q <= add_tag_count_q - 6'd1;
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
      pack_return_count_q <= 5'd0;
      fp16_result_q       <= 256'd0;
      result_valid_o      <= 1'b0;
    end else begin
      if (result_valid_o && result_ready_i) begin
        result_valid_o <= 1'b0;
      end

      if (start_batch && snapshot_dot_last_q[head_slot]) begin
        pack_batch_busy_q   <= 1'b1;
        pack_return_count_q <= 5'd0;
        fp16_result_q       <= 256'd0;
      end

      if (pack_in_valid) begin
        pack_tag_pe_q[pack_tag_wr_ptr_q] <=
          add_tag_pe_q[add_tag_rd_ptr_q];
        pack_tag_wr_ptr_q <= pack_tag_wr_ptr_q + 5'd1;
      end

      if (pack_tag_pop) begin
        fp16_result_q[pack_tag_pe_q[pack_tag_rd_ptr_q]*16 +: 16] <=
          pack_fp16;
        pack_tag_rd_ptr_q <= pack_tag_rd_ptr_q + 5'd1;
        if (pack_return_count_q == 5'd15) begin
          pack_return_count_q <= 5'd0;
          pack_batch_busy_q   <= 1'b0;
          result_valid_o      <= 1'b1;
        end else begin
          pack_return_count_q <= pack_return_count_q + 5'd1;
        end
      end

      case ({pack_in_valid, pack_tag_pop})
        2'b10: pack_tag_count_q <= pack_tag_count_q + 6'd1;
        2'b01: pack_tag_count_q <= pack_tag_count_q - 6'd1;
        default: pack_tag_count_q <= pack_tag_count_q;
      endcase
    end
  end

  // Sticky status flags.  Arithmetic exceptions are qualified by the
  // corresponding pipeline valid.  Protocol errors should be unreachable in
  // legal ready/valid use, but remain visible in silicon experiments.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      status_invalid_o        <= 1'b0;
      status_overflow_o       <= 1'b0;
      status_underflow_o      <= 1'b0;
      status_protocol_error_o <= 1'b0;
    end else begin
      if (accepted_fire && !op_mode_is_valid(op_mode_i)) begin
        status_invalid_o <= 1'b1;
      end
      if ((mul_out_valid && mul_invalid) ||
          (add_out_valid && add_invalid) ||
          (pack_out_valid && pack_invalid)) begin
        status_invalid_o <= 1'b1;
      end
      if ((mul_out_valid && mul_overflow) ||
          (add_out_valid && add_overflow) ||
          (pack_out_valid && pack_overflow)) begin
        status_overflow_o <= 1'b1;
      end
      if ((mul_out_valid && mul_underflow) ||
          (add_out_valid && add_underflow) ||
          (pack_out_valid && pack_underflow)) begin
        status_underflow_o <= 1'b1;
      end

      if ((raw_pcu_out_valid && (raw_tag_count_q == 4'd0)) ||
          (snapshot_capture &&
           (slot_state_q[capture_slot] != SLOT_RESERVED)) ||
          (mul_out_valid && (mul_tag_count_q == 6'd0)) ||
          (add_out_valid && (add_tag_count_q == 6'd0)) ||
          (pack_out_valid && (pack_tag_count_q == 6'd0)) ||
          (reserve_fire && !alloc_available) ||
          (slot_fifo_count_q > 2'd2) ||
          (mul_tag_count_q > 6'd32) ||
          (add_tag_count_q > 6'd32) ||
          (pack_tag_count_q > 6'd32)) begin
        status_protocol_error_o <= 1'b1;
      end
    end
  end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (!(accepted_fire && group_last_i && !alloc_available))
        else $error("p3llm_pcu_dequant: group end accepted without slot");
      assert (!(raw_pcu_out_valid && (raw_tag_count_q == 4'd0)))
        else $error("p3llm_pcu_dequant: raw output tag underflow");
      assert (!(mul_out_valid && (mul_tag_count_q == 6'd0)))
        else $error("p3llm_pcu_dequant: multiplier tag underflow");
      assert (!(add_out_valid && (add_tag_count_q == 6'd0)))
        else $error("p3llm_pcu_dequant: adder tag underflow");
      assert (!(pack_out_valid && (pack_tag_count_q == 6'd0)))
        else $error("p3llm_pcu_dequant: pack tag underflow");
      if (snapshot_capture) begin
        assert (slot_state_q[capture_slot] == SLOT_RESERVED)
          else $error("p3llm_pcu_dequant: snapshot slot state mismatch");
      end
    end
  end

  logic         result_stalled_q;
  logic [255:0] result_hold_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      result_stalled_q <= 1'b0;
      result_hold_q    <= 256'd0;
    end else begin
      if (result_stalled_q) begin
        assert (fp16_result_q == result_hold_q)
          else $error("p3llm_pcu_dequant: result changed while stalled");
      end
      result_stalled_q <= result_valid_o && !result_ready_i;
      result_hold_q    <= fp16_result_q;
    end
  end
`endif
`endif

endmodule
