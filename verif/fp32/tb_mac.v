`timescale 1ns/1ps
// Pipeline harness: one MAC lane per format, each with a combinational tap on
// the same multiplier so the reference does not have to re-implement it.
module tb_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_valid,
    input  wire        i_acc_clear,
    input  wire        i_acc_enable,

    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire        o_valid_fp16,
    output wire [31:0] o_acc_fp16,
    output wire [15:0] o_ref_product_fp16,

    input  wire [15:0] i_act,
    input  wire [3:0]  i_weight_q,
    input  wire [3:0]  i_weight_zp,
    output wire        o_valid_bf16,
    output wire [31:0] o_acc_bf16,
    output wire [15:0] o_ref_product_bf16,

    input  wire [15:0] i_act_fp16,
    output wire        o_valid_int4fp16,
    output wire [31:0] o_acc_int4fp16,
    output wire [15:0] o_ref_product_int4fp16
);
    hbmpim_fp16_mac_1_lane u_mac_fp16 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_acc_clear(i_acc_clear), .i_acc_enable(i_acc_enable),
        .i_a(i_a), .i_b(i_b),
        .o_valid(o_valid_fp16), .o_acc(o_acc_fp16)
    );
    hbmpim_fp16_mul u_ref_fp16 (
        .i_a(i_a), .i_b(i_b), .o_result(o_ref_product_fp16)
    );

    awq_int4bf16_mac_1_lane u_mac_bf16 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_acc_clear(i_acc_clear), .i_acc_enable(i_acc_enable),
        .i_act(i_act), .i_weight_q(i_weight_q), .i_weight_zp(i_weight_zp),
        .o_valid(o_valid_bf16), .o_acc(o_acc_bf16)
    );
    awq_int4bf16_mul u_ref_bf16 (
        .i_act(i_act), .i_weight_q(i_weight_q), .i_weight_zp(i_weight_zp),
        .o_result(o_ref_product_bf16)
    );

    awq_int4fp16_mac_1_lane u_mac_int4fp16 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_acc_clear(i_acc_clear), .i_acc_enable(i_acc_enable),
        .i_act(i_act_fp16), .i_weight_q(i_weight_q), .i_weight_zp(i_weight_zp),
        .o_valid(o_valid_int4fp16), .o_acc(o_acc_int4fp16)
    );
    awq_int4fp16_mul u_ref_int4fp16 (
        .i_act(i_act_fp16), .i_weight_q(i_weight_q), .i_weight_zp(i_weight_zp),
        .o_result(o_ref_product_int4fp16)
    );
endmodule
