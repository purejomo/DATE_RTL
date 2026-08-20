`timescale 1ns/1ps

module spinquant_pcu_v2_acc16 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         w_load_i,
    input  wire [511:0] w_beat_i,
    input  wire         mac_valid_i,
    input  wire [15:0]  a_q4_i,
    input  wire [1:0]   acc_entry_i,
    input  wire         acc_clear_i,
    output wire         mac_done_o,
    input  wire [1:0]   drain_entry_i,
    output wire [511:0] drain_data_o,
    input  wire         status_clr_i,
    output wire         ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (32),
        .NWAY        (4),
        .NROW        (1),
        .NENTRY      (4),
        .ACC_W       (16),
        .ACC_CHAIN_W (16),
        .ACC_RSH     (7),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule
