`timescale 1ns/1ps

// Reduced-complexity HBM-PIM binary16 multiplier.
//
// Supported arithmetic contract:
//   - normal finite inputs use round-to-nearest, ties-to-even;
//   - zero and subnormal inputs are treated as signed zero (DAZ);
//   - subnormal results are flushed to signed zero (FTZ);
//   - finite overflow produces signed infinity;
//   - NaN and infinity inputs are outside the supported domain.
//
// Removing IEEE special-value and gradual-underflow hardware matches the
// arithmetic assumptions used by the reduced-area HBM-PIM comparison.
module hbmpim_fp16_mul (
    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire [15:0] o_result
);

    function automatic [15:0] fp16_mul_normal_rne_ftz;
        input [15:0] a;
        input [15:0] b;
        reg sign_out;
        reg [21:0] product_exact;
        reg [10:0] retained;
        reg guard_bit;
        reg sticky_bit;
        reg [11:0] rounded;
        reg signed [7:0] exponent_out;
        reg underflow_before_round;
        begin
            sign_out = a[15] ^ b[15];
            product_exact = {1'b1, a[9:0]} * {1'b1, b[9:0]};

            if (product_exact[21]) begin
                retained = product_exact[21:11];
                guard_bit = product_exact[10];
                sticky_bit = |product_exact[9:0];
                exponent_out = $signed({3'd0, a[14:10]})
                             + $signed({3'd0, b[14:10]}) - 8'sd14;
            end else begin
                retained = product_exact[20:10];
                guard_bit = product_exact[9];
                sticky_bit = |product_exact[8:0];
                exponent_out = $signed({3'd0, a[14:10]})
                             + $signed({3'd0, b[14:10]}) - 8'sd15;
            end

            underflow_before_round = (exponent_out <= 8'sd0);
            rounded = {1'b0, retained}
                    + {11'd0, guard_bit && (sticky_bit || retained[0])};
            if (rounded[11]) begin
                rounded = rounded >> 1;
                exponent_out = exponent_out + 8'sd1;
            end

            // Exponent zero covers both signed zero and subnormal inputs.
            if ((a[14:10] == 5'd0) || (b[14:10] == 5'd0)
                || underflow_before_round) begin
                fp16_mul_normal_rne_ftz = {sign_out, 15'd0};
            end else if (exponent_out >= 8'sd31) begin
                fp16_mul_normal_rne_ftz = {sign_out, 5'h1f, 10'd0};
            end else begin
                fp16_mul_normal_rne_ftz = {
                    sign_out, exponent_out[4:0], rounded[9:0]
                };
            end
        end
    endfunction

    assign o_result = fp16_mul_normal_rne_ftz(i_a, i_b);

endmodule
