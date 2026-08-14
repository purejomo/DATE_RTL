`timescale 1ns/1ps

// Shared binary32 accumulator adder for the P3-LLM dequantization path.
//
// Supported input contract is binary32 normal finite values and signed zero.
// A subnormal, infinity, or NaN input asserts invalid_o and produces the
// canonical quiet NaN.  Finite arithmetic uses round-to-nearest, ties-to-even.
// Results are gradual (a cancellation result may be binary32 subnormal).
//
// Unlike an aligner which prematurely replaces all discarded bits with one
// sticky bit, this implementation aligns both 24-bit significands exactly for
// every exponent distance that can affect binary32 RNE (distance <= 25).  The
// distance-25 case matters when subtracting from an exact power of two, because
// the predecessor has half the spacing of the successor.  At distance >= 26
// the correctly rounded result is exactly the larger operand.  Consequently
// subtraction/cancellation and GRS tie cases are not corrupted by sticky-bit
// borrowing.
//
// Pipeline/latency contract:
//   * initiation interval is one clock; bubbles are allowed;
//   * LATENCY is the number of full rising-edge intervals from acceptance to
//     result: an input sampled with in_valid_i at edge N is reported with
//     out_valid_o immediately after edge N+LATENCY;
//   * outputs/flags are zero during bubbles.
// A lane/context tag can therefore be delayed by LATENCY clocks in parallel.
module p3llm_dequant_fp32_add_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,

    output logic        out_valid_o,
    output logic [31:0] result_o,
    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o
);

    localparam int unsigned LATENCY = 2;

    localparam int unsigned RESULT_LSB    = 0;
    localparam int unsigned INVALID_BIT   = 32;
    localparam int unsigned OVERFLOW_BIT  = 33;
    localparam int unsigned UNDERFLOW_BIT = 34;

    // Pack exact_magnitude * 2**base_exp as binary32.
    function automatic logic [34:0] pack_exact_fp32 (
        input logic               sign,
        input logic        [48:0] exact_magnitude,
        input logic signed [10:0] base_exp
    );
        logic [31:0] result;
        logic        overflow_flag;
        logic        underflow_flag;
        logic [23:0] retained_sig;
        logic [24:0] rounded_sig;
        logic [7:0]  biased_exp;
        logic        guard_bit;
        logic        sticky_bit;
        logic        round_up;
        logic [48:0] shifted_magnitude;
        logic [63:0] subnormal_shifted;
        logic [49:0] subnormal_quotient;
        logic [49:0] subnormal_rounded;
        integer      leading_index;
        integer      unbiased_exp;
        integer      biased_exp_integer;
        integer      base_exp_integer;
        integer      shift_amount;
        integer      subnormal_power;
        integer      scan;
        begin
            result             = 32'd0;
            overflow_flag      = 1'b0;
            underflow_flag     = 1'b0;
            retained_sig       = 24'd0;
            rounded_sig        = 25'd0;
            biased_exp         = 8'd0;
            guard_bit          = 1'b0;
            sticky_bit         = 1'b0;
            round_up           = 1'b0;
            shifted_magnitude  = 49'd0;
            subnormal_shifted  = 64'd0;
            subnormal_quotient = 50'd0;
            subnormal_rounded  = 50'd0;
            leading_index      = -1;
            unbiased_exp       = 0;
            biased_exp_integer  = 0;
            base_exp_integer     =
                $signed({{21{base_exp[10]}}, base_exp});
            shift_amount       = 0;
            subnormal_power    = 0;

            for (scan = 0; scan < 49; scan = scan + 1) begin
                if (exact_magnitude[scan]) begin
                    leading_index = scan;
                end
            end

            if (leading_index < 0) begin
                // Exact cancellation is +0 under RNE.
                result = 32'd0;
            end else begin
                unbiased_exp = base_exp_integer + leading_index;
                if (unbiased_exp >= -126) begin
                    shift_amount = leading_index - 23;
                    if (shift_amount > 0) begin
                        shifted_magnitude =
                            exact_magnitude >> shift_amount;
                        retained_sig = shifted_magnitude[23:0];
                        guard_bit = exact_magnitude[shift_amount-1];
                        sticky_bit = 1'b0;
                        for (scan = 0; scan < 49; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit
                                           | exact_magnitude[scan];
                            end
                        end
                    end else begin
                        shifted_magnitude =
                            exact_magnitude << (-shift_amount);
                        retained_sig = shifted_magnitude[23:0];
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
                    // This path is reached only by cancellation near the
                    // binary32 normal/subnormal boundary.  Pack gradually.
                    subnormal_power = base_exp_integer + 149;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                    if (subnormal_power >= 0) begin
                        subnormal_shifted =
                            {15'd0, exact_magnitude}
                            << subnormal_power;
                        subnormal_quotient =
                            {1'b0, subnormal_shifted[48:0]};
                    end else begin
                        shift_amount = -subnormal_power;
                        if (shift_amount < 49) begin
                            subnormal_quotient =
                                {1'b0, exact_magnitude} >> shift_amount;
                        end
                        if ((shift_amount >= 1) && (shift_amount <= 49)) begin
                            guard_bit = exact_magnitude[shift_amount-1];
                        end
                        for (scan = 0; scan < 49; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit
                                           | exact_magnitude[scan];
                            end
                        end
                    end

                    round_up = guard_bit
                             & (sticky_bit | subnormal_quotient[0]);
                    subnormal_rounded = subnormal_quotient
                                      + {{49{1'b0}}, round_up};
                    if (subnormal_rounded[23]) begin
                        result = {sign, 8'd1, 23'd0};
                    end else begin
                        result = {sign, 8'd0, subnormal_rounded[22:0]};
                        // Tininess-after-rounding flag semantics, including
                        // exact nonzero subnormal results.
                        underflow_flag = 1'b1;
                    end
                end
            end

            pack_exact_fp32 = {
                underflow_flag,
                overflow_flag,
                1'b0,
                result
            };
        end
    endfunction

    // Stage 0 captures the operands.  The next combinational cone performs
    // classification, magnitude sorting, exact alignment, and exact add/sub.
    // Its 49-bit magnitude and common binary exponent are the meaningful
    // timing cut before normalization and RNE packing.
    logic        s0_valid_q;
    logic [31:0] s0_a_q;
    logic [31:0] s0_b_q;

    logic [7:0]  exp_a_s0;
    logic [7:0]  exp_b_s0;
    logic [23:0] sig_a_s0;
    logic [23:0] sig_b_s0;
    logic        a_zero_s0;
    logic        b_zero_s0;
    logic        a_unsupported_s0;
    logic        b_unsupported_s0;
    logic [7:0]  high_exp_s0;
    logic [7:0]  low_exp_s0;
    logic [23:0] high_sig_s0;
    logic [23:0] low_sig_s0;
    logic        high_sign_s0;
    logic        low_sign_s0;
    logic [48:0] high_aligned_s0;
    logic [48:0] low_exact_s0;
    integer      high_exp_integer_s0;
    integer      low_exp_integer_s0;
    integer      exponent_distance_s0;
    integer      common_base_exp_s0;

    logic               s1_direct_d;
    logic        [34:0] s1_direct_bundle_d;
    logic               s1_sign_d;
    logic        [48:0] s1_exact_magnitude_d;
    logic signed [10:0] s1_base_exp_d;

    always_comb begin
        exp_a_s0 = s0_a_q[30:23];
        exp_b_s0 = s0_b_q[30:23];
        sig_a_s0 = {1'b1, s0_a_q[22:0]};
        sig_b_s0 = {1'b1, s0_b_q[22:0]};
        a_zero_s0 = (exp_a_s0 == 8'd0)
                  && (s0_a_q[22:0] == 23'd0);
        b_zero_s0 = (exp_b_s0 == 8'd0)
                  && (s0_b_q[22:0] == 23'd0);
        a_unsupported_s0 = (exp_a_s0 == 8'hff)
                         || ((exp_a_s0 == 8'd0) && !a_zero_s0);
        b_unsupported_s0 = (exp_b_s0 == 8'hff)
                         || ((exp_b_s0 == 8'd0) && !b_zero_s0);

        high_exp_s0 = exp_a_s0;
        low_exp_s0 = exp_b_s0;
        high_sig_s0 = sig_a_s0;
        low_sig_s0 = sig_b_s0;
        high_sign_s0 = s0_a_q[31];
        low_sign_s0 = s0_b_q[31];
        high_aligned_s0 = 49'd0;
        low_exact_s0 = 49'd0;
        high_exp_integer_s0 = 0;
        low_exp_integer_s0 = 0;
        exponent_distance_s0 = 0;
        common_base_exp_s0 = 0;

        s1_direct_d = 1'b0;
        s1_direct_bundle_d = 35'd0;
        s1_sign_d = 1'b0;
        s1_exact_magnitude_d = 49'd0;
        s1_base_exp_d = 11'sd0;

        if (a_unsupported_s0 || b_unsupported_s0) begin
            s1_direct_d = 1'b1;
            s1_direct_bundle_d = {
                1'b0,
                1'b0,
                1'b1,
                32'h7fc0_0000
            };
        end else if (a_zero_s0 && b_zero_s0) begin
            // IEEE RNE sign rule: only -0 + -0 gives -0.
            s1_direct_d = 1'b1;
            s1_direct_bundle_d = {
                3'b000,
                s0_a_q[31] & s0_b_q[31],
                31'd0
            };
        end else if (a_zero_s0) begin
            s1_direct_d = 1'b1;
            s1_direct_bundle_d = {3'b000, s0_b_q};
        end else if (b_zero_s0) begin
            s1_direct_d = 1'b1;
            s1_direct_bundle_d = {3'b000, s0_a_q};
        end else begin
            // Sort by absolute value so unlike-sign arithmetic is always an
            // unsigned high-low subtraction.
            if ((exp_b_s0 > exp_a_s0)
                || ((exp_b_s0 == exp_a_s0)
                    && (sig_b_s0 > sig_a_s0))) begin
                high_exp_s0 = exp_b_s0;
                low_exp_s0 = exp_a_s0;
                high_sig_s0 = sig_b_s0;
                low_sig_s0 = sig_a_s0;
                high_sign_s0 = s0_b_q[31];
                low_sign_s0 = s0_a_q[31];
            end

            high_exp_integer_s0 = {24'd0, high_exp_s0};
            low_exp_integer_s0 = {24'd0, low_exp_s0};
            exponent_distance_s0 =
                high_exp_integer_s0 - low_exp_integer_s0;

            if (exponent_distance_s0 >= 26) begin
                // At this distance the lower operand cannot change RNE, even
                // below an exact power-of-two binade boundary.
                s1_direct_d = 1'b1;
                s1_direct_bundle_d = {
                    3'b000,
                    high_sign_s0,
                    high_exp_s0,
                    high_sig_s0[22:0]
                };
            end else begin
                high_aligned_s0 = {25'd0, high_sig_s0}
                                << exponent_distance_s0;
                low_exact_s0 = {25'd0, low_sig_s0};
                s1_sign_d = high_sign_s0;
                if (high_sign_s0 == low_sign_s0) begin
                    s1_exact_magnitude_d =
                        high_aligned_s0 + low_exact_s0;
                end else begin
                    s1_exact_magnitude_d =
                        high_aligned_s0 - low_exact_s0;
                end
                // Each normal input denotes sig * 2**(field-150).
                common_base_exp_s0 = low_exp_integer_s0 - 150;
                s1_base_exp_d = common_base_exp_s0[10:0];
            end
        end
    end

    // Stage 1 registers the exact aligned arithmetic.  Stage 2 performs the
    // leading-bit search, normalization, GRS/RNE, and final binary32 packing.
    logic               s1_valid_q;
    logic               s1_direct_q;
    logic        [34:0] s1_direct_bundle_q;
    logic               s1_sign_q;
    logic        [48:0] s1_exact_magnitude_q;
    logic signed [10:0] s1_base_exp_q;
    logic        [34:0] packed_s1;

    always_comb begin
        if (s1_direct_q) begin
            packed_s1 = s1_direct_bundle_q;
        end else begin
            packed_s1 = pack_exact_fp32(
                s1_sign_q,
                s1_exact_magnitude_q,
                s1_base_exp_q
            );
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q            <= 1'b0;
            s0_a_q                <= 32'd0;
            s0_b_q                <= 32'd0;
            s1_valid_q            <= 1'b0;
            s1_direct_q           <= 1'b0;
            s1_direct_bundle_q    <= 35'd0;
            s1_sign_q             <= 1'b0;
            s1_exact_magnitude_q  <= 49'd0;
            s1_base_exp_q         <= 11'sd0;
            out_valid_o           <= 1'b0;
            result_o              <= 32'd0;
            invalid_o             <= 1'b0;
            overflow_o            <= 1'b0;
            underflow_o           <= 1'b0;
        end else begin
            s0_valid_q <= in_valid_i;
            if (in_valid_i) begin
                s0_a_q <= a_i;
                s0_b_q <= b_i;
            end

            s1_valid_q <= s0_valid_q;
            if (s0_valid_q) begin
                s1_direct_q          <= s1_direct_d;
                s1_direct_bundle_q   <= s1_direct_bundle_d;
                s1_sign_q            <= s1_sign_d;
                s1_exact_magnitude_q <= s1_exact_magnitude_d;
                s1_base_exp_q        <= s1_base_exp_d;
            end

            out_valid_o <= s1_valid_q;
            if (s1_valid_q) begin
                result_o    <= packed_s1[RESULT_LSB +: 32];
                invalid_o   <= packed_s1[INVALID_BIT];
                overflow_o  <= packed_s1[OVERFLOW_BIT];
                underflow_o <= packed_s1[UNDERFLOW_BIT];
            end else begin
                result_o    <= 32'd0;
                invalid_o   <= 1'b0;
                overflow_o  <= 1'b0;
                underflow_o <= 1'b0;
            end
        end
    end

endmodule
