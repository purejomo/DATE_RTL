`timescale 1ns/1ps

// Reduced-complexity asymmetric INT4 x binary16 multiplier.
//
// Supported arithmetic contract:
//   - normal finite activations use round-to-nearest, ties-to-even;
//   - zero and subnormal activations are treated as signed zero (DAZ);
//   - subnormal products are flushed to signed zero (FTZ);
//   - finite overflow produces signed infinity;
//   - NaN and infinity activations are outside the supported domain.
//
// The asymmetric INT4 decode remains exact over the full [-15, +15] range.
module awq_int4fp16_mul (
    input  wire [15:0] i_act,
    input  wire [3:0]  i_weight_q,
    input  wire [3:0]  i_weight_zp,
    output wire [15:0] o_result
);

    wire signed [4:0] weight_difference =
        $signed({1'b0, i_weight_q}) - $signed({1'b0, i_weight_zp});
    wire       weight_sign = weight_difference[4];
    wire [3:0] weight_magnitude = weight_difference[4]
        ? (~weight_difference[3:0] + 4'd1)
        : weight_difference[3:0];
    wire       weight_zero = (weight_difference == 5'sd0);

    // A normal binary16 significand multiplied by a four-bit magnitude has
    // its leading one in product bit 10 through 14.
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

    // Only shifts 0 through 4 are reachable for a normal finite activation.
    // Gradual-underflow shifts are deliberately absent under the FTZ contract.
    function automatic [11:0] round_product_rne;
        input [14:0] value;
        input [2:0] shift;
        reg [11:0] retained;
        reg guard_bit;
        reg sticky_bit;
        begin
            retained = 12'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            case (shift)
                3'd0: retained = value[11:0];
                3'd1: begin
                    retained = value[12:1];
                    guard_bit = value[0];
                end
                3'd2: begin
                    retained = value[13:2];
                    guard_bit = value[1];
                    sticky_bit = value[0];
                end
                3'd3: begin
                    retained = value[14:3];
                    guard_bit = value[2];
                    sticky_bit = |value[1:0];
                end
                default: begin
                    retained = {1'b0, value[14:4]};
                    guard_bit = value[3];
                    sticky_bit = |value[2:0];
                end
            endcase
            round_product_rne = retained
                + {11'd0, guard_bit && (sticky_bit || retained[0])};
        end
    endfunction

    function automatic [15:0] int4_fp16_mul_normal_rne_ftz;
        input [15:0] act;
        input weight_neg;
        input [3:0] weight_mag;
        input weight_is_zero;
        reg sign_out;
        reg [14:0] product;
        reg [2:0] normal_shift;
        reg [11:0] rounded;
        reg signed [7:0] result_exp;
        reg underflow_before_round;
        begin
            sign_out = act[15] ^ weight_neg;
            product = {1'b1, act[9:0]} * weight_mag;
            normal_shift = product_leading_shift(product[14:11]);
            result_exp = $signed({3'd0, act[14:10]}) - 8'sd15
                       + $signed({5'd0, normal_shift});
            underflow_before_round = (result_exp < -8'sd14);
            rounded = round_product_rne(product, normal_shift);

            if (rounded[11]) begin
                rounded = rounded >> 1;
                result_exp = result_exp + 8'sd1;
            end

            // Exponent zero covers both signed zero and subnormal activation.
            if ((act[14:10] == 5'd0) || weight_is_zero
                || underflow_before_round) begin
                int4_fp16_mul_normal_rne_ftz = {sign_out, 15'd0};
            end else if (result_exp > 8'sd15) begin
                int4_fp16_mul_normal_rne_ftz = {sign_out, 5'h1f, 10'd0};
            end else begin
                int4_fp16_mul_normal_rne_ftz = {
                    sign_out, result_exp[4:0] + 5'd15, rounded[9:0]
                };
            end
        end
    endfunction

    assign o_result = int4_fp16_mul_normal_rne_ftz(
        i_act, weight_sign, weight_magnitude, weight_zero
    );

endmodule
