`timescale 1ns/1ps
// INT4 weight x binary16 activation PCU with 32 multipliers (8 PE x 4 lanes).
// Matched to the 32-lane SIMD bank in operator count and throughput so the
// comparison isolates the processing-element organization.
module int4fp16_pcu32 (
    input  wire clk, input wire rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, input wire i_acc_enable,
    input  wire [63:0] i_act, input wire signed [9:0] i_ref_exp,
    input  wire [127:0] i_weight_q, input wire [3:0] i_weight_zp,
    output wire o_valid, output wire [255:0] o_acc,
    output wire o_saturate, output wire o_invalid
);
    int4float_pcu #(.EXP_W(5), .MANT_W(10), .GUARD(8), .NUM_PES(8))
        u_pcu (.*);
endmodule
