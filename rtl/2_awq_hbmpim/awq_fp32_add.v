`timescale 1ns/1ps

// Reduced-complexity AWQ-HBM-PIM binary32 accumulator adder.
//
// Supported arithmetic contract:
//   - normal finite inputs use round-to-nearest, ties-to-even;
//   - zero and subnormal inputs are treated as signed zero (DAZ);
//   - subnormal results are flushed to signed zero (FTZ);
//   - finite overflow produces signed infinity;
//   - NaN and infinity inputs are outside the supported domain.
module awq_fp32_add (
    input  wire [31:0] i_a,
    input  wire [31:0] i_b,
    output wire [31:0] o_result
);

    // Align a normal 24-bit significand into hidden/fraction plus GRS bits.
    function automatic [26:0] align_significand;
        input [23:0] significand;
        input [7:0] shift;
        reg [26:0] extended;
        reg [26:0] shifted;
        reg [26:0] dropped_mask;
        reg sticky;
        begin
            extended = {significand, 3'b000};
            if (shift >= 8'd27) begin
                shifted = 27'd0;
                sticky = (significand != 24'd0);
            end else begin
                shifted = extended >> shift[4:0];
                dropped_mask = (27'd1 << shift[4:0]) - 27'd1;
                sticky = ((extended & dropped_mask) != 27'd0);
            end
            align_significand = shifted | {26'd0, sticky};
        end
    endfunction

    function automatic [4:0] leading_zero_count27;
        input [26:0] value;
        integer index;
        begin
            leading_zero_count27 = 5'd27;
            for (index = 0; index < 27; index = index + 1) begin
                if (value[index]) begin
                    leading_zero_count27 = 5'd26 - index[4:0];
                end
            end
        end
    endfunction

    function automatic [31:0] fp32_add_normal_rne_ftz;
        input [31:0] a;
        input [31:0] b;
        reg [7:0] exp_a;
        reg [7:0] exp_b;
        reg [7:0] high_exp;
        reg [7:0] low_exp;
        reg [7:0] exp_difference;
        reg [7:0] result_exp;
        reg [7:0] available_shift;
        reg [23:0] sig_a;
        reg [23:0] sig_b;
        reg [23:0] high_sig;
        reg [23:0] low_sig;
        reg high_sign;
        reg low_sign;
        reg result_sign;
        reg [26:0] high_extended;
        reg [26:0] low_aligned;
        reg [26:0] normalized;
        reg [26:0] difference;
        reg [27:0] sum;
        reg [4:0] leading_zeros;
        reg [4:0] normalize_shift;
        reg round_up;
        reg [24:0] rounded_sig;
        begin
            exp_a = a[30:23];
            exp_b = b[30:23];

            // Exponent zero covers both signed zero and subnormal inputs.
            if (exp_a == 8'd0) begin
                fp32_add_normal_rne_ftz = (exp_b == 8'd0)
                    ? {a[31] & b[31], 31'd0} : b;
            end else if (exp_b == 8'd0) begin
                fp32_add_normal_rne_ftz = a;
            end else begin
                sig_a = {1'b1, a[22:0]};
                sig_b = {1'b1, b[22:0]};
                high_exp = exp_a;
                low_exp = exp_b;
                high_sig = sig_a;
                low_sig = sig_b;
                high_sign = a[31];
                low_sign = b[31];
                if ((exp_b > exp_a)
                    || ((exp_b == exp_a) && (sig_b > sig_a))) begin
                    high_exp = exp_b;
                    low_exp = exp_a;
                    high_sig = sig_b;
                    low_sig = sig_a;
                    high_sign = b[31];
                    low_sign = a[31];
                end

                exp_difference = high_exp - low_exp;
                high_extended = {high_sig, 3'b000};
                low_aligned = align_significand(low_sig, exp_difference);
                result_sign = high_sign;
                result_exp = high_exp;
                normalized = 27'd0;

                if (high_sign == low_sign) begin
                    sum = {1'b0, high_extended} + {1'b0, low_aligned};
                    if (sum[27]) begin
                        normalized = {sum[27:2], sum[1] | sum[0]};
                        result_exp = high_exp + 8'd1;
                    end else begin
                        normalized = sum[26:0];
                    end
                end else begin
                    difference = high_extended - low_aligned;
                    leading_zeros = leading_zero_count27(difference);
                    available_shift = high_exp - 8'd1;
                    if ({3'd0, leading_zeros} > available_shift) begin
                        normalize_shift = available_shift[4:0];
                    end else begin
                        normalize_shift = leading_zeros;
                    end
                    normalized = difference << normalize_shift;
                    result_exp = high_exp - {3'd0, normalize_shift};
                end

                round_up = normalized[2]
                    && (normalized[1] || normalized[0] || normalized[3]);
                rounded_sig = {1'b0, normalized[26:3]}
                            + {24'd0, round_up};
                if (rounded_sig[24]) begin
                    rounded_sig = rounded_sig >> 1;
                    result_exp = result_exp + 8'd1;
                end

                if (normalized == 27'd0) begin
                    fp32_add_normal_rne_ftz = 32'd0;
                end else if (result_exp >= 8'd255) begin
                    fp32_add_normal_rne_ftz = {
                        result_sign, 8'hff, 23'd0
                    };
                end else if ((result_exp == 8'd1) && !rounded_sig[23]) begin
                    fp32_add_normal_rne_ftz = {result_sign, 31'd0};
                end else begin
                    fp32_add_normal_rne_ftz = {
                        result_sign, result_exp, rounded_sig[22:0]
                    };
                end
            end
        end
    endfunction

    assign o_result = fp32_add_normal_rne_ftz(i_a, i_b);

endmodule

