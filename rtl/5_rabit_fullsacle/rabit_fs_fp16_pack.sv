`timescale 1ns/1ps

// Pack a sign-magnitude fixed-point value into one binary16 code, RNE.
//
//     value = (-1)**sign_i * mag_i * 2**exp_lsb_i
//
// This is the one rounding primitive the full-scale variant needs twice: the
// h path turns a (fp16 x fp8) product into the binary16 word the convert unit
// consumes, and the g path turns the dequantized path sum into the final y.
// Both arrive as "an integer magnitude and the weight of its LSB", so they
// share this module instead of carrying two copies of the same normalizer.
//
// Numeric contract, matching the decode rabit_cvt_fp16_blk already uses:
//
//     binary16 (s, exp, frac) denotes sig * 2**(e_eff - 25)
//     sig   = {exp != 0, frac}          e_eff = (exp == 0) ? 1 : exp
//
// so a normal result needs sig in [1024, 2047] and a subnormal one needs
// frac * 2**(1 - 25) = frac * 2**-24. Writing n for the index of the magnitude's
// most significant set bit,
//
//     E = exp_lsb + n + 15                       biased exponent field
//     s = (E > 0) ? (n - 10) : -(exp_lsb + 24)   right shift onto the target
//
// and one 15-bit field {E, frac} covers both cases: a subnormal result that
// rounds up to 1024 already reads as {exp = 1, frac = 0}, the smallest normal,
// so no extra carry logic is needed on that boundary.
//
// Range policy, shared with the rest of the design and documented in README.md:
//   - E >= 31 saturates to the largest finite binary16 (0x7BFF) and raises
//     ovf_o. No infinity is ever produced, because rabit_cvt_fp16_blk does not
//     special case exp == 31 and would decode it as an ordinary number.
//   - subnormals are produced exactly, never flushed: the convert unit
//     represents them exactly, so flushing would only lose accuracy.
//   - a zero magnitude yields signed zero.
module rabit_fs_fp16_pack #(
    parameter int MAG_W = 15,   // width of the magnitude
    parameter int EXP_W = 10    // signed width of exp_lsb_i
) (
    input  logic                    sign_i,
    input  logic [MAG_W-1:0]        mag_i,
    input  logic signed [EXP_W-1:0] exp_lsb_i,
    output logic [15:0]             fp16_o,
    output logic                    ovf_o
);

    localparam int NW     = $clog2(MAG_W + 2) + 1;   // holds 0 .. MAG_W + 1
    localparam int SW     = ((EXP_W > NW) ? EXP_W : NW) + 3;
    localparam int SL_MAX = 10;                      // widest left shift
    localparam int SR_MAX = MAG_W + 1;               // past this the result is 0
    localparam int IW     = $clog2(SR_MAX + 1);      // index into the guard arrays

    // ---- leading-one position ---------------------------------------------
    logic          nz;
    logic [NW-1:0] msb_idx;

    integer li;
    always_comb begin
        nz      = |mag_i;
        msb_idx = {NW{1'b0}};
        for (li = 0; li < MAG_W; li = li + 1) begin
            if (mag_i[li]) msb_idx = NW'(li);
        end
    end

    // ---- prefix OR so the sticky bit is a mux, not a masked compare -------
    //
    // or_below[i] is 1 when any of mag_i[i-1:0] is set, and mag_ext[i] is the
    // round bit for a right shift by i+1. The shifter therefore costs one
    // barrel shift plus two muxes instead of a shifted mask and a compare.
    logic [SR_MAX:0] or_below;
    logic [SR_MAX:0] mag_ext;

    integer oi;
    logic   run_or;

    always_comb begin
        mag_ext     = {{(SR_MAX+1-MAG_W){1'b0}}, mag_i};
        run_or      = 1'b0;
        or_below[0] = 1'b0;
        for (oi = 1; oi <= SR_MAX; oi = oi + 1) begin
            run_or       = run_or | mag_ext[oi-1];
            or_below[oi] = run_or;
        end
    end

    // ---- exponent field and the shift that lands on it --------------------
    logic signed [SW-1:0] exp_ext;
    logic signed [SW-1:0] e_biased;
    logic signed [SW-1:0] shift_req;
    logic signed [SW-1:0] shift_use;
    logic                 subnormal;

    always_comb begin
        exp_ext   = $signed({{(SW-EXP_W){exp_lsb_i[EXP_W-1]}}, exp_lsb_i});
        e_biased  = exp_ext + $signed({{(SW-NW){1'b0}}, msb_idx}) + SW'(15);
        subnormal = !(e_biased > $signed(SW'(0)));

        shift_req = subnormal ? -(exp_ext + SW'(24))
                              : ($signed({{(SW-NW){1'b0}}, msb_idx}) - SW'(10));

        // Both branches can only ask for a left shift when the magnitude
        // already sits below bit 11, so these clamps are safety nets that the
        // reachable input space never exercises.
        if (shift_req < -$signed(SW'(SL_MAX))) begin
            shift_use = -$signed(SW'(SL_MAX));
        end else if (shift_req > $signed(SW'(SR_MAX))) begin
            shift_use = SW'(SR_MAX);
        end else begin
            shift_use = shift_req;
        end
    end

    // ---- shift and round ---------------------------------------------------
    logic [11:0]      rounded;
    logic [MAG_W-1:0] quotient;
    logic             round_bit;
    logic             sticky;
    logic             round_up;
    logic [NW-1:0]    r_amt;
    logic [3:0]       l_amt;
    logic [11:0]      mag_low;

    always_comb mag_low = 12'(mag_i);

    always_comb begin
        r_amt     = {NW{1'b0}};
        l_amt     = 4'd0;
        quotient  = {MAG_W{1'b0}};
        round_bit = 1'b0;
        sticky    = 1'b0;
        round_up  = 1'b0;

        if (shift_use[SW-1]) begin
            // Left: the magnitude is below bit 11 in this branch, so the
            // shifted result always fits the 12-bit rounding field.
            l_amt   = 4'(-shift_use);
            rounded = mag_low << l_amt;
        end else begin
            r_amt = NW'(shift_use);
            quotient = mag_i >> r_amt;
            if (r_amt != {NW{1'b0}}) begin
                round_bit = mag_ext[IW'(r_amt - NW'(1))];
                sticky    = or_below[IW'(r_amt - NW'(1))];
            end
            round_up = round_bit & (sticky | quotient[0]);
            rounded  = 12'(quotient) + {11'd0, round_up};
        end
    end

    // ---- assemble ----------------------------------------------------------
    logic signed [SW-1:0] e_final;
    logic [9:0]           frac;
    logic [14:0]          magnitude_code;

    always_comb begin
        if (subnormal) begin
            // rounded <= 1024 here, and a value of exactly 1024 already reads
            // as {exp = 1, frac = 0}, which is the smallest normal.
            e_final        = SW'(0);
            frac           = 10'd0;
            magnitude_code = {4'd0, rounded[10:0]};
            ovf_o          = 1'b0;
        end else begin
            // A rounding carry pushes the significand to 2048; renormalize by
            // bumping the exponent and clearing the fraction.
            e_final = rounded[11] ? (e_biased + SW'(1)) : e_biased;
            frac    = rounded[11] ? 10'd0 : rounded[9:0];
            if (e_final >= $signed(SW'(31))) begin
                magnitude_code = 15'h7BFF;   // largest finite binary16
                ovf_o          = 1'b1;
            end else begin
                magnitude_code = {e_final[4:0], frac};
                ovf_o          = 1'b0;
            end
        end
    end

    always_comb fp16_o = nz ? {sign_i, magnitude_code} : {sign_i, 15'd0};

`ifndef SYNTHESIS
    initial begin
        if (MAG_W < 12)
            $fatal(1, "rabit_fs_fp16_pack: MAG_W must be at least 12");
    end
`endif

endmodule
