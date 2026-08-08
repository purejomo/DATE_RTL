`timescale 1ns/1ps

// IEEE-754 binary16 multiplier with round-to-nearest, ties-to-even.
// The lane is combinational; the execution datapath provides the cycle
// boundary and exposes the rounded value through M_OUT.
module hbmpim_fp16_mul_lane (
    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire [15:0] o_result
);

    // Return the shift needed to place a nonzero subnormal fraction's leading
    // one in bit 10 of an 11-bit normalized significand.
    function automatic [3:0] subnormal_lshift;
        input [9:0] fraction;
        begin
            if (fraction[9]) begin
                subnormal_lshift = 4'd1;
            end else if (fraction[8]) begin
                subnormal_lshift = 4'd2;
            end else if (fraction[7]) begin
                subnormal_lshift = 4'd3;
            end else if (fraction[6]) begin
                subnormal_lshift = 4'd4;
            end else if (fraction[5]) begin
                subnormal_lshift = 4'd5;
            end else if (fraction[4]) begin
                subnormal_lshift = 4'd6;
            end else if (fraction[3]) begin
                subnormal_lshift = 4'd7;
            end else if (fraction[2]) begin
                subnormal_lshift = 4'd8;
            end else if (fraction[1]) begin
                subnormal_lshift = 4'd9;
            end else if (fraction[0]) begin
                subnormal_lshift = 4'd10;
            end else begin
                subnormal_lshift = 4'd0;
            end
        end
    endfunction

    // Round a 22-bit exact product after a right shift. Only shifts that can
    // produce a nonzero binary16 result are represented. Each case explicitly
    // forms the retained bits, guard bit, and sticky bit.
    function automatic [11:0] round_product_rne;
        input [21:0] value;
        input [4:0] shift;
        reg [11:0] retained;
        reg guard_bit;
        reg sticky_bit;
        begin
            retained = 12'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            case (shift)
                5'd10: begin
                    retained = value[21:10];
                    guard_bit = value[9];
                    sticky_bit = |value[8:0];
                end
                5'd11: begin
                    retained = {1'd0, value[21:11]};
                    guard_bit = value[10];
                    sticky_bit = |value[9:0];
                end
                5'd12: begin
                    retained = {2'd0, value[21:12]};
                    guard_bit = value[11];
                    sticky_bit = |value[10:0];
                end
                5'd13: begin
                    retained = {3'd0, value[21:13]};
                    guard_bit = value[12];
                    sticky_bit = |value[11:0];
                end
                5'd14: begin
                    retained = {4'd0, value[21:14]};
                    guard_bit = value[13];
                    sticky_bit = |value[12:0];
                end
                5'd15: begin
                    retained = {5'd0, value[21:15]};
                    guard_bit = value[14];
                    sticky_bit = |value[13:0];
                end
                5'd16: begin
                    retained = {6'd0, value[21:16]};
                    guard_bit = value[15];
                    sticky_bit = |value[14:0];
                end
                5'd17: begin
                    retained = {7'd0, value[21:17]};
                    guard_bit = value[16];
                    sticky_bit = |value[15:0];
                end
                5'd18: begin
                    retained = {8'd0, value[21:18]};
                    guard_bit = value[17];
                    sticky_bit = |value[16:0];
                end
                5'd19: begin
                    retained = {9'd0, value[21:19]};
                    guard_bit = value[18];
                    sticky_bit = |value[17:0];
                end
                5'd20: begin
                    retained = {10'd0, value[21:20]};
                    guard_bit = value[19];
                    sticky_bit = |value[18:0];
                end
                5'd21: begin
                    retained = {11'd0, value[21]};
                    guard_bit = value[20];
                    sticky_bit = |value[19:0];
                end
                5'd22: begin
                    retained = 12'd0;
                    guard_bit = value[21];
                    sticky_bit = |value[20:0];
                end
                default: begin
                    retained = 12'd0;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                end
            endcase

            if (guard_bit && (sticky_bit || retained[0])) begin
                round_product_rne = retained + 12'd1;
            end else begin
                round_product_rne = retained;
            end
        end
    endfunction

    function automatic [15:0] fp16_mul_rne;
        input [15:0] a;
        input [15:0] b;
        reg sign_out;
        reg a_nan;
        reg b_nan;
        reg a_inf;
        reg b_inf;
        reg a_zero;
        reg b_zero;
        reg [3:0] shift_a;
        reg [3:0] shift_b;
        reg [10:0] sig_a;
        reg [10:0] sig_b;
        reg [21:0] product;
        reg signed [6:0] exp_a;
        reg signed [6:0] exp_b;
        reg signed [6:0] result_exp;
        reg [4:0] normal_shift;
        reg [6:0] underflow_distance;
        reg [6:0] subnormal_shift;
        reg [11:0] rounded;
        reg [4:0] biased_exp;
        begin
            sign_out = a[15] ^ b[15];
            a_nan = (a[14:10] == 5'h1f) && (a[9:0] != 10'd0);
            b_nan = (b[14:10] == 5'h1f) && (b[9:0] != 10'd0);
            a_inf = (a[14:10] == 5'h1f) && (a[9:0] == 10'd0);
            b_inf = (b[14:10] == 5'h1f) && (b[9:0] == 10'd0);
            a_zero = (a[14:10] == 5'd0) && (a[9:0] == 10'd0);
            b_zero = (b[14:10] == 5'd0) && (b[9:0] == 10'd0);

            shift_a = 4'd0;
            shift_b = 4'd0;
            sig_a = 11'd0;
            sig_b = 11'd0;
            product = 22'd0;
            exp_a = 7'sd0;
            exp_b = 7'sd0;
            result_exp = 7'sd0;
            normal_shift = 5'd0;
            underflow_distance = 7'd0;
            subnormal_shift = 7'd0;
            rounded = 12'd0;
            biased_exp = 5'd0;

            if (a_nan || b_nan ||
                ((a_inf || b_inf) && (a_zero || b_zero))) begin
                fp16_mul_rne = 16'h7e00;
            end else if (a_inf || b_inf) begin
                fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
            end else if (a_zero || b_zero) begin
                fp16_mul_rne = {sign_out, 15'd0};
            end else begin
                if (a[14:10] == 5'd0) begin
                    shift_a = subnormal_lshift(a[9:0]);
                    sig_a = {1'b0, a[9:0]} << shift_a;
                    exp_a = -7'sd14 - $signed({3'd0, shift_a});
                end else begin
                    sig_a = {1'b1, a[9:0]};
                    exp_a = $signed({2'd0, a[14:10]}) - 7'sd15;
                end

                if (b[14:10] == 5'd0) begin
                    shift_b = subnormal_lshift(b[9:0]);
                    sig_b = {1'b0, b[9:0]} << shift_b;
                    exp_b = -7'sd14 - $signed({3'd0, shift_b});
                end else begin
                    sig_b = {1'b1, b[9:0]};
                    exp_b = $signed({2'd0, b[14:10]}) - 7'sd15;
                end

                product = sig_a * sig_b;
                result_exp = exp_a + exp_b;
                if (product[21]) begin
                    result_exp = result_exp + 7'sd1;
                    normal_shift = 5'd11;
                end else begin
                    normal_shift = 5'd10;
                end

                if (result_exp > 7'sd15) begin
                    fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
                end else if (result_exp < -7'sd14) begin
                    underflow_distance =
                        $unsigned(-7'sd14 - result_exp);
                    subnormal_shift =
                        {2'd0, normal_shift} + underflow_distance;
                    if (subnormal_shift > 7'd22) begin
                        rounded = 12'd0;
                    end else begin
                        rounded =
                            round_product_rne(product, subnormal_shift[4:0]);
                    end

                    if (rounded == 12'd0) begin
                        fp16_mul_rne = {sign_out, 15'd0};
                    end else if (rounded >= 12'd1024) begin
                        fp16_mul_rne = {sign_out, 5'd1, 10'd0};
                    end else begin
                        fp16_mul_rne = {sign_out, 5'd0, rounded[9:0]};
                    end
                end else begin
                    rounded = round_product_rne(product, normal_shift);
                    if (rounded[11]) begin
                        rounded = rounded >> 1;
                        result_exp = result_exp + 7'sd1;
                    end

                    if (result_exp > 7'sd15) begin
                        fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
                    end else begin
                        biased_exp = result_exp[4:0] + 5'd15;
                        fp16_mul_rne =
                            {sign_out, biased_exp, rounded[9:0]};
                    end
                end
            end
        end
    endfunction

    assign o_result = fp16_mul_rne(i_a, i_b);

endmodule
