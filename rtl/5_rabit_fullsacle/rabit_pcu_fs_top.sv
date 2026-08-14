`timescale 1ns/1ps

// RaBiT PCU, full-scale variant: the same projection-layer GEMV engine as
// rabit_pcu_top, with the RaBiT input and output scales moved inside the PCU.
//
//     A_p[j] = sum_k B_p[j][k] * u_p[k],   B_p[j][k] in {+1,-1},  p in 1..NPATH
//     u_p[k] = h_p[k] * x[k]                       <- here, not in the NPU
//     y[j]   = g_1[j]*A_1[j] + g_2[j]*A_2[j]       <- here, not in the NPU
//
// Everything that made the base variant work is reused unmodified from
// rtl/5_rabit: the convert-on-write unit, the processing elements and their
// compressor tree and aligner, the accumulator register file, and the
// sequencer. This file adds three blocks and rewires the ports around them.
//
//   rabit_fs_h_scale_unit   fp16 x fp8 multiply array on the write path
//   rabit_fs_g_buffer       the stripe's 32 x 2 binary16 output scales
//   rabit_fs_dq_unit        the drain-time dequantizer, plus its sequencer
//
// The inner loop is byte-for-byte the base schedule: two writes and four reads
// per 16-input chunk, two PCU cycles per column command. Only the write payload
// changes.
//
//     wr_kind_i = WRK_H   h chunk, {h1[k], h2[k]} as FP8-E4M3 (256b)
//     wr_kind_i = WRK_X   x chunk, binary16 x 16 (256b), takes NPATH cycles
//     wr_kind_i = WRK_G   one quarter of the stripe's g table (256b)
//
// A WRK_H write must precede the WRK_X write of the same chunk, because the x
// write is the cycle pair that consumes it. The four WRK_G writes happen once
// per stripe, before its k sweep.
//
// There is no multiplier on the read path. h multiplies live on the write path,
// g multiplies live on the drain path, and the PE array is the same
// multiplier-free sign-and-add tree the base variant uses.
//
// Two drains coexist. drain_req_i is the base's raw per-group drain, kept for
// debug and for measuring against the base variant; dq_req_i drains a whole
// stripe through the dequantizer and produces binary16 y. They share the
// accumulator port, so neither may overlap the other or a column command.
module rabit_pcu_fs_top #(
    parameter int MANT_W        = 12,
    parameter int SHIFTER_EN    = 1,
    parameter int NOUT_PER_WORD = 8,
    parameter int NPATH         = 2,
    parameter int NIN           = 16,
    parameter int NGROUP        = 4,
    parameter int ACC_W         = 32,
    parameter int EXP_W         = 6,
    parameter int SHIFT_RND     = 0,
    // full-scale options
    parameter int H_FMT         = 0,    // 0 = FP8_E4M3 (2 WR/chunk), 1 = FP16_3WR
    parameter int H_MUL_PIPE    = 0,    // 1 = register between the array and cvt
    parameter int NMULT_H       = 16,
    parameter int DQ_LANES      = 4,
    parameter int ALIGN_MAX     = 16,
    // derived; do not override
    parameter int BLK_W         = NIN*(MANT_W+1) + EXP_W,
    parameter int WORD_W        = NIN*NOUT_PER_WORD*NPATH,
    parameter int GW            = $clog2(NGROUP),
    parameter int PW            = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int SH_W          = EXP_W + 1,
    parameter int PSUM_W        = MANT_W + 1 + $clog2(NIN),
    parameter int DRAIN_W       = NOUT_PER_WORD*ACC_W,
    parameter int NOUT_STRIPE   = NGROUP*NOUT_PER_WORD,
    parameter int NHALF         = NOUT_PER_WORD / DQ_LANES,
    parameter int BEAT_W        = $clog2(NGROUP*NHALF),
    parameter int Y_W           = DQ_LANES*16
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- configuration ------------------------------------------------
    input  logic [EXP_W-1:0]        cfg_e0_i,

    // ---- write port: x, h and g all arrive as 256-bit column writes ----
    input  logic                    wr_valid_i,
    output logic                    wr_ready_o,
    input  logic [1:0]              wr_kind_i,
    input  logic [1:0]              wr_sel_i,
    input  logic [NIN*16-1:0]       wr_data_i,
    output logic                    cvt_we_o,
    output logic [1:0]              cvt_entry_o,
    output logic [BLK_W-1:0]        cvt_blk_o,

    // ---- compute port -------------------------------------------------
    input  logic                    rd_valid_i,
    output logic                    rd_ready_o,
    input  logic [GW-1:0]           rd_group_i,
    input  logic                    rd_pair_i,
    input  logic [WORD_W-1:0]       rd_word_i,
    output logic                    grf_pair_o,
    input  logic [NPATH*BLK_W-1:0]  grf_blk_i,
    output logic                    rd_done_o,

    // ---- raw drain port (base semantics, kept for debug) ---------------
    input  logic                    drain_req_i,
    input  logic [GW-1:0]           drain_group_i,
    output logic                    drain_ready_o,
    output logic                    drain_valid_o,
    output logic [GW-1:0]           drain_group_o,
    output logic [PW-1:0]           drain_path_o,
    output logic                    drain_last_o,
    output logic [DRAIN_W-1:0]      drain_data_o,

    // ---- dequantizing drain port --------------------------------------
    input  logic                    dq_req_i,
    output logic                    dq_ready_o,
    output logic                    dq_busy_o,
    output logic                    y_valid_o,
    output logic [Y_W-1:0]          y_data_o,
    output logic [BEAT_W-1:0]       y_beat_o,
    output logic                    y_last_o,

    // ---- status -------------------------------------------------------
    input  logic                    status_clr_i,
    output logic [2:0]              status_sticky_o,
    output logic [3:0]              status_fs_o
);

    localparam int MANT_BUS = NIN*(MANT_W+1);
    localparam int NSLOT    = NGROUP*NPATH;
    localparam int SEL_W    = GW + PW;
    localparam int IDX_W    = $clog2(NOUT_STRIPE);
    localparam int WSEL_W   = $clog2((NOUT_STRIPE*NPATH*16)/256);

    localparam logic [1:0] WRK_X = 2'd0;
    localparam logic [1:0] WRK_H = 2'd1;
    localparam logic [1:0] WRK_G = 2'd2;

    // =====================================================================
    // write path: h latch, x multiply, convert on write, g buffer
    // =====================================================================
    //
    // A WRK_X write is the only multi-cycle command on this port: it occupies
    // the whole tCCD_S column slot and spends cycle p on path p+1. wr_ready_o
    // is a function of state alone, so there is no combinational loop back to
    // the command source.
    logic          w_busy_q;
    logic [PW-1:0] w_path_q;
    logic          w_pair_q;

    logic          w_is_x;
    logic          w_start_c;
    logic          w_active_c;
    logic [PW-1:0] w_path_c;
    logic          w_pair_c;

    always_comb begin
        w_is_x     = (wr_kind_i == WRK_X);
        w_start_c  = !w_busy_q && wr_valid_i && w_is_x && rst_n;
        w_active_c = w_busy_q || w_start_c;
        w_path_c   = w_start_c ? {PW{1'b0}} : w_path_q;
        w_pair_c   = w_start_c ? wr_sel_i[0] : w_pair_q;

        wr_ready_o = w_is_x ? (w_busy_q && (w_path_q == PW'(NPATH-1)))
                            : rst_n;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_busy_q <= 1'b0;
            w_path_q <= {PW{1'b0}};
            w_pair_q <= 1'b0;
        end else if (w_start_c) begin
            w_pair_q <= wr_sel_i[0];
            if (NPATH > 1) begin
                w_busy_q <= 1'b1;
                w_path_q <= PW'(1);
            end
        end else if (w_busy_q) begin
            if (w_path_q == PW'(NPATH-1)) begin
                w_busy_q <= 1'b0;
                w_path_q <= {PW{1'b0}};
            end else begin
                w_path_q <= w_path_q + PW'(1);
            end
        end
    end

    logic h_we;
    logic g_we;

    always_comb begin
        h_we = wr_valid_i && rst_n && !w_busy_q && (wr_kind_i == WRK_H);
        g_we = wr_valid_i && rst_n && !w_busy_q && (wr_kind_i == WRK_G);
    end

    logic [NIN*16-1:0] u_fp16;
    logic              h_nan;
    logic              h_ovf;
    logic              h_loaded;

    rabit_fs_h_scale_unit #(
        .NIN     (NIN),
        .NPATH   (NPATH),
        .H_FMT   (H_FMT),
        .NMULT_H (NMULT_H)
    ) u_hscale (
        .clk        (clk),
        .rst_n      (rst_n),
        .h_we_i     (h_we),
        .h_sel_i    (wr_sel_i[PW-1:0]),
        .h_word_i   (wr_data_i),
        .x_i        (wr_data_i),
        .path_i     (w_path_c),
        .u_fp16_o   (u_fp16),
        .h_nan_o    (h_nan),
        .h_ovf_o    (h_ovf),
        .h_loaded_o (h_loaded)
    );

    // ---- optional register between the multiply array and the convert unit --
    //
    // Unpipelined (H_MUL_PIPE = 0) is the specified datapath: one column-slot
    // cycle decodes h, multiplies, rounds to binary16, converts to a block entry
    // and writes it. That is a long combinational path, and synthesis says it is
    // what misses tCCD_S -- see README.md and results/rabit_fs_report.md.
    //
    // H_MUL_PIPE = 1 splits it in two without costing a single column slot,
    // because the deadline still works out. Cycle 0 of the x write multiplies
    // u_1 and cycle 1 converts it while multiplying u_2; the conversion of u_2
    // lands one cycle into the following column slot, which is the RD's pump 0
    // and reads entry {pair, 0}. Pump 1 reads {pair, 1} the cycle after that,
    // exactly when it has become available. The deadline assertion below checks
    // this in both modes rather than trusting the argument.
    logic [NIN*16-1:0] cvt_fp16;
    logic              cvt_we;
    logic [1:0]        cvt_entry;

    generate
        if (H_MUL_PIPE == 0) begin : g_hmul_flow
            always_comb begin
                cvt_fp16  = u_fp16;
                cvt_we    = w_active_c;
                cvt_entry = {w_pair_c, w_path_c};
            end
        end else begin : g_hmul_reg
            logic [NIN*16-1:0] u_q;
            logic              we_q;
            logic [1:0]        entry_q;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    we_q    <= 1'b0;
                    entry_q <= 2'b00;
                    u_q     <= {(NIN*16){1'b0}};
                end else begin
                    we_q <= w_active_c;
                    if (w_active_c) begin
                        u_q     <= u_fp16;
                        entry_q <= {w_pair_c, w_path_c};
                    end
                end
            end

            always_comb begin
                cvt_fp16  = u_q;
                cvt_we    = we_q;
                cvt_entry = entry_q;
            end
        end
    endgenerate

    logic [MANT_BUS-1:0] cvt_mant;
    logic [EXP_W-1:0]    cvt_eent;
    logic                cvt_ovf;

    rabit_cvt_fp16_blk #(
        .NIN        (NIN),
        .MANT_W     (MANT_W),
        .EXP_W      (EXP_W),
        .SHIFTER_EN (SHIFTER_EN)
    ) u_cvt (
        .fp16_i  (cvt_fp16),
        .e0_i    (cfg_e0_i),
        .blk_o   (cvt_mant),
        .e_ent_o (cvt_eent),
        .ovf_o   (cvt_ovf)
    );

    always_comb begin
        cvt_we_o    = cvt_we;
        cvt_entry_o = cvt_entry;
        cvt_blk_o   = {cvt_eent, cvt_mant};
    end

    logic [DQ_LANES*16-1:0] g_rd;
    logic [IDX_W-1:0]       g_base;
    logic [PW-1:0]          g_path;
    logic                   g_loaded;

    rabit_fs_g_buffer #(
        .NOUT  (NOUT_STRIPE),
        .NPATH (NPATH),
        .NRD   (DQ_LANES)
    ) u_gbuf (
        .clk       (clk),
        .rst_n     (rst_n),
        .we_i      (g_we),
        .wsel_i    (wr_sel_i[WSEL_W-1:0]),
        .wdata_i   (wr_data_i),
        .rd_base_i (g_base),
        .rd_path_i (g_path),
        .g_o       (g_rd),
        .loaded_o  (g_loaded)
    );

    // =====================================================================
    // sequencer: the base one for compute and the raw drain, plus the
    // full-scale drain sequencer beside it
    // =====================================================================
    logic             fs_ready;
    logic             fs_start;
    logic             fs_busy;
    logic             fs_acc_busy;
    logic [SEL_W-1:0] fs_rd_sel;
    logic             fs_wr_en;
    logic [SEL_W-1:0] fs_wr_sel;
    logic             fs_lane_valid;
    logic             fs_half;
    logic             fs_path;
    logic [BEAT_W-1:0] fs_beat;
    logic             fs_last;

    logic             word_start;
    logic             stage_a_en;
    logic [PW-1:0]    path_sel;
    logic [SEL_W-1:0] ctrl_rd_sel;
    logic             ctrl_wr_en;
    logic [SEL_W-1:0] ctrl_wr_sel;
    logic             ctrl_wr_zero;
    logic             ctrl_wr_pe;
    logic             ctrl_rd_ready;
    logic             ctrl_drain_ready;

    rabit_pcu_ctrl #(
        .NPATH  (NPATH),
        .NGROUP (NGROUP)
    ) u_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .rd_valid_i    (rd_valid_i && !fs_acc_busy),
        .rd_group_i    (rd_group_i),
        .rd_ready_o    (ctrl_rd_ready),
        .drain_req_i   (drain_req_i && !fs_busy),
        .drain_group_i (drain_group_i),
        .drain_ready_o (ctrl_drain_ready),
        .word_start_o  (word_start),
        .stage_a_en_o  (stage_a_en),
        .path_sel_o    (path_sel),
        .acc_rd_sel_o  (ctrl_rd_sel),
        .acc_wr_en_o   (ctrl_wr_en),
        .acc_wr_sel_o  (ctrl_wr_sel),
        .acc_wr_zero_o (ctrl_wr_zero),
        .acc_wr_pe_o   (ctrl_wr_pe),
        .drain_valid_o (drain_valid_o),
        .drain_group_o (drain_group_o),
        .drain_path_o  (drain_path_o),
        .drain_last_o  (drain_last_o),
        .rd_done_o     (rd_done_o)
    );

    rabit_fs_drain_seq #(
        .NGROUP        (NGROUP),
        .NPATH         (NPATH),
        .NOUT_PER_WORD (NOUT_PER_WORD),
        .DQ_LANES      (DQ_LANES)
    ) u_drain_seq (
        .clk          (clk),
        .rst_n        (rst_n),
        .req_i        (dq_req_i),
        .pipe_idle_i  (ctrl_drain_ready),
        .ready_o      (fs_ready),
        .start_o      (fs_start),
        .busy_o       (fs_busy),
        .acc_busy_o   (fs_acc_busy),
        .acc_rd_sel_o (fs_rd_sel),
        .acc_wr_en_o  (fs_wr_en),
        .acc_wr_sel_o (fs_wr_sel),
        .lane_valid_o (fs_lane_valid),
        .half_o       (fs_half),
        .path_o       (fs_path),
        .g_base_o     (g_base),
        .g_path_o     (g_path),
        .beat_o       (fs_beat),
        .last_o       (fs_last)
    );

    always_comb begin
        rd_ready_o    = ctrl_rd_ready && !fs_acc_busy;
        drain_ready_o = ctrl_drain_ready && !fs_busy;
        dq_ready_o    = fs_ready;
        dq_busy_o     = fs_busy;
    end

    // The GRF pair select is held across the whole 2-pump window so the command
    // source only has to present it once, on the cycle the word starts.
    logic pair_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pair_q <= 1'b0;
        end else if (word_start) begin
            pair_q <= rd_pair_i;
        end
    end

    always_comb grf_pair_o = word_start ? rd_pair_i : pair_q;

    // ---- stage A operand select ------------------------------------------
    logic [BLK_W-1:0]       blk_sel;
    logic [MANT_BUS-1:0]    blk_mant;
    logic [EXP_W-1:0]       blk_eent;
    logic signed [SH_W-1:0] shift_c;

    always_comb begin
        blk_sel  = grf_blk_i[path_sel*BLK_W +: BLK_W];
        blk_mant = blk_sel[MANT_BUS-1:0];
        blk_eent = blk_sel[BLK_W-1 -: EXP_W];
        shift_c  = $signed({1'b0, blk_eent}) - $signed({1'b0, cfg_e0_i});
    end

    logic signed [SH_W-1:0] shift_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shift_q <= {SH_W{1'b0}};
        end else if (stage_a_en) begin
            shift_q <= shift_c;
        end
    end

    // =====================================================================
    // accumulator file, shared by the PEs, the raw drain and the dequantizer
    // =====================================================================
    logic [DRAIN_W-1:0] acc_rd_data;
    logic [DRAIN_W-1:0] acc_wr_data;
    logic [SEL_W-1:0]   acc_rd_sel;
    logic               acc_wr_en;
    logic [SEL_W-1:0]   acc_wr_sel;

    rabit_acc_regfile #(
        .NPE   (NOUT_PER_WORD),
        .NSLOT (NSLOT),
        .ACC_W (ACC_W)
    ) u_acc (
        .clk       (clk),
        .rst_n     (rst_n),
        .rd_sel_i  (acc_rd_sel),
        .rd_data_o (acc_rd_data),
        .wr_en_i   (acc_wr_en),
        .wr_sel_i  (acc_wr_sel),
        .wr_data_i (acc_wr_data)
    );

    always_comb drain_data_o = acc_rd_data;

    // ---- processing elements ---------------------------------------------
    logic [NOUT_PER_WORD-1:0] pe_acc_sat;
    logic [NOUT_PER_WORD-1:0] pe_shift_sat;
    logic [DRAIN_W-1:0]       pe_acc_next;

    genvar pe;
    generate
        for (pe = 0; pe < NOUT_PER_WORD; pe = pe + 1) begin : g_pe
            logic [NIN-1:0] pe_bits;

            always_comb begin
                pe_bits = rd_word_i[pe*(NPATH*NIN) + path_sel*NIN +: NIN];
            end

            rabit_pe #(
                .NIN        (NIN),
                .MANT_W     (MANT_W),
                .ACC_W      (ACC_W),
                .SH_W       (SH_W),
                .SHIFTER_EN (SHIFTER_EN),
                .SHIFT_RND  (SHIFT_RND),
                .PSUM_W     (PSUM_W)
            ) u_pe (
                .clk         (clk),
                .rst_n       (rst_n),
                .ce_i        (stage_a_en),
                .b_bits_i    (pe_bits),
                .blk_i       (blk_mant),
                .shift_i     (shift_q),
                .acc_cur_i   (acc_rd_data[pe*ACC_W +: ACC_W]),
                .acc_next_o  (pe_acc_next[pe*ACC_W +: ACC_W]),
                .acc_sat_o   (pe_acc_sat[pe]),
                .shift_sat_o (pe_shift_sat[pe]),
                .psum_o      ()
            );
        end
    endgenerate

    always_comb begin
        if (fs_acc_busy) begin
            acc_rd_sel  = fs_rd_sel;
            acc_wr_en   = fs_wr_en;
            acc_wr_sel  = fs_wr_sel;
            acc_wr_data = {DRAIN_W{1'b0}};
        end else begin
            acc_rd_sel  = ctrl_rd_sel;
            acc_wr_en   = ctrl_wr_en;
            acc_wr_sel  = ctrl_wr_sel;
            acc_wr_data = ctrl_wr_zero ? {DRAIN_W{1'b0}} : pe_acc_next;
        end
    end

    // =====================================================================
    // dequantizer
    // =====================================================================
    logic y_ovf;

    rabit_fs_dq_unit #(
        .NOUT_PER_WORD (NOUT_PER_WORD),
        .NPATH         (NPATH),
        .DQ_LANES      (DQ_LANES),
        .ACC_W         (ACC_W),
        .MANT_W        (MANT_W),
        .EXP_W         (EXP_W),
        .ALIGN_MAX     (ALIGN_MAX),
        .BEAT_W        (BEAT_W)
    ) u_dq (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_i     (acc_rd_data),
        .g_i       (g_rd),
        .e0_i      (cfg_e0_i),
        .valid_i   (fs_lane_valid),
        .half_i    (fs_half),
        .path_i    (fs_path),
        .beat_i    (fs_beat),
        .last_i    (fs_last),
        .y_valid_o (y_valid_o),
        .y_data_o  (y_data_o),
        .y_beat_o  (y_beat_o),
        .y_last_o  (y_last_o),
        .y_ovf_o   (y_ovf)
    );

    // =====================================================================
    // sticky status
    // =====================================================================
    //
    // status_sticky_o keeps the base meaning:
    //   [0] a 32-bit accumulator add saturated
    //   [1] an alignment left shift saturated (E0 set too far below max e_ent)
    //   [2] convert-on-write clamped a lane (only with SHIFTER_EN = 0)
    //
    // status_fs_o is what the full-scale path adds:
    //   [0] an FP8-E4M3 h code was a NaN encoding
    //   [1] an h*x product saturated to the largest finite binary16
    //   [2] a dequantized y saturated to the largest finite binary16
    //   [3] a dequantizing drain started with the g buffer incomplete
    logic [2:0] sticky_q;
    logic [3:0] fs_sticky_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sticky_q    <= 3'b000;
            fs_sticky_q <= 4'b0000;
        end else if (status_clr_i) begin
            sticky_q    <= 3'b000;
            fs_sticky_q <= 4'b0000;
        end else begin
            sticky_q <= sticky_q |
                        {cvt_we_o  & cvt_ovf,
                         ctrl_wr_pe & (|pe_shift_sat),
                         ctrl_wr_pe & (|pe_acc_sat)};
            // The h flags belong to the multiply array's cycle, which is one
            // ahead of cvt_we_o when H_MUL_PIPE is on, so they are qualified
            // with w_active_c rather than with the convert unit's write enable.
            fs_sticky_q <= fs_sticky_q |
                           {fs_start & ~g_loaded,
                            y_ovf,
                            w_active_c & h_ovf,
                            w_active_c & h_nan};
        end
    end

    always_comb begin
        status_sticky_o = sticky_q;
        status_fs_o     = fs_sticky_q;
    end

`ifndef SYNTHESIS
    initial begin
        if (WORD_W != NIN*NOUT_PER_WORD*NPATH)
            $fatal(1, "rabit_pcu_fs_top: WORD_W is derived, do not override it");
        if (NGROUP != (1 << GW))
            $fatal(1, "rabit_pcu_fs_top: NGROUP must be a power of two");
    end
