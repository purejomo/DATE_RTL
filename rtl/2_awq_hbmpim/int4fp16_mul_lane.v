`timescale 1ns/1ps

// Asymmetric INT4 weight times IEEE-754 binary16 activation, rounded once with
// round-to-nearest, ties-to-even. The lane is combinational; the execution
// datapath provides the cycle boundary.
//
// The weight is an exact integer in [-15, +15], so the significand product is
// an unsigned 11x4 array instead of the baseline's 11x11. The result exponent
// is the activation exponent plus however far the product's leading one moved,
// which is at most four places.
module int4fp16_mul_lane (
    input  wire [15:0] i_act,
    input  wire [3:0]  i_weight_q,
    input  wire [3:0]  i_weight_zp,
    output wire [15:0] o_result
);

    wire       weight_sign;
    wire [3:0] weight_magnitude;
    wire       weight_zero;

    int4_asym_decode u_decode (
        .i_q          (i_weight_q),
        .i_zero_point (i_weight_zp),
        .o_sign       (weight_sign),
        .o_magnitude  (weight_magnitude),
        .o_zero       (weight_zero)
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

    // The significand always carries its hidden bit into the product, so a
    // nonzero product's leading one sits in bit 10 through bit 14. Only those
    // top four bits decide how far the leading one moved.
    function automatic [2:0] product_leading_shift;
        input [3:0] product_high;
        begin
            if (product_high[3]) begin
                product_leading_shift = 3'd4;
            end else if (product_high[2]) begin
                product_leading_shift = 3'd3;
            end else if (product_high[1]) begin
                product_leading_shift = 3'd2;
            end else if (product_high[0]) begin
                product_leading_shift = 3'd1;
            end else begin
                product_leading_shift = 3'd0;
            end
        end
    endfunction

    // Round a 15-bit exact product after a right shift. The retained field is
    // twelve bits so that a rounding carry out of bit 10 stays visible.
    function automatic [11:0] round_product_rne;
        input [14:0] value;
        input [4:0] shift;
        reg [11:0] retained;
        reg guard_bit;
        reg sticky_bit;
        begin
            retained = 12'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            case (shift)
                5'd0: begin
                    retained = value[11:0];
                end
                5'd1: begin
                    retained = value[12:1];
                    guard_bit = value[0];
                end
                5'd2: begin
                    retained = value[13:2];
                    guard_bit = value[1];
                    sticky_bit = value[0];
                end
                5'd3: begin
                    retained = value[14:3];
                    guard_bit = value[2];
                    sticky_bit = |value[1:0];
                end
                5'd4: begin
                    retained = {1'd0, value[14:4]};
                    guard_bit = value[3];
                    sticky_bit = |value[2:0];
                end
                5'd5: begin
                    retained = {2'd0, value[14:5]};
                    guard_bit = value[4];
                    sticky_bit = |value[3:0];
                end
                5'd6: begin
                    retained = {3'd0, value[14:6]};
                    guard_bit = value[5];
                    sticky_bit = |value[4:0];
                end
                5'd7: begin
                    retained = {4'd0, value[14:7]};
                    guard_bit = value[6];
                    sticky_bit = |value[5:0];
                end
                5'd8: begin
                    retained = {5'd0, value[14:8]};
                    guard_bit = value[7];
                    sticky_bit = |value[6:0];
                end
                5'd9: begin
                    retained = {6'd0, value[14:9]};
                    guard_bit = value[8];
                    sticky_bit = |value[7:0];
                end
                5'd10: begin
                    retained = {7'd0, value[14:10]};
                    guard_bit = value[9];
                    sticky_bit = |value[8:0];
                end
                5'd11: begin
                    retained = {8'd0, value[14:11]};
                    guard_bit = value[10];
                    sticky_bit = |value[9:0];
                end
                5'd12: begin
                    retained = {9'd0, value[14:12]};
                    guard_bit = value[11];
                    sticky_bit = |value[10:0];
                end
                5'd13: begin
                    retained = {10'd0, value[14:13]};
                    guard_bit = value[12];
                    sticky_bit = |value[11:0];
                end
                5'd14: begin
                    retained = {11'd0, value[14]};
                    guard_bit = value[13];
                    sticky_bit = |value[12:0];
                end
                5'd15: begin
                    guard_bit = value[14];
                    sticky_bit = |value[13:0];
                end
                default: begin
                    retained = 12'd0;
                end
            endcase

            if (guard_bit && (sticky_bit || retained[0])) begin
                round_product_rne = retained + 12'd1;
            end else begin
                round_product_rne = retained;
            end
        end
    endfunction

    function automatic [15:0] int4_fp16_mul_rne;
        input [15:0] act;
        input weight_neg;
        input [3:0] weight_mag;
        input weight_is_zero;
        reg sign_out;
        reg act_nan;
        reg act_inf;
        reg act_zero;
        reg [3:0] shift_act;
        reg [10:0] sig_act;
        reg [14:0] product;
        reg signed [6:0] exp_act;
        reg signed [6:0] result_exp;
        reg [2:0] normal_shift;
        reg [6:0] underflow_distance;
        reg [6:0] subnormal_shift;
        reg [11:0] rounded;
        reg [4:0] biased_exp;
        begin
            sign_out = act[15] ^ weight_neg;
            act_nan = (act[14:10] == 5'h1f) && (act[9:0] != 10'd0);
            act_inf = (act[14:10] == 5'h1f) && (act[9:0] == 10'd0);
            act_zero = (act[14:10] == 5'd0) && (act[9:0] == 10'd0);

            shift_act = 4'd0;
            sig_act = 11'd0;
            product = 15'd0;
            exp_act = 7'sd0;
            result_exp = 7'sd0;
            normal_shift = 3'd0;
            underflow_distance = 7'd0;
            subnormal_shift = 7'd0;
            rounded = 12'd0;
            biased_exp = 5'd0;

            if (act_nan || (act_inf && weight_is_zero)) begin
                int4_fp16_mul_rne = 16'h7e00;
            end else if (act_inf) begin
                int4_fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
            end else if (act_zero || weight_is_zero) begin
                int4_fp16_mul_rne = {sign_out, 15'd0};
            end else begin
                if (act[14:10] == 5'd0) begin
                    shift_act = subnormal_lshift(act[9:0]);
                    sig_act = {1'b0, act[9:0]} << shift_act;
                    exp_act = -7'sd14 - $signed({3'd0, shift_act});
                end else begin
                    sig_act = {1'b1, act[9:0]};
                    exp_act = $signed({2'd0, act[14:10]}) - 7'sd15;
                end

                product = sig_act * weight_mag;
                normal_shift = product_leading_shift(product[14:11]);
                // The product's binary point sits ten places below its leading
                // one once the leading one is normalized back to bit 10.
                result_exp = exp_act + $signed({4'd0, normal_shift});

                if (result_exp > 7'sd15) begin
                    int4_fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
                end else if (result_exp < -7'sd14) begin
                    underflow_distance = $unsigned(-7'sd14 - result_exp);
                    subnormal_shift =
                        {4'd0, normal_shift} + underflow_distance;
                    if (subnormal_shift > 7'd15) begin
                        rounded = 12'd0;
                    end else begin
                        rounded =
                            round_product_rne(product, subnormal_shift[4:0]);
                    end

                    if (rounded == 12'd0) begin
                        int4_fp16_mul_rne = {sign_out, 15'd0};
                    end else if (rounded >= 12'd1024) begin
                        int4_fp16_mul_rne = {sign_out, 5'd1, 10'd0};
                    end else begin
                        int4_fp16_mul_rne = {sign_out, 5'd0, rounded[9:0]};
                    end
                end else begin
                    rounded = round_product_rne(product, {2'd0, normal_shift});
                    if (rounded[11]) begin
                        rounded = rounded >> 1;
                        result_exp = result_exp + 7'sd1;
                    end

                    if (result_exp > 7'sd15) begin
                        int4_fp16_mul_rne = {sign_out, 5'h1f, 10'd0};
                    end else begin
                        biased_exp = result_exp[4:0] + 5'd15;
                        int4_fp16_mul_rne =
                            {sign_out, biased_exp, rounded[9:0]};
                    end
                end
            end
        end
    endfunction

    assign o_result = int4_fp16_mul_rne(
        i_act, weight_sign, weight_magnitude, weight_zero
    );

endmodule
