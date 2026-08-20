`timescale 1ns/1ps
module rabit_blk_acc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [2:0]   rd_sel_i,
    output wire [255:0] rd_data_o,
    input  wire         wr_en_i,
    input  wire [2:0]   wr_sel_i,
    input  wire [255:0] wr_data_i
);
    rabit_acc_regfile #(.NPE(8), .NSLOT(8), .ACC_W(32))
        u_acc (.*);
endmodule
