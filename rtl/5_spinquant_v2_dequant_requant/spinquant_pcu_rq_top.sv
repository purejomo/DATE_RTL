`timescale 1ns/1ps

// SpinQuant W4A4 PCU with PCU-local dequantization AND requantization (axis 4).
//
// This is the row that closes the loop. SpinQuant is the only design in this
// comparison whose activations are quantized, so it is the only one where
// "finish the postprocess inside the PIM" means a requantizer and not just a
// dequantizer. What leaves the PCU is unsigned INT4 -- the format the next
// layer's PCU reads -- so no host kernel touches the output row at all.
//
//     axis 1  rtl/5_spinquant                 INT32   32 bit/element
//     axis 2  rtl/5_spinquant_acc16           INT16   16 bit/element
//     axis 3  rtl/5_spinquant_dequant_rne     binary16 16 bit/element, host still quantizes
//     axis 4  this directory                  INT4     4 bit/element, host does nothing
//
// ---------------------------------------------------------------------------
// Numeric contract
// ---------------------------------------------------------------------------
//
// The dequantization half is rtl/5_spinquant_dequant_rne's, unchanged:
//
//     fixed[i] = acc[i] + bias_int[i]           bias_int[i] = -zp_a*sum(W_q_row[i])
//     fp32[i]  = RNE32(fixed[i] * s[i])         s[i] = s_w[i]*s_a
//
// and the requantization half is
//
//     A_q'[i]  = clamp( RNE(fp32[i] / s_a') + zp_a', 0, 15 )
//
// with the division folded into the scale the driver already supplies. That is
// the whole trick: in pass 2 the driver sends t[i] = s[i]/s_a' instead of s[i],
// so the multiply pipe produces fp32[i]/s_a' directly and the requantizer only
// has to round, offset and clamp. No second multiplier.
//
// ---------------------------------------------------------------------------
// Why two passes
// ---------------------------------------------------------------------------
//
// s_a' comes from per-token asymmetric min-max, so it needs the extreme values
// of the WHOLE output row. A PCU sees NLANE of them. This is a dataflow
// problem, not a width problem, and no amount of local hardware solves it.
//
//     pass 1   run the dequantization with s[i]; the PCU reduces its own lanes
//              to one min and one max and hands those two scalars over
//              (spinquant_rq_minmax). The NPU finishes the reduction across
//              banks, computes s_a' and zp_a', and forms t[i] = s[i]/s_a' and
//              bias_int[i] from data it already holds -- s_w, sum(W_q_row) and
//              the token scalars. No wide data moves.
//     pass 2   run it again with t[i]; the requantizer emits INT4.
//
// The accumulator file stays resident across a whole k sweep anyway, so holding
// it for one more pass costs no storage. The cost is 2 x NLANE issue cycles per
// drain instead of NLANE.
//
// The alternative -- a static per-layer activation scale, one pass -- is not
// implemented here. It abandons SpinQuant's per-token dynamic quantization and
// the accuracy that comes with it, and would be an ablation of a different
// algorithm rather than of this hardware.
//
// R4, the online Hadamard on the down_proj input, stays on the NPU. It applies
// to one of seven projections and rotating a vector inside the PCU is a
// different design question from the one this row asks.
//
// ---------------------------------------------------------------------------
// KEEP_FP16_OUT
// ---------------------------------------------------------------------------
//
// KEEP_FP16_OUT retains the axis-3 FP16 side output when required. The v2
// UINT4-only wrapper sets it to zero and removes that packer.
module spinquant_pcu_rq_top #(
    parameter int NPE            = 16,
    parameter int NWAY           = 4,
    parameter int NROW           = 1,
    parameter int NENTRY         = 4,
    parameter int ACC_W          = 32,
    parameter int ACC_CHAIN_W    = 24,
    parameter int W_LATCH        = 1,
    parameter int Q_W            = 4,
    parameter int SCALE_EXP_W    = 5,
    parameter int SCALE_MANT_W   = 10,
    parameter int OUT_EXP_W      = 5,
    parameter int OUT_MANT_W     = 10,
    parameter int KEEP_FP16_OUT  = 1,
    // derived; do not override
    parameter int WBEAT_W        = NPE*NWAY*Q_W,
    parameter int ABEAT_W        = NROW*NWAY*Q_W,
    parameter int NLANE          = NROW*NPE,
    parameter int SEL_W          = $clog2(NENTRY),
    parameter int ENT_W          = NLANE*ACC_W,
    parameter int LANE_W         = $clog2(NLANE),
    parameter int CNT_W          = LANE_W + 1
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---- raw port, passed straight through -----------------------------
    input  logic                w_load_i,
    input  logic [WBEAT_W-1:0]  w_beat_i,
    input  logic                mac_valid_i,
    input  logic [ABEAT_W-1:0]  a_q4_i,
    input  logic [SEL_W-1:0]    acc_entry_i,
    input  logic                acc_clear_i,
    output logic                mac_done_o,
    input  logic [SEL_W-1:0]    drain_entry_i,
    output logic [ENT_W-1:0]    drain_data_o,
    input  logic                status_clr_i,
    output logic                ovf_sticky_o,

    // ---- postprocess drain port ----------------------------------------
    //
    // One pass per request. The driver runs it twice, with the pass-1 and
    // pass-2 metadata; the engine itself does not distinguish the two.
    input  logic                dq_req_i,
    input  logic [SEL_W-1:0]    dq_entry_i,
    output logic                dq_busy_o,

    output logic                dq_issue_o,
    output logic [LANE_W-1:0]   dq_lane_o,
    input  logic [15:0]         dq_scale_i,     // s[i] in pass 1, t[i] in pass 2
    input  logic signed [31:0]  dq_bias_i,
    input  logic [4:0]          rq_zp_i,        // zp_a', pass 2 only

    // ---- pass-1 result: the two scalars the NPU reduces globally --------
    output logic [31:0]         mm_min_o,
    output logic [31:0]         mm_max_o,

    // ---- pass-2 result: the next layer's activation ---------------------
    output logic                y_valid_o,
    output logic [LANE_W-1:0]   y_lane_o,
    output logic [3:0]          y_q4_o,
    output logic [15:0]         y_fp16_o,       // zero when KEEP_FP16_OUT = 0

    // [0] invalid  [1] overflow  [2] underflow  [3] integer bias add overflow
    // [4] INT4 clamped  [5] INT4 input was inf or NaN
    output logic [5:0]          dq_status_sticky_o
);

    // ---- sequencer --------------------------------------------------------
    localparam logic [LANE_W-1:0] LAST_LANE = {LANE_W{1'b1}};
    localparam logic [CNT_W-1:0]  LAST_RET  = {1'b0, {LANE_W{1'b1}}};

    logic              issue_q;
    logic [LANE_W-1:0] issue_cnt_q;
    logic [SEL_W-1:0]  dq_entry_q;
    logic [CNT_W-1:0]  ret_cnt_q;
    logic              active_q;
    logic              start;

    logic last_issue;
    always_comb begin
        last_issue = issue_q && (issue_cnt_q == LAST_LANE);
        start      = !active_q && dq_req_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            issue_q     <= 1'b0;
            issue_cnt_q <= {LANE_W{1'b0}};
            dq_entry_q  <= {SEL_W{1'b0}};
            ret_cnt_q   <= {CNT_W{1'b0}};
            active_q    <= 1'b0;
        end else begin
            if (start) begin
                issue_q     <= 1'b1;
                issue_cnt_q <= {LANE_W{1'b0}};
                dq_entry_q  <= dq_entry_i;
                ret_cnt_q   <= {CNT_W{1'b0}};
                active_q    <= 1'b1;
            end else begin
                if (issue_q) begin
                    if (last_issue) begin
                        issue_q <= 1'b0;
                    end else begin
                        issue_cnt_q <= issue_cnt_q + LANE_W'(1);
                    end
                end
                if (y_valid_o) begin
                    if (ret_cnt_q == LAST_RET) begin
                        active_q  <= 1'b0;
                        ret_cnt_q <= {CNT_W{1'b0}};
                    end else begin
                        ret_cnt_q <= ret_cnt_q + CNT_W'(1);
                    end
                end
            end
        end
    end

    always_comb begin
        dq_issue_o = issue_q;
        dq_lane_o  = issue_cnt_q;
        dq_busy_o  = active_q;
        y_lane_o   = ret_cnt_q[LANE_W-1:0];
    end

    // ---- raw PCU ----------------------------------------------------------
    logic [SEL_W-1:0] drain_sel;
    always_comb drain_sel = active_q ? dq_entry_q : drain_entry_i;

    spinquant_pcu_top #(
        .NPE         (NPE),
        .NWAY        (NWAY),
        .NROW        (NROW),
        .NENTRY      (NENTRY),
        .ACC_W       (ACC_W),
        .ACC_CHAIN_W (ACC_CHAIN_W),
        .W_LATCH     (W_LATCH),
        .Q_W         (Q_W)
    ) u_raw (
        .clk           (clk),
        .rst_n         (rst_n),
        .w_load_i      (w_load_i),
        .w_beat_i      (w_beat_i),
        .mac_valid_i   (mac_valid_i),
        .a_q4_i        (a_q4_i),
        .acc_entry_i   (acc_entry_i),
        .acc_clear_i   (acc_clear_i),
        .mac_done_o    (mac_done_o),
        .drain_entry_i (drain_sel),
        .drain_data_o  (drain_data_o),
        .status_clr_i  (status_clr_i),
        .ovf_sticky_o  (ovf_sticky_o)
    );

    // ---- stage A: integer bias add ---------------------------------------
    logic signed [ACC_W-1:0] acc_lane;
    logic signed [31:0]      acc_lane_ext;
    logic signed [32:0]      bias_sum_wide;
    logic signed [31:0]      bias_sum;
    logic                    bias_ovf;

    always_comb begin
        acc_lane      = $signed(drain_data_o[issue_cnt_q*ACC_W +: ACC_W]);
        acc_lane_ext  = 32'(acc_lane);
        bias_sum_wide = {acc_lane_ext[31], acc_lane_ext} +
                        {dq_bias_i[31], dq_bias_i};
        bias_sum      = bias_sum_wide[31:0];
        bias_ovf      = issue_q && (bias_sum_wide[32] != bias_sum_wide[31]);
    end

    // ---- stage B: the dequantizing multiply -------------------------------
    logic        mul_valid;
    logic [31:0] mul_fp32;
    logic        mul_invalid, mul_overflow, mul_underflow;

    spinquant_dq_fixed32_float16_mul_pipe #(
        .SCALE_EXP_W  (SCALE_EXP_W),
        .SCALE_MANT_W (SCALE_MANT_W)
    ) u_mul (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid_i   (issue_q),
        .fixed_i      (bias_sum),
        .scale_i      (dq_scale_i),
        .exp_offset_i (12'sd0),
        .out_valid_o  (mul_valid),
        .fp32_o       (mul_fp32),
        .invalid_o    (mul_invalid),
        .overflow_o   (mul_overflow),
        .underflow_o  (mul_underflow)
    );

    // ---- pass 1: the local reduction --------------------------------------
    spinquant_rq_minmax u_minmax (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear_i (start),
        .valid_i (mul_valid),
        .fp32_i  (mul_fp32),
        .min_o   (mm_min_o),
        .max_o   (mm_max_o)
    );

    // ---- pass 2: the requantizer ------------------------------------------
    logic [3:0] q4_c;
    logic       q4_clamped_c;
    logic       q4_invalid_c;

    spinquant_rq_fp32_to_int4 u_cvt (
        .fp32_i    (mul_fp32),
        .zp_i      (rq_zp_i),
        .q4_o      (q4_c),
        .clamped_o (q4_clamped_c),
        .invalid_o (q4_invalid_c)
    );

    // The requantizer is combinational, so on its own it would present a result
    // one cycle before the binary16 pack does -- the pack registers twice
    // between accepting a value and raising out_valid_o. Two registers here put
    // the two paths on the same cycle, which is what lets one lane counter and
    // one handshake serve both. Five flip-flops is the whole cost, and the
    // assertion in g_fp16 below is what would catch it if the pack ever changed
    // depth.
    logic       res_valid_q;
    logic       res_valid_q2;
    logic [3:0] q4_q;
    logic [3:0] q4_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            res_valid_q  <= 1'b0;
            res_valid_q2 <= 1'b0;
            q4_q         <= 4'd0;
            q4_q2        <= 4'd0;
        end else begin
            res_valid_q  <= mul_valid;
            if (mul_valid) begin
                q4_q <= q4_c;
            end
            res_valid_q2 <= res_valid_q;
            if (res_valid_q) begin
                q4_q2 <= q4_q;
            end
        end
    end

    always_comb begin
        y_valid_o = res_valid_q2;
        y_q4_o    = q4_q2;
    end

    // ---- the retained binary16 output -------------------------------------
    logic pack_invalid, pack_overflow, pack_underflow;

    generate
        if (KEEP_FP16_OUT != 0) begin : g_fp16
            logic pack_valid;
            spinquant_dq_fp32_pack_pipe #(
                .EXP_W  (OUT_EXP_W),
                .MANT_W (OUT_MANT_W)
            ) u_pack (
                .clk         (clk),
                .rst_n       (rst_n),
                .in_valid_i  (mul_valid),
                .fp32_i      (mul_fp32),
                .out_valid_o (pack_valid),
                .float16_o   (y_fp16_o),
                .invalid_o   (pack_invalid),
                .overflow_o  (pack_overflow),
                .underflow_o (pack_underflow)
            );
`ifndef SYNTHESIS
            // The two paths must stay in step; if they ever do not, the shared
            // lane counter is lying about one of them.
            always_ff @(posedge clk) begin
                if (rst_n) begin
                    assert (pack_valid == res_valid_q2)
                        else $error("spinquant_pcu_rq_top: output paths skewed");
                end
            end
