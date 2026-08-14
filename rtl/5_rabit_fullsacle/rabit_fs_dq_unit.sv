`timescale 1ns/1ps

// g_dequant_unit: the drain-time engine that turns raw accumulators into y.
//
//     y[j] = fp16( g_1[j]*A_1[j] + g_2[j]*A_2[j] ),
//     A_p[j] = acc_p[j] * 2**(E0 - 14 - MANT_W)
//
// Organization. The accumulator file has one read port and one write port, both
// slot granular, and a slot is one path of one output group -- NOUT_PER_WORD
// accumulators. So a cycle can see one path of NOUT_PER_WORD outputs, not both
// paths of one output. The unit is therefore DQ_LANES lanes wide across the
// output axis and serializes the path axis:
//
//     cycle 0   slot (group, path 0), outputs 0 .. DQ_LANES-1     -> partial
//     cycle 1   slot (group, path 0), outputs DQ_LANES .. 2*DQ-1  -> partial
//     cycle 2   slot (group, path 1), outputs 0 .. DQ_LANES-1     -> y beat
//     cycle 3   slot (group, path 1), outputs DQ_LANES .. 2*DQ-1  -> y beat
//
// which is NPATH * NHALF = 4 cycles per group and NGROUP * 4 = 16 cycles for the
// 32 outputs of a stripe, at an average of two finished outputs per cycle. The
// price of the single read port is one partial register bank
// (NHALF x DQ_LANES products) and DQ_LANES adders instead of DQ_LANES/2.
//
// Pipeline, three stages, one result per cycle:
//
//     S0  lane      normalize the accumulator, decode and normalize g, multiply
//     S1  add       align the two paths and add, or park the path-0 product
//     S2  pack      normalize the sum and round to binary16
//
// Only S1 and S2 do work on a path-1 cycle, so a y beat appears every other
// cycle carrying DQ_LANES outputs, which is exactly the 16b x DQ_LANES output
// port. The three-cycle latency is a tail on the drain, not a throughput cost.
module rabit_fs_dq_unit #(
    parameter int NOUT_PER_WORD = 8,
    parameter int NPATH         = 2,
    parameter int DQ_LANES      = 4,
    parameter int ACC_W         = 32,
    parameter int MANT_W        = 12,
    parameter int EXP_W         = 6,
    parameter int ALIGN_MAX     = 16,
    parameter int BEAT_W        = 3,
    // derived; do not override
    parameter int NHALF         = NOUT_PER_WORD / DQ_LANES,
    parameter int HW            = (NHALF > 1) ? $clog2(NHALF) : 1,
    parameter int QW            = (MANT_W + 1) + 11,
    parameter int FW            = 10,
    parameter int MAG_W         = QW + ALIGN_MAX + 1,
    parameter int EXPO_W        = FW + 1
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- accumulator slot currently on the read port ----------------------
    input  logic [NOUT_PER_WORD*ACC_W-1:0]  acc_i,
    input  logic [DQ_LANES*16-1:0]          g_i,
    input  logic [EXP_W-1:0]                e0_i,

    // ---- what this cycle is -----------------------------------------------
    input  logic                            valid_i,
    input  logic [HW-1:0]                   half_i,
    input  logic                            path_i,
    input  logic [BEAT_W-1:0]               beat_i,
    input  logic                            last_i,

    // ---- finished outputs --------------------------------------------------
    output logic                            y_valid_o,
    output logic [DQ_LANES*16-1:0]          y_data_o,
    output logic [BEAT_W-1:0]               y_beat_o,
    output logic                            y_last_o,
    output logic                            y_ovf_o
);

    localparam int PROD_W = 1 + QW + FW;

    // =====================================================================
    // S0: one lane per output being processed this cycle
    // =====================================================================
    logic [DQ_LANES-1:0]        l_sign_c;
    logic [DQ_LANES*QW-1:0]     l_q_c;
    logic [DQ_LANES*FW-1:0]     l_f_c;

    genvar l;
    generate
        for (l = 0; l < DQ_LANES; l = l + 1) begin : g_lane
            logic signed [ACC_W-1:0] acc_sel;
            integer                  sel;

            always_comb begin
                sel     = half_i * DQ_LANES + l;
                acc_sel = acc_i[sel*ACC_W +: ACC_W];
            end

            rabit_fs_dq_lane #(
                .ACC_W  (ACC_W),
                .MANT_W (MANT_W),
                .EXP_W  (EXP_W),
                .QW     (QW),
                .FW     (FW)
            ) u_lane (
                .acc_i  (acc_sel),
                .g_i    (g_i[l*16 +: 16]),
                .e0_i   (e0_i),
                .sign_o (l_sign_c[l]),
                .q_o    (l_q_c[l*QW +: QW]),
                .f_o    (l_f_c[l*FW +: FW])
            );
        end
    endgenerate

    logic [DQ_LANES-1:0]    s0_sign_q;
    logic [DQ_LANES*QW-1:0] s0_q_q;
    logic [DQ_LANES*FW-1:0] s0_f_q;
    logic                   s0_valid_q;
    logic [HW-1:0]          s0_half_q;
    logic                   s0_path_q;
    logic [BEAT_W-1:0]      s0_beat_q;
    logic                   s0_last_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q <= 1'b0;
            s0_path_q  <= 1'b0;
            s0_half_q  <= {HW{1'b0}};
            s0_beat_q  <= {BEAT_W{1'b0}};
            s0_last_q  <= 1'b0;
            s0_sign_q  <= {DQ_LANES{1'b0}};
            s0_q_q     <= {(DQ_LANES*QW){1'b0}};
            s0_f_q     <= {(DQ_LANES*FW){1'b0}};
        end else begin
            s0_valid_q <= valid_i;
            s0_path_q  <= path_i;
            s0_half_q  <= half_i;
            s0_beat_q  <= beat_i;
            s0_last_q  <= last_i;
            if (valid_i) begin
                s0_sign_q <= l_sign_c;
                s0_q_q    <= l_q_c;
                s0_f_q    <= l_f_c;
            end
        end
    end

    // =====================================================================
    // S1: park path 0, or align and add path 1 against the parked partial
    // =====================================================================
    logic [DQ_LANES-1:0]    p_sign_q [0:NHALF-1];
    logic [DQ_LANES*QW-1:0] p_q_q    [0:NHALF-1];
    logic [DQ_LANES*FW-1:0] p_f_q    [0:NHALF-1];

    integer ph;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (ph = 0; ph < NHALF; ph = ph + 1) begin
                p_sign_q[ph] <= {DQ_LANES{1'b0}};
                p_q_q[ph]    <= {(DQ_LANES*QW){1'b0}};
                p_f_q[ph]    <= {(DQ_LANES*FW){1'b0}};
            end
        end else if (s0_valid_q && !s0_path_q) begin
            p_sign_q[s0_half_q] <= s0_sign_q;
            p_q_q[s0_half_q]    <= s0_q_q;
            p_f_q[s0_half_q]    <= s0_f_q;
        end
    end

    logic [DQ_LANES-1:0]        a_sign_c;
    logic [DQ_LANES*MAG_W-1:0]  a_mag_c;
    logic [DQ_LANES*EXPO_W-1:0] a_exp_c;

    generate
        for (l = 0; l < DQ_LANES; l = l + 1) begin : g_add
            rabit_fs_dq_add #(
                .QW        (QW),
                .FW        (FW),
                .ALIGN_MAX (ALIGN_MAX)
            ) u_add (
                .s1_i      (p_sign_q[s0_half_q][l]),
                .q1_i      (p_q_q[s0_half_q][l*QW +: QW]),
                .f1_i      (p_f_q[s0_half_q][l*FW +: FW]),
                .s2_i      (s0_sign_q[l]),
                .q2_i      (s0_q_q[l*QW +: QW]),
                .f2_i      (s0_f_q[l*FW +: FW]),
                .sign_o    (a_sign_c[l]),
                .mag_o     (a_mag_c[l*MAG_W +: MAG_W]),
                .exp_lsb_o (a_exp_c[l*EXPO_W +: EXPO_W])
            );
        end
    endgenerate

    logic [DQ_LANES-1:0]        s1_sign_q;
    logic [DQ_LANES*MAG_W-1:0]  s1_mag_q;
    logic [DQ_LANES*EXPO_W-1:0] s1_exp_q;
    logic                       s1_valid_q;
    logic [BEAT_W-1:0]          s1_beat_q;
    logic                       s1_last_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid_q <= 1'b0;
            s1_beat_q  <= {BEAT_W{1'b0}};
            s1_last_q  <= 1'b0;
            s1_sign_q  <= {DQ_LANES{1'b0}};
            s1_mag_q   <= {(DQ_LANES*MAG_W){1'b0}};
            s1_exp_q   <= {(DQ_LANES*EXPO_W){1'b0}};
        end else begin
            s1_valid_q <= s0_valid_q && s0_path_q;
            s1_beat_q  <= s0_beat_q;
            s1_last_q  <= s0_last_q;
            if (s0_valid_q && s0_path_q) begin
                s1_sign_q <= a_sign_c;
                s1_mag_q  <= a_mag_c;
                s1_exp_q  <= a_exp_c;
            end
        end
    end

    // =====================================================================
    // S2: one rounding, into binary16
    // =====================================================================
    logic [DQ_LANES*16-1:0] pack_c;
    logic [DQ_LANES-1:0]    pack_ovf_c;

    generate
        for (l = 0; l < DQ_LANES; l = l + 1) begin : g_pack
            rabit_fs_fp16_pack #(
                .MAG_W (MAG_W),
                .EXP_W (EXPO_W)
            ) u_pack (
                .sign_i    (s1_sign_q[l]),
                .mag_i     (s1_mag_q[l*MAG_W +: MAG_W]),
                .exp_lsb_i (s1_exp_q[l*EXPO_W +: EXPO_W]),
                .fp16_o    (pack_c[l*16 +: 16]),
                .ovf_o     (pack_ovf_c[l])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_valid_o <= 1'b0;
            y_data_o  <= {(DQ_LANES*16){1'b0}};
            y_beat_o  <= {BEAT_W{1'b0}};
            y_last_o  <= 1'b0;
            y_ovf_o   <= 1'b0;
        end else begin
            y_valid_o <= s1_valid_q;
            y_beat_o  <= s1_beat_q;
            y_last_o  <= s1_last_q;
            y_ovf_o   <= s1_valid_q && (|pack_ovf_c);
            if (s1_valid_q) begin
                y_data_o <= pack_c;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NPATH != 2)
            $fatal(1, "rabit_fs_dq_unit: the parked-partial organization assumes NPATH = 2");
        if (NHALF*DQ_LANES != NOUT_PER_WORD)
            $fatal(1, "rabit_fs_dq_unit: DQ_LANES must divide NOUT_PER_WORD");
    end
`endif

endmodule
