`timescale 1ns/1ps
// Harness for the block-float aligner, plus one processing element so the
// saturating accumulator can be driven into overflow.
module tb_align (
    input  wire [15:0]       i_float,
    input  wire signed [9:0] i_ref_exp,

    output wire signed [16:0] o_aligned_bf16,
    output wire               o_saturate_bf16,
    output wire               o_invalid_bf16,

    input  wire               clk,
    input  wire               rst_n,
    input  wire               i_valid,
    input  wire               i_acc_clear,
    input  wire               i_acc_enable,
    input  wire signed [19:0] i_act0,
    input  wire signed [19:0] i_act1,
    input  wire signed [19:0] i_act2,
    input  wire signed [19:0] i_act3,
    input  wire [15:0]        i_weight_q,
    input  wire [3:0]         i_weight_zp,
    output wire               o_pe_valid,
    output wire signed [31:0] o_pe_acc
);
    int4float_align #(.EXP_W(8), .MANT_W(7), .GUARD(8)) u_bf16 (
        .i_float(i_float), .i_ref_exp(i_ref_exp),
        .o_aligned(o_aligned_bf16), .o_saturate(o_saturate_bf16),
        .o_invalid(o_invalid_bf16));

    int4float_pe #(.ALIGNED_W(20)) u_pe (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_acc_clear(i_acc_clear), .i_acc_enable(i_acc_enable),
        .i_act0(i_act0), .i_act1(i_act1), .i_act2(i_act2), .i_act3(i_act3),
        .i_weight_q(i_weight_q), .i_weight_zp(i_weight_zp),
        .o_valid(o_pe_valid), .o_acc(o_pe_acc));
endmodule
