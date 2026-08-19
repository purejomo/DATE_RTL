`timescale 1ns/1ps
// Standard AutoAWQ W4G128 x BF16 PCU, 32 multipliers (8 PE x 4 lanes).
// Each output PE consumes its own four-bit group zero point.
module int4bf16_pcu32 (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [255:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(8), .MANT_W(7), .GUARD(8), .NUM_PES(8))
        u_pcu (.*);
endmodule

// Compatibility name used by Fusion-PIMSim's explicit per-PE-ZP wrapper.
// It is a pure alias and adds no state or arithmetic.
module int4bf16_pcu32_per_pe_zp (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [31:0] i_weight_zp,
    output wire o_valid, output wire [255:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4bf16_pcu32 u_v2 (.*);
endmodule
