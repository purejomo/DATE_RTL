`timescale 1ns/1ps

// Asymmetric INT4 weight decode: a stored unsigned nibble minus an unsigned
// four-bit zero point. The exact range is [-15, +15], so the magnitude fits in
// four bits and the sign is separate. Keeping sign and magnitude apart lets the
// multiplier lane feed an unsigned 11x4 array and apply the sign at the end,
// which is smaller than a signed 12x5 product.
//
// This is the same numerical contract as the P3-LLM int4_asym_decoder, which
// widens to a signed six-bit value instead because its datapath is fixed point.
module int4_asym_decode (
    input  wire [3:0] i_q,
    input  wire [3:0] i_zero_point,
    output wire       o_sign,
    output wire [3:0] o_magnitude,
    output wire       o_zero
);

    // A five-bit signed difference covers [-15, +15] without saturation.
    wire signed [4:0] difference =
        $signed({1'b0, i_q}) - $signed({1'b0, i_zero_point});

    assign o_sign      = difference[4];
    assign o_magnitude = difference[4] ? (~difference[3:0] + 4'd1)
                                       : difference[3:0];
    assign o_zero      = (difference == 5'sd0);

endmodule
