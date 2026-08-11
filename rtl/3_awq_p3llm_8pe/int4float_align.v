`timescale 1ns/1ps

// Convert a 16-bit floating-point activation to a signed fixed-point value at
// a software-chosen block exponent.
//
// This is the front end that lets an INT4 x float datapath use P3-LLM's
// fixed-point processing element. P3-LLM can shift by the raw exponent because
// FP8-E4M3 has only four exponent bits; binary16 has five and bfloat16 has
// eight. Shifting by the raw exponent needs (product magnitude + max shift +
// sign) bits, so against an INT4 weight binary16 would need 15 + 30 + 1 = 46
// bits and bfloat16 12 + 254 + 1 = 267, against P3-LLM's 26.
// Instead every activation is aligned once to a reference exponent that
// software supplies, which is the standard block-floating-point arrangement
// and the same idea as AiM's bf16_to_q816 with a programmable binary point.
//
// The reference exponent i_ref_exp is the unbiased exponent of the largest
// activation in the block. Software must not set it below that; if it does,
// the shift saturates at zero and the value is clipped, which o_saturate
// reports.
//
//   aligned = (-1)^sign * ((mantissa << GUARD) >> (i_ref_exp - unbiased_exp))
//   value   = aligned * 2^(i_ref_exp - GUARD)
//
// GUARD extra low bits keep activations that are up to GUARD binades below the
// block maximum from flushing to zero. Anything further below does flush; that
// is inherent to block floating point and is why the reference is per block
// rather than global.
//
// Infinity and NaN decode to zero and raise o_invalid, matching the way the
// P3-LLM decoders handle NaN.
module int4float_align #(
    parameter integer EXP_W  = 5,   // 5 = binary16, 8 = bfloat16
    parameter integer MANT_W = 10,  // stored fraction bits
    parameter integer GUARD  = 8
) (
    input  wire [15:0]                    i_float,
    input  wire signed [9:0]              i_ref_exp,
    output wire signed [MANT_W+GUARD+1:0] o_aligned,
    output wire                           o_saturate,
    output wire                           o_invalid
);

    localparam integer SIG_W   = MANT_W + 1;              // with hidden bit
    localparam integer ALIGN_W = MANT_W + 1 + GUARD;      // magnitude width
    localparam integer BIAS    = (1 << (EXP_W - 1)) - 1;
    localparam [EXP_W-1:0] EXP_MAX = {EXP_W{1'b1}};

    wire                  sign     = i_float[15];
    wire [EXP_W-1:0]      exponent = i_float[14 -: EXP_W];
    wire [MANT_W-1:0]     fraction = i_float[MANT_W-1:0];

    wire is_zero_exp = (exponent == {EXP_W{1'b0}});
    wire is_max_exp  = (exponent == EXP_MAX);
    wire is_zero     = is_zero_exp && (fraction == {MANT_W{1'b0}});

    assign o_invalid = is_max_exp;

    // Significand carries the hidden bit for normals. Subnormals share the
    // minimum normal exponent and simply lack it.
    wire [SIG_W-1:0] significand = is_zero_exp ? {1'b0, fraction}
                                               : {1'b1, fraction};

    // Exponent arithmetic is done at full integer width and truncated only
    // where the shifter consumes it, so no intermediate can wrap.
    wire signed [31:0] reference_exponent = {{22{i_ref_exp[9]}}, i_ref_exp};
    wire signed [31:0] exponent_field     = {{(32 - EXP_W){1'b0}}, exponent};

    // Unbiased exponent of the significand's least significant bit. Subnormals
    // share the minimum normal exponent and simply lack the hidden bit.
    wire signed [31:0] lsb_exponent =
        is_zero_exp ? (32'sd1 - BIAS - MANT_W)
                    : (exponent_field - BIAS - MANT_W);

    // Right shift that brings this activation onto the block's scale.
    wire signed [31:0] shift_signed = reference_exponent - lsb_exponent;
    wire               shift_negative = shift_signed[31];
    wire [31:0]        shift_magnitude = shift_signed;

    assign o_saturate = shift_negative && !is_zero && !is_max_exp;

    // Beyond the aligned width the activation contributes nothing.
    wire flush = (!shift_negative) && (shift_magnitude > ALIGN_W);

    wire [31:0] shift_amount = shift_negative ? 32'd0 : shift_magnitude;

    wire [ALIGN_W-1:0] widened = {significand, {GUARD{1'b0}}};
    wire [ALIGN_W-1:0] magnitude =
        (is_zero || is_max_exp || flush) ? {ALIGN_W{1'b0}}
                                        : (widened >> shift_amount);

    assign o_aligned = sign ? -$signed({1'b0, magnitude})
                            :  $signed({1'b0, magnitude});

endmodule
