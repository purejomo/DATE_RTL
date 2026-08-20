`timescale 1ns/1ps

// binary32 -> unsigned INT4, round to nearest even, with the activation zero
// point added and the result clamped into [0, 15].
//
//     A_q'[i] = clamp( RNE(y[i] / s_a') + zp_a' , 0, 15 )
//
// The division by s_a' does not happen here. The driver folds it into the
// per-channel scale the multiply pipe already applies, so what arrives is
// already y/s_a' and this module only has to round it to an integer. zp_a' is
// an integer, so adding it after the rounding is exact and identical to adding
// it before -- which is why it can sit downstream of the rounder.
//
// Why the integer part is only six bits wide. The result is clamped into
// [0, 15] and zp_a' is at most 15, so any magnitude at or above 32 clamps
// whatever else happens. Writing the input as sig * 2**(exp - 150) with
// sig in [2**23, 2**24):
//
//     exp >= 132   magnitude >= 2**4 * 2 = 32          -> saturate
//     exp <= 125   magnitude <  2**-1 = 0.5            -> rounds to zero
//     126..131     shift = 150 - exp is in [19, 24]    -> the real path
//
// so the shifted quotient never exceeds five bits and one rounding carry. A
// full 24-bit barrel shifter would be dead silicon.
//
// Rounding is exactly the rule the rest of this repository uses:
//
//     round_bit = sig[shift-1]
//     sticky    = |sig[shift-2:0]
//     round_up  = round_bit & (sticky | quotient[0])   // tie -> even
//
// Infinities and NaNs saturate by sign and raise invalid_o; a NaN has no sign
// to respect, so it is reported rather than silently mapped.
module spinquant_rq_fp32_to_int4 (
    input  logic [31:0] fp32_i,
    input  logic [4:0]  zp_i,          // activation zero point, 0..15

    output logic [3:0]  q4_o,
    output logic        clamped_o,     // the clamp actually did something
    output logic        invalid_o      // input was inf or NaN
);

    logic        sign;
    logic [7:0]  exponent;
    logic [22:0] fraction;
    logic [23:0] significand;

    always_comb begin
        sign        = fp32_i[31];
        exponent    = fp32_i[30:23];
        fraction    = fp32_i[22:0];
        significand = {1'b1, fraction};
    end

    // ---- the six-bit magnitude -------------------------------------------
    //
    // Only six exponents reach the real path, so the shift is a six-way case
    // rather than a barrel shifter. Each arm is "quotient = sig >> (150-exp),
    // round bit just below it, sticky everything under that".
    logic [5:0]  quotient;
    logic        round_bit;
    logic        sticky;
    logic        round_up;
    logic [5:0]  magnitude;      // 0..32

    logic is_special;            // inf or NaN
    logic is_saturating;         // magnitude at or above 32
    logic is_tiny;               // magnitude below 0.5

    always_comb begin
        is_special    = (exponent == 8'd255);
        is_saturating = !is_special && (exponent >= 8'd132);
        is_tiny       = (exponent <= 8'd125);

        quotient  = 6'd0;
        round_bit = 1'b0;
        sticky    = 1'b0;

        case (exponent)
            8'd126: begin                                   // shift 24
                quotient  = 6'd0;
                round_bit = significand[23];
                sticky    = |significand[22:0];
            end
            8'd127: begin                                   // shift 23
                quotient  = {5'd0, significand[23]};
                round_bit = significand[22];
                sticky    = |significand[21:0];
            end
            8'd128: begin                                   // shift 22
                quotient  = {4'd0, significand[23:22]};
                round_bit = significand[21];
                sticky    = |significand[20:0];
            end
            8'd129: begin                                   // shift 21
                quotient  = {3'd0, significand[23:21]};
                round_bit = significand[20];
                sticky    = |significand[19:0];
            end
            8'd130: begin                                   // shift 20
                quotient  = {2'd0, significand[23:20]};
                round_bit = significand[19];
                sticky    = |significand[18:0];
            end
            8'd131: begin                                   // shift 19
                quotient  = {1'b0, significand[23:19]};
                round_bit = significand[18];
                sticky    = |significand[17:0];
            end
            default: begin
                quotient  = 6'd0;
                round_bit = 1'b0;
                sticky    = 1'b0;
            end
        endcase

        round_up = round_bit & (sticky | quotient[0]);

        if (is_special || is_saturating) begin
            magnitude = 6'd32;
        end else if (is_tiny) begin
            magnitude = 6'd0;
        end else begin
            magnitude = quotient + {5'd0, round_up};
        end
    end

    // ---- zero point and clamp --------------------------------------------
    //
    // signed_value is in [-32, 32] and zp_i in [0, 15], so the sum lives in
    // [-32, 47] and eight signed bits are enough.
    logic signed [7:0] signed_value;
    logic signed [7:0] shifted;

    always_comb begin
        signed_value = sign ? -$signed({2'b00, magnitude})
                            :  $signed({2'b00, magnitude});
        shifted      = signed_value + $signed({3'd0, zp_i});

        if (shifted < 8'sd0) begin
            q4_o      = 4'd0;
            clamped_o = 1'b1;
        end else if (shifted > 8'sd15) begin
            q4_o      = 4'd15;
            clamped_o = 1'b1;
        end else begin
            q4_o      = shifted[3:0];
            clamped_o = 1'b0;
        end

        invalid_o = is_special;
    end

endmodule
