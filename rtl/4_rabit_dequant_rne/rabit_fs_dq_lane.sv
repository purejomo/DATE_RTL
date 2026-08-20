`timescale 1ns/1ps

// One dequantization lane: raw accumulator x per-output scale -> a floating
// product, still unrounded.
//
//     A_p[j] = acc * 2**(E0 - 14 - MANT_W)          the base variant's contract
//     g_p[j] = (-1)**sg * sig_g * 2**(e_g - 25)     binary16
//     out    = (-1)**(sa^sg) * (m12 * sig_g) * 2**F
//
// Datapath, all combinational, one lane per output being processed this cycle:
//
//   normalize  32-bit two's complement accumulator -> sign, 12-bit mantissa
//              with its leading one at bit 11, and the shift that got it there.
//              Right shifts round to nearest even; a rounding carry to 2**12
//              renormalizes by bumping the exponent.
//   decode     binary16 scale -> an 11-bit significand with its leading one at
//              bit 10 and an adjusted exponent. Subnormal scales are normalized
//              here rather than flushed, which keeps the exponent difference the
//              adder sees a faithful magnitude ratio -- see rabit_fs_dq_add.
//   multiply   12 x 11 -> 23 bits, and an exponent add.
//
// This is the only multiplier on the drain path and there is none at all on the
// read path, which is the property the whole design rests on: g scaling costs
// DQ_LANES multipliers used once per stripe, not NOUT_PER_WORD multipliers used
// every column command.
//
// Rounding the accumulator to 12 bits before the multiply is deliberate and is
// the specified datapath. It caps the multiplier at 12x11 and is harmless for a
// binary16 output, which keeps 11 bits.
module rabit_fs_dq_lane #(
    parameter int ACC_W  = 32,
    parameter int MANT_W = 12,
    parameter int EXP_W  = 6,
    // derived; do not override
    parameter int QW     = MANT_W + 11,
    parameter int FW     = 8     // signed exponent of the product LSB
) (
    input  logic signed [ACC_W-1:0] acc_i,
    input  logic [15:0]             g_i,
    input  logic [EXP_W-1:0]        e0_i,

    output logic                    sign_o,
    output logic [QW-1:0]           q_o,
    output logic signed [FW-1:0]    f_o
);

    localparam int NW = $clog2(ACC_W + 1) + 1;
    localparam int IW = $clog2(ACC_W);
    localparam int JW = $clog2(ACC_W + 1);

    // ---- accumulator magnitude --------------------------------------------
    logic              sign_a;
    logic [ACC_W-1:0]  mag_a;
    logic              acc_nz;

    always_comb begin
        sign_a = acc_i[ACC_W-1];
        // |-2**(ACC_W-1)| is exactly representable as an unsigned ACC_W word.
        mag_a  = sign_a ? (~acc_i[ACC_W-1:0] + {{(ACC_W-1){1'b0}}, 1'b1})
                        : acc_i[ACC_W-1:0];
        acc_nz = |acc_i;
    end

    // ---- leading one, prefix OR for the sticky bit ------------------------
    logic [NW-1:0]   n_a;
    logic [ACC_W:0]  or_below;

    integer li;
    always_comb begin
        n_a = {NW{1'b0}};
        for (li = 0; li < ACC_W; li = li + 1) begin
            if (mag_a[li]) n_a = NW'(li);
        end
    end

    integer oi;
    logic   run_or;

    always_comb begin
        run_or      = 1'b0;
        or_below[0] = 1'b0;
        for (oi = 1; oi <= ACC_W; oi = oi + 1) begin
            run_or       = run_or | mag_a[oi-1];
            or_below[oi] = run_or;
        end
    end

    // ---- normalize to MANT_W bits, leading one at bit MANT_W-1 ------------
    localparam int TOP = MANT_W - 1;

    logic [NW-1:0]     r_amt;
    logic [ACC_W-1:0]  shifted;
    logic [MANT_W:0]   norm;          // one bit wider: rounding can carry
    logic              round_bit;
    logic              sticky;
    logic              round_up;
    logic [MANT_W-1:0] m_mant;
    logic [NW-1:0]     n_adj;

    always_comb begin
        round_bit = 1'b0;
        sticky    = 1'b0;
        round_up  = 1'b0;
        r_amt     = {NW{1'b0}};
        shifted   = {ACC_W{1'b0}};

        if (n_a > NW'(TOP)) begin
            r_amt     = n_a - NW'(TOP);
            shifted   = mag_a >> r_amt;
            round_bit = mag_a[IW'(r_amt - NW'(1))];
            sticky    = or_below[JW'(r_amt - NW'(1))];
            round_up  = round_bit & (sticky | shifted[0]);
            norm      = {1'b0, shifted[MANT_W-1:0]} +
                        {{MANT_W{1'b0}}, round_up};
        end else begin
            shifted = mag_a << (NW'(TOP) - n_a);
            norm    = {1'b0, shifted[MANT_W-1:0]};
        end

        // A carry out of the rounding puts the leading one one place higher.
        if (norm[MANT_W]) begin
            m_mant = MANT_W'(norm >> 1);
            n_adj  = n_a + NW'(1);
        end else begin
            m_mant = norm[MANT_W-1:0];
            n_adj  = n_a;
        end
    end

    // ---- binary16 scale, normalized ---------------------------------------
    logic              sign_g;
    logic [4:0]        exp_g;
    logic [9:0]        frac_g;
    logic [10:0]       sig_g;
    logic signed [6:0] e_g;
    logic              g_nz;
    logic [3:0]        lz_g;

    integer zi;
    always_comb begin
        sign_g = g_i[15];
        exp_g  = g_i[14:10];
        frac_g = g_i[9:0];
        g_nz   = (exp_g != 5'd0) || (frac_g != 10'd0);

        // Leading-zero count of the 10-bit fraction, only used when the scale
        // is subnormal. lz_g is the distance from bit 9 to the leading one.
        lz_g = 4'd10;
        for (zi = 0; zi < 10; zi = zi + 1) begin
            if (frac_g[zi]) lz_g = 4'(9 - zi);
        end

        if (exp_g != 5'd0) begin
            sig_g = {1'b1, frac_g};
            e_g   = $signed({2'b00, exp_g});
        end else begin
            // value = frac * 2**(1-25); shifting left by (lz_g + 1) puts the
            // leading one at bit 10 and drops the exponent by the same amount.
            sig_g = {frac_g, 1'b0} << lz_g;
            e_g   = $signed(7'sd1) - $signed({3'b000, lz_g});
        end
    end

    // ---- product ----------------------------------------------------------
    //
    // A zero product carries the most negative exponent so it can never win the
    // max in rabit_fs_dq_add and shift the other path out of range.
    localparam logic signed [FW-1:0] F_ZERO = {1'b1, {(FW-1){1'b0}}};

    logic [QW-1:0] prod;
    logic          nonzero;

    always_comb begin
        nonzero = acc_nz && g_nz;
        prod    = nonzero ? (m_mant * sig_g) : {QW{1'b0}};
        sign_o  = sign_a ^ sign_g;
        q_o     = prod;
        // out = m_mant * 2**(n_adj - (MANT_W-1)) * 2**(E0-14-MANT_W)
        //       * sig_g * 2**(e_g - 25)
        f_o     = nonzero
                ? ($signed(FW'(n_adj)) + $signed(FW'(e0_i)) + $signed(FW'(e_g)) -
                   $signed(FW'(2*MANT_W + 38)))
                : F_ZERO;
    end

`ifndef SYNTHESIS
    initial begin
        if (QW != MANT_W + 11)
            $fatal(1, "rabit_fs_dq_lane: QW is derived from MANT_W, do not override it");
    end
`endif

endmodule
