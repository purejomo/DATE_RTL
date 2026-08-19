`timescale 1ns/1ps

// Convert-on-write: NIN binary16 values -> one block-floating-point entry.
//
// The NPU writes u = h (*) x as binary16. Nothing downstream of this unit
// understands floating point, so the write path converts a whole GRF entry at
// once and stores it as a shared exponent plus NIN sign-magnitude fixed-point
// mantissas:
//
//     blk_o   = { sign, mant[MANT_W-1:0] } x NIN     (little-indexed lanes)
//     e_ent_o = shared block exponent, EXP_W bits
//
// Numeric contract. A binary16 code (s, exp, frac) denotes
//
//     (-1)**s * sig * 2**(e_eff - 25),
//     sig   = {exp != 0, frac}                       (SIG_W = 11 bits)
//     e_eff = (exp == 0) ? 1 : exp
//
// which is exact for normals, subnormals and zero alike -- a fixed-point
// converter has no reason to flush, so there is no DAZ here. The block exponent
// is e_ent = max_k e_eff[k] and every lane is right-aligned to it under
// round-to-nearest-even:
//
//     mant[k] = RNE( (sig[k] << LSH) >> (e_ent - e_eff[k] + RSH0) )
//
// so the value the entry represents is
//
//     u[k] = (-1)**sign[k] * mant[k] * 2**(e_ent - 14 - MANT_W).
//
// Check with MANT_W = 12: a lane holding exactly 2**(e_ent-15) has sig = 1024,
// LSH = 1 and no alignment shift, so mant = 2048 and 2048 * 2**(e_ent-26) =
// 2**(e_ent-15).
//
// SHIFTER_EN = 0 replaces the per-entry exponent with the global reference
// e0_i. The PE then needs no barrel shifter, at the cost of flushing every
// entry below e0_i and saturating every lane above it (ovf_o).
//
// TODO(spec): binary16 codes with exp == 31 (infinity, NaN) are not special
// cased -- they decode as ordinary numbers with e_eff = 31. u is an NPU-computed
// product of finite tensors, so the format the PCU consumes has no infinities
// and special-casing them would cost area for nothing. Confirm this is
// acceptable; see docs/rabit_pcu_spec.md, open question Q3.
module rabit_cvt_fp16_blk #(
    parameter int NIN        = 16,
    parameter int MANT_W     = 12,
    parameter int EXP_W      = 6,
    parameter int SHIFTER_EN = 1
) (
    input  logic [NIN*16-1:0]         fp16_i,
    input  logic [EXP_W-1:0]          e0_i,
    output logic [NIN*(MANT_W+1)-1:0] blk_o,
    output logic [EXP_W-1:0]          e_ent_o,
    output logic                      ovf_o
);

    // ---- derived geometry -------------------------------------------------
    localparam int SIG_W = 11;                                 // {1, frac}
    localparam int LSH   = (MANT_W > SIG_W) ? (MANT_W - SIG_W) : 0;
    localparam int RSH0  = (MANT_W < SIG_W) ? (SIG_W - MANT_W) : 0;
    localparam int WW    = SIG_W + LSH;                        // pre-shift width
    localparam int DMAX  = WW + 1;    // past this the aligned lane is always 0
    localparam int DW    = $clog2(DMAX + 1);
    localparam int LVL   = $clog2(NIN);
    localparam int SW    = EXP_W + 2;                          // signed shift math

    localparam logic [MANT_W-1:0] MANT_MAX = {MANT_W{1'b1}};
    localparam logic signed [SW-1:0] RSH0_S = SW'(RSH0);
    localparam logic signed [SW-1:0] DMAX_S = SW'(DMAX);

    // ---- per-lane binary16 fields -----------------------------------------
    logic             sign      [0:NIN-1];
    logic [4:0]       exp_field [0:NIN-1];
    logic [9:0]       frac      [0:NIN-1];
    logic [SIG_W-1:0] sig       [0:NIN-1];
    logic [4:0]       e_eff     [0:NIN-1];

    integer lane;
    always_comb begin
        for (lane = 0; lane < NIN; lane = lane + 1) begin
            sign[lane]      = fp16_i[lane*16 + 15];
            exp_field[lane] = fp16_i[lane*16 + 10 +: 5];
            frac[lane]      = fp16_i[lane*16 +: 10];
            sig[lane]       = {(exp_field[lane] != 5'd0), frac[lane]};
            e_eff[lane]     = (exp_field[lane] == 5'd0) ? 5'd1 : exp_field[lane];
        end
    end

    // ---- shared exponent: balanced max tree over e_eff --------------------
    //
    // Reduced in place inside one always_comb: entry i of a level is written
    // from entries 2i and 2i+1 of the level below, and 2i >= i, so a slot is
    // always read before it is overwritten. Keeping the whole tree local to one
    // process is what makes it a plain acyclic block rather than an array that
    // appears to feed itself.
    logic [EXP_W-1:0] e_max;

    integer mx_level;
    integer mx_node;
    always_comb begin
        logic [4:0] node [0:NIN-1];
        for (mx_node = 0; mx_node < NIN; mx_node = mx_node + 1) begin
            node[mx_node] = e_eff[mx_node];
        end
        for (mx_level = 1; mx_level <= LVL; mx_level = mx_level + 1) begin
            for (mx_node = 0;
                 mx_node < (NIN >> mx_level);
                 mx_node = mx_node + 1) begin
                node[mx_node] = (node[2*mx_node] > node[2*mx_node + 1])
                                    ? node[2*mx_node]
                                    : node[2*mx_node + 1];
            end
        end
        e_max = {{(EXP_W-5){1'b0}}, node[0]};
    end

    always_comb e_ent_o = (SHIFTER_EN != 0) ? e_max : e0_i;

    // ---- align every lane to the shared exponent, RNE ---------------------
    //
    // shift_req only goes negative when SHIFTER_EN == 0 and a lane sits above
    // the global reference; that lane saturates and raises ovf_o.
    logic signed [SW-1:0] shift_req [0:NIN-1];
    logic [DW-1:0]        shift_use [0:NIN-1];
    logic                 lane_ovf  [0:NIN-1];
    logic [2*WW-1:0]      wide      [0:NIN-1];
    logic [2*WW-1:0]      shifted   [0:NIN-1];
    logic [WW:0]          rounded   [0:NIN-1];
    logic [MANT_W-1:0]    mant      [0:NIN-1];
    logic                 round_bit [0:NIN-1];
    logic                 sticky    [0:NIN-1];
    logic                 round_up  [0:NIN-1];

    integer al;
    always_comb begin
        ovf_o = 1'b0;
        for (al = 0; al < NIN; al = al + 1) begin
            shift_req[al] = $signed({2'b00, e_ent_o}) -
                            $signed({{(SW-5){1'b0}}, e_eff[al]}) +
                            RSH0_S;

            lane_ovf[al]  = shift_req[al] < 0;
            shift_use[al] = lane_ovf[al]                ? {DW{1'b0}} :
                            (shift_req[al] > DMAX_S)    ? DW'(DMAX)  :
                                                          shift_req[al][DW-1:0];

            // {sig, LSH zeros} in the upper half with WW guard bits below, so a
            // single right shift yields quotient, round bit and sticky at once.
            wide[al]      = {sig[al], {(LSH+WW){1'b0}}};
            shifted[al]   = wide[al] >> shift_use[al];
            round_bit[al] = shifted[al][WW-1];
            sticky[al]    = |shifted[al][WW-2:0];
            round_up[al]  = round_bit[al] & (sticky[al] | shifted[al][WW]);
            rounded[al]   = {1'b0, shifted[al][2*WW-1:WW]} +
                            {{WW{1'b0}}, round_up[al]};

            // A rounding carry-out can push the top lane one code past MANT_MAX
            // whenever MANT_W < SIG_W. Clamping costs 1 ulp there and keeps the
            // stored mantissa inside its declared width.
            if (lane_ovf[al] || (rounded[al] > {{(WW+1-MANT_W){1'b0}}, MANT_MAX}))
            begin
                mant[al] = MANT_MAX;
            end else begin
                mant[al] = rounded[al][MANT_W-1:0];
            end

            ovf_o = ovf_o | lane_ovf[al];
            blk_o[al*(MANT_W+1) +: (MANT_W+1)] = {sign[al], mant[al]};
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NIN != (1 << LVL))
            $fatal(1, "rabit_cvt_fp16_blk: NIN must be a power of two");
        if (EXP_W < 6)
            $fatal(1, "rabit_cvt_fp16_blk: EXP_W must be at least 6");
        if (MANT_W > WW)
            $fatal(1, "rabit_cvt_fp16_blk: MANT_W wider than the pre-shift word");
    end
`endif

endmodule
