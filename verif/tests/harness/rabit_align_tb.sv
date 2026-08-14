`timescale 1ns/1ps

// Exposes the exponent aligner in both rounding modes against one stimulus.
//
// SHIFT_RND is off in the delivered design -- the specified behaviour is a
// plain arithmetic shift. It is still built and checked here so the option is
// not unverified RTL sitting in the tree, and so the accuracy sweep's "+RNE"
// row describes something that has actually been exercised.
module rabit_align_tb (
    input  logic signed [16:0] psum_i,
    input  logic signed [6:0]  shift_i,

    output logic signed [31:0] trunc_o,
    output logic               trunc_sat_o,

    output logic signed [31:0] round_o,
    output logic               round_sat_o
);

    rabit_align_shift #(.PSUM_W(17), .ACC_W(32), .SH_W(7), .SHIFT_RND(0))
        u_trunc (
            .psum_i    (psum_i),
            .shift_i   (shift_i),
            .aligned_o (trunc_o),
            .sat_o     (trunc_sat_o)
        );

    rabit_align_shift #(.PSUM_W(17), .ACC_W(32), .SH_W(7), .SHIFT_RND(1))
        u_round (
            .psum_i    (psum_i),
            .shift_i   (shift_i),
            .aligned_o (round_o),
            .sat_o     (round_sat_o)
        );

endmodule
