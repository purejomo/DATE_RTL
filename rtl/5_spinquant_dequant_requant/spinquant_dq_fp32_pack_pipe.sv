`timescale 1ns/1ps

// Final shared packer for the AWQ in-PCU dequantization path.
//
// Numeric operation:
//
//   float16_o = RNE_float16(fp32_i)
//
// This is rtl/3_p3llm_dequant_rne/p3llm_dequant_fp32_fp16_mul_pack_pipe.sv with
// the second scale multiply removed and the output format parameterized.
//
// Why there is no second scale.  P3-LLM splits its dequantization into a
// per-group vector scale and one common final scale (the token activation
// scale, or the common query scale).  AWQ has neither: the activation is
// already bfloat16 or binary16, so the only quantization scale in the problem
// is the weight group scale, and that one is consumed by the first multiplier.
// AWQ also has no requantization step for the same reason -- the output format
// is the activation format the next layer already reads.
//
// EXP_W/MANT_W select the output format: 8/7 is bfloat16, 5/10 is binary16.
// Both are sixteen bits wide, so the port width does not change.
//
// fp32_i may be any finite binary32 value (normal, subnormal, or signed zero).
// A binary32 infinity/NaN asserts invalid_o and produces the canonical quiet
// NaN of the output format.  Packing uses gradual underflow and
// round-to-nearest, ties-to-even; overflow goes to signed infinity, which is
// the IEEE RNE destination and is representable in both output formats.
//
// The binary32 significand is retained exactly until the one final rounding.
// No intermediate rounding is inserted ahead of the requested conversion.
//
// Pipeline/latency contract:
//   * initiation interval is one clock; bubbles are allowed;
//   * LATENCY is the number of full rising-edge intervals from acceptance to
//     result: an input sampled with in_valid_i at edge N is reported with
//     out_valid_o immediately after edge N+LATENCY;
//   * outputs/flags are zero during bubbles.
// A lane/context tag can therefore be delayed by LATENCY clocks in parallel.
module spinquant_dq_fp32_pack_pipe #(
    parameter int unsigned EXP_W  = 8,   // 8 = bfloat16, 5 = binary16
    parameter int unsigned MANT_W = 7    // 7 = bfloat16, 10 = binary16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid_i,
    input  logic [31:0] fp32_i,

    output logic        out_valid_o,
    output logic [15:0] float16_o,
    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o
);

    localparam int unsigned LATENCY = 1;

    localparam int unsigned SIG_W = 24;              // binary32 significand
    localparam int          OBIAS = (1 << (EXP_W - 1)) - 1;
    localparam int          EMIN  = 1 - OBIAS;       // least normal exponent
    localparam int          EMAX  = OBIAS;           // greatest normal exponent
    // A subnormal output fraction is RNE(significand * 2**(base_exp + SUBP)).
    localparam int          SUBP  = OBIAS + MANT_W - 1;

    localparam int unsigned RESULT_LSB    = 0;
    localparam int unsigned INVALID_BIT   = 16;
    localparam int unsigned OVERFLOW_BIT  = 17;
    localparam int unsigned UNDERFLOW_BIT = 18;

    function automatic logic [18:0] pack_exact_float16 (
        input logic              sign,
        input logic              invalid,
        input logic [SIG_W-1:0]  significand,
        input logic signed [11:0] base_exp
    );
        logic [15:0]        result;
        logic               invalid_flag;
        logic               overflow_flag;
        logic               underflow_flag;
        logic [MANT_W:0]    retained_sig;
        logic [MANT_W+1:0]  rounded_sig;
        logic [EXP_W-1:0]   biased_exp;
        logic               guard_bit;
        logic               sticky_bit;
        logic               round_up;
        logic [SIG_W-1:0]   shifted_sig;
        logic [63:0]        subnormal_shifted;
        logic [SIG_W:0]     subnormal_quotient;
        logic [SIG_W:0]     subnormal_rounded;
        integer             leading_index;
        integer             unbiased_exp;
        integer             biased_exp_integer;
        integer             base_exp_integer;
        integer             shift_amount;
        integer             subnormal_power;
        integer             scan;
        begin
            result             = 16'd0;
            invalid_flag       = invalid;
            overflow_flag      = 1'b0;
            underflow_flag     = 1'b0;
            retained_sig       = {(MANT_W+1){1'b0}};
            rounded_sig        = {(MANT_W+2){1'b0}};
            biased_exp         = {EXP_W{1'b0}};
            guard_bit          = 1'b0;
            sticky_bit         = 1'b0;
            round_up           = 1'b0;
            shifted_sig        = {SIG_W{1'b0}};
            subnormal_shifted  = 64'd0;
            subnormal_quotient = {(SIG_W+1){1'b0}};
            subnormal_rounded  = {(SIG_W+1){1'b0}};
            leading_index      = -1;
            unbiased_exp       = 0;
            biased_exp_integer = 0;
            base_exp_integer   =
                $signed({{20{base_exp[11]}}, base_exp});
            shift_amount       = 0;
            subnormal_power    = 0;

            for (scan = 0; scan < SIG_W; scan = scan + 1) begin
                if (significand[scan]) begin
                    leading_index = scan;
                end
            end

            if (invalid) begin
                // Canonical quiet NaN of the output format.
                result = {1'b0, {EXP_W{1'b1}}, 1'b1, {(MANT_W-1){1'b0}}};
            end else if (leading_index < 0) begin
                result = {sign, 15'd0};
            end else begin
                unbiased_exp = base_exp_integer + leading_index;
                if (unbiased_exp >= EMIN) begin
                    shift_amount = leading_index - MANT_W;
                    if (shift_amount > 0) begin
                        shifted_sig = significand >> shift_amount;
                        retained_sig = shifted_sig[MANT_W:0];
                        guard_bit = significand[shift_amount-1];
                        sticky_bit = 1'b0;
                        for (scan = 0; scan < SIG_W; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | significand[scan];
                            end
                        end
                    end else begin
                        shifted_sig = significand << (-shift_amount);
                        retained_sig = shifted_sig[MANT_W:0];
                    end

                    round_up = guard_bit
                             & (sticky_bit | retained_sig[0]);
                    rounded_sig = {1'b0, retained_sig}
                                + {{(MANT_W+1){1'b0}}, round_up};
                    if (rounded_sig[MANT_W+1]) begin
                        retained_sig = rounded_sig[MANT_W+1:1];
                        unbiased_exp = unbiased_exp + 1;
                    end else begin
                        retained_sig = rounded_sig[MANT_W:0];
                    end

                    if (unbiased_exp > EMAX) begin
                        // IEEE RNE overflow destination is signed infinity.
                        result = {sign, {EXP_W{1'b1}}, {MANT_W{1'b0}}};
                        overflow_flag = 1'b1;
                    end else begin
                        biased_exp_integer = unbiased_exp + OBIAS;
                        biased_exp = biased_exp_integer[EXP_W-1:0];
                        result = {sign, biased_exp,
                                  retained_sig[MANT_W-1:0]};
                    end
                end else begin
                    subnormal_power = base_exp_integer + SUBP;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                    if (subnormal_power >= 0) begin
                        // The subnormal condition guarantees this exact shift
                        // stays below the hidden-bit position.
                        subnormal_shifted =
                            {{(64-SIG_W){1'b0}}, significand}
                            << subnormal_power;
                        subnormal_quotient = subnormal_shifted[SIG_W:0];
                    end else begin
                        shift_amount = -subnormal_power;
                        if (shift_amount < SIG_W) begin
                            subnormal_quotient =
                                {1'b0, significand} >> shift_amount;
                        end else begin
                            subnormal_quotient = {(SIG_W+1){1'b0}};
                        end
                        if ((shift_amount >= 1) &&
                            (shift_amount <= SIG_W)) begin
                            guard_bit = significand[shift_amount-1];
                        end
                        for (scan = 0; scan < SIG_W; scan = scan + 1) begin
                            if (scan < (shift_amount - 1)) begin
                                sticky_bit = sticky_bit | significand[scan];
                            end
                        end
                    end

                    round_up = guard_bit
                             & (sticky_bit | subnormal_quotient[0]);
                    subnormal_rounded = subnormal_quotient
                                      + {{SIG_W{1'b0}}, round_up};
                    if (subnormal_rounded[MANT_W]) begin
                        // RNE promoted the largest tiny result to min-normal.
                        result = {sign, {{(EXP_W-1){1'b0}}, 1'b1},
                                  {MANT_W{1'b0}}};
                    end else begin
                        result = {sign, {EXP_W{1'b0}},
                                  subnormal_rounded[MANT_W-1:0]};
                        // Tininess-after-rounding semantics: exact nonzero
                        // subnormal outputs also assert underflow_o.
                        underflow_flag = 1'b1;
                    end
                end
            end

            pack_exact_float16 = {
                underflow_flag,
                overflow_flag,
                invalid_flag,
                result
            };
        end
    endfunction

    logic [SIG_W-1:0]   significand_d;
    logic signed [11:0] base_exp_d;
    logic               sign_d;
    logic               invalid_d;
    integer             base_exp_integer_d;
    integer             fp32_exp_integer_d;

    always_comb begin
        sign_d = fp32_i[31];
        invalid_d = (fp32_i[30:23] == 8'hff);

        fp32_exp_integer_d = {24'd0, fp32_i[30:23]};
        if (fp32_i[30:23] == 8'd0) begin
            // Includes signed zero and binary32 subnormal inputs.
            significand_d = {1'b0, fp32_i[22:0]};
            base_exp_integer_d = -149;
        end else begin
            significand_d = {1'b1, fp32_i[22:0]};
            base_exp_integer_d = fp32_exp_integer_d - 150;
        end
        base_exp_d = base_exp_integer_d[11:0];
    end

    // Stage 0: decode and register the exact binary32 significand.
    logic               s0_valid_q;
    logic               s0_sign_q;
    logic               s0_invalid_q;
    logic [SIG_W-1:0]   s0_significand_q;
    logic signed [11:0] s0_base_exp_q;
    logic        [18:0] packed_s0;

    always_comb begin
        packed_s0 = pack_exact_float16(
            s0_sign_q,
            s0_invalid_q,
            s0_significand_q,
            s0_base_exp_q
        );
    end

    // Stage 1: normalize, gradual-underflow RNE-pack, and register the result.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q       <= 1'b0;
            s0_sign_q        <= 1'b0;
            s0_invalid_q     <= 1'b0;
            s0_significand_q <= {SIG_W{1'b0}};
            s0_base_exp_q    <= 12'sd0;
            out_valid_o      <= 1'b0;
            float16_o        <= 16'd0;
            invalid_o        <= 1'b0;
            overflow_o       <= 1'b0;
            underflow_o      <= 1'b0;
        end else begin
            s0_valid_q <= in_valid_i;
            if (in_valid_i) begin
                s0_sign_q        <= sign_d;
                s0_invalid_q     <= invalid_d;
                s0_significand_q <= significand_d;
                s0_base_exp_q    <= base_exp_d;
            end

            out_valid_o <= s0_valid_q;
            if (s0_valid_q) begin
                float16_o   <= packed_s0[RESULT_LSB +: 16];
                invalid_o   <= packed_s0[INVALID_BIT];
                overflow_o  <= packed_s0[OVERFLOW_BIT];
                underflow_o <= packed_s0[UNDERFLOW_BIT];
            end else begin
                float16_o   <= 16'd0;
                invalid_o   <= 1'b0;
                overflow_o  <= 1'b0;
                underflow_o <= 1'b0;
            end
        end
    end

endmodule
