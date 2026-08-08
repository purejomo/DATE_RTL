`timescale 1ns/1ps

// Sixteen independent FP16 multiplier lanes. Lane 0 occupies bits [15:0].
module hbmpim_simd_mul (
    input  wire [255:0] i_a,
    input  wire [255:0] i_b,
    output wire [255:0] o_result
);

    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_mul_lane
            hbmpim_fp16_mul_lane u_mul_lane (
                .i_a      (i_a[(lane * 16) +: 16]),
                .i_b      (i_b[(lane * 16) +: 16]),
                .o_result (o_result[(lane * 16) +: 16])
            );
        end
    endgenerate

endmodule
