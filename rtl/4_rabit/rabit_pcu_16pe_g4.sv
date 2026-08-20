`timescale 1ns/1ps
module rabit_pcu_16pe_g4 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [5:0]   cfg_e0_i,
    input  wire         wr_valid_i,
    output wire         wr_ready_o,
    input  wire [1:0]   wr_entry_i,
    input  wire [255:0] wr_fp16_i,
    output wire         cvt_we_o,
    output wire [1:0]   cvt_entry_o,
    output wire [213:0] cvt_blk_o,
    input  wire         rd_valid_i,
    output wire         rd_ready_o,
    input  wire [1:0]   rd_group_i,
    input  wire         rd_pair_i,
    input  wire [511:0] rd_word_i,
    output wire         grf_pair_o,
    input  wire [427:0] grf_blk_i,
    output wire         rd_done_o,
    input  wire         drain_req_i,
    input  wire [1:0]   drain_group_i,
    output wire         drain_ready_o,
    output wire         drain_valid_o,
    output wire [1:0]   drain_group_o,
    output wire         drain_path_o,
    output wire         drain_last_o,
    output wire [511:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (16),
        .NPATH         (2),
        .NGROUP        (4)
    ) u_pcu (.*);
endmodule
