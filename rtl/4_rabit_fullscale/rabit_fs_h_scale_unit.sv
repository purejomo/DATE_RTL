`timescale 1ns/1ps

// h_scale_unit: the input-scale multiply the base variant leaves to the NPU.
//
// Base RaBiT PCU receives u_p = h_p (*) x already formed, two binary16 writes
// per 16-input chunk. The full-scale variant receives raw x and raw h instead
// and forms the product here, keeping the write budget at two column slots per
// chunk:
//
//     WR slot B   h chunk   {h1[k], h2[k]} as FP8-E4M3, 16 dim x 2 path x 8b
//     WR slot A   x chunk   binary16 x 16, the same 256-bit format as base
//
// h1 and h2 as binary16 would need a third write and would break the schedule,
// which is why the delivered format is FP8. H_FMT = 1 selects the binary16
// fallback (two h writes, three writes per chunk) for accuracy comparison; it
// is a verification and measurement mode, not a delivered configuration.
//
// One column slot is two PCU cycles (tCCD_S), and the unit spends them on the
// two residual paths: cycle 0 forms u1 = x (*) h1, cycle 1 forms u2 = x (*) h2.
// Each cycle drives a whole 256-bit binary16 vector into the existing
// rabit_cvt_fp16_blk, so nothing downstream changes.
//
// Arithmetic. This is deliberately not a binary16 multiplier. A binary16
// significand is 11 bits and an FP8-E4M3 significand is 4 bits, so the array is
// NIN multipliers of 11x4 plus an exponent add:
//
//     x = (-1)**sx * sig_x * 2**(e_x - 25)        sig_x 11b, e_x = max(exp,1)
//     h = (-1)**sh * sig_h * 2**(e_h - 10)        sig_h  4b, e_h = max(exp,1)
//     u = (-1)**(sx^sh) * (sig_x * sig_h) * 2**(e_x + e_h - 35)
//
// and rabit_fs_fp16_pack rounds that to binary16 under RNE. Re-encoding to
// binary16 before the block convert costs nothing at the entry's own exponent:
// with MANT_W = 12 the convert unit stores the top lane as sig << 1, so an
// 11-bit significand is exactly representable and only lanes already being
// right-aligned see a second rounding. See README.md, "double rounding".
//
// FP8-E4M3 follows OCP: bias 7, no infinity, and 0x7F / 0xFF are NaN. Like
// rabit_cvt_fp16_blk with binary16 exp == 31, a NaN code is not special cased
// -- it decodes as sig_h = 15, e_h = 15 -- but it does raise h_nan_o so a
// mis-quantized scale table cannot pass silently. See README.md, open question.
module rabit_fs_h_scale_unit #(
    parameter int NIN     = 16,
    parameter int NPATH   = 2,
    parameter int H_FMT   = 0,    // 0 = FP8_E4M3 (1 WR), 1 = FP16_3WR (NPATH WR)
    parameter int NMULT_H = 16,
    // derived; do not override
    parameter int PW      = (NPATH > 1) ? $clog2(NPATH) : 1
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // ---- h write port ------------------------------------------------------
    input  logic                  h_we_i,
    input  logic [PW-1:0]         h_sel_i,      // H_FMT = 1: which h vector
    input  logic [NIN*16-1:0]     h_word_i,

    // ---- x and path --------------------------------------------------------
    input  logic [NIN*16-1:0]     x_i,
    input  logic [PW-1:0]         path_i,

    // ---- product -----------------------------------------------------------
    output logic [NIN*16-1:0]     u_fp16_o,
    output logic                  h_nan_o,
    output logic                  h_ovf_o,
    output logic                  h_loaded_o
);

    localparam int NHWORD = (H_FMT == 0) ? 1 : NPATH;
    localparam int HSIG_W = (H_FMT == 0) ? 4 : 11;
    localparam int HOFF   = (H_FMT == 0) ? 10 : 25;
    localparam int MAG_W  = 11 + HSIG_W;
    localparam int EXPL_W = 9;

    // ---- h_latch -----------------------------------------------------------
    logic [NIN*16-1:0] h_latch [0:NHWORD-1];
    logic [NHWORD-1:0] h_valid_q;

    integer hi;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (hi = 0; hi < NHWORD; hi = hi + 1) begin
                h_latch[hi] <= {(NIN*16){1'b0}};
            end
            h_valid_q <= {NHWORD{1'b0}};
        end else if (h_we_i) begin
            h_latch[(NHWORD == 1) ? 0 : h_sel_i] <= h_word_i;
            h_valid_q[(NHWORD == 1) ? 0 : h_sel_i] <= 1'b1;
        end
    end

    always_comb h_loaded_o = &h_valid_q;

    // ---- mult_array --------------------------------------------------------
    logic [NIN-1:0] lane_nan;
    logic [NIN-1:0] lane_ovf;

    genvar k;
    generate
        for (k = 0; k < NIN; k = k + 1) begin : g_mult
            // binary16 activation lane
            logic        sx;
            logic [4:0]  ex_field;
            logic [10:0] sig_x;
            logic [4:0]  e_x;

            always_comb begin
                sx       = x_i[k*16 + 15];
                ex_field = x_i[k*16 + 10 +: 5];
                sig_x    = {(ex_field != 5'd0), x_i[k*16 +: 10]};
                e_x      = (ex_field == 5'd0) ? 5'd1 : ex_field;
            end

            // scale lane
            logic              sh;
            logic [HSIG_W-1:0] sig_h;
            logic [4:0]        e_h;
            logic              nan_h;

            if (H_FMT == 0) begin : g_fp8
                logic [7:0] hc;
                logic [3:0] eh_field;
                logic [2:0] mh;

                always_comb begin
                    hc       = h_latch[0][k*16 + path_i*8 +: 8];
                    sh       = hc[7];
                    eh_field = hc[6:3];
                    mh       = hc[2:0];
                    sig_h    = {(eh_field != 4'd0), mh};
                    e_h      = (eh_field == 4'd0) ? 5'd1 : {1'b0, eh_field};
                    nan_h    = (eh_field == 4'hF) && (mh == 3'h7);
                end
            end else begin : g_fp16
                logic [15:0] hc;
                logic [4:0]  eh_field;

                always_comb begin
                    hc       = h_latch[(NHWORD == 1) ? 0 : path_i][k*16 +: 16];
                    sh       = hc[15];
                    eh_field = hc[14:10];
                    sig_h    = {(eh_field != 5'd0), hc[9:0]};
                    e_h      = (eh_field == 5'd0) ? 5'd1 : eh_field;
                    nan_h    = 1'b0;   // same policy as rabit_cvt_fp16_blk
                end
            end

            // 11 x HSIG_W product and the exponent add
            logic [MAG_W-1:0]         prod;
            logic signed [EXPL_W-1:0] exp_lsb;

            always_comb begin
                prod    = sig_x * sig_h;
                exp_lsb = $signed(EXPL_W'(e_x)) + $signed(EXPL_W'(e_h)) -
                          $signed(EXPL_W'(25 + HOFF));
            end

            rabit_fs_fp16_pack #(
                .MAG_W (MAG_W),
                .EXP_W (EXPL_W)
            ) u_pack (
                .sign_i    (sx ^ sh),
                .mag_i     (prod),
                .exp_lsb_i (exp_lsb),
                .fp16_o    (u_fp16_o[k*16 +: 16]),
                .ovf_o     (lane_ovf[k])
            );

            always_comb lane_nan[k] = nan_h;
        end
    endgenerate

    always_comb begin
        h_nan_o = |lane_nan;
        h_ovf_o = |lane_ovf;
    end

`ifndef SYNTHESIS
    initial begin
        if (NMULT_H != NIN)
            $fatal(1, "rabit_fs_h_scale_unit: NMULT_H must equal NIN; a narrower array misses the RD og0 path-2 deadline (README.md)");
        if (H_FMT != 0 && H_FMT != 1)
            $fatal(1, "rabit_fs_h_scale_unit: H_FMT must be 0 (FP8_E4M3) or 1 (FP16_3WR)");
    end
`endif

endmodule
