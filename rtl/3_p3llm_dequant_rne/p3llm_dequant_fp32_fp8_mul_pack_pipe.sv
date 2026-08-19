`timescale 1ns/1ps

// Final shared scaler/packer for the P3-LLM in-PCU dequantization path.
//
// Numeric operation:
//
//   fp8_o = RNE_E4M3(fp32_i * scale_i)
//
// The output format is OCP FP8-E4M3FN, not binary16.  P3-LLM's activations are
// FP8: rtl/3_p3llm/p3llm_pe.sv decodes the LHS as E4M3 in OP_LINEAR and OP_QK
// and as S0E4M4 in OP_PV.  Ending the dequantization in binary16 would leave
// the requantization to the host, which is exactly the data movement this
// design exists to remove, so the PCU emits the format the next layer reads.
//
// All three modes emit E4M3.  S0E4M4 is the format softmax produces, so it
// appears only as a PCU *input*: an OP_QK result is the signed score that goes
// to softmax, and an OP_PV result is the activation of the output projection.
// Neither is ever an unsigned probability.
//
// This module is the exact inverse of fp8_e4m3_decoder.sv in the same
// directory, which defines the encoding as
//
//     normal    (exp != 0)  value = {1, frac, 0} * 2**(exp - 11)
//                                 = (8 + frac) * 2**(exp - 10)
//     subnormal (exp == 0)  value = {0, frac, 0} * 2**(1 - 11)
//                                 = frac * 2**-9
//     NaN       exp == 0xf and frac == 0x7 (codes 0x7f and 0xff)
//
// so bias 7, three fraction bits, gradual underflow, and a maximum finite
// magnitude of 448 at exp = 0xf, frac = 6.  verif's p3llm_dequant_arith
// regression checks the round trip over all 256 codes.
//
// Range policy, matching rabit_fs_fp16_pack.sv rather than IEEE binary16:
//   - a magnitude at or above the rounding boundary of the largest finite code
//     saturates to that code (0x7e / 0xfe) and raises overflow_o.  No infinity
//     is produced, because E4M3FN has none: the only non-finite encoding is
//     NaN, and emitting 0x7f here would make the decoder read a NaN where the
//     arithmetic produced a large finite number.
//   - subnormals are produced exactly, never flushed, because the decoder
//     represents them exactly.
//   - a zero magnitude yields signed zero.
//
// fp32_i may be any finite binary32 value (normal, subnormal, or signed zero).
// scale_i is required to be positive and finite; +0 and binary16 subnormals are
// supported.  A binary32 infinity/NaN, or a negative/infinite/NaN scale,
// asserts invalid_o and produces the canonical E4M3 NaN (0x7f).
//
// The exact 24-by-11-bit significand product is retained until the one final
// E4M3 rounding.  No binary32 multiply rounding is inserted ahead of the
// requested output conversion.
//
// Pipeline/latency contract:
//   * initiation interval is one clock; bubbles are allowed;
//   * LATENCY is the number of full rising-edge intervals from acceptance to
//     result: an input sampled with in_valid_i at edge N is reported with
//     out_valid_o immediately after edge N+LATENCY;
//   * outputs/flags are zero during bubbles.
// A lane/context tag can therefore be delayed by LATENCY clocks in parallel.
module p3llm_dequant_fp32_fp8_mul_pack_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid_i,
    input  logic [31:0] fp32_i,
    input  logic [15:0] scale_i,

    output logic        out_valid_o,
    output logic [7:0]  fp8_o,
    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o
);

    localparam int unsigned LATENCY = 1;

    // OCP FP8-E4M3FN.
    localparam int unsigned E4M3_EXP_W  = 4;
    localparam int unsigned E4M3_MANT_W = 3;
    localparam int          E4M3_BIAS   = 7;
    localparam int          E4M3_EMIN   = 1 - E4M3_BIAS;   // -6, least normal
    localparam int          E4M3_EMAX   = 8;               // 0xf - bias
    // A subnormal fraction is RNE(product * 2**(base_exp + SUBP)).
    localparam int          E4M3_SUBP   = E4M3_BIAS + E4M3_MANT_W - 1;  // 9
    localparam logic [7:0]  E4M3_NAN    = 8'h7f;
    localparam logic [6:0]  E4M3_MAX    = {4'hf, 3'h6};    // magnitude 448

    localparam int unsigned RESULT_LSB    = 0;
    localparam int unsigned INVALID_BIT   = 8;
    localparam int unsigned OVERFLOW_BIT  = 9;
    localparam int unsigned UNDERFLOW_BIT = 10;

    function automatic logic [10:0] pack_exact_fp8 (
        input logic               sign,
        input logic               invalid,
        input logic        [34:0] exact_product,
        input logic signed [11:0] base_exp
    );
        logic [7:0]  result;
        logic        invalid_flag;
        logic        overflow_flag;
        logic        underflow_flag;
        logic [3:0]  retained_sig;      // hidden bit + 3 fraction bits
        logic [4:0]  rounded_sig;
        logic [3:0]  biased_exp;
        logic        guard_bit;
        logic        sticky_bit;
        logic        round_up;
        logic [34:0] shifted_product;
        logic [63:0] subnormal_shifted;
        logic [35:0] subnormal_quotient;
        logic [35:0] subnormal_rounded;
        integer      leading_index;
        integer      unbiased_exp;
        integer      biased_exp_integer;
        integer      base_exp_integer;
        integer      shift_amount;
        integer      subnormal_power;
        integer      scan;
        begin
            result             = 8'd0;
            invalid_flag       = invalid;
            overflow_flag      = 1'b0;
            underflow_flag     = 1'b0;
            retained_sig       = 4'd0;
            rounded_sig        = 5'd0;
            biased_exp         = 4'd0;
            guard_bit          = 1'b0;
            sticky_bit         = 1'b0;
            round_up           = 1'b0;
            shifted_product    = 35'd0;
            subnormal_shifted  = 64'd0;
            subnormal_quotient = 36'd0;
            subnormal_rounded  = 36'd0;
            leading_index      = -1;
            unbiased_exp       = 0;
            biased_exp_integer = 0;
            base_exp_integer   =
                $signed({{20{base_exp[11]}}, base_exp});
            shift_amount       = 0;
            subnormal_power    = 0;

            for (scan = 0; scan < 35; scan = scan + 1) begin
                if (exact_product[scan]) begin
                    leading_index = scan;
                end
            end

            if (invalid) begin
                result = E4M3_NAN;
            end else if (leading_index < 0) begin
                result = {sign, 7'd0};
            end else begin
                unbiased_exp = base_exp_integer + leading_index;
                if (unbiased_exp >= E4M3_EMIN) begin
                    shift_amount = leading_index - E4M3_MANT_W;
                    if (shift_amount > 0) begin
                        shifted_product = exact_product >> shift_amount;
                        retained_sig = shifted_product[3:0];
                        guard_bit = exact_product[shift_amount-1];
                        sticky_bit = 1'b0;
                        for (scan = 0; scan < 35; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | exact_product[scan];
                            end
                        end
                    end else begin
                        shifted_product = exact_product << (-shift_amount);
                        retained_sig = shifted_product[3:0];
                    end

                    round_up = guard_bit
                             & (sticky_bit | retained_sig[0]);
                    rounded_sig = {1'b0, retained_sig}
                                + {{4{1'b0}}, round_up};
                    if (rounded_sig[4]) begin
                        retained_sig = rounded_sig[4:1];
                        unbiased_exp = unbiased_exp + 1;
                    end else begin
                        retained_sig = rounded_sig[3:0];
                    end

                    // E4M3FN has no infinity, and {0xf, 0x7} is NaN, so the
                    // largest finite code is the saturation destination.
                    if ((unbiased_exp > E4M3_EMAX) ||
                        ((unbiased_exp == E4M3_EMAX) &&
                         (retained_sig == 4'b1111))) begin
                        result = {sign, E4M3_MAX};
                        overflow_flag = 1'b1;
                    end else begin
                        biased_exp_integer = unbiased_exp + E4M3_BIAS;
                        biased_exp = biased_exp_integer[3:0];
                        result = {sign, biased_exp, retained_sig[2:0]};
                    end
                end else begin
                    // E4M3 subnormal fraction =
                    // RNE(exact_product * 2**(base_exp + 9)).
                    subnormal_power = base_exp_integer + E4M3_SUBP;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                    if (subnormal_power >= 0) begin
                        // The subnormal condition guarantees this exact shift
                        // remains below the E4M3 hidden-bit position.
                        subnormal_shifted =
                            {29'd0, exact_product} << subnormal_power;
                        subnormal_quotient = subnormal_shifted[35:0];
                    end else begin
                        shift_amount = -subnormal_power;
                        if (shift_amount < 35) begin
                            subnormal_quotient =
                                {1'b0, exact_product} >> shift_amount;
                        end
                        if ((shift_amount >= 1) && (shift_amount <= 35)) begin
                            guard_bit = exact_product[shift_amount-1];
                        end
                        for (scan = 0; scan < 35; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | exact_product[scan];
                            end
                        end
                    end

                    round_up = guard_bit
                             & (sticky_bit | subnormal_quotient[0]);
                    subnormal_rounded = subnormal_quotient
                                      + {{35{1'b0}}, round_up};
                    if (subnormal_rounded[E4M3_MANT_W]) begin
                        // RNE promoted the largest tiny result to min-normal.
                        result = {sign, 4'd1, 3'd0};
                    end else begin
                        result = {sign, 4'd0, subnormal_rounded[2:0]};
                        // Tininess-after-rounding semantics: exact nonzero
                        // subnormal outputs also assert underflow_o.
                        underflow_flag = 1'b1;
                    end
                end
            end

            pack_exact_fp8 = {
                underflow_flag,
                overflow_flag,
                invalid_flag,
                result
            };
        end
    endfunction

    logic        [23:0] fp32_significand_d;
    logic        [10:0] scale_significand_d;
    logic        [34:0] exact_product_d;
    logic signed [11:0] base_exp_d;
    logic                sign_d;
    logic                invalid_d;
    integer              base_exp_integer_d;
    integer              fp32_exp_integer_d;
    integer              scale_exp_integer_d;

    always_comb begin
        sign_d = fp32_i[31];
        invalid_d = (fp32_i[30:23] == 8'hff)
                  || scale_i[15]
                  || (scale_i[14:10] == 5'h1f);

        fp32_exp_integer_d = {24'd0, fp32_i[30:23]};
        scale_exp_integer_d = {27'd0, scale_i[14:10]};
        if (fp32_i[30:23] == 8'd0) begin
            // Includes signed zero and binary32 subnormal inputs.
            fp32_significand_d = {1'b0, fp32_i[22:0]};
            base_exp_integer_d = -149;
        end else begin
            fp32_significand_d = {1'b1, fp32_i[22:0]};
            base_exp_integer_d = fp32_exp_integer_d - 150;
        end

        if (scale_i[14:10] == 5'd0) begin
            scale_significand_d = {1'b0, scale_i[9:0]};
            base_exp_integer_d = base_exp_integer_d - 24;
        end else begin
            scale_significand_d = {1'b1, scale_i[9:0]};
            base_exp_integer_d = base_exp_integer_d
                               + scale_exp_integer_d - 25;
        end
        base_exp_d = base_exp_integer_d[11:0];
        exact_product_d = fp32_significand_d * scale_significand_d;
    end

    // Stage 0: decode and register the exact 24-by-11-bit product.
    logic               s0_valid_q;
    logic               s0_sign_q;
    logic               s0_invalid_q;
    logic        [34:0] s0_exact_product_q;
    logic signed [11:0] s0_base_exp_q;
    logic        [10:0] packed_s0;

    always_comb begin
        packed_s0 = pack_exact_fp8(
            s0_sign_q,
            s0_invalid_q,
            s0_exact_product_q,
            s0_base_exp_q
        );
    end

    // Stage 1: normalize, gradual-underflow RNE-pack, and register the E4M3
    // code.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q         <= 1'b0;
            s0_sign_q          <= 1'b0;
            s0_invalid_q       <= 1'b0;
            s0_exact_product_q <= 35'd0;
            s0_base_exp_q      <= 12'sd0;
            out_valid_o        <= 1'b0;
            fp8_o              <= 8'd0;
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
                fp8_o       <= packed_s0[RESULT_LSB +: 8];
                invalid_o   <= packed_s0[INVALID_BIT];
                overflow_o  <= packed_s0[OVERFLOW_BIT];
                underflow_o <= packed_s0[UNDERFLOW_BIT];
            end else begin
                fp8_o       <= 8'd0;
                invalid_o   <= 1'b0;
                overflow_o  <= 1'b0;
                underflow_o <= 1'b0;
            end
        end
    end

endmodule
