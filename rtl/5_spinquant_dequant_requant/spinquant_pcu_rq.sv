`timescale 1ns/1ps

// Synthesis wrapper for the dequant_requant variant (axis 4).
//
// Unique top name, for the reason spelled out in the other wrappers: two rows
// sharing a top overwrite each other's sv2v output and power report.
//
// Geometry is the delivered configuration of rtl/5_spinquant unchanged, and the
// accumulator stays 32 bits: requantization needs the full-precision value, so
// this row builds on axis 1 and not on axis 2. KEEP_FP16_OUT = 1 makes it a
// strict superset of spinquant_pcu_dq, so the two rows differ by the
// requantizer and nothing else -- structurally. Their area totals are not
// decomposable, though; see the note in spinquant_pcu_rq_top.sv.
module spinquant_pcu_rq (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         w_load_i,
    input  wire [255:0] w_beat_i,
    input  wire         mac_valid_i,
    input  wire [15:0]  a_q4_i,
    input  wire [1:0]   acc_entry_i,
    input  wire         acc_clear_i,
    output wire         mac_done_o,
    input  wire [1:0]   drain_entry_i,
    output wire [511:0] drain_data_o,
    input  wire         status_clr_i,
    output wire         ovf_sticky_o,

    input  wire         dq_req_i,
    input  wire [1:0]   dq_entry_i,
    output wire         dq_busy_o,
    output wire         dq_issue_o,
    output wire [3:0]   dq_lane_o,
    input  wire [15:0]  dq_scale_i,
    input  wire [31:0]  dq_bias_i,
    input  wire [4:0]   rq_zp_i,
    output wire [31:0]  mm_min_o,
    output wire [31:0]  mm_max_o,
    output wire         y_valid_o,
    output wire [3:0]   y_lane_o,
    output wire [3:0]   y_q4_o,
    output wire [15:0]  y_fp16_o,
    output wire [5:0]   dq_status_sticky_o
);
    spinquant_pcu_rq_top #(
        .NPE           (16),
        .NWAY          (4),
        .NROW          (1),
        .NENTRY        (4),
        .ACC_W         (32),
        .ACC_CHAIN_W   (24),
        .W_LATCH       (1),
        .SCALE_EXP_W   (5),
        .SCALE_MANT_W  (10),
        .OUT_EXP_W     (5),
        .OUT_MANT_W    (10),
        .KEEP_FP16_OUT (1)
    ) u_pcu (.*);
endmodule
