`timescale 1ns/1ps

// RaBiT 2-bit residual-binarization PCU: projection-layer GEMV, compute only.
//
//     A_p[j] = sum_k B_p[j][k] * u_p[k],   B_p[j][k] in {+1,-1},  p in 1..NPATH
//     u_p[k] = h_p[k] * x[k]                       (precomputed by the NPU)
//     y[j]   = g_1[j]*A_1[j] + g_2[j]*A_2[j]       (dequantized by the NPU)
//
// The PCU only produces the raw per-path partial sums A_p as 32-bit fixed-point
// values at the reference exponent E0. Both g scaling and the path sum stay
// with the NPU, which is why this design contains no multiplier at all.
//
// What is inside this boundary
//   - the convert-on-write unit (binary16 -> block fixed point)
//   - NOUT_PER_WORD processing elements (sign correction, 4:2 tree, CPA,
//     exponent alignment, saturating 32-bit add)
//   - the architectural accumulator array, 64 x 32b with the defaults
//   - the sequencer
//
// What is outside, modelled behaviourally by the testbench
//   - the input GRF (4 entries), which stores what cvt_blk_o produces and
//     returns it on grf_blk_i
//   - the CRF / instruction store, the DRAM bank, and the host NPU
//
// Word format (WORD_W = NIN * NOUT_PER_WORD * NPATH = 256 bits by default)
//
//     rd_word_i[j*(NPATH*NIN) + p*NIN + k] = B_(p+1)[out j][in k]
//     bit value 0 -> +1, 1 -> -1
//
// which is the packing the RaBiT GPU kernel already uses, so the PE reads its
// sixteen weight bits as one contiguous slice with no shuffle in between.
//
// Numeric contract. A block entry stores mantissas whose LSB weighs
// 2**(e_ent - 14 - MANT_W); the accumulator holds everything at
// 2**(E0 - 14 - MANT_W). So the integer the PCU drains relates to the real
// partial sum by
//
//     A_p[j] = drain_data_o(j) * 2**(cfg_e0_i - 14 - MANT_W).
//
// cfg_e0_i lives in the same domain as the binary16 biased exponent. Pick it as
// the maximum e_ent over the k sweep: that makes every alignment a right shift
// and keeps the left-shift saturation path (status_sticky_o[1]) idle. E0 below
// (max e_ent - (ACC_W - PSUM_W)) is outside the design's range and will
// saturate; see docs/rabit_pcu_spec.md.
module rabit_pcu_top #(
    parameter int MANT_W        = 12,
    parameter int SHIFTER_EN    = 1,
    parameter int NOUT_PER_WORD = 8,
    parameter int NPATH         = 2,
    parameter int NIN           = 16,
    parameter int NGROUP        = 4,
    parameter int ACC_W         = 32,
    parameter int EXP_W         = 6,
    parameter int SHIFT_RND     = 0,
    // derived; do not override
    parameter int BLK_W         = NIN*(MANT_W+1) + EXP_W,
    parameter int WORD_W        = NIN*NOUT_PER_WORD*NPATH,
    parameter int GW            = $clog2(NGROUP),
    parameter int PW            = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int SH_W          = EXP_W + 1,
    parameter int PSUM_W        = MANT_W + 1 + $clog2(NIN),
    parameter int DRAIN_W       = NOUT_PER_WORD*ACC_W
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- configuration ------------------------------------------------
    input  logic [EXP_W-1:0]        cfg_e0_i,

    // ---- convert-on-write port (GRF storage is external) --------------
    input  logic                    wr_valid_i,
    output logic                    wr_ready_o,
    input  logic [1:0]              wr_entry_i,
    input  logic [NIN*16-1:0]       wr_fp16_i,
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

    // ---- drain port ---------------------------------------------------
    input  logic                    drain_req_i,
    input  logic [GW-1:0]           drain_group_i,
    output logic                    drain_ready_o,
    output logic                    drain_valid_o,
    output logic [GW-1:0]           drain_group_o,
    output logic [PW-1:0]           drain_path_o,
    output logic                    drain_last_o,
    output logic [DRAIN_W-1:0]      drain_data_o,

    // ---- status -------------------------------------------------------
    input  logic                    status_clr_i,
    output logic [2:0]              status_sticky_o
);

    localparam int MANT_BUS = NIN*(MANT_W+1);
    localparam int NSLOT    = NGROUP*NPATH;
    localparam int SEL_W    = GW + PW;

    // ---- convert-on-write -------------------------------------------------
    logic [MANT_BUS-1:0] cvt_mant;
    logic [EXP_W-1:0]    cvt_eent;
    logic                cvt_ovf;

    rabit_cvt_fp16_blk #(
        .NIN        (NIN),
        .MANT_W     (MANT_W),
        .EXP_W      (EXP_W),
        .SHIFTER_EN (SHIFTER_EN)
    ) u_cvt (
        .fp16_i  (wr_fp16_i),
        .e0_i    (cfg_e0_i),
        .blk_o   (cvt_mant),
        .e_ent_o (cvt_eent),
        .ovf_o   (cvt_ovf)
    );

    always_comb begin
        wr_ready_o  = rst_n;
        cvt_we_o    = wr_valid_i && rst_n;
        cvt_entry_o = wr_entry_i;
        cvt_blk_o   = {cvt_eent, cvt_mant};
    end

    // ---- sequencer --------------------------------------------------------
    logic             word_start;
    logic             stage_a_en;
    logic [PW-1:0]    path_sel;
    logic [SEL_W-1:0] acc_rd_sel;
    logic             acc_wr_en;
    logic [SEL_W-1:0] acc_wr_sel;
    logic             acc_wr_zero;
    logic             acc_wr_pe;

    rabit_pcu_ctrl #(
        .NPATH  (NPATH),
        .NGROUP (NGROUP)
    ) u_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .rd_valid_i    (rd_valid_i),
        .rd_group_i    (rd_group_i),
        .rd_ready_o    (rd_ready_o),
        .drain_req_i   (drain_req_i),
        .drain_group_i (drain_group_i),
        .drain_ready_o (drain_ready_o),
        .word_start_o  (word_start),
        .stage_a_en_o  (stage_a_en),
        .path_sel_o    (path_sel),
        .fold_sel_o    (),
        .acc_rd_sel_o  (acc_rd_sel),
        .acc_wr_en_o   (acc_wr_en),
        .acc_wr_sel_o  (acc_wr_sel),
        .acc_wr_zero_o (acc_wr_zero),
        .acc_wr_pe_o   (acc_wr_pe),
        .acc_fold_o    (),
        .drain_valid_o (drain_valid_o),
        .drain_group_o (drain_group_o),
        .drain_path_o  (drain_path_o),
        .drain_last_o  (drain_last_o),
        .rd_done_o     (rd_done_o)
    );

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
    logic [BLK_W-1:0]     blk_sel;
    logic [MANT_BUS-1:0]  blk_mant;
    logic [EXP_W-1:0]     blk_eent;
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

    // ---- accumulator file -------------------------------------------------
    logic [DRAIN_W-1:0] acc_rd_data;
    logic [DRAIN_W-1:0] acc_wr_data;

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

            // bit[j*(NPATH*NIN) + p*NIN + k]: one contiguous slice per PE.
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
        acc_wr_data = acc_wr_zero ? {DRAIN_W{1'b0}} : pe_acc_next;
    end

    // ---- sticky status ----------------------------------------------------
    //
    // [0] a 32-bit accumulator add saturated
    // [1] an alignment left shift saturated (E0 set too far below max e_ent)
    // [2] convert-on-write clamped a lane (only reachable with SHIFTER_EN = 0)
    logic [2:0] sticky_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sticky_q <= 3'b000;
        end else if (status_clr_i) begin
            sticky_q <= 3'b000;
        end else begin
            sticky_q <= sticky_q |
                        {cvt_we_o    & cvt_ovf,
                         acc_wr_pe   & (|pe_shift_sat),
                         acc_wr_pe   & (|pe_acc_sat)};
        end
    end

    always_comb status_sticky_o = sticky_q;

`ifndef SYNTHESIS
    initial begin
        if (WORD_W != NIN*NOUT_PER_WORD*NPATH)
            $fatal(1, "rabit_pcu_top: WORD_W is derived, do not override it");
        if (NGROUP != (1 << GW))
            $fatal(1, "rabit_pcu_top: NGROUP must be a power of two");
    end
`endif

`ifdef RABIT_ASSERTIONS
`ifndef SYNTHESIS
    // Interface rules. A column command is either a read or a write, never
    // both, and a source that has not been granted must hold its payload.
    logic [WORD_W-1:0] hold_word_q;
    logic              hold_check_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_word_q  <= {WORD_W{1'b0}};
            hold_check_q <= 1'b0;
        end else begin
            hold_word_q  <= rd_word_i;
            hold_check_q <= rd_valid_i && !rd_ready_o;

            assert (!(wr_valid_i && rd_valid_i))
                else $error("rabit_pcu_top: WR and RD in the same column slot");

            if (hold_check_q) begin
                assert (rd_valid_i && (rd_word_i === hold_word_q))
                    else $error("rabit_pcu_top: rd_valid_i/rd_word_i moved before rd_ready_o (valid=%b, pump=%b)",
                                rd_valid_i, u_ctrl.pump_q);
            end
        end
    end
`endif
`endif

endmodule
