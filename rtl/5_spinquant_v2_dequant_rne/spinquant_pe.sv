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
// Accumulator. ACC_CHAIN_W = 24 bits carry the live value and the remaining
// ACC_W - ACC_CHAIN_W bits hold its sign extension, so the register keeps the
// architectural 32-bit width while the carry chain the clock has to cross is
// only 24 bits. The worst case a projection layer can reach is K = 14336
// products of -120, that is -1720320, which needs 22 bits -- two bits of
// headroom, and the chain does not overflow until K = 69905.
//
// Overflow is detected and reported on acc_ovf_o, not saturated. Saturating
// logic would be dead silicon for every K this design supports, while the
// report makes a violated assumption observable instead of silent.
module spinquant_pe #(
    parameter int NWAY        = 4,
    parameter int ACC_W       = 32,
    parameter int ACC_CHAIN_W = 24,
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
    logic signed [ACC_CHAIN_W-1:0] psum_ext;
    logic signed [ACC_CHAIN_W-1:0] acc_cur_chain;
    logic signed [ACC_CHAIN_W-1:0] chain_next;

    always_comb begin
        psum_ext      = {{(ACC_CHAIN_W-PSUM_W){psum_q[PSUM_W-1]}}, psum_q};
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
