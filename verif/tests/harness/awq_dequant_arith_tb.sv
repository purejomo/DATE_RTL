`timescale 1ns/1ps

// Verification-only wrapper around the shared AWQ dequant arithmetic pipes.
//
// The multiplier and the packer are format-parameterized, so both formats are
// instantiated here and the one regression covers bfloat16 and binary16
// together. The binary32 adder has no format parameter and is instantiated
// once.
module awq_dequant_arith_tb (
  input  logic               clk,
  input  logic               rst_n,

  // fixed32 x scale -> binary32, bfloat16 scale
  input  logic               bf_mul_valid_i,
  input  logic signed [31:0] bf_mul_fixed_i,
  input  logic [15:0]        bf_mul_scale_i,
  input  logic signed [11:0] bf_mul_offset_i,
  output logic               bf_mul_valid_o,
  output logic [31:0]        bf_mul_fp32_o,
  output logic               bf_mul_invalid_o,
  output logic               bf_mul_overflow_o,
  output logic               bf_mul_underflow_o,

  // fixed32 x scale -> binary32, binary16 scale
  input  logic               fp_mul_valid_i,
  input  logic signed [31:0] fp_mul_fixed_i,
  input  logic [15:0]        fp_mul_scale_i,
  input  logic signed [11:0] fp_mul_offset_i,
  output logic               fp_mul_valid_o,
  output logic [31:0]        fp_mul_fp32_o,
  output logic               fp_mul_invalid_o,
  output logic               fp_mul_overflow_o,
  output logic               fp_mul_underflow_o,

  // binary32 accumulate
  input  logic               add_valid_i,
  input  logic [31:0]        add_a_i,
  input  logic [31:0]        add_b_i,
  output logic               add_valid_o,
  output logic [31:0]        add_result_o,
  output logic               add_invalid_o,
  output logic               add_overflow_o,
  output logic               add_underflow_o,

  // binary32 -> bfloat16 pack
  input  logic               bf_pack_valid_i,
  input  logic [31:0]        bf_pack_fp32_i,
  output logic               bf_pack_valid_o,
  output logic [15:0]        bf_pack_out_o,
  output logic               bf_pack_invalid_o,
  output logic               bf_pack_overflow_o,
  output logic               bf_pack_underflow_o,

  // binary32 -> binary16 pack
  input  logic               fp_pack_valid_i,
  input  logic [31:0]        fp_pack_fp32_i,
  output logic               fp_pack_valid_o,
  output logic [15:0]        fp_pack_out_o,
  output logic               fp_pack_invalid_o,
  output logic               fp_pack_overflow_o,
  output logic               fp_pack_underflow_o
);

  awq_dq_fixed32_float16_mul_pipe #(
    .SCALE_EXP_W  (8),
    .SCALE_MANT_W (7)
  ) u_bf_mul (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid_i   (bf_mul_valid_i),
    .fixed_i      (bf_mul_fixed_i),
    .scale_i      (bf_mul_scale_i),
    .exp_offset_i (bf_mul_offset_i),
    .out_valid_o  (bf_mul_valid_o),
    .fp32_o       (bf_mul_fp32_o),
    .invalid_o    (bf_mul_invalid_o),
    .overflow_o   (bf_mul_overflow_o),
    .underflow_o  (bf_mul_underflow_o)
  );

  awq_dq_fixed32_float16_mul_pipe #(
    .SCALE_EXP_W  (5),
    .SCALE_MANT_W (10)
  ) u_fp_mul (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid_i   (fp_mul_valid_i),
    .fixed_i      (fp_mul_fixed_i),
    .scale_i      (fp_mul_scale_i),
    .exp_offset_i (fp_mul_offset_i),
    .out_valid_o  (fp_mul_valid_o),
    .fp32_o       (fp_mul_fp32_o),
    .invalid_o    (fp_mul_invalid_o),
    .overflow_o   (fp_mul_overflow_o),
    .underflow_o  (fp_mul_underflow_o)
  );

  awq_dq_fp32_add_pipe u_add (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_valid_i  (add_valid_i),
    .a_i         (add_a_i),
    .b_i         (add_b_i),
    .out_valid_o (add_valid_o),
    .result_o    (add_result_o),
    .invalid_o   (add_invalid_o),
    .overflow_o  (add_overflow_o),
    .underflow_o (add_underflow_o)
  );

  awq_dq_fp32_pack_pipe #(
    .EXP_W  (8),
    .MANT_W (7)
  ) u_bf_pack (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_valid_i  (bf_pack_valid_i),
    .fp32_i      (bf_pack_fp32_i),
    .out_valid_o (bf_pack_valid_o),
    .float16_o   (bf_pack_out_o),
    .invalid_o   (bf_pack_invalid_o),
    .overflow_o  (bf_pack_overflow_o),
    .underflow_o (bf_pack_underflow_o)
  );

  awq_dq_fp32_pack_pipe #(
    .EXP_W  (5),
    .MANT_W (10)
  ) u_fp_pack (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_valid_i  (fp_pack_valid_i),
    .fp32_i      (fp_pack_fp32_i),
    .out_valid_o (fp_pack_valid_o),
    .float16_o   (fp_pack_out_o),
    .invalid_o   (fp_pack_invalid_o),
    .overflow_o  (fp_pack_overflow_o),
    .underflow_o (fp_pack_underflow_o)
  );

endmodule
