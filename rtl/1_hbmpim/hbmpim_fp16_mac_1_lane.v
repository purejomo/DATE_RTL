`timescale 1ns/1ps

// One HBM-PIM FP16 MAC lane: a binary16 multiply followed by a binary32
// accumulation, in four registered stages.
//
//   0  capture the two operands
//   1  binary16 multiply
//   2  widen the product to binary32
//   3  binary32 add into the accumulator
//
// The stage count matches int4float_pe and p3llm_pe so the two organizations
// are compared at equal pipeline depth. Stage 2 stands where the PCU puts its
// 4:2 compressor: a SIMD lane has one multiplier and nothing to compress, so
// the slot holds the format widening instead.
//
// The format widening and accumulator control are local to this lane so the
// HBM-PIM directory is self-contained.
module hbmpim_fp16_mac_1_lane (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_valid,
    input  wire        i_acc_clear,
    input  wire        i_acc_enable,

    input  wire [15:0] i_a,
    input  wire [15:0] i_b,

    output wire        o_valid,
    output wire [31:0] o_acc
);

    // Every binary16 value has an exact binary32 representation. Normal values
    // only need exponent rebiasing; binary16 subnormals become binary32 normals.
    function automatic [31:0] fp16_to_fp32_exact;
        input [15:0] value;
        reg          sign;
        reg [4:0]    exponent;
        reg [9:0]    fraction;
        reg [4:0]    leading_zeros;
        reg [7:0]    exponent32;
        reg [9:0]    shifted_fraction;
        integer      scan;
        begin
            sign = value[15];
            exponent = value[14:10];
            fraction = value[9:0];
            leading_zeros = 5'd10;
            exponent32 = 8'd0;
            shifted_fraction = 10'd0;

            // Scanning upward leaves the highest set bit as the final match.
            for (scan = 0; scan < 10; scan = scan + 1) begin
                if (fraction[scan]) begin
                    leading_zeros = 5'd9 - scan[4:0];
                end
            end

            if (exponent == 5'd0) begin
                if (fraction == 10'd0) begin
                    fp16_to_fp32_exact = {sign, 31'd0};
                end else begin
                    exponent32 = 8'd112 - {3'd0, leading_zeros};
                    shifted_fraction =
                        fraction << (leading_zeros + 5'd1);
                    fp16_to_fp32_exact = {
                        sign, exponent32, shifted_fraction, 13'd0
                    };
                end
            end else if (exponent == 5'h1f) begin
                // Infinity keeps a zero payload; NaN payloads are left-aligned.
                fp16_to_fp32_exact = {sign, 8'hff, fraction, 13'd0};
            end else begin
                exponent32 = {3'd0, exponent} + 8'd112;
                fp16_to_fp32_exact = {
                    sign, exponent32, fraction, 13'd0
                };
            end
        end
    endfunction

    // ---- stage 0: capture operands ---------------------------------------
    reg        s0_valid_q;
    reg        s0_clear_q;
    reg        s0_enable_q;
    reg [15:0] s0_a_q;
    reg [15:0] s0_b_q;

    wire [15:0] product;

    hbmpim_fp16_mul u_mul (
        .i_a      (s0_a_q),
        .i_b      (s0_b_q),
        .o_result (product)
    );

    // ---- stage 1: register the product -----------------------------------
    reg        s1_valid_q;
    reg        s1_clear_q;
    reg        s1_enable_q;
    reg [15:0] s1_product_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            s0_valid_q   <= 1'b0;
            s0_clear_q   <= 1'b0;
            s0_enable_q  <= 1'b0;
            s0_a_q       <= 16'd0;
            s0_b_q       <= 16'd0;
            s1_valid_q   <= 1'b0;
            s1_clear_q   <= 1'b0;
            s1_enable_q  <= 1'b0;
            s1_product_q <= 16'd0;
        end else begin
            s0_valid_q  <= i_valid;
            s0_clear_q  <= i_acc_clear;
            s0_enable_q <= i_acc_enable;
            s0_a_q      <= i_a;
            s0_b_q      <= i_b;

            s1_valid_q   <= s0_valid_q;
            s1_clear_q   <= s0_clear_q;
            s1_enable_q  <= s0_enable_q;
            s1_product_q <= product;
        end
    end

    // ---- stage 2: widen the product to binary32 --------------------------
    wire [31:0] widened = fp16_to_fp32_exact(s1_product_q);

    reg        s2_valid_q;
    reg        s2_clear_q;
    reg        s2_enable_q;
    reg [31:0] s2_widened_q;

    // ---- stage 3: binary32 add into the running accumulator --------------
    reg        s3_valid_q;
    reg [31:0] acc_q;

    wire [31:0] accumulated;

    hbmpim_fp32_add u_add (
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
