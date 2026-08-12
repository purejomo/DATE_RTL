`timescale 1ns/1ps

// One AWQ-on-HBM-PIM MAC lane for INT4 weights and bfloat16 activations: an
// INT4 x bfloat16 multiply followed by a binary32 accumulation, in four
// registered stages.
//
//   0  capture the activation and the weight nibble
//   1  INT4 x bfloat16 multiply
//   2  widen the product to binary32
//   3  binary32 add into the accumulator
//
// Same staging as the other MAC lanes and as the PCU processing elements. The
// multiplier and accumulator use the reduced normal-finite DAZ/FTZ contract.
//
// The widening stage is nearly free for this row: bfloat16 shares binary32's
// exponent width and bias, so a normal value only gains sixteen zero bits. It
// is still a separate stage so that this lane and the binary16 lane are
// measured at the same depth.
module awq_int4bf16_mac_1_lane (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_valid,
    input  wire        i_acc_clear,
    input  wire        i_acc_enable,

    input  wire [15:0] i_act,
    input  wire [3:0]  i_weight_q,
    input  wire [3:0]  i_weight_zp,

    output wire        o_valid,
    output wire [31:0] o_acc
);

    // ---- stage 0: capture operands ---------------------------------------
    reg        s0_valid_q;
    reg        s0_clear_q;
    reg        s0_enable_q;
    reg [15:0] s0_act_q;
    reg [3:0]  s0_weight_q;
    reg [3:0]  s0_weight_zp_q;

    wire [15:0] mul_result;

    awq_int4bf16_mul u_mul (
        .i_act       (s0_act_q),
        .i_weight_q  (s0_weight_q),
        .i_weight_zp (s0_weight_zp_q),
        .o_result    (mul_result)
    );

    // ---- stage 1: register the product -----------------------------------
    reg        s1_valid_q;
    reg        s1_clear_q;
    reg        s1_enable_q;
    reg [15:0] s1_product_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q     <= 1'b0;
            s0_clear_q     <= 1'b0;
            s0_enable_q    <= 1'b0;
            s0_act_q       <= 16'd0;
            s0_weight_q    <= 4'd0;
            s0_weight_zp_q <= 4'd0;
            s1_valid_q     <= 1'b0;
            s1_clear_q     <= 1'b0;
            s1_enable_q    <= 1'b0;
            s1_product_q   <= 16'd0;
        end else begin
            s0_valid_q     <= i_valid;
            s0_clear_q     <= i_acc_clear;
            s0_enable_q    <= i_acc_enable;
            s0_act_q       <= i_act;
            s0_weight_q    <= i_weight_q;
            s0_weight_zp_q <= i_weight_zp;

            s1_valid_q   <= s0_valid_q;
            s1_clear_q   <= s0_clear_q;
            s1_enable_q  <= s0_enable_q;
            s1_product_q <= mul_result;
        end
    end

    // ---- stage 2: widen and register -------------------------------------
    // Bfloat16 shares binary32's exponent width and bias, so the reduced
    // multiplier result widens by appending sixteen zero fraction bits.
    wire [31:0] widened = {s1_product_q, 16'd0};
    reg         s2_valid_q;
    reg         s2_clear_q;
    reg         s2_enable_q;
    reg [31:0]  s2_widened_q;

    // ---- stage 3: binary32 add and accumulate ----------------------------
    reg         s3_valid_q;
    reg [31:0]  acc_q;
    wire [31:0] accumulated;

    awq_fp32_add u_add (
        .i_a      (acc_q),
        .i_b      (s2_widened_q),
        .o_result (accumulated)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            s2_valid_q   <= 1'b0;
            s2_clear_q   <= 1'b0;
            s2_enable_q  <= 1'b0;
            s2_widened_q <= 32'd0;
            s3_valid_q   <= 1'b0;
            acc_q        <= 32'd0;
        end else begin
            s2_valid_q   <= s1_valid_q;
            s2_clear_q   <= s1_clear_q;
            s2_enable_q  <= s1_enable_q;
            s2_widened_q <= widened;

            s3_valid_q <= s2_valid_q;
            if (s2_valid_q) begin
                if (s2_clear_q) begin
                    acc_q <= s2_widened_q;
                end else if (s2_enable_q) begin
                    acc_q <= accumulated;
                end
            end
        end
    end

    assign o_valid = s3_valid_q;
    assign o_acc   = acc_q;

endmodule
