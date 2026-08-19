`timescale 1ns/1ps

// Synthesis wrapper for the dequant_rne variant (axis 3).
//
// One top only, and its name is unique across the whole repository: two
// synthesis rows that share a top module name overwrite each other's sv2v
// output and each other's power report (synth/run_block_synth.sh writes
// generated/${TOP}.v, synth/run_all.sh writes ${top}_power.rpt).
//
// Geometry is the delivered configuration of rtl/5_spinquant, unchanged --
// 16 PE x 4 ways, 32-bit accumulators with the 24-bit carry chain, bank read
// latch in. The accumulator stays 32 bits on purpose: narrowing it is a
// different axis (rtl/5_spinquant_acc16) and the two must not be mixed into
// one row.
module spinquant_pcu_dq (
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
    output wire         y_valid_o,
    output wire [3:0]   y_lane_o,
    output wire [15:0]  y_data_o,
    output wire [3:0]   dq_status_sticky_o
);
    spinquant_pcu_dq_top #(
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
        .OUT_MANT_W    (10)
    ) u_pcu (.*);
endmodule
