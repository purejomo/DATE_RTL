`timescale 1ns/1ps
// Standard asymmetric INT4 x FP16 PCU, 32 multipliers (8 PE x 4 lanes),
// narrow-accumulator (acc16) variant of int4fp16_pcu32.  Retained for matched
// arithmetic experiments; the synthesis rows use the BF16 top.
//
// ACC_RSH = 15 is the FP16 worst-case-safe shift: ALIGNED_W = 10 + 8 + 2 = 20
// bounds one product below 2^23, four lanes below 2^25, and a 128-element
// group below 2^30, which is signed 16 bits after a 15-bit shift.
module int4fp16_pcu32_acc16 (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [127:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(5), .MANT_W(10), .GUARD(8), .NUM_PES(8),
                    .ACC_W(16), .ACC_RSH(15))
        u_pcu (.*);
endmodule