`endif
        end else begin : g_no_fp16
            always_comb begin
                y_fp16_o       = 16'd0;
                pack_invalid   = 1'b0;
                pack_overflow  = 1'b0;
                pack_underflow = 1'b0;
            end
        end
    endgenerate

    // ---- status -----------------------------------------------------------
    logic [5:0] status_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            status_q <= 6'd0;
        end else if (status_clr_i) begin
            status_q <= 6'd0;
        end else begin
            status_q[0] <= status_q[0] | (mul_valid & mul_invalid)
                                       | (res_valid_q2 & pack_invalid);
            status_q[1] <= status_q[1] | (mul_valid & mul_overflow)
                                       | (res_valid_q2 & pack_overflow);
            status_q[2] <= status_q[2] | (mul_valid & mul_underflow)
                                       | (res_valid_q2 & pack_underflow);
            status_q[3] <= status_q[3] | bias_ovf;
            status_q[4] <= status_q[4] | (mul_valid & q4_clamped_c);
            status_q[5] <= status_q[5] | (mul_valid & q4_invalid_c);
        end
    end

    always_comb dq_status_sticky_o = status_q;

`ifndef SYNTHESIS
    initial begin
        if (NLANE != (1 << LANE_W))
            $fatal(1, "spinquant_pcu_rq_top: NLANE must be a power of two");
        if (ACC_W > 32)
            $fatal(1, "spinquant_pcu_rq_top: the multiply pipe takes 32 bits");
    end
`endif

endmodule
