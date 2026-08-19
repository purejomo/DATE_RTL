`timescale 1ns/1ps

// Processing element for the INT4 x float PCU, narrow-accumulator variant.
//
// This is the axis-2 (acc16) build. It is the same four-lane carry-save PE as
// rtl/2_awq_p3llm_8pe_v2/int4float_pe.v with one change: the 4-lane partial
// sum is rounded to nearest, ties to even, down to ACC_W bits *before* it
// enters the accumulator, and the accumulator itself is ACC_W bits instead of
// 32. Everything ahead of that point -- alignment, weight decode, the four
// signed multipliers, the 4:2 compressor and the final CPA -- is bit-identical
// to the 32-bit build, so the area delta this row reports is the accumulator
// and its rounding logic and nothing else.
//
// Why round rather than truncate. A 4-lane partial sum needs 28 bits and does
// not fit in 16 under any shift, so bits must be discarded on every
// accumulation. Truncation biases each one toward -inf by up to one LSB, and
// the bias is systematic, so over the 32 transactions of a 128-element group it
// accumulates in one direction. RNE leaves no first-order bias. This is the
// same argument int4float_align.v already makes for the alignment shift.
//
//   narrow(x, n):
//       round_bit = x[n-1]
//       sticky    = |x[n-2:0]
//       round_up  = round_bit & (sticky | x[n])      // tie -> even
//       y         = (x >>> n) + round_up             // arithmetic shift
//       return saturate_to_signed(y, ACC_W)
//
// Accumulation is a saturating add, exactly as the 32-bit build's is. No new
// status bit is exported: the 32-bit build also saturates silently, and the
// three axes are only comparable if they report the same thing.
//
// Scale. The accumulator LSB is worth 2^(ref_exp - GUARD + ACC_RSH) instead of
// 2^(ref_exp - GUARD). Software already applies the 2^(ref_exp - GUARD) factor
// together with the weight group's quantization scale, so folding one more
// power of two into it needs no new port.
//
// ACC_RSH defaults. These are the smallest shifts for which a full group can
// never saturate, i.e. the worst-case bound, not an accuracy optimum:
//
//   BF16  ALIGNED_W = MANT_W + GUARD + 2 = 7 + 8 + 2 = 17, so |aligned| < 2^16
//         and |weight| <= 15 < 2^4, giving |product| < 2^20, |4 lanes| < 2^22,
//         and over a 128-element group (32 accepted transactions) < 2^27.
//         Fitting 2^27 into signed 16 bits needs ACC_RSH = 12.
//   FP16  ALIGNED_W = 10 + 8 + 2 = 20, so the same chain gives < 2^30 and
//         ACC_RSH = 15.
//
// A smaller shift keeps more low-order precision at the cost of saturating on
// large groups; sweeping it is an accuracy question, not an area one, because
// the shift is wiring. See the open items in EXTENSION_PLAN.md.
module int4float_pe #(
    parameter integer ALIGNED_W = 20,  // signed width from int4float_align
    parameter integer ACC_W     = 16,  // narrowed accumulator width
    parameter integer ACC_RSH   = 12   // RNE shift applied before accumulating
) (
    input  wire                            clk,
    input  wire                            rst_n,

    input  wire                            i_valid,
    input  wire                            i_acc_clear,
    input  wire                            i_acc_enable,

    input  wire signed [ALIGNED_W-1:0]     i_act0,
    input  wire signed [ALIGNED_W-1:0]     i_act1,
    input  wire signed [ALIGNED_W-1:0]     i_act2,
    input  wire signed [ALIGNED_W-1:0]     i_act3,

    input  wire [15:0]                     i_weight_q,   // four INT4 nibbles
    input  wire [3:0]                      i_weight_zp,

    output wire                            o_valid,
    output wire signed [ACC_W-1:0]         o_acc
);

    localparam integer PROD_W = ALIGNED_W + 5;
    localparam integer PSUM_W = 28;                  // compressor CPA width

    // ---- stage 0: capture and decode -------------------------------------
    reg                        s0_valid_q;
    reg                        s0_clear_q;
    reg                        s0_enable_q;
    reg signed [ALIGNED_W-1:0] s0_act_q [0:3];
    reg signed [4:0]           s0_weight_q [0:3];

    wire        weight_sign    [0:3];
    wire [3:0]  weight_magnitude [0:3];
    wire        weight_zero    [0:3];

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_decode
            int4_asym_decode u_decode (
                .i_q          (i_weight_q[lane*4 +: 4]),
                .i_zero_point (i_weight_zp),
                .o_sign       (weight_sign[lane]),
                .o_magnitude  (weight_magnitude[lane]),
                .o_zero       (weight_zero[lane])
            );
        end
    endgenerate

    wire signed [4:0] weight_signed [0:3];
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_signed
            assign weight_signed[lane] =
                weight_zero[lane] ? 5'sd0
                                  : (weight_sign[lane]
                                        ? -$signed({1'b0, weight_magnitude[lane]})
                                        :  $signed({1'b0, weight_magnitude[lane]}));
        end
    endgenerate

    // ---- stage 1: four signed multiplies ---------------------------------
    reg                    s1_valid_q;
    reg                    s1_clear_q;
    reg                    s1_enable_q;
    reg signed [PROD_W-1:0] s1_product_q [0:3];

    // ---- stage 2: carry-save reduction -----------------------------------
    reg                 s2_valid_q;
    reg                 s2_clear_q;
    reg                 s2_enable_q;
    reg signed [27:0]   s2_sum_q;
    reg signed [27:0]   s2_carry_q;

    wire signed [25:0] compressor_in [0:3];
    wire signed [27:0] compressor_sum;
    wire signed [27:0] compressor_carry;

    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_extend
            assign compressor_in[lane] =
                {{(26 - PROD_W){s1_product_q[lane][PROD_W-1]}},
                 s1_product_q[lane]};
        end
    endgenerate

    compressor_4to2 u_compressor (
        .in0_i   (compressor_in[0]),
        .in1_i   (compressor_in[1]),
        .in2_i   (compressor_in[2]),
        .in3_i   (compressor_in[3]),
        .sum_o   (compressor_sum),
        .carry_o (compressor_carry)
    );

    // ---- stage 3: CPA, RNE narrow, and accumulate ------------------------
    reg                     s3_valid_q;
    reg signed [ACC_W-1:0]  acc_q;

    wire signed [PSUM_W-1:0] partial_sum = s2_sum_q + s2_carry_q;
    wire        [PSUM_W-1:0] partial_bits = partial_sum;

    // RNE on the ACC_RSH low bits the accumulator does not keep.
    localparam [PSUM_W-1:0] STICKY_MASK =
        (({{(PSUM_W-1){1'b0}}, 1'b1} << (ACC_RSH - 1)) -
         {{(PSUM_W-1){1'b0}}, 1'b1});

    wire narrow_round_bit = partial_bits[ACC_RSH-1];
    wire narrow_sticky    = |(partial_bits & STICKY_MASK);
    wire narrow_round_up  =
        narrow_round_bit & (narrow_sticky | partial_bits[ACC_RSH]);

    wire signed [PSUM_W-1:0] narrow_shifted = partial_sum >>> ACC_RSH;
    wire signed [PSUM_W:0]   narrow_wide =
        {narrow_shifted[PSUM_W-1], narrow_shifted} +
        {{PSUM_W{1'b0}}, narrow_round_up};

    // The rounded value fits ACC_W bits only when every bit above the
    // destination sign position repeats it.
    wire narrow_overflow =
        ~((&narrow_wide[PSUM_W:ACC_W-1]) | (~|narrow_wide[PSUM_W:ACC_W-1]));
    wire signed [ACC_W-1:0] narrowed =
        narrow_overflow
            ? (narrow_wide[PSUM_W] ? {1'b1, {(ACC_W-1){1'b0}}}
                                   : {1'b0, {(ACC_W-1){1'b1}}})
            : narrow_wide[ACC_W-1:0];

    // Saturating accumulate, same policy as the 32-bit build.
    wire signed [ACC_W:0] acc_wide =
        {acc_q[ACC_W-1], acc_q} + {narrowed[ACC_W-1], narrowed};
    wire acc_overflow = acc_wide[ACC_W] ^ acc_wide[ACC_W-1];
    wire signed [ACC_W-1:0] acc_next =
        acc_overflow ? (acc_wide[ACC_W] ? {1'b1, {(ACC_W-1){1'b0}}}
                                        : {1'b0, {(ACC_W-1){1'b1}}})
                     : acc_wide[ACC_W-1:0];

    integer index;
    always @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q <= 1'b0;
            s0_clear_q <= 1'b0;
            s0_enable_q <= 1'b0;
            s1_valid_q <= 1'b0;
            s1_clear_q <= 1'b0;
            s1_enable_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s2_clear_q <= 1'b0;
            s2_enable_q <= 1'b0;
            s3_valid_q <= 1'b0;
            s2_sum_q <= 28'sd0;
            s2_carry_q <= 28'sd0;
            acc_q <= {ACC_W{1'b0}};
            for (index = 0; index < 4; index = index + 1) begin
                s0_act_q[index] <= {ALIGNED_W{1'b0}};
                s0_weight_q[index] <= 5'sd0;
                s1_product_q[index] <= {PROD_W{1'b0}};
            end
        end else begin
            s0_valid_q <= i_valid;
            s0_clear_q <= i_acc_clear;
            s0_enable_q <= i_acc_enable;
            s0_act_q[0] <= i_act0;
            s0_act_q[1] <= i_act1;
            s0_act_q[2] <= i_act2;
            s0_act_q[3] <= i_act3;
            for (index = 0; index < 4; index = index + 1) begin
                s0_weight_q[index] <= weight_signed[index];
            end

            s1_valid_q <= s0_valid_q;
            s1_clear_q <= s0_clear_q;
            s1_enable_q <= s0_enable_q;
            for (index = 0; index < 4; index = index + 1) begin
                s1_product_q[index] <= s0_act_q[index] * s0_weight_q[index];
            end

            s2_valid_q <= s1_valid_q;
            s2_clear_q <= s1_clear_q;
            s2_enable_q <= s1_enable_q;
            s2_sum_q <= compressor_sum;
            s2_carry_q <= compressor_carry;

            s3_valid_q <= s2_valid_q;
            if (s2_valid_q) begin
                if (s2_clear_q) begin
                    acc_q <= narrowed;
                end else if (s2_enable_q) begin
                    acc_q <= acc_next;
                end
            end
        end
    end

    assign o_valid = s3_valid_q;
    assign o_acc = acc_q;

endmodule
