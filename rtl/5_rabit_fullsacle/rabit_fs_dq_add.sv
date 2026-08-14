`timescale 1ns/1ps

// Sum the two residual paths of one output, in floating point.
//
//     y_raw[j] = g_1[j]*A_1[j] + g_2[j]*A_2[j]
//
// Both inputs arrive from rabit_fs_dq_lane as an exact QW-bit product with the
// exponent of its LSB. The unit aligns them to the larger exponent, adds in two's
// complement, and hands the magnitude to rabit_fs_fp16_pack, which does the one
// rounding of the whole drain path.
//
// Alignment is lossless for exponent differences up to ALIGN_MAX. Both lanes
// normalize before multiplying, so a product's leading one is always at bit
// QW-2 or QW-1 and the exponent difference is a faithful magnitude ratio: a term
// dropped at ALIGN_MAX = 16 is below 2**-15 of the other one, while the binary16
// result keeps 11 bits. It can therefore only change a round-to-nearest tie,
// which README.md records as accepted behaviour. Cancellation is unaffected,
// because two terms that cancel have nearly equal exponents and are aligned
// exactly.
module rabit_fs_dq_add #(
    parameter int QW        = 23,
    parameter int FW        = 10,
    parameter int ALIGN_MAX = 16,
    // derived; do not override
    parameter int FIELD_W   = QW + ALIGN_MAX,
    parameter int MAG_W     = QW + ALIGN_MAX + 1,
    parameter int EXPO_W    = FW + 1
) (
    input  logic                    s1_i,
    input  logic [QW-1:0]           q1_i,
    input  logic signed [FW-1:0]    f1_i,
    input  logic                    s2_i,
    input  logic [QW-1:0]           q2_i,
    input  logic signed [FW-1:0]    f2_i,

    output logic                    sign_o,
    output logic [MAG_W-1:0]        mag_o,
    output logic signed [EXPO_W-1:0] exp_lsb_o
);

    localparam int DW = FW + 1;

    logic signed [FW-1:0]  fmax;
    logic [DW-1:0]         d1;
    logic [DW-1:0]         d2;
    logic [DW-1:0]         d1_use;
    logic [DW-1:0]         d2_use;

    always_comb begin
        fmax   = (f1_i >= f2_i) ? f1_i : f2_i;
        d1     = DW'($signed({fmax[FW-1], fmax}) - $signed({f1_i[FW-1], f1_i}));
        d2     = DW'($signed({fmax[FW-1], fmax}) - $signed({f2_i[FW-1], f2_i}));
        d1_use = (d1 > DW'(FIELD_W)) ? DW'(FIELD_W) : d1;
        d2_use = (d2 > DW'(FIELD_W)) ? DW'(FIELD_W) : d2;
    end

    logic [FIELD_W-1:0]         a1;
    logic [FIELD_W-1:0]         a2;
    logic signed [FIELD_W:0]    t1;
    logic signed [FIELD_W:0]    t2;
    logic signed [FIELD_W+1:0]  sum;

    always_comb begin
        a1 = {q1_i, {ALIGN_MAX{1'b0}}} >> d1_use;
        a2 = {q2_i, {ALIGN_MAX{1'b0}}} >> d2_use;

        t1 = s1_i ? -$signed({1'b0, a1}) : $signed({1'b0, a1});
        t2 = s2_i ? -$signed({1'b0, a2}) : $signed({1'b0, a2});

        sum = $signed({t1[FIELD_W], t1}) + $signed({t2[FIELD_W], t2});

        sign_o    = sum[FIELD_W+1];
        mag_o     = sign_o ? MAG_W'(-sum) : MAG_W'(sum);
        exp_lsb_o = $signed({fmax[FW-1], fmax}) - $signed(EXPO_W'(ALIGN_MAX));
    end

endmodule
