`timescale 1ns/1ps

module bf16_add_lane (
    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire [15:0] o_result
);

    // Align an 8-bit significand into hidden/fraction plus GRS positions.
    // Shifts of ten or more retain only a sticky bit.
    function automatic [10:0] align_significand;
        input [7:0] significand;
        input [7:0] shift;
        begin
            case (shift)
                8'd0: align_significand = {significand, 3'b000};
                8'd1: align_significand = {1'b0, significand, 2'b00};
                8'd2: align_significand = {2'b00, significand, 1'b0};
                8'd3: align_significand = {3'b000, significand};
                8'd4: align_significand = {
                    4'b0000, significand[7:2], |significand[1:0]
                };
                8'd5: align_significand = {
                    5'b00000, significand[7:3], |significand[2:0]
                };
                8'd6: align_significand = {
                    6'b000000, significand[7:4], |significand[3:0]
                };
                8'd7: align_significand = {
                    7'b0000000, significand[7:5], |significand[4:0]
                };
                8'd8: align_significand = {
                    8'b00000000, significand[7:6], |significand[5:0]
                };
                8'd9: align_significand = {
                    9'b000000000, significand[7], |significand[6:0]
                };
                default: align_significand = {
                    10'b0000000000, |significand
                };
            endcase
        end
    endfunction

    function automatic [3:0] leading_zero_count11;
        input [10:0] value;
        begin
            casez (value)
                11'b1??????????: leading_zero_count11 = 4'd0;
                11'b01?????????: leading_zero_count11 = 4'd1;
                11'b001????????: leading_zero_count11 = 4'd2;
                11'b0001???????: leading_zero_count11 = 4'd3;
                11'b00001??????: leading_zero_count11 = 4'd4;
                11'b000001?????: leading_zero_count11 = 4'd5;
                11'b0000001????: leading_zero_count11 = 4'd6;
                11'b00000001???: leading_zero_count11 = 4'd7;
                11'b000000001??: leading_zero_count11 = 4'd8;
                11'b0000000001?: leading_zero_count11 = 4'd9;
                11'b00000000001: leading_zero_count11 = 4'd10;
                default:         leading_zero_count11 = 4'd11;
            endcase
        end
    endfunction

    function automatic [15:0] bf16_add_rne;
        input [15:0] a;
        input [15:0] b;
        reg a_nan;
        reg b_nan;
        reg a_inf;
        reg b_inf;
        reg [7:0] exp_a;
        reg [7:0] exp_b;
        reg [7:0] effective_exp_a;
        reg [7:0] effective_exp_b;
        reg [7:0] high_exp;
        reg [7:0] low_exp;
        reg [7:0] exp_difference;
        reg [7:0] result_exp;
        reg [7:0] available_shift;
        reg [7:0] sig_a;
        reg [7:0] sig_b;
        reg [7:0] high_sig;
        reg [7:0] low_sig;
        reg high_sign;
        reg low_sign;
        reg result_sign;
        reg exact_zero;
        reg [10:0] high_extended;
        reg [10:0] low_aligned;
        reg [10:0] normalized;
        reg [10:0] difference;
        reg [11:0] sum;
        reg [3:0] leading_zeros;
        reg [3:0] normalize_shift;
        reg round_up;
        reg [8:0] rounded_sig;
        begin
            exp_a = a[14:7];
            exp_b = b[14:7];
            a_nan = (exp_a == 8'hff) && (a[6:0] != 7'd0);
            b_nan = (exp_b == 8'hff) && (b[6:0] != 7'd0);
            a_inf = (exp_a == 8'hff) && (a[6:0] == 7'd0);
            b_inf = (exp_b == 8'hff) && (b[6:0] == 7'd0);

            effective_exp_a = (exp_a == 8'd0) ? 8'd1 : exp_a;
            effective_exp_b = (exp_b == 8'd0) ? 8'd1 : exp_b;
            sig_a = (exp_a == 8'd0) ? {1'b0, a[6:0]} : {1'b1, a[6:0]};
            sig_b = (exp_b == 8'd0) ? {1'b0, b[6:0]} : {1'b1, b[6:0]};

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
            normalized = 11'd0;
            difference = 11'd0;
            sum = 12'd0;
            leading_zeros = 4'd0;
            normalize_shift = 4'd0;
            available_shift = 8'd0;
            exact_zero = 1'b0;
            round_up = 1'b0;
            rounded_sig = 9'd0;

            if (high_sign == low_sign) begin
                sum = {1'b0, high_extended} + {1'b0, low_aligned};
                if (sum == 12'd0) begin
                    exact_zero = 1'b1;
                end else if (sum[11]) begin
                    // Shift-right-jam one place after a same-sign carry.
                    normalized = {sum[11:2], sum[1] | sum[0]};
                    result_exp = high_exp + 8'd1;
                end else begin
                    normalized = sum[10:0];
                end
            end else begin
                difference = high_extended - low_aligned;
                if (difference == 11'd0) begin
                    exact_zero = 1'b1;
                end else begin
                    leading_zeros = leading_zero_count11(difference);
                    available_shift = high_exp - 8'd1;
                    if ({4'd0, leading_zeros} > available_shift) begin
                        normalize_shift = available_shift[3:0];
                    end else begin
                        normalize_shift = leading_zeros;
                    end
                    normalized = difference << normalize_shift;
                    result_exp = high_exp - {4'd0, normalize_shift};
                end
            end

            if (a_nan || b_nan ||
                (a_inf && b_inf && (a[15] != b[15]))) begin
                bf16_add_rne = 16'h7fc0;
            end else if (a_inf) begin
                bf16_add_rne = {a[15], 8'hff, 7'd0};
            end else if (b_inf) begin
                bf16_add_rne = {b[15], 8'hff, 7'd0};
            end else if (exact_zero) begin
                // RNE gives -0 only when both exact-zero inputs are negative.
                bf16_add_rne = {a[15] & b[15], 15'd0};
            end else begin
                round_up = normalized[2] &&
                    (normalized[1] || normalized[0] || normalized[3]);
                rounded_sig = {1'b0, normalized[10:3]} + {8'd0, round_up};

                if (rounded_sig[8]) begin
                    rounded_sig = rounded_sig >> 1;
                    result_exp = result_exp + 8'd1;
                end

                if (result_exp >= 8'd255) begin
                    bf16_add_rne = {result_sign, 8'hff, 7'd0};
                end else if ((result_exp == 8'd1) && !rounded_sig[7]) begin
                    // Effective exponent one with no hidden bit is subnormal.
                    bf16_add_rne = {result_sign, 8'd0, rounded_sig[6:0]};
                end else begin
                    bf16_add_rne = {result_sign, result_exp, rounded_sig[6:0]};
                end
            end
        end
    endfunction

    assign o_result = bf16_add_rne(i_a, i_b);

endmodule