`endif

`ifdef RABIT_FS_ASSERTIONS
`ifndef SYNTHESIS
    // ---- interface rules --------------------------------------------------
    logic [WORD_W-1:0] hold_word_q;
    logic              hold_check_q;
    logic [NIN*16-1:0] hold_wdata_q;
    logic              hold_wr_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_word_q  <= {WORD_W{1'b0}};
            hold_check_q <= 1'b0;
            hold_wdata_q <= {(NIN*16){1'b0}};
            hold_wr_q    <= 1'b0;
        end else begin
            hold_word_q  <= rd_word_i;
            hold_check_q <= rd_valid_i && !rd_ready_o;
            hold_wdata_q <= wr_data_i;
            hold_wr_q    <= wr_valid_i && !wr_ready_o;

            // One command per column slot. The base sequencer already gives a
            // raw drain priority over a new word, but the dequantizing drain
            // sits beside it rather than inside it, so a column read presented
            // in the same slot as dq_req_i would be started and then have its
            // stage-B write muxed away. The command source must not do that.
            assert (!(wr_valid_i && rd_valid_i))
                else $error("rabit_pcu_fs_top: WR and RD in the same column slot");
            assert (!(rd_valid_i && dq_req_i))
                else $error("rabit_pcu_fs_top: RD and dq_req in the same column slot");
            assert (!(wr_valid_i && dq_req_i))
                else $error("rabit_pcu_fs_top: WR and dq_req in the same column slot");
            assert (!(drain_req_i && dq_req_i))
                else $error("rabit_pcu_fs_top: both drains requested in the same column slot");

            if (hold_check_q) begin
                assert (rd_valid_i && (rd_word_i === hold_word_q))
                    else $error("rabit_pcu_fs_top: word changed before rd_ready");
            end
            if (hold_wr_q) begin
                assert (wr_valid_i && (wr_data_i === hold_wdata_q) &&
                        (wr_kind_i == WRK_X))
                    else $error("rabit_pcu_fs_top: x write changed before wr_ready");
            end
        end
    end

    // ---- the u_p deadline -------------------------------------------------
    //
    // A column word's pump p reads GRF entry {pair, p}. The external GRF
    // registers what cvt_blk_o carries, so an entry becomes readable on the
    // cycle after its cvt_we_o pulse. The deadline is therefore: the entry a
    // pump reads must already be in the file, and must not be the one the
    // convert unit is producing in that same cycle.
    //
    // Both halves matter, and which one is tight depends on H_MUL_PIPE. With
    // the register in place, the conversion of u_2 runs during the following
    // column slot's pump 0 -- a different entry, in the same cycle -- and pump 1
    // reads it the cycle after. That is the tightest the schedule ever gets.
    localparam int NENTRY = 2*NPATH;

    logic [NENTRY-1:0] cvt_seen_q;

    integer ai;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cvt_seen_q <= {NENTRY{1'b0}};
        end else begin
            for (ai = 0; ai < NENTRY; ai = ai + 1) begin
                if (cvt_we_o && (cvt_entry_o == ai[1:0])) begin
                    cvt_seen_q[ai] <= 1'b1;
                end
            end

            if (stage_a_en) begin
                assert (cvt_seen_q[{grf_pair_o, path_sel}])
                    else $error("rabit_pcu_fs_top: RD consumed GRF entry %0d before any x write",
                                {grf_pair_o, path_sel});
                assert (!(cvt_we_o && (cvt_entry_o == {grf_pair_o, path_sel})))
                    else $error("rabit_pcu_fs_top: u_%0d missed its deadline -- entry %0d is being converted in the cycle that reads it",
                                path_sel + 1, {grf_pair_o, path_sel});
            end
        end
    end

    // ---- drain rules ------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(fs_start && !g_loaded))
                else $error("rabit_pcu_fs_top: dequantizing drain started with an incomplete g buffer");
            assert (!(fs_acc_busy && stage_a_en))
                else $error("rabit_pcu_fs_top: column read accepted during a dequantizing drain");
            assert (!(fs_acc_busy && drain_valid_o))
                else $error("rabit_pcu_fs_top: raw drain overlapped a dequantizing drain");
            assert (!(h_we && w_busy_q))
                else $error("rabit_pcu_fs_top: h write inside an x write's column slot");
        end
    end
`endif
`endif

endmodule
