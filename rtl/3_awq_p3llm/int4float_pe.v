`timescale 1ns/1ps

// Processing element for the INT4 x float PCU: four lanes, a carry-save
// reduction, and one signed 32-bit fixed-point accumulator.
//
// This is P3-LLM's PE with the operand formats swapped. The organization is
// identical -- four signed fixed-point multipliers, a 4:2 compressor, a final
// carry-propagate adder, and an accumulator that lives inside the PE rather
// than in a register file. The compressor is literally P3-LLM's
// compressor_4to2 module; its 26-bit input width accommodates both activation
// formats without change.
//
// What differs from P3-LLM is only where the exponent is handled. P3-LLM
// shifts each product by the activation's own four-bit exponent inside the PE.
// Sixteen-bit float activations have too much exponent range for that, so
// alignment happens once in the shared front end (int4float_align) and the PE
// sees operands that are already on a common scale. That makes the PE simpler
// than P3-LLM's, not more complex: there is no per-lane shifter.
//
// Pipeline, matching P3-LLM's four registered stages:
//
//   0  capture aligned activations and decode weights
//   1  four signed multiplies
//   2  4:2 carry-save reduction
//   3  final CPA and accumulate
//
// The accumulator wraps on overflow, as P3-LLM's does. Its least significant
// bit is worth 2^(ref_exp - GUARD); software applies that scale, along with
// the weight group's quantization scale, outside this core.
module int4float_pe #(
    parameter integer ALIGNED_W = 20   // signed width from int4float_align
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
    output wire signed [31:0]              o_acc
);

    localparam integer PROD_W = ALIGNED_W + 5;

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

    // ---- stage 3: CPA and accumulate -------------------------------------
    reg                 s3_valid_q;
    reg signed [31:0]   acc_q;

    wire signed [27:0] partial_sum = s2_sum_q + s2_carry_q;
    wire signed [31:0] partial_sum_32 = {{4{partial_sum[27]}}, partial_sum};

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
            acc_q <= 32'sd0;
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
                    acc_q <= partial_sum_32;
                end else if (s2_enable_q) begin
                    acc_q <= acc_q + partial_sum_32;
                end
            end
        end
    end

    assign o_valid = s3_valid_q;
    assign o_acc = acc_q;

endmodule
