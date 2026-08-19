`timescale 1ns/1ps
// INT4 weight x bfloat16 activation PCU with 64 multipliers (16 PE x 4 lanes),
// with PCU-local dequantization: the axis-3 (dequant_rne) variant of
// int4bf16_pcu_top.
//
// v2 metadata contract: i_weight_zp carries one independent four-bit zero
// point per output PE (16 x 4 = 64 bits).  NUM_PES is passed explicitly so
// this top cannot pick up the eight-PE twin of int4float_pcu by accident.
//
// The raw 32-bit accumulator path is unchanged and o_acc still drains it. One
// shared floating-point engine turns the sixteen INT32 accumulators into a
// bfloat16 output vector at the end of a dot product:
//
//   prod32[p]   = RNE32(acc_int32[p] * scale_bf16[p,g] * 2**(i_ref_exp - 8))
//   fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])
//   o_result[p] = RNE_bf16(fp_acc32[p])            // once, at i_dot_last
//
// Sixteen PEs cost sixteen engine issue cycles per group against the 32
// accepted tiles a 128-element group takes, so one shared lane still has
// margin.
module int4bf16_pcu_top_dq (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [255:0] i_weight_q, input wire [63:0] i_weight_zp,
    output wire o_valid, output wire [511:0] o_acc,
    output wire o_saturate, output wire o_invalid,
    input  wire i_group_last,
    input  wire [255:0] i_scale,
    input  wire i_fp_acc_clear, input wire i_dot_last,
    output wire o_result_valid, input wire i_result_ready,
    output wire [255:0] o_result,
    output wire o_busy, output wire [3:0] o_status_sticky
);
    int4float_pcu_dq #(.EXP_W(8), .MANT_W(7), .GUARD(8), .NUM_PES(16))
        u_pcu (.*);
endmodule
