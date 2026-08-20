`timescale 1ns/1ps

// Final RaBiT dequant_rne synthesis boundary.
module rabit_pcu_fs (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [5:0]   cfg_e0_i,
    input  wire         wr_valid_i,
    output wire         wr_ready_o,
    input  wire [1:0]   wr_kind_i,
    input  wire [1:0]   wr_sel_i,
    input  wire [255:0] wr_data_i,
    output wire         cvt_we_o,
    output wire [1:0]   cvt_entry_o,
    output wire [213:0] cvt_blk_o,
    input  wire         rd_valid_i,
    output wire         rd_ready_o,
    input  wire [1:0]   rd_group_i,
    input  wire         rd_pair_i,
    input  wire [255:0] rd_word_i,
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
    output wire [255:0] drain_data_o,
    input  wire         dq_req_i,
    output wire         dq_ready_o,
    output wire         dq_busy_o,
    output wire         y_valid_o,
    output wire [63:0]  y_data_o,
    output wire [2:0]   y_beat_o,
    output wire         y_last_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o,
    output wire [3:0]   status_fs_o
);
    localparam int ACC_W = 27;

    wire [8*ACC_W-1:0] core_drain;
    wire                core_y_valid;
    wire [15:0]         core_y_data;
    wire [4:0]          core_y_beat;
    wire                core_y_last;

    rabit_pcu_fs_top #(
        .MANT_W(12), .SHIFTER_EN(1), .NOUT_PER_WORD(8),
        .PE_LANES(8), .NPATH(2), .ACC_W(ACC_W),
        .H_FMT(0), .H_MUL_PIPE(1), .NMULT_H(16),
        .DQ_LANES(1), .ALIGN_MAX(16)
    ) u_pcu (
        .drain_data_o(core_drain),
        .y_valid_o(core_y_valid), .y_data_o(core_y_data),
        .y_beat_o(core_y_beat), .y_last_o(core_y_last), .*
    );

    genvar d;
    generate
        for (d = 0; d < 8; d = d + 1) begin : g_raw_expand
            assign drain_data_o[d*32 +: 32] =
                {{(32-ACC_W){core_drain[d*ACC_W + ACC_W-1]}},
                  core_drain[d*ACC_W +: ACC_W]};
        end
    endgenerate

    rabit_fs_y_pack1to4 u_pack (
        .clk(clk), .rst_n(rst_n), .valid_i(core_y_valid),
        .data_i(core_y_data), .beat_i(core_y_beat), .last_i(core_y_last),
        .valid_o(y_valid_o), .data_o(y_data_o), .beat_o(y_beat_o),
        .last_o(y_last_o)
    );
endmodule
