`timescale 1ns/1ps

// IEEE-754 binary16 adder with round-to-nearest, ties-to-even.
// The finite path carries an 11-bit significand plus guard, round, and sticky
// bits. The lane is combinational; the execution datapath supplies the cycle
// boundary and exposes the rounded value through A_OUT.
module hbmpim_fp16_add_lane (
    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire [15:0] o_result
);

    // Align an 11-bit significand into hidden/fraction plus GRS positions.
    // Shifts of 13 or more retain only a sticky bit.
    function automatic [13:0] align_significand;
        input [10:0] significand;
        input [4:0] shift;
        begin
            case (shift)
                5'd0:  align_significand = {significand, 3'b000};
                5'd1:  align_significand = {1'b0, significand, 2'b00};
                5'd2:  align_significand = {2'b00, significand, 1'b0};
                5'd3:  align_significand = {3'b000, significand};
                5'd4:  align_significand = {
                    4'b0000, significand[10:2], |significand[1:0]
                };
                5'd5:  align_significand = {
                    5'b00000, significand[10:3], |significand[2:0]
                };
                5'd6:  align_significand = {
                    6'b000000, significand[10:4], |significand[3:0]
                };
                5'd7:  align_significand = {
                    7'b0000000, significand[10:5], |significand[4:0]
                };
                5'd8:  align_significand = {
                    8'b00000000, significand[10:6], |significand[5:0]
                };
                5'd9:  align_significand = {
                    9'b000000000, significand[10:7], |significand[6:0]
                };
                5'd10: align_significand = {
                    10'b0000000000, significand[10:8], |significand[7:0]
                };
                5'd11: align_significand = {
                    11'b00000000000, significand[10:9], |significand[8:0]
                };
                5'd12: align_significand = {
                    12'b000000000000, significand[10], |significand[9:0]
                };
                default: align_significand = {
                    13'b0000000000000, |significand
                };
            endcase
        end
    endfunction

    function automatic [3:0] leading_zero_count14;
        input [13:0] value;
        begin
            casez (value)
                14'b1?????????????: leading_zero_count14 = 4'd0;
                14'b01????????????: leading_zero_count14 = 4'd1;
                14'b001???????????: leading_zero_count14 = 4'd2;
                14'b0001??????????: leading_zero_count14 = 4'd3;
                14'b00001?????????: leading_zero_count14 = 4'd4;
                14'b000001????????: leading_zero_count14 = 4'd5;
                14'b0000001???????: leading_zero_count14 = 4'd6;
                14'b00000001??????: leading_zero_count14 = 4'd7;
                14'b000000001?????: leading_zero_count14 = 4'd8;
                14'b0000000001????: leading_zero_count14 = 4'd9;
                14'b00000000001???: leading_zero_count14 = 4'd10;
                14'b000000000001??: leading_zero_count14 = 4'd11;
                14'b0000000000001?: leading_zero_count14 = 4'd12;
                14'b00000000000001: leading_zero_count14 = 4'd13;
                default:            leading_zero_count14 = 4'd14;
            endcase
        end
    endfunction

    function automatic [15:0] fp16_add_rne;
        input [15:0] a;
        input [15:0] b;
        reg a_nan;
        reg b_nan;
        reg a_inf;
        reg b_inf;
        reg [4:0] exp_a;
        reg [4:0] exp_b;
        reg [4:0] effective_exp_a;
        reg [4:0] effective_exp_b;
        reg [4:0] high_exp;
        reg [4:0] low_exp;
        reg [4:0] exp_difference;
        reg [4:0] result_exp;
        reg [4:0] available_shift;
        reg [10:0] sig_a;
        reg [10:0] sig_b;
        reg [10:0] high_sig;
        reg [10:0] low_sig;
        reg high_sign;
        reg low_sign;
        reg result_sign;
        reg exact_zero;
        reg [13:0] high_extended;
        reg [13:0] low_aligned;
        reg [13:0] normalized;
        reg [13:0] difference;
        reg [14:0] sum;
        reg [3:0] leading_zeros;
        reg [3:0] normalize_shift;
        reg round_up;
        reg [11:0] rounded_sig;
        begin
            exp_a = a[14:10];
            exp_b = b[14:10];
            a_nan = (exp_a == 5'h1f) && (a[9:0] != 10'd0);
            b_nan = (exp_b == 5'h1f) && (b[9:0] != 10'd0);
            a_inf = (exp_a == 5'h1f) && (a[9:0] == 10'd0);
            b_inf = (exp_b == 5'h1f) && (b[9:0] == 10'd0);

            effective_exp_a = (exp_a == 5'd0) ? 5'd1 : exp_a;
            effective_exp_b = (exp_b == 5'd0) ? 5'd1 : exp_b;
            sig_a = (exp_a == 5'd0) ?
                {1'b0, a[9:0]} : {1'b1, a[9:0]};
            sig_b = (exp_b == 5'd0) ?
                {1'b0, b[9:0]} : {1'b1, b[9:0]};

            high_exp = effective_exp_a;
            low_exp = effective_exp_b;
            high_sig = sig_a;
            low_sig = sig_b;
            high_sign = a[15];
            low_sign = b[15];
            if ((effective_exp_b > effective_exp_a) ||
                ((effective_exp_b == effective_exp_a) && (sig_b > sig_a))) begin
                high_exp = effective_exp_b;
                low_exp = effective_exp_a;
                high_sig = sig_b;
                low_sig = sig_a;
                high_sign = b[15];
                low_sign = a[15];
            end

            exp_difference = high_exp - low_exp;
            high_extended = {high_sig, 3'b000};
            low_aligned = align_significand(low_sig, exp_difference);
            result_sign = high_sign;
            result_exp = high_exp;
            normalized = 14'd0;
            difference = 14'd0;
            sum = 15'd0;
            leading_zeros = 4'd0;
            normalize_shift = 4'd0;
            available_shift = 5'd0;
            exact_zero = 1'b0;
            round_up = 1'b0;
            rounded_sig = 12'd0;

            if (high_sign == low_sign) begin
                sum = {1'b0, high_extended} + {1'b0, low_aligned};
                if (sum == 15'd0) begin
                    exact_zero = 1'b1;
                end else if (sum[14]) begin
                    // Shift-right-jam one place after a same-sign carry.
                    normalized = {sum[14:2], sum[1] | sum[0]};
                    result_exp = high_exp + 5'd1;
                end else begin
                    normalized = sum[13:0];
                end
            end else begin
                difference = high_extended - low_aligned;
                if (difference == 14'd0) begin
                    exact_zero = 1'b1;
                end else begin
                    leading_zeros = leading_zero_count14(difference);
                    available_shift = high_exp - 5'd1;
                    if ({1'b0, leading_zeros} > available_shift) begin
                        normalize_shift = available_shift[3:0];
                    end else begin
                        normalize_shift = leading_zeros;
                    end
                    normalized = difference << normalize_shift;
                    result_exp = high_exp - {1'b0, normalize_shift};
                end
            end

            if (a_nan || b_nan ||
                (a_inf && b_inf && (a[15] != b[15]))) begin
                fp16_add_rne = 16'h7e00;
            end else if (a_inf) begin
                fp16_add_rne = {a[15], 5'h1f, 10'd0};
            end else if (b_inf) begin
                fp16_add_rne = {b[15], 5'h1f, 10'd0};
            end else if (exact_zero) begin
                // RNE gives -0 only when both exact-zero inputs are negative.
                fp16_add_rne = {a[15] & b[15], 15'd0};
            end else begin
                round_up = normalized[2] &&
                    (normalized[1] || normalized[0] || normalized[3]);
                rounded_sig = {1'b0, normalized[13:3]} +
                    {11'd0, round_up};

                if (rounded_sig[11]) begin
                    rounded_sig = rounded_sig >> 1;
                    result_exp = result_exp + 5'd1;
                end

                if (result_exp >= 5'd31) begin
                    fp16_add_rne = {result_sign, 5'h1f, 10'd0};
                end else if ((result_exp == 5'd1) && !rounded_sig[10]) begin
                    // Effective exponent one with no hidden bit is subnormal.
                    fp16_add_rne = {result_sign, 5'd0, rounded_sig[9:0]};
                end else begin
                    fp16_add_rne = {
                        result_sign, result_exp, rounded_sig[9:0]
                    };
                end
            end
        end
    endfunction

    assign o_result = fp16_add_rne(i_a, i_b);

endmodule
