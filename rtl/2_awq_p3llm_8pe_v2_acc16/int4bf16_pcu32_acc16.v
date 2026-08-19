`timescale 1ns/1ps
// Standard AutoAWQ W4G128 x BF16 PCU, 32 multipliers (8 PE x 4 lanes),
// narrow-accumulator (acc16) variant of int4bf16_pcu32.
//
// Each output PE consumes its own four-bit group zero point, exactly as the
// 32-bit build does. The accumulator is 16 bits and every 4-lane partial sum
// is RNE-narrowed by ACC_RSH before it is added, so o_acc is 8 x 16 = 128 bits
// instead of 256.
//
// ACC_RSH = 12 is the BF16 worst-case-safe shift: ALIGNED_W = 7 + 8 + 2 = 17
// bounds one product below 2^20, four lanes below 2^22, and a 128-element
// group (32 accepted transactions) below 2^27, which is exactly signed 16 bits
// after a 12-bit shift. The Fusion-PIMSim alias wrapper the 32-bit build
// carries is deliberately absent: acc16 is not a simulator contract.
module int4bf16_pcu32_acc16 (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [127:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(8), .MANT_W(7), .GUARD(8), .NUM_PES(8),
                    .ACC_W(16), .ACC_RSH(12))
        u_pcu (.*);
endmodule
