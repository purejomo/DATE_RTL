`timescale 1ns/1ps
// ---- per-module breakdown wrappers ---------------------------------------

module spinquant_blk_pe (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                ce_i,
    input  wire [15:0]         w_q4_i,
    input  wire [15:0]         a_q4_i,
    input  wire                acc_clear_i,
    input  wire signed [31:0]  acc_cur_i,
    output wire signed [31:0]  acc_next_o,
    output wire                acc_ovf_o
);
    spinquant_pe #(
        .NWAY        (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .Q_W         (4)
    ) u_pe (
        .clk         (clk),
        .rst_n       (rst_n),
        .ce_i        (ce_i),
        .w_q4_i      (w_q4_i),
        .a_q4_i      (a_q4_i),
        .acc_clear_i (acc_clear_i),
        .acc_cur_i   (acc_cur_i),
        .acc_next_o  (acc_next_o),
        .acc_ovf_o   (acc_ovf_o),
        .psum_o      ()
    );
endmodule
