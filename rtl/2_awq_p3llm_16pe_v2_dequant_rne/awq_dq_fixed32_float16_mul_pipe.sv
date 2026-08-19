`timescale 1ns/1ps

// Shared AWQ dequantization multiplier.
//
// Numeric operation:
//
//   fp32_o = RNE_binary32(fixed_i * scale_i * 2**exp_offset_i)
//
// This is rtl/3_p3llm_dequant_rne/p3llm_dequant_fixed32_fp16_mul_pipe.sv with
// two generalizations, and no change to the arithmetic:
//
//   * the binary exponent offset is a wider signed input. P3-LLM needed only
//     the three fixed decoder binary points (-12/-11/-19); AWQ needs
//     (i_ref_exp - GUARD), where i_ref_exp is the software-chosen block
//     exponent, so the offset spans the full binary16/bfloat16 exponent range.
//   * the scale format is a parameter. AutoAWQ stores the group scale in the
//     activation dtype, so SCALE_EXP_W/SCALE_MANT_W select bfloat16 (8/7) or
//     binary16 (5/10).
//
// fixed_i is a two's-complement signed integer.  scale_i is required to be a
// positive, finite float; +0 and subnormals are supported.  A negative scale
// (including -0), infinity, or NaN is outside that contract, asserts
// invalid_o, and produces the canonical binary32 quiet NaN.
//
// The integer is never converted to binary32 before the multiply.  Its full
// 32-bit magnitude (including abs(INT32_MIN) == 2**31) is multiplied by the
// complete scale significand, and the exact PROD_W-bit product is rounded only
// once when it is packed as binary32.
//
// Pipeline/latency contract:
//   * initiation interval is one clock; bubbles are allowed;
//   * LATENCY is the number of full rising-edge intervals from acceptance to
//     result: an input sampled with in_valid_i at edge N is reported with
//     out_valid_o immediately after edge N+LATENCY;
//   * outputs/flags are zero during bubbles.
// A lane/context tag can therefore be delayed by LATENCY clocks in parallel.
module awq_dq_fixed32_float16_mul_pipe #(
    parameter int unsigned SCALE_EXP_W  = 8,   // 8 = bfloat16, 5 = binary16
    parameter int unsigned SCALE_MANT_W = 7    // 7 = bfloat16, 10 = binary16
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      in_valid_i,
    input  logic signed [31:0]        fixed_i,
    input  logic        [15:0]        scale_i,
    input  logic signed [11:0]        exp_offset_i,

    output logic                      out_valid_o,
    output logic        [31:0]        fp32_o,
    output logic                      invalid_o,
    output logic                      overflow_o,
    output logic                      underflow_o
);

    localparam int unsigned LATENCY = 1;

    localparam int unsigned SIG_W  = SCALE_MANT_W + 1;
    localparam int unsigned PROD_W = 32 + SIG_W;
    localparam int unsigned SBIAS  = (1 << (SCALE_EXP_W - 1)) - 1;
    // Weight of the significand LSB for a normal scale is
    // 2**(exp - SBIAS - SCALE_MANT_W); a subnormal shares the minimum normal
    // exponent and simply lacks the hidden bit.
    localparam int unsigned NORMAL_BIAS   = SBIAS + SCALE_MANT_W;
    localparam int unsigned SUBNORMAL_SUB = SBIAS + SCALE_MANT_W - 1;

    // Result bundle layout used by the exact-product packer.
    localparam int unsigned RESULT_LSB    = 0;
    localparam int unsigned INVALID_BIT   = 32;
    localparam int unsigned OVERFLOW_BIT  = 33;
    localparam int unsigned UNDERFLOW_BIT = 34;

    // Pack exact_product * 2**base_exp as binary32.  The subnormal path is
    // retained so that the range handling and flags remain explicit and
    // self-checkable even where the legal input ranges cannot reach it.
    function automatic logic [34:0] pack_exact_fp32 (
        input logic                sign,
        input logic                invalid,
        input logic [PROD_W-1:0]   exact_product,
        input logic signed [12:0]  base_exp
    );
        logic [31:0] result;
        logic        invalid_flag;
        logic        overflow_flag;
        logic        underflow_flag;
        logic [23:0] retained_sig;
        logic [24:0] rounded_sig;
        logic [7:0]  biased_exp;
        logic        guard_bit;
        logic        sticky_bit;
        logic        round_up;
        logic [PROD_W-1:0] shifted_product;
        logic [63:0] subnormal_shifted;
        logic [PROD_W:0] subnormal_quotient;
        logic [PROD_W:0] subnormal_rounded;
        integer      leading_index;
        integer      unbiased_exp;
        integer      biased_exp_integer;
        integer      base_exp_integer;
        integer      shift_amount;
        integer      subnormal_power;
        integer      scan;
        begin
            result         = 32'd0;
            invalid_flag   = invalid;
            overflow_flag  = 1'b0;
            underflow_flag = 1'b0;
            retained_sig   = 24'd0;
            rounded_sig    = 25'd0;
            biased_exp     = 8'd0;
            guard_bit      = 1'b0;
            sticky_bit     = 1'b0;
            round_up       = 1'b0;
            shifted_product = {PROD_W{1'b0}};
            subnormal_shifted = 64'd0;
            subnormal_quotient = {(PROD_W+1){1'b0}};
            subnormal_rounded  = {(PROD_W+1){1'b0}};
            leading_index  = -1;
            unbiased_exp   = 0;
            biased_exp_integer = 0;
            base_exp_integer = $signed({{19{base_exp[12]}}, base_exp});
            shift_amount   = 0;
            subnormal_power = 0;

            for (scan = 0; scan < PROD_W; scan = scan + 1) begin
                if (exact_product[scan]) begin
                    leading_index = scan;
                end
            end

            if (invalid) begin
                result = 32'h7fc0_0000;
            end else if (leading_index < 0) begin
                // The positive scale may be +0.  Preserve the integer sign on
                // a zero product, matching an ordinary signed FP multiply.
                result = {sign, 31'd0};
            end else begin
                unbiased_exp = base_exp_integer + leading_index;

                if (unbiased_exp >= -126) begin
                    // Form hidden bit + 23 fraction bits, then use every bit
                    // discarded from the exact product for RNE.
                    shift_amount = leading_index - 23;
                    if (shift_amount > 0) begin
                        shifted_product = exact_product >> shift_amount;
                        retained_sig = shifted_product[23:0];
                        guard_bit = exact_product[shift_amount-1];
                        sticky_bit = 1'b0;
                        for (scan = 0; scan < PROD_W; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | exact_product[scan];
                            end
                        end
                    end else begin
                        shifted_product = exact_product << (-shift_amount);
                        retained_sig = shifted_product[23:0];
                        guard_bit = 1'b0;
                        sticky_bit = 1'b0;
                    end

                    round_up = guard_bit
                             & (sticky_bit | retained_sig[0]);
                    rounded_sig = {1'b0, retained_sig}
                                + {{24{1'b0}}, round_up};
                    if (rounded_sig[24]) begin
                        retained_sig = rounded_sig[24:1];
                        unbiased_exp = unbiased_exp + 1;
                    end else begin
                        retained_sig = rounded_sig[23:0];
                    end

                    if (unbiased_exp > 127) begin
                        result = {sign, 8'hff, 23'd0};
                        overflow_flag = 1'b1;
                    end else begin
                        biased_exp_integer = unbiased_exp + 127;
                        biased_exp = biased_exp_integer[7:0];
                        result = {
                            sign,
                            biased_exp,
                            retained_sig[22:0]
                        };
                    end
                end else begin
                    // Binary32 subnormal fraction =
                    // RNE(exact_product * 2**(base_exp + 149)).
                    subnormal_power = base_exp_integer + 149;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                    if (subnormal_power >= 0) begin
                        // The subnormal branch guarantees the shifted value
                        // fits below bit 23.
                        subnormal_shifted =
                            {{(64-PROD_W){1'b0}}, exact_product}
                            << subnormal_power;
                        subnormal_quotient = subnormal_shifted[PROD_W:0];
                    end else begin
                        shift_amount = -subnormal_power;
                        if (shift_amount < PROD_W) begin
                            subnormal_quotient =
                                {1'b0, exact_product} >> shift_amount;
                        end else begin
                            subnormal_quotient = {(PROD_W+1){1'b0}};
                        end
                        if ((shift_amount >= 1) &&
                            (shift_amount <= PROD_W)) begin
                            guard_bit = exact_product[shift_amount-1];
                        end
                        for (scan = 0; scan < PROD_W; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | exact_product[scan];
                            end
                        end
                    end

                    round_up = guard_bit
                             & (sticky_bit | subnormal_quotient[0]);
                    subnormal_rounded = subnormal_quotient
                                      + {{PROD_W{1'b0}}, round_up};
                    if (subnormal_rounded[23]) begin
                        // Rounding can promote the largest subnormal to the
                        // smallest normal binary32 value.
                        result = {sign, 8'd1, 23'd0};
                    end else begin
                        result = {sign, 8'd0, subnormal_rounded[22:0]};
                        // Flag semantics are tininess after rounding.  Thus an
                        // exact, nonzero subnormal also reports underflow.
                        underflow_flag = 1'b1;
                    end
                end
            end

            pack_exact_fp32 = {
                underflow_flag,
                overflow_flag,
                invalid_flag,
                result
            };
        end
    endfunction

    logic        [31:0]       magnitude_d;
    logic        [SIG_W-1:0]  scale_significand_d;
    logic        [PROD_W-1:0] exact_product_d;
    logic signed [12:0]       base_exp_d;
    logic                     sign_d;
    logic                     invalid_d;
    logic [SCALE_EXP_W-1:0]   scale_exp_field_d;
    logic [SCALE_MANT_W-1:0]  scale_frac_d;
    integer                   base_exp_integer_d;
    integer                   scale_exp_integer_d;

    always_comb begin
        sign_d = fixed_i[31];
        // Two's-complement negation in 32 unsigned bits intentionally maps
        // INT32_MIN to the representable magnitude 32'h8000_0000.
        magnitude_d = fixed_i[31]
                    ? (~$unsigned(fixed_i) + 32'd1)
                    :  $unsigned(fixed_i);

        scale_exp_field_d = scale_i[14 -: SCALE_EXP_W];
        scale_frac_d      = scale_i[SCALE_MANT_W-1:0];

        invalid_d = scale_i[15] || (&scale_exp_field_d);
        base_exp_integer_d =
            $signed({{20{exp_offset_i[11]}}, exp_offset_i});
        scale_exp_integer_d =
            {{(32-SCALE_EXP_W){1'b0}}, scale_exp_field_d};
        if (scale_exp_field_d == {SCALE_EXP_W{1'b0}}) begin
            scale_significand_d = {1'b0, scale_frac_d};
            base_exp_integer_d = base_exp_integer_d - SUBNORMAL_SUB;
        end else begin
            scale_significand_d = {1'b1, scale_frac_d};
            base_exp_integer_d = base_exp_integer_d
                               + scale_exp_integer_d - NORMAL_BIAS;
        end
        base_exp_d = base_exp_integer_d[12:0];
        exact_product_d = magnitude_d * scale_significand_d;
    end

    // Stage 0: decode and register the exact integer/significand product.
    logic              s0_valid_q;
    logic              s0_sign_q;
    logic              s0_invalid_q;
    logic [PROD_W-1:0] s0_exact_product_q;
    logic signed [12:0] s0_base_exp_q;
    logic        [34:0] packed_s0;

    always_comb begin
        packed_s0 = pack_exact_fp32(
            s0_sign_q,
            s0_invalid_q,
            s0_exact_product_q,
            s0_base_exp_q
        );
    end

    // Stage 1: normalize, RNE-pack, and register the binary32 result.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q         <= 1'b0;
            s0_sign_q          <= 1'b0;
            s0_invalid_q       <= 1'b0;
            s0_exact_product_q <= {PROD_W{1'b0}};
            s0_base_exp_q      <= 13'sd0;
            out_valid_o        <= 1'b0;
            fp32_o             <= 32'd0;
            invalid_o          <= 1'b0;
            overflow_o         <= 1'b0;
            underflow_o        <= 1'b0;
        end else begin
            s0_valid_q <= in_valid_i;
            if (in_valid_i) begin
                s0_sign_q          <= sign_d;
                s0_invalid_q       <= invalid_d;
                s0_exact_product_q <= exact_product_d;
                s0_base_exp_q      <= base_exp_d;
            end

            out_valid_o <= s0_valid_q;
            if (s0_valid_q) begin
                fp32_o      <= packed_s0[RESULT_LSB +: 32];
                invalid_o   <= packed_s0[INVALID_BIT];
                overflow_o  <= packed_s0[OVERFLOW_BIT];
                underflow_o <= packed_s0[UNDERFLOW_BIT];
            end else begin
                fp32_o      <= 32'd0;
                invalid_o   <= 1'b0;
                overflow_o  <= 1'b0;
                underflow_o <= 1'b0;
            end
        end
    end

endmodule
