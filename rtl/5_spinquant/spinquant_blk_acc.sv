`timescale 1ns/1ps
module spinquant_blk_acc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [1:0]   rd_sel_i,
    output wire [511:0] rd_data_o,
    input  wire [1:0]   drain_sel_i,
    output wire [511:0] drain_data_o,
    input  wire         wr_en_i,
    input  wire [1:0]   wr_sel_i,
    input  wire [511:0] wr_data_i
);
    spinquant_acc_regfile #(
        .NLANE  (16),
        .NENTRY (4),
        .ACC_W  (32)
    ) u_acc (.*);
endmodule
