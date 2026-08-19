`timescale 1ns/1ps

// Exponent alignment: PSUM_W-bit block partial sum -> ACC_W-bit accumulator
// operand, shifted by (e_ent - E0).
//
// A PE reduces one entry whose mantissa LSB weighs 2**(e_ent - 14 - MANT_W).
// The accumulator holds everything at the fixed reference weight
// 2**(E0 - 14 - MANT_W), so the partial sum has to move left by (e_ent - E0)
// -- or right by (E0 - e_ent) -- before it can be added.
//
// Both directions are cheap because of one observation: a PSUM_W-bit signed
// value shifted left by at most (ACC_W - PSUM_W) can never overflow ACC_W bits.
// So the left barrel shifter is ACC_W bits wide with a saturating clamp on the
// amount instead of an overflow detector on the data, and the right barrel
// shifter only has to be PSUM_W bits wide because an arithmetic right shift by
// PSUM_W already sits at its own limit (0 for a positive input, -1 for a
// negative one, which is the correct floor for every larger shift).
//
// SHIFT_RND is off by default, which is the specified behaviour: the right
// shift truncates toward -inf like any arithmetic shift. Turning it on adds
// round-to-nearest-even on the discarded bits, which removes the -0.5 LSB per
// chunk bias that truncation accumulates over a long k sweep. It is reported in
// docs/rabit_pcu_spec.md as a proposal, not as part of the delivered default.
module rabit_align_shift #(
    parameter int PSUM_W    = 17,
    parameter int ACC_W     = 32,
    parameter int SH_W      = 7,
    parameter int SHIFT_RND = 0
) (
    input  logic signed [PSUM_W-1:0] psum_i,
    input  logic signed [SH_W-1:0]   shift_i,
    output logic signed [ACC_W-1:0]  aligned_o,
    output logic                     sat_o
);

    localparam int SHL_MAX = ACC_W - PSUM_W;         // lossless left headroom
    localparam int SHR_MAX = PSUM_W;                 // past this the shift idles
    localparam int SHL_W   = $clog2(SHL_MAX + 1);
    localparam int SHR_W   = $clog2(SHR_MAX + 1);
    localparam int MW      = SH_W + 1;               // shift magnitude width

    localparam logic signed [ACC_W-1:0] ACC_MAX = {1'b0, {(ACC_W-1){1'b1}}};
    localparam logic signed [ACC_W-1:0] ACC_MIN = {1'b1, {(ACC_W-1){1'b0}}};

    // ---- split the signed shift into a direction and a magnitude ----------
    logic                left_dir;
    logic signed [MW-1:0] shift_ext;
    logic        [MW-1:0] shift_mag;

    always_comb begin
        shift_ext = {shift_i[SH_W-1], shift_i};
        left_dir  = ~shift_i[SH_W-1];
        shift_mag = left_dir ? shift_ext[MW-1:0]
                             : (~shift_ext[MW-1:0] + {{(MW-1){1'b0}}, 1'b1});
    end

    logic                left_clamped;
    logic [SHL_W-1:0]    shl_amt;
    logic [SHR_W-1:0]    shr_amt;

    always_comb begin
        left_clamped = left_dir && (shift_mag > MW'(SHL_MAX));
        shl_amt      = left_clamped ? SHL_W'(SHL_MAX) : shift_mag[SHL_W-1:0];
        shr_amt      = (shift_mag > MW'(SHR_MAX)) ? SHR_W'(SHR_MAX)
                                                  : shift_mag[SHR_W-1:0];
    end

    // ---- left path: widen first, then shift; overflow is impossible -------
    logic signed [ACC_W-1:0] psum_ext;
    logic signed [ACC_W-1:0] left_val;

    always_comb begin
        psum_ext = {{(ACC_W-PSUM_W){psum_i[PSUM_W-1]}}, psum_i};
        left_val = psum_ext <<< shl_amt;
    end

    // ---- right path -------------------------------------------------------
    logic signed [PSUM_W-1:0] right_trunc;
    logic signed [ACC_W-1:0]  right_val;

    always_comb right_trunc = psum_i >>> shr_amt;

    generate
        if (SHIFT_RND != 0) begin : g_round
            // Guard half: one shift produces quotient, round bit and sticky.
            logic signed [2*PSUM_W-1:0] guard_wide;
            logic signed [2*PSUM_W-1:0] guard_shifted;
            logic                       round_bit;
            logic                       sticky;
            logic                       round_up;
            logic signed [PSUM_W:0]     rounded;

            always_comb begin
                guard_wide    = {psum_i, {PSUM_W{1'b0}}};
                guard_shifted = guard_wide >>> shr_amt;
                round_bit     = guard_shifted[PSUM_W-1];
                sticky        = |guard_shifted[PSUM_W-2:0];
                round_up      = round_bit & (sticky | guard_shifted[PSUM_W]);
                rounded       = $signed({guard_shifted[2*PSUM_W-1],
                                         guard_shifted[2*PSUM_W-1:PSUM_W]}) +
                                $signed({{PSUM_W{1'b0}}, round_up});
                right_val     = {{(ACC_W-PSUM_W-1){rounded[PSUM_W]}}, rounded};
            end
        end else begin : g_trunc
            always_comb begin
                right_val = {{(ACC_W-PSUM_W){right_trunc[PSUM_W-1]}}, right_trunc};
            end
        end
    endgenerate

    // ---- select and saturate ----------------------------------------------
    logic psum_nonzero;

    always_comb begin
        psum_nonzero = |psum_i;
        sat_o        = left_clamped & psum_nonzero;

        if (sat_o) begin
            aligned_o = psum_i[PSUM_W-1] ? ACC_MIN : ACC_MAX;
        end else if (left_dir) begin
            aligned_o = left_val;
        end else begin
            aligned_o = right_val;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ACC_W <= PSUM_W)
            $fatal(1, "rabit_align_shift: ACC_W must exceed PSUM_W");
        if (SH_W < 2)
            $fatal(1, "rabit_align_shift: SH_W must be at least 2");
    end
`endif

endmodule
