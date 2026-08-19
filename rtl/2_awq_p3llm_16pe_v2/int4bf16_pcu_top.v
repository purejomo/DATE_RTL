`timescale 1ns/1ps
// INT4 weight x bfloat16 activation PCU with 64 multipliers (16 PE x 4 lanes),
// P3-LLM organization. NUM_PES is passed explicitly rather than defaulted so
// this top cannot pick up the eight-PE twin of int4float_pcu by accident.
//
// v2 metadata contract: i_weight_zp carries one independent four-bit zero
// point per output PE (16 x 4 = 64 bits), matching what AutoAWQ stores per
// output channel and group. The v1 broadcast nibble is gone.
module int4bf16_pcu_top (
    input  wire clk, input  wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [255:0] i_weight_q, input wire [63:0] i_weight_zp,
    output wire o_valid, output wire [511:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(8), .MANT_W(7), .GUARD(8), .NUM_PES(16))
        u_pcu (.*);
endmodule
