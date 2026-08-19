`timescale 1ns/1ps
// Standard AutoAWQ W4G128 x BF16 PCU, 32 multipliers (8 PE x 4 lanes), with
// PCU-local dequantization: the axis-3 (dequant_rne) variant of
// int4bf16_pcu32.
//
// The raw 32-bit accumulator path is unchanged and o_acc still drains it. What
// is added is one shared floating-point engine that, at each weight-group
// boundary, turns the eight INT32 accumulators into a bfloat16 output vector:
//
//   prod32[p]   = RNE32(acc_int32[p] * scale_bf16[p,g] * 2**(i_ref_exp - 8))
//   fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])
//   o_result[p] = RNE_bf16(fp_acc32[p])            // once, at i_dot_last
//
// The output is bfloat16 because that is what the next layer consumes: AWQ
// activations are already bfloat16, so this design ends the dequantization
// inside the PCU and there is no requantization step.
module int4bf16_pcu32_dq (
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
    int4float_pcu_dq #(.EXP_W(8), .MANT_W(7), .GUARD(8), .NUM_PES(8))
        u_pcu (.*);
endmodule
