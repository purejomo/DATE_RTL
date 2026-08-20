`timescale 1ns/1ps

module spinquant_pcu_v2_rq (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [511:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [15:0]   a_q4_i,
    input  wire [1:0]    acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire [1:0]    drain_entry_i,
    output wire [1023:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o,
    input  wire          dq_req_i,
    input  wire [1:0]    dq_entry_i,
    output wire          dq_busy_o,
    output wire          dq_issue_o,
    output wire [4:0]    dq_lane_o,
    input  wire [15:0]   dq_scale_i,
    input  wire [31:0]   dq_bias_i,
    input  wire [4:0]    rq_zp_i,
    output wire [31:0]   mm_min_o,
    output wire [31:0]   mm_max_o,
    output wire          y_valid_o,
    output wire [4:0]    y_lane_o,
    output wire [3:0]    y_q4_o,
    output wire [15:0]   y_fp16_o,
    output wire [5:0]    dq_status_sticky_o
);
    spinquant_pcu_rq_top #(
        .NPE           (32),
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
        .KEEP_FP16_OUT (0)
    ) u_pcu (.*);
endmodule
