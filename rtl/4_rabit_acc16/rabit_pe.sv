`timescale 1ns/1ps

// One RaBiT processing element: the dot product of a binary row with one
// block-floating-point entry, accumulated into a 32-bit fixed-point register.
//
//     A_p[j] = sum_k B_p[j][k] * u_p[k],     B_p[j][k] in {+1, -1}
//
// There is no multiplier anywhere in this file, and there must not be one: the
// weight is a single bit, so the product is the mantissa with a conditional sign
// flip. The g and h scales stay with the NPU.
//
// Datapath, two pipeline stages:
//
//   stage A (combinational, registered into psum_q)
//     negate   b_bits_i[k] = 1 means -1, so the product sign is
//              sign(u[k]) XOR b_bits_i[k]. A negated lane contributes
//              (mant ^ all-ones), and the missing +1 per negated lane is
//              collected into one popcount correction term instead of NIN
//              separate increments -- this is the carry-correction row.
//     reduce   NIN operands through a 4:2 compressor tree, then one 3:2
//              compressor folds in the correction, then a single CPA.
//
//   stage B (combinational, registered into the accumulator file)
//     align    arithmetic shift by (e_ent - E0)
//     accum    32-bit add against the current accumulator, saturating
//
// Widths. mant is MANT_W bits and NIN of them are summed, so the exact partial
// sum needs MANT_W + 1 + log2(NIN) bits: with the defaults, 16 * 4094 = 65504
// fits a 17-bit signed value with room to spare. The compressor tree runs at
// that same width and wraps modulo 2**PSUM_W; because the true result fits, the
// wrap cancels and the CPA output is exact. RABIT_ASSERTIONS checks that.
module rabit_pe #(
    parameter int NIN        = 16,
    parameter int MANT_W     = 12,
    parameter int ACC_W      = 32,
    parameter int SH_W       = 7,
    parameter int SHIFTER_EN = 1,
    parameter int SHIFT_RND  = 0,
    parameter int PSUM_W     = MANT_W + 1 + $clog2(NIN)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // stage A
    input  logic                        ce_i,
    input  logic [NIN-1:0]              b_bits_i,
    input  logic [NIN*(MANT_W+1)-1:0]   blk_i,

    // stage B
    input  logic signed [SH_W-1:0]      shift_i,
    input  logic signed [ACC_W-1:0]     acc_cur_i,

    output logic signed [ACC_W-1:0]     acc_next_o,
    output logic                        acc_sat_o,
    output logic                        shift_sat_o,
    output logic signed [PSUM_W-1:0]    psum_o
);

    localparam int TW   = MANT_W + 1;               // one signed operand
    localparam int CW   = $clog2(NIN + 1);          // correction width
    localparam int PLVL = CW - 1;                   // popcount tree depth

    // ---- stage A: conditional negate --------------------------------------
    logic [NIN-1:0]    neg;
    logic [PSUM_W-1:0] term [0:NIN-1];

    integer tk;
    always_comb begin
        for (tk = 0; tk < NIN; tk = tk + 1) begin
            neg[tk] = blk_i[tk*TW + MANT_W] ^ b_bits_i[tk];
            // {neg, mant ^ {MANT_W{neg}}} is +mant when neg is 0 and
            // -(mant + 1) when neg is 1; the missing +1 lands in corr.
            term[tk] = {{(PSUM_W-TW){neg[tk]}},
                        neg[tk],
                        blk_i[tk*TW +: MANT_W] ^ {MANT_W{neg[tk]}}};
        end
    end

    // ---- stage A: carry-correction row, balanced popcount tree ------------
    //
    // Reduced in place inside one always_comb, same shape as the exponent max
    // tree in rabit_cvt_fp16_blk: slot i is written from slots 2i and 2i+1, and
    // 2i >= i, so nothing is overwritten before it has been read.
    logic [PSUM_W-1:0] corr;

    integer pop_level;
    integer pop_node;
    always_comb begin
        logic [CW-1:0] node [0:NIN-1];
        for (pop_node = 0; pop_node < NIN; pop_node = pop_node + 1) begin
            node[pop_node] = {{(CW-1){1'b0}}, neg[pop_node]};
        end
        for (pop_level = 1; pop_level <= PLVL; pop_level = pop_level + 1) begin
            for (pop_node = 0;
                 pop_node < (NIN >> pop_level);
                 pop_node = pop_node + 1) begin
                node[pop_node] = node[2*pop_node] + node[2*pop_node + 1];
            end
        end
        corr = {{(PSUM_W-CW){1'b0}}, node[0]};
    end

    // ---- stage A: 4:2 compressor tree, 16 operands -> 2 ------------------
    //
    // One array per level rather than one array indexed by level: the tree is
    // strictly acyclic and keeping the levels in separate variables lets a
    // simulator's dependency analysis see that. The shape is fixed because the
    // entry size is fixed -- 16 inputs per GRF entry is the word format, not a
    // knob (MANT_W, SHIFTER_EN, NOUT_PER_WORD and NPATH are the knobs).
    logic [PSUM_W-1:0] lvl0 [0:15];
    logic [PSUM_W-1:0] lvl1 [0:7];
    logic [PSUM_W-1:0] lvl2 [0:3];
    logic [PSUM_W-1:0] lvl3 [0:1];

    genvar ci;
    generate
        for (ci = 0; ci < 16; ci = ci + 1) begin : g_tree_leaf
            always_comb lvl0[ci] = term[ci];
        end
        for (ci = 0; ci < 4; ci = ci + 1) begin : g_tree_l1
            rabit_compressor_4to2 #(.W(PSUM_W)) u_comp (
                .in0_i   (lvl0[4*ci + 0]),
                .in1_i   (lvl0[4*ci + 1]),
                .in2_i   (lvl0[4*ci + 2]),
                .in3_i   (lvl0[4*ci + 3]),
                .sum_o   (lvl1[2*ci + 0]),
                .carry_o (lvl1[2*ci + 1])
            );
        end
        for (ci = 0; ci < 2; ci = ci + 1) begin : g_tree_l2
            rabit_compressor_4to2 #(.W(PSUM_W)) u_comp (
                .in0_i   (lvl1[4*ci + 0]),
                .in1_i   (lvl1[4*ci + 1]),
                .in2_i   (lvl1[4*ci + 2]),
                .in3_i   (lvl1[4*ci + 3]),
                .sum_o   (lvl2[2*ci + 0]),
                .carry_o (lvl2[2*ci + 1])
            );
        end
        for (ci = 0; ci < 1; ci = ci + 1) begin : g_tree_l3
            rabit_compressor_4to2 #(.W(PSUM_W)) u_comp (
                .in0_i   (lvl2[4*ci + 0]),
                .in1_i   (lvl2[4*ci + 1]),
                .in2_i   (lvl2[4*ci + 2]),
                .in3_i   (lvl2[4*ci + 3]),
                .sum_o   (lvl3[2*ci + 0]),
                .carry_o (lvl3[2*ci + 1])
            );
        end
    endgenerate

    // ---- stage A: fold the correction in, then one CPA -------------------
    logic [PSUM_W-1:0] csa_sum;
    logic [PSUM_W-1:0] csa_carry;
    logic [PSUM_W-1:0] psum_c;

    always_comb begin
        csa_sum   = lvl3[0] ^ lvl3[1] ^ corr;
        csa_carry = ((lvl3[0] & lvl3[1]) |
                     (lvl3[0] & corr) |
                     (lvl3[1] & corr)) << 1;
        psum_c    = csa_sum + csa_carry;
    end

    logic signed [PSUM_W-1:0] psum_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            psum_q <= {PSUM_W{1'b0}};
        end else if (ce_i) begin
            psum_q <= psum_c;
        end
    end

    always_comb psum_o = psum_q;

    // ---- stage B: align, then accumulate ---------------------------------
    logic signed [ACC_W-1:0] aligned;
    logic                    align_sat;

    generate
        if (SHIFTER_EN != 0) begin : g_shifter
            rabit_align_shift #(
                .PSUM_W    (PSUM_W),
                .ACC_W     (ACC_W),
                .SH_W      (SH_W),
                .SHIFT_RND (SHIFT_RND)
            ) u_align (
                .psum_i    (psum_q),
                .shift_i   (shift_i),
                .aligned_o (aligned),
                .sat_o     (align_sat)
            );
        end else begin : g_no_shifter
            // Every entry was already aligned to E0 on write, so the partial sum
            // only has to widen. shift_i is tied off by the top level here.
            logic unused_shift;
            always_comb begin
                unused_shift = ^shift_i;
                aligned      = {{(ACC_W-PSUM_W){psum_q[PSUM_W-1]}}, psum_q};
                align_sat    = 1'b0;
            end
        end
    endgenerate

    logic signed [ACC_W:0] acc_wide;

    always_comb begin
        acc_wide = $signed({acc_cur_i[ACC_W-1], acc_cur_i}) +
                   $signed({aligned[ACC_W-1], aligned});

        acc_sat_o   = acc_wide[ACC_W] ^ acc_wide[ACC_W-1];
        shift_sat_o = align_sat;

        if (acc_sat_o) begin
            acc_next_o = acc_wide[ACC_W] ? {1'b1, {(ACC_W-1){1'b0}}}
                                         : {1'b0, {(ACC_W-1){1'b1}}};
        end else begin
            acc_next_o = acc_wide[ACC_W-1:0];
        end
    end

    // Elaboration guards that survive `SYNTHESIS`.
    //
    // The 4:2 tree above is literal-shaped for sixteen operands: lvl0 is
    // declared [0:15] and driven from term[ci] for ci = 0..15. With NIN != 16
    // those reads run off the end of term, and neither sv2v nor Yosys treats
    // that as an error -- Yosys just reports "Replacing memory \term with list
    // of registers" and builds a tree that reduces the real operands together
    // with garbage. The $fatal below cannot catch it because synthesis is run
    // with SYNTHESIS defined (synth/run_block_synth.sh), which compiles that
    // block out.
    //
    // The guard is a reference to a module that does not exist. The branch is
    // not taken in a legal configuration, so it costs nothing (verified: the
    // shipped build is byte-identical in area with and without it); in an
    // illegal one `hierarchy -check` fails with the module name as the message.
    // A negative-width net was tried first and is not sufficient -- sv2v passes
    // it through and neither Yosys nor Verilator rejects it.
    generate
        if (NIN != 16) begin : g_nin_guard
            rabit_pe_ERROR_the_4to2_tree_requires_NIN_eq_16 u_guard ();
        end
        if (PSUM_W < MANT_W + 1 + $clog2(NIN)) begin : g_psum_guard
            rabit_pe_ERROR_PSUM_W_too_narrow_for_exact_partial_sum u_guard ();
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (NIN != 16)
            $fatal(1, "rabit_pe: the 4:2 tree is shaped for NIN = 16");
        if (PSUM_W < MANT_W + 1 + $clog2(NIN))
            $fatal(1, "rabit_pe: PSUM_W is too narrow for an exact partial sum");
    end
`endif

`ifdef RABIT_ASSERTIONS
`ifndef SYNTHESIS
    // The compressor tree wraps modulo 2**PSUM_W, which is only sound while the
    // exact sum fits. Recompute it here and compare against the wrapped result.
    function automatic integer exact_partial(
        input logic [NIN-1:0]            bits,
        input logic [NIN*(MANT_W+1)-1:0] blk
    );
        integer          k;
        integer          total;
        logic [MANT_W:0] mag;
        begin
            total = 0;
            for (k = 0; k < NIN; k = k + 1) begin
                mag = {1'b0, blk[k*TW +: MANT_W]};
                if (blk[k*TW + MANT_W] ^ bits[k]) begin
                    total = total - integer'({{(32-MANT_W-1){1'b0}}, mag});
                end else begin
                    total = total + integer'({{(32-MANT_W-1){1'b0}}, mag});
                end
            end
            exact_partial = total;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && ce_i && !$isunknown({b_bits_i, blk_i})) begin
            assert (exact_partial(b_bits_i, blk_i) == integer'($signed(psum_c)))
                else $error("rabit_pe: exact partial %0d != tree result %0d",
                            exact_partial(b_bits_i, blk_i), $signed(psum_c));
        end
    end
`endif
`endif

endmodule
