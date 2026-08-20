`timescale 1ns/1ps
module int4fp16_pcu32_per_pe_zp (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [255:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4fp16_pcu32 u_v2 (.*);
endmodule
