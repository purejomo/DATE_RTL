`timescale 1ns/1ps
module spinquant_pcu_r2e2 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [255:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [31:0]   a_q4_i,
    input  wire          acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire          drain_entry_i,
    output wire [1023:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NROW        (2),
        .NENTRY      (2),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule
