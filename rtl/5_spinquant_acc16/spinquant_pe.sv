`timescale 1ns/1ps

// One SpinQuant W4A4 processing element: a NWAY-wide integer dot product that
// updates one entry of the architectural accumulator file.
//
//     acc[e] += sum_{j < NWAY} w[j] * a[j]      w signed INT4, a unsigned INT4
//
// Two pipeline stages, one command per stage, so the PE sustains a MAC every
// cycle at the tCCD_S command rate:
//
//   stage 1 (combinational, registered into psum_q)
//     multiply   NWAY signed4 x unsigned4 products, each exact in 8 bits
//     reduce     one 4:2 compressor level, then a single PSUM_W-bit CPA
//
//   stage 2 (combinational, registered into the accumulator file in the top)
//     accumulate one ACC_CHAIN_W-bit add against the selected entry
//
// Widths. |w*a| <= 120, so a product is exact in PROD_W = 8 bits, and NWAY = 4
// of them sum to at most 480 in magnitude, which is exact in
// PSUM_W = PROD_W + log2(NWAY) = 10 bits. The compressor tree wraps modulo
// 2**PSUM_W and the wrap cancels because the true value fits;
// SPINQUANT_ASSERTIONS recomputes the dot product and compares.
//
// Accumulator, acc16 variant. The architectural accumulator is ACC_W = 16 bits
// and it keeps the MOST significant bits of the live value: every partial sum
// is rounded to nearest, ties to even, down by ACC_RSH before it is added.
//
//   narrow(x, n):
//       round_bit = x[n-1]
//       sticky    = |x[n-2:0]
//       round_up  = round_bit & (sticky | x[n])      // tie -> even
//       return (x >>> n) + round_up                  // arithmetic shift
//
// Why the MSBs and not the LSBs. The base design's live value needs 22 bits:
// a product is exact in 8 bits, NWAY = 4 of them sum to at most 480, and the
// worst case a projection layer can reach is K = 14336 products of -120, that
// is -1720320. Keeping the same LSB weight in 16 bits would cap the design at
// 32767/480 ~ 68 MAC commands, K = 273 -- one fiftieth of what a projection
// layer needs. So the accumulator is moved up: ACC_RSH = 22 - 15 = 7 puts the
// full 22-bit range inside 16 signed bits and spends the low 7 bits on
// rounding instead.
//
// What that costs. Each add discards at most half an accumulator LSB, which is
// 2^(ACC_RSH-1) = 64 in raw product units, and RNE makes the error zero mean.
// Over K = 14336 (3584 accepted MAC commands) the error accumulates as a random
// walk, roughly sqrt(3584) * 0.29 * 128 ~ 2200 against a full-scale 1720320,
// about 0.13%. That estimate is analytic; measuring it is out of this
// directory's scope.
//
// Overflow is detected and reported on acc_ovf_o, not saturated -- the same
// policy as the base design. Note this differs from the other acc16 rows in
// this repository, which saturate: here the point is a like-for-like reading
// against rtl/5_spinquant, so the base policy is the one that must be kept.
module spinquant_pe #(
    parameter int NWAY        = 4,
    parameter int ACC_W       = 16,
    parameter int ACC_CHAIN_W = 16,
    parameter int ACC_RSH     = 7,
    parameter int Q_W         = 4,
    // derived; do not override
    parameter int PROD_W      = 8,
    parameter int PSUM_W      = PROD_W + $clog2(NWAY)
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- stage 1 -------------------------------------------------------
    input  logic                       ce_i,
    input  logic [NWAY*Q_W-1:0]        w_q4_i,
    input  logic [NWAY*Q_W-1:0]        a_q4_i,

    // ---- stage 2 -------------------------------------------------------
    input  logic                       acc_clear_i,
    // Only the low ACC_CHAIN_W bits are read back: everything above them is
    // the sign extension this PE wrote there in the first place.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic signed [ACC_W-1:0]    acc_cur_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic signed [ACC_W-1:0]    acc_next_o,
    output logic                       acc_ovf_o,

    output logic signed [PSUM_W-1:0]   psum_o
);

    // ---- stage 1: NWAY products ------------------------------------------
    logic signed [PROD_W-1:0] prod [0:NWAY-1];
    logic        [PSUM_W-1:0] term [0:NWAY-1];

    genvar mi;
    generate
        for (mi = 0; mi < NWAY; mi = mi + 1) begin : g_mul
            spinquant_mul_s4u4 u_mul (
                .w_i (w_q4_i[mi*Q_W +: Q_W]),
                .a_i (a_q4_i[mi*Q_W +: Q_W]),
                .p_o (prod[mi])
            );
            always_comb begin
                term[mi] = {{(PSUM_W-PROD_W){prod[mi][PROD_W-1]}}, prod[mi]};
            end
        end
    endgenerate

    // ---- stage 1: 4:2 reduction, then one CPA -----------------------------
    //
    // NWAY = 4 is the beat geometry, not a knob: a 256-bit bank word holds
    // 16 output channels x 4 k-elements, so the reduction is exactly one
    // compressor level wide. The guard below keeps that assumption honest.
    logic [PSUM_W-1:0] csa_sum;
    logic [PSUM_W-1:0] csa_carry;
    logic [PSUM_W-1:0] psum_c;

    spinquant_compressor_4to2 #(.W(PSUM_W)) u_comp (
        .in0_i   (term[0]),
        .in1_i   (term[1]),
        .in2_i   (term[2]),
        .in3_i   (term[3]),
        .sum_o   (csa_sum),
        .carry_o (csa_carry)
    );

    always_comb psum_c = csa_sum + csa_carry;

    logic signed [PSUM_W-1:0] psum_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            psum_q <= {PSUM_W{1'b0}};
        end else if (ce_i) begin
            psum_q <= psum_c;
        end
    end

    always_comb psum_o = psum_q;

    // ---- stage 2: accumulate ---------------------------------------------
    // The RNE narrow sits between the CPA and the accumulate adder. It is pure
    // combinational logic on a PSUM_W-bit value, so it adds no pipeline stage.
    logic                     narrow_round_bit;
    logic                     narrow_sticky;
    logic                     narrow_round_up;
    logic signed [PSUM_W-1:0] psum_narrow;

    always_comb begin
        narrow_round_bit = psum_q[ACC_RSH-1];
        narrow_sticky    = (ACC_RSH < 2) ? 1'b0 : |psum_q[ACC_RSH-2:0];
        narrow_round_up  = narrow_round_bit & (narrow_sticky | psum_q[ACC_RSH]);
        psum_narrow      = (psum_q >>> ACC_RSH) +
                           $signed({{(PSUM_W-1){1'b0}}, narrow_round_up});
    end

    logic signed [ACC_CHAIN_W-1:0] psum_ext;
    logic signed [ACC_CHAIN_W-1:0] acc_cur_chain;
    logic signed [ACC_CHAIN_W-1:0] chain_next;

    always_comb begin
        psum_ext      = {{(ACC_CHAIN_W-PSUM_W){psum_narrow[PSUM_W-1]}},
                         psum_narrow};
        acc_cur_chain = acc_cur_i[ACC_CHAIN_W-1:0];

        if (acc_clear_i) begin
            chain_next = psum_ext;
            acc_ovf_o  = 1'b0;
        end else begin
            chain_next = acc_cur_chain + psum_ext;
            // Two's complement overflow: both addends share a sign that the
            // sum does not.
            acc_ovf_o  = (psum_ext[ACC_CHAIN_W-1] ==
                          acc_cur_chain[ACC_CHAIN_W-1]) &&
                         (chain_next[ACC_CHAIN_W-1] !=
                          acc_cur_chain[ACC_CHAIN_W-1]);
        end
    end

    generate
        if (ACC_CHAIN_W < ACC_W) begin : g_sext
            // The stored value is the sign extension of the live chain, which
            // is what keeps acc_cur_i[ACC_CHAIN_W-1:0] a lossless read.
            always_comb begin
                acc_next_o = {{(ACC_W-ACC_CHAIN_W){chain_next[ACC_CHAIN_W-1]}},
                              chain_next};
            end
        end else begin : g_full
            always_comb acc_next_o = chain_next;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (NWAY != 4)
            $fatal(1, "spinquant_pe: the 4:2 reduction is shaped for NWAY = 4");
        if (Q_W != 4)
            $fatal(1, "spinquant_pe: the multiplier is shaped for Q_W = 4");
        if (ACC_CHAIN_W <= PSUM_W)
            $fatal(1, "spinquant_pe: ACC_CHAIN_W must exceed PSUM_W");
        if (ACC_CHAIN_W > ACC_W)
            $fatal(1, "spinquant_pe: ACC_CHAIN_W must not exceed ACC_W");
        // ACC_RSH = 0 would be the base design and is reachable only by
        // deleting the narrow; ACC_RSH >= PSUM_W would shift every partial sum
        // to zero or one.
        if (ACC_RSH < 1 || ACC_RSH >= PSUM_W)
            $fatal(1, "spinquant_pe: ACC_RSH must be in [1, PSUM_W)");
    end
`endif

`ifdef SPINQUANT_ASSERTIONS
`ifndef SYNTHESIS
    // The compressor tree wraps modulo 2**PSUM_W, which is only sound while the
    // exact dot product fits. Recompute it and compare against the wrapped CPA.
    function automatic integer exact_dot(
        input logic [NWAY*Q_W-1:0] w,
        input logic [NWAY*Q_W-1:0] a
    );
        integer            j;
        integer            total;
        logic signed [3:0] wv;
        logic        [3:0] av;
        begin
            total = 0;
            for (j = 0; j < NWAY; j = j + 1) begin
                wv    = w[j*Q_W +: Q_W];
                av    = a[j*Q_W +: Q_W];
                total = total + (integer'(wv) * integer'({28'd0, av}));
            end
            exact_dot = total;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && ce_i && !$isunknown({w_q4_i, a_q4_i})) begin
            assert (exact_dot(w_q4_i, a_q4_i) == integer'($signed(psum_c)))
                else $error("spinquant_pe: exact dot %0d != tree result %0d",
                            exact_dot(w_q4_i, a_q4_i), $signed(psum_c));
        end
    end
`endif
`endif

endmodule
