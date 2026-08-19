`timescale 1ns/1ps

// Synthesis wrappers for the full-scale variant.
//
// Same rule as rtl/4_rabit/rabit_pcu_synth.sv: the input GRF and the CRF live in
// the testbench as behavioural models, so the synthesis boundary is the top
// itself with its parameters frozen, and each wrapper gives the flow a stable
// module name per configuration.
//
//   rabit_pcu_fs         the specified datapath: FP8-E4M3 h, 4 dq lanes, the
//                        h multiply and the block convert in one cycle
//   rabit_pcu_fs_p       the same with H_MUL_PIPE = 1, which splits that path
//                        and is the configuration that closes tCCD_S
//   rabit_pcu_fs_h16     the FP16_3WR fallback, for the area cost of fp16 h
//
// The rabit_fs_blk_* wrappers synthesize one added block at a time so the area
// report can be broken down against the base variant's blocks. Their sum does
// not have to equal the flat top: the flow flattens everything, so the top gets
// cross-boundary optimization the isolated blocks do not.

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
    rabit_pcu_fs_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (8),
        .NPATH         (2),
        .H_FMT         (0),
        .NMULT_H       (16),
        .DQ_LANES      (4),
        .ALIGN_MAX     (16)
    ) u_pcu (.*);
endmodule


module rabit_pcu_fs_p (
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
    rabit_pcu_fs_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (8),
        .NPATH         (2),
        .H_FMT         (0),
        .H_MUL_PIPE    (1),
        .NMULT_H       (16),
        .DQ_LANES      (4),
        .ALIGN_MAX     (16)
    ) u_pcu (.*);
endmodule


module rabit_pcu_fs_h16 (
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
    rabit_pcu_fs_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (8),
        .NPATH         (2),
        .H_FMT         (1),
        .NMULT_H       (16),
        .DQ_LANES      (4),
        .ALIGN_MAX     (16)
    ) u_pcu (.*);
endmodule


// ---- per-module breakdown wrappers ----------------------------------------
//
// Registered at both ends so an isolated combinational block still reports a
// meaningful timing path under the shared constraint, the same convention
// rabit_blk_cvt uses.

module rabit_fs_blk_hscale (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         h_we_i,
    input  wire [255:0] h_word_i,
    input  wire [255:0] x_i,
    input  wire         path_i,
    output reg  [255:0] u_fp16_o,
    output reg          h_nan_o,
    output reg          h_ovf_o,
    output reg          h_loaded_o
);
    reg  [255:0] x_q;
    reg          path_q;
    wire [255:0] u_w;
    wire         nan_w;
    wire         ovf_w;
    wire         loaded_w;

    rabit_fs_h_scale_unit #(.NIN(16), .NPATH(2), .H_FMT(0), .NMULT_H(16))
        u_hscale (
            .clk        (clk),
            .rst_n      (rst_n),
            .h_we_i     (h_we_i),
            .h_sel_i    (1'b0),
            .h_word_i   (h_word_i),
            .x_i        (x_q),
            .path_i     (path_q),
            .u_fp16_o   (u_w),
            .h_nan_o    (nan_w),
            .h_ovf_o    (ovf_w),
            .h_loaded_o (loaded_w)
        );

    always @(posedge clk) begin
        if (!rst_n) begin
            x_q <= 256'd0; path_q <= 1'b0;
            u_fp16_o <= 256'd0; h_nan_o <= 1'b0; h_ovf_o <= 1'b0;
            h_loaded_o <= 1'b0;
        end else begin
            x_q <= x_i; path_q <= path_i;
            u_fp16_o <= u_w; h_nan_o <= nan_w; h_ovf_o <= ovf_w;
            h_loaded_o <= loaded_w;
        end
    end
endmodule


module rabit_fs_blk_gbuf (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         we_i,
    input  wire [1:0]   wsel_i,
    input  wire [255:0] wdata_i,
    input  wire [4:0]   rd_base_i,
    input  wire         rd_path_i,
    output reg  [63:0]  g_o,
    output reg          loaded_o
);
    wire [63:0] g_w;
    wire        loaded_w;

    rabit_fs_g_buffer #(.NOUT(32), .NPATH(2), .NRD(4))
        u_gbuf (
            .clk       (clk),
            .rst_n     (rst_n),
            .we_i      (we_i),
            .wsel_i    (wsel_i),
            .wdata_i   (wdata_i),
            .rd_base_i (rd_base_i),
            .rd_path_i (rd_path_i),
            .g_o       (g_w),
            .loaded_o  (loaded_w)
        );

    always @(posedge clk) begin
        if (!rst_n) begin
            g_o <= 64'd0; loaded_o <= 1'b0;
        end else begin
            g_o <= g_w; loaded_o <= loaded_w;
        end
    end
endmodule


module rabit_fs_blk_dq (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [255:0] acc_i,
    input  wire [63:0]  g_i,
    input  wire [5:0]   e0_i,
    input  wire         valid_i,
    input  wire         half_i,
    input  wire         path_i,
    input  wire [2:0]   beat_i,
    input  wire         last_i,
    output wire         y_valid_o,
    output wire [63:0]  y_data_o,
    output wire [2:0]   y_beat_o,
    output wire         y_last_o,
    output wire         y_ovf_o
);
    rabit_fs_dq_unit #(
        .NOUT_PER_WORD (8),
        .NPATH         (2),
        .DQ_LANES      (4),
        .ACC_W         (32),
        .MANT_W        (12),
        .EXP_W         (6),
        .ALIGN_MAX     (16),
        .BEAT_W        (3)
    ) u_dq (.*);
endmodule
