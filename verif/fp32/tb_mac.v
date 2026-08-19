`timescale 1ns/1ps
// Pipeline harness: the MAC lane with a combinational tap on the same
// multiplier, so the reference does not have to re-implement it.
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
    output wire [15:0] o_ref_product_fp16
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
endmodule
