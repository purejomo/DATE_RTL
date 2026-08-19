`timescale 1ns/1ps

// SpinQuant W4A4 PCU with PCU-local dequantization (axis 3).
//
// The raw integer engine is rtl/5_spinquant unchanged -- spinquant_pcu_top is
// instantiated, not copied and edited. What this file adds is one shared
// dequantization engine on the drain path and the sequencer that walks the
// accumulator file through it.
//
// ---------------------------------------------------------------------------
// Numeric contract
// ---------------------------------------------------------------------------
//
// SpinQuant's own algebra, from docs/spinquant_pcu_spec.md, is
//
//     A~ = s_a * A_q + beta                     activation dequantization
//     W  = s_w * W_q                            per-output-channel symmetric
//
// so for output channel i, writing acc[i] for the integer dot product the raw
// PCU accumulates,
//
//     y[i] = s_w[i]*s_a * acc[i] + s_w[i]*beta * sum(W_q_row[i])
//          = s[i] * ( acc[i] + (beta/s_a) * sum(W_q_row[i]) )
//          = s[i] * ( acc[i] + bias_int[i] )
//
// because min-max asymmetric quantization gives beta = -s_a * zp_a, so
// beta/s_a = -zp_a is an integer and
//
//     s[i]        = s_w[i] * s_a                per output channel, 16-bit float
//     bias_int[i] = -zp_a * sum(W_q_row[i])     per output channel, INTEGER
//
// **The activation zero point folds into the integer domain.** That is what
// makes this engine cheaper than the AWQ and P3-LLM ones: there is no
// floating-point accumulator and no second scale multiply, only
//
//     fixed[i] = acc[i] + bias_int[i]           one 32-bit integer add
//     fp32[i]  = RNE32(fixed[i] * s[i])         spinquant_dq_fixed32_..._mul
//     y16[i]   = RNE16(fp32[i])                 spinquant_dq_fp32_pack_pipe
//
// Both operands of the multiply are exact and the product is rounded once, so
// the only roundings in the whole path are the two named above.
//
// Neither s[i] nor bias_int[i] costs a PIM-to-host transfer. s_w and
// sum(W_q_row) are static per layer and resident on the NPU; s_a and zp_a are
// per-token scalars the NPU already computed when it quantized the activation.
// The NPU therefore forms both per-channel vectors from data it already holds.
//
// ---------------------------------------------------------------------------
// This row does NOT close the loop
// ---------------------------------------------------------------------------
//
// SpinQuant is W4A4. y16 is a 16-bit float, but the next layer's PCU wants
// unsigned INT4, so a quantization kernel still runs on the host. Every other
// axis-3 row in this repository ends in the format its own next layer accepts
// and removes the host kernel entirely; this one does not. It exists as the
// ablation midpoint: rtl/5_spinquant_dequant_requant adds the requantizer, and
// the area difference between the two is the requantizer's cost on its own.
//
// ---------------------------------------------------------------------------
// Sequencing
// ---------------------------------------------------------------------------
//
// The accumulator file already has a drain port that is independent of the
// compute port, so unlike the AWQ and P3-LLM dequantizers this one needs no
// snapshot queue: it reads the entry in place. The cost is a scheduling rule
// rather than silicon.
//
//   RULE: no MAC command may target dq_entry_i while dq_busy_o is high.
//   Other entries stay free, which is why NENTRY = 4 exists.
//
// One lane is issued per cycle, in ascending lane order, starting the cycle
// after dq_req_i is accepted. NLANE = 16 lanes therefore take 16 issue cycles.
// Metadata is streamed in that same order: the driver presents dq_scale_i and
// dq_bias_i for the lane named by dq_lane_o on the cycle dq_issue_o is high.
// Results leave in the same order on y_valid_o, tagged with y_lane_o.
//
// At tCCD_S the raw port accepts a MAC every cycle, so a 16-cycle drain is
// affordable exactly when the k sweep of another entry is longer than 16
// commands -- which it is by three orders of magnitude for any real projection.
module spinquant_pcu_dq_top #(
    parameter int NPE           = 16,
    parameter int NWAY          = 4,
    parameter int NROW          = 1,
    parameter int NENTRY        = 4,
    parameter int ACC_W         = 32,
    parameter int ACC_CHAIN_W   = 24,
    parameter int W_LATCH       = 1,
    parameter int Q_W           = 4,
    // Scale and output format. 5/10 is binary16, 8/7 is bfloat16. The
    // activation SpinQuant quantizes is binary16 in the reference flow, so the
    // delivered configuration keeps both at binary16.
    parameter int SCALE_EXP_W   = 5,
    parameter int SCALE_MANT_W  = 10,
    parameter int OUT_EXP_W     = 5,
    parameter int OUT_MANT_W    = 10,
    // derived; do not override
    parameter int WBEAT_W       = NPE*NWAY*Q_W,
    parameter int ABEAT_W       = NROW*NWAY*Q_W,
    parameter int NLANE         = NROW*NPE,
    parameter int SEL_W         = $clog2(NENTRY),
    parameter int ENT_W         = NLANE*ACC_W,
    parameter int LANE_W        = $clog2(NLANE),
    parameter int CNT_W         = LANE_W + 1
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

    // ---- dequantizing drain port ---------------------------------------
    input  logic                dq_req_i,
    input  logic [SEL_W-1:0]    dq_entry_i,
    output logic                dq_busy_o,

    output logic                dq_issue_o,
    output logic [LANE_W-1:0]   dq_lane_o,
    input  logic [15:0]         dq_scale_i,
    input  logic signed [31:0]  dq_bias_i,

    output logic                y_valid_o,
    output logic [LANE_W-1:0]   y_lane_o,
    output logic [15:0]         y_data_o,

    // [0] invalid  [1] overflow  [2] underflow  [3] integer bias add overflow
    output logic [3:0]          dq_status_sticky_o
);

    // ---- sequencer --------------------------------------------------------
    logic               issue_q;
    logic [LANE_W-1:0]  issue_cnt_q;
    logic [SEL_W-1:0]   dq_entry_q;
    logic [CNT_W-1:0]   ret_cnt_q;
    logic               active_q;

    // NLANE is asserted to be a power of two below, so the last lane index is
    // all ones in LANE_W bits and the last return count is the same value in
    // the one-bit-wider return counter. Writing them this way keeps the
    // comparison exactly as wide as the register it compares against.
    localparam logic [LANE_W-1:0] LAST_LANE = {LANE_W{1'b1}};
    localparam logic [CNT_W-1:0]  LAST_RET  = {1'b0, {LANE_W{1'b1}}};

    logic last_issue;
    always_comb last_issue = issue_q && (issue_cnt_q == LAST_LANE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            issue_q     <= 1'b0;
            issue_cnt_q <= {LANE_W{1'b0}};
            dq_entry_q  <= {SEL_W{1'b0}};
            ret_cnt_q   <= {CNT_W{1'b0}};
            active_q    <= 1'b0;
        end else begin
            if (!active_q && dq_req_i) begin
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
    //
    // The drain select is the only place the engine reaches into the raw PCU,
    // and it is a NENTRY-wide mux on a SEL_W-bit signal.
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
    //
    // acc[i] reaches 22 bits at K = 14336 and bias_int[i] = -zp_a*sum(W_q_row)
    // reaches 15*14336*8 = 1720320, also 22 bits, so the sum needs 23. The add
    // is done at 32 bits and the carry-out is reported rather than saturated,
    // matching the raw PE's policy.
    logic signed [ACC_W-1:0]  acc_lane;
    logic signed [31:0]       acc_lane_ext;
    logic signed [32:0]       bias_sum_wide;
    logic signed [31:0]       bias_sum;
    logic                     bias_ovf;

    always_comb begin
        acc_lane      = $signed(drain_data_o[issue_cnt_q*ACC_W +: ACC_W]);
        acc_lane_ext  = 32'(acc_lane);
        bias_sum_wide = {acc_lane_ext[31], acc_lane_ext} +
                        {dq_bias_i[31], dq_bias_i};
        bias_sum      = bias_sum_wide[31:0];
        bias_ovf      = issue_q &&
                        (bias_sum_wide[32] != bias_sum_wide[31]);
    end

    // ---- stage B: the two rounding steps ---------------------------------
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
        // The raw accumulator is a plain integer: unlike the AWQ engine there
        // is no block exponent to fold in, so the offset is zero.
        .exp_offset_i (12'sd0),
        .out_valid_o  (mul_valid),
        .fp32_o       (mul_fp32),
        .invalid_o    (mul_invalid),
        .overflow_o   (mul_overflow),
        .underflow_o  (mul_underflow)
    );

    logic        pack_invalid, pack_overflow, pack_underflow;

    spinquant_dq_fp32_pack_pipe #(
        .EXP_W  (OUT_EXP_W),
        .MANT_W (OUT_MANT_W)
    ) u_pack (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid_i  (mul_valid),
        .fp32_i      (mul_fp32),
        .out_valid_o (y_valid_o),
        .float16_o   (y_data_o),
        .invalid_o   (pack_invalid),
        .overflow_o  (pack_overflow),
        .underflow_o (pack_underflow)
    );

    // ---- status -----------------------------------------------------------
    logic [3:0] status_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            status_q <= 4'd0;
        end else if (status_clr_i) begin
            status_q <= 4'd0;
        end else begin
            status_q[0] <= status_q[0] | (mul_valid & mul_invalid)
                                       | (y_valid_o & pack_invalid);
            status_q[1] <= status_q[1] | (mul_valid & mul_overflow)
                                       | (y_valid_o & pack_overflow);
            status_q[2] <= status_q[2] | (mul_valid & mul_underflow)
                                       | (y_valid_o & pack_underflow);
            status_q[3] <= status_q[3] | bias_ovf;
        end
    end

    always_comb dq_status_sticky_o = status_q;

`ifndef SYNTHESIS
    initial begin
        if (NLANE != (1 << LANE_W))
            $fatal(1, "spinquant_pcu_dq_top: NLANE must be a power of two");
        if (ACC_W > 32)
            $fatal(1, "spinquant_pcu_dq_top: the multiply pipe takes 32 bits");
    end
`endif

endmodule
