`timescale 1ns/1ps
module rabit_blk_pe (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                ce_i,
    input  wire [15:0]         b_bits_i,
    input  wire [207:0]        blk_i,
    input  wire signed [6:0]   shift_i,
    input  wire signed [31:0]  acc_cur_i,
    output wire signed [31:0]  acc_next_o,
    output wire                acc_sat_o,
    output wire                shift_sat_o
);
    rabit_pe #(.NIN(16), .MANT_W(12), .ACC_W(32), .SH_W(7), .SHIFTER_EN(1))
        u_pe (
            .clk         (clk),
            .rst_n       (rst_n),
            .ce_i        (ce_i),
            .b_bits_i    (b_bits_i),
            .blk_i       (blk_i),
            .shift_i     (shift_i),
            .acc_cur_i   (acc_cur_i),
            .acc_next_o  (acc_next_o),
            .acc_sat_o   (acc_sat_o),
            .shift_sat_o (shift_sat_o),
            .psum_o      ()
        );
endmodule
