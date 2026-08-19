`timescale 1ns/1ps
// Standard asymmetric INT4 x FP16 PCU, 32 multipliers (8 PE x 4 lanes), with
// PCU-local dequantization.  Same structure as int4bf16_pcu32_dq with the
// scale and output format in binary16; retained for matched arithmetic
// experiments, while the synthesis rows use the BF16 top.
module int4fp16_pcu32_dq (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [255:0] o_acc,
    output wire o_saturate, output wire o_invalid,
    input  wire i_group_last,
    input  wire [127:0] i_scale,
    input  wire i_fp_acc_clear, input wire i_dot_last,
    output wire o_result_valid, input wire i_result_ready,
    output wire [127:0] o_result,
    output wire o_busy, output wire [3:0] o_status_sticky
);
    int4float_pcu_dq #(.EXP_W(5), .MANT_W(10), .GUARD(8), .NUM_PES(8))
        u_pcu (.*);
endmodule
