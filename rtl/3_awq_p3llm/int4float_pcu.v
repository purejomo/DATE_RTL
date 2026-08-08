`timescale 1ns/1ps

// INT4 weight x 16-bit float activation PCU in P3-LLM's organization.
//
// One accepted transaction computes a 1 x 4 x 16 GEMV tile: four activations
// shared across sixteen processing elements, each PE holding four weights and
// its own accumulator. That is exactly P3-LLM Fig. 6(a); only the operand
// formats differ, which is what this row of the comparison is for.
//
//   4 shared activations (BF16 or binary16)
//          |
//          +--> shared block-exponent alignment (4 instances)
//          |
//          +--> 16 parallel PEs, 4 signed multipliers each = 64 multipliers
//                 each: 4:2 compressor -> CPA -> signed 32-bit accumulator
//
// With the default sixteen PEs one 256-bit bank access is exactly the 64
// four-bit weights consumed per transaction, so the bank interface needs no
// slicing. NUM_PES is a parameter so the operator count can be swept against
// the SIMD organization at matched throughput.
//
// Why alignment is shared rather than per lane: P3-LLM shifts each product by
// the activation's own four-bit exponent inside the PE. Binary16 has a
// five-bit exponent and bfloat16 an eight-bit one, so the same trick would
// need a 46-bit and a 267-bit field. Aligning once to a block exponent keeps
// the PE narrower than P3-LLM's and moves the only exponent logic into four
// shared instances instead of sixty-four per-lane shifters.
//
// i_ref_exp is the unbiased exponent of the largest activation in the block.
// Software sets it; o_saturate reports any activation that exceeded it.
module int4float_pcu #(
    parameter integer EXP_W   = 5,   // 5 = binary16, 8 = bfloat16
    parameter integer MANT_W  = 10,  // stored fraction bits
    parameter integer GUARD   = 8,
    parameter integer NUM_PES = 16   // four multipliers each
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         i_valid,
    output wire         i_ready,
    input  wire         i_acc_clear,
    input  wire         i_acc_enable,

    input  wire [63:0]  i_act,        // four 16-bit float activations
    input  wire signed [9:0] i_ref_exp,
    input  wire [NUM_PES*16-1:0] i_weight_q,  // four INT4 nibbles per PE
    input  wire [3:0]   i_weight_zp,

    output wire         o_valid,
    output wire [NUM_PES*32-1:0] o_acc,       // one signed 32-bit accumulator per PE
    output wire         o_saturate,
    output wire         o_invalid
);

    localparam integer ALIGNED_W = MANT_W + GUARD + 2;   // signed width

    // The PCU accepts one tile per cycle after reset; the wrapper that drives
    // it is responsible for any tCCD pacing.
    assign i_ready = rst_n;

    wire signed [ALIGNED_W-1:0] aligned [0:3];
    wire [3:0] saturate_bits;
    wire [3:0] invalid_bits;

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_align
            int4float_align #(
                .EXP_W  (EXP_W),
                .MANT_W (MANT_W),
                .GUARD  (GUARD)
            ) u_align (
                .i_float    (i_act[lane*16 +: 16]),
                .i_ref_exp  (i_ref_exp),
                .o_aligned  (aligned[lane]),
                .o_saturate (saturate_bits[lane]),
                .o_invalid  (invalid_bits[lane])
            );
        end
    endgenerate

    assign o_saturate = |saturate_bits;
    assign o_invalid  = |invalid_bits;

    wire [NUM_PES-1:0] pe_valid;

    genvar pe;
    generate
        for (pe = 0; pe < NUM_PES; pe = pe + 1) begin : g_pe
            int4float_pe #(
                .ALIGNED_W (ALIGNED_W)
            ) u_pe (
                .clk          (clk),
                .rst_n        (rst_n),
                .i_valid      (i_valid & i_ready),
                .i_acc_clear  (i_acc_clear),
                .i_acc_enable (i_acc_enable),
                .i_act0       (aligned[0]),
                .i_act1       (aligned[1]),
                .i_act2       (aligned[2]),
                .i_act3       (aligned[3]),
                .i_weight_q   (i_weight_q[pe*16 +: 16]),
                .i_weight_zp  (i_weight_zp),
                .o_valid      (pe_valid[pe]),
                .o_acc        (o_acc[pe*32 +: 32])
            );
        end
    endgenerate

    // Every PE is in lockstep, so the AND both states that and consumes every
    // valid bit.
    assign o_valid = &pe_valid;

endmodule
