`timescale 1ns/1ps

// Sixteen independent FP16 adder lanes. There is no cross-lane adder tree.
module hbmpim_simd_add (
    input  wire [255:0] i_a,
    input  wire [255:0] i_b,
    output wire [255:0] o_result
);

    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_add_lane
            hbmpim_fp16_add_lane u_add_lane (
                .i_a      (i_a[(lane * 16) +: 16]),
                .i_b      (i_b[(lane * 16) +: 16]),
                .o_result (o_result[(lane * 16) +: 16])
            );
        end
    endgenerate

endmodule
