`timescale 1ns/1ps
// Verification harness: expose both directory-local binary32 adders to the
// same inputs so each implementation is checked against the host FP32 oracle.
module tb_top (
    input  wire [31:0] i_a,
    input  wire [31:0] i_b,
    output wire [31:0] o_sum_hbmpim,
    output wire [31:0] o_sum_awq
);
    hbmpim_fp32_add u_hbmpim_add (
        .i_a(i_a), .i_b(i_b), .o_result(o_sum_hbmpim)
    );
    awq_fp32_add u_awq_add (
        .i_a(i_a), .i_b(i_b), .o_result(o_sum_awq)
    );
endmodule
