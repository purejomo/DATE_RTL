`timescale 1ns/1ps
// INT4 weight x binary16 activation PCU, P3-LLM organization.
module int4fp16_pcu_top (
    input  wire clk, input  wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [255:0] i_weight_q, input wire [3:0] i_weight_zp,
    output wire o_valid, output wire [511:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(5), .MANT_W(10), .GUARD(8)) u_pcu (.*);
endmodule
