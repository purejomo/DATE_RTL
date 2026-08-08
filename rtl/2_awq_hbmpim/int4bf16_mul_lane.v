`timescale 1ns/1ps

module int4bf16_mul_lane (
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
    // one in bit 7 of an 8-bit normalized significand.
    function automatic [2:0] subnormal_lshift;
        input [6:0] fraction;
        begin
            if (fraction[6]) begin
                subnormal_lshift = 3'd1;
            end else if (fraction[5]) begin
                subnormal_lshift = 3'd2;
            end else if (fraction[4]) begin
                subnormal_lshift = 3'd3;
            end else if (fraction[3]) begin
                subnormal_lshift = 3'd4;
            end else if (fraction[2]) begin
                subnormal_lshift = 3'd5;
            end else if (fraction[1]) begin
                subnormal_lshift = 3'd6;
            end else if (fraction[0]) begin
                subnormal_lshift = 3'd7;
            end else begin
                subnormal_lshift = 3'd0;
            end
        end
    endfunction

    // The significand always carries its hidden bit into the product, so a
    // nonzero product's leading one sits in bit 7 through bit 11.
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

    // Round a 12-bit exact product after a right shift. The retained field is
    // nine bits so that a rounding carry out of bit 7 stays visible.
    function automatic [8:0] round_product_rne;
        input [11:0] value;
        input [3:0] shift;
        reg [8:0] retained;
        reg guard_bit;
        reg sticky_bit;
        begin
            retained = 9'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            case (shift)
                4'd0: begin
                    retained = value[8:0];
                end
                4'd1: begin
                    retained = value[9:1];
                    guard_bit = value[0];
                end
                4'd2: begin
                    retained = value[10:2];
                    guard_bit = value[1];
                    sticky_bit = value[0];
                end
                4'd3: begin
                    retained = value[11:3];
                    guard_bit = value[2];
                    sticky_bit = |value[1:0];
                end
                4'd4: begin
                    retained = {1'd0, value[11:4]};
                    guard_bit = value[3];
                    sticky_bit = |value[2:0];
                end
                4'd5: begin
                    retained = {2'd0, value[11:5]};
                    guard_bit = value[4];
                    sticky_bit = |value[3:0];
                end
                4'd6: begin
                    retained = {3'd0, value[11:6]};
                    guard_bit = value[5];
                    sticky_bit = |value[4:0];
                end
                4'd7: begin
                    retained = {4'd0, value[11:7]};
                    guard_bit = value[6];
                    sticky_bit = |value[5:0];
                end
                4'd8: begin
                    retained = {5'd0, value[11:8]};
                    guard_bit = value[7];
                    sticky_bit = |value[6:0];
                end
                4'd9: begin
                    retained = {6'd0, value[11:9]};
                    guard_bit = value[8];
                    sticky_bit = |value[7:0];
                end
                4'd10: begin
                    retained = {7'd0, value[11:10]};
                    guard_bit = value[9];
                    sticky_bit = |value[8:0];
                end
                4'd11: begin
                    retained = {8'd0, value[11]};
                    guard_bit = value[10];
                    sticky_bit = |value[9:0];
                end
                4'd12: begin
                    guard_bit = value[11];
                    sticky_bit = |value[10:0];
                end
                default: begin
                    retained = 9'd0;
                end
            endcase

            if (guard_bit && (sticky_bit || retained[0])) begin
                round_product_rne = retained + 9'd1;
            end else begin
                round_product_rne = retained;
            end
        end
    endfunction

    function automatic [15:0] int4_bf16_mul_rne;
        input [15:0] act;
        input weight_neg;
        input [3:0] weight_mag;
        input weight_is_zero;
        reg sign_out;
        reg act_nan;
        reg act_inf;
        reg act_zero;
        reg [2:0] shift_act;
        reg [7:0] sig_act;
        reg [11:0] product;
        reg signed [9:0] exp_act;
        reg signed [9:0] result_exp;
        reg [2:0] normal_shift;
        reg [9:0] underflow_distance;
        reg [9:0] subnormal_shift;
        reg [8:0] rounded;
        reg [7:0] biased_exp;
        begin
            sign_out = act[15] ^ weight_neg;
            act_nan = (act[14:7] == 8'hff) && (act[6:0] != 7'd0);
            act_inf = (act[14:7] == 8'hff) && (act[6:0] == 7'd0);
            act_zero = (act[14:7] == 8'd0) && (act[6:0] == 7'd0);

            shift_act = 3'd0;
            sig_act = 8'd0;
            product = 12'd0;
            exp_act = 10'sd0;
            result_exp = 10'sd0;
            normal_shift = 3'd0;
            underflow_distance = 10'd0;
            subnormal_shift = 10'd0;
            rounded = 9'd0;
            biased_exp = 8'd0;

            if (act_nan || (act_inf && weight_is_zero)) begin
                int4_bf16_mul_rne = 16'h7fc0;
            end else if (act_inf) begin
                int4_bf16_mul_rne = {sign_out, 8'hff, 7'd0};
            end else if (act_zero || weight_is_zero) begin
                int4_bf16_mul_rne = {sign_out, 15'd0};
            end else begin
                if (act[14:7] == 8'd0) begin
                    shift_act = subnormal_lshift(act[6:0]);
                    sig_act = {1'b0, act[6:0]} << shift_act;
                    exp_act = -10'sd126 - $signed({7'd0, shift_act});
                end else begin
                    sig_act = {1'b1, act[6:0]};
                    exp_act = $signed({2'd0, act[14:7]}) - 10'sd127;
                end

                product = sig_act * weight_mag;
                normal_shift = product_leading_shift(product[11:8]);
                result_exp = exp_act + $signed({7'd0, normal_shift});

                if (result_exp > 10'sd127) begin
                    int4_bf16_mul_rne = {sign_out, 8'hff, 7'd0};
                end else if (result_exp < -10'sd126) begin
                    underflow_distance = $unsigned(-10'sd126 - result_exp);
                    subnormal_shift =
                        {7'd0, normal_shift} + underflow_distance;
                    if (subnormal_shift > 10'd12) begin
                        rounded = 9'd0;
                    end else begin
                        rounded =
                            round_product_rne(product, subnormal_shift[3:0]);
                    end

                    if (rounded == 9'd0) begin
                        int4_bf16_mul_rne = {sign_out, 15'd0};
                    end else if (rounded >= 9'd128) begin
                        int4_bf16_mul_rne = {sign_out, 8'd1, 7'd0};
                    end else begin
                        int4_bf16_mul_rne = {sign_out, 8'd0, rounded[6:0]};
                    end
                end else begin
                    rounded = round_product_rne(product, {1'd0, normal_shift});
                    if (rounded[8]) begin
                        rounded = rounded >> 1;
                        result_exp = result_exp + 10'sd1;
                    end

                    if (result_exp > 10'sd127) begin
                        int4_bf16_mul_rne = {sign_out, 8'hff, 7'd0};
                    end else begin
                        biased_exp = result_exp[7:0] + 8'd127;
                        int4_bf16_mul_rne =
                            {sign_out, biased_exp, rounded[6:0]};
                    end
                end
            end
        end
    endfunction

    assign o_result = int4_bf16_mul_rne(
        i_act, weight_sign, weight_magnitude, weight_zero
    );

endmodule
