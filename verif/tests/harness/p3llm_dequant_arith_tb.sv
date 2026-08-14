`timescale 1ns/1ps

// Verification-only wrapper around the three shared dequant arithmetic pipes.
module p3llm_dequant_arith_tb (
  input  logic               clk,
  input  logic               rst_n,

  input  logic               fixed_valid_i,
  input  logic signed [31:0] fixed_i,
  input  logic [15:0]        fixed_scale_i,
  input  logic signed [6:0]  fixed_binary_exp_i,
  output logic               fixed_valid_o,
  output logic [31:0]        fixed_fp32_o,
  output logic               fixed_invalid_o,
  output logic               fixed_overflow_o,
  output logic               fixed_underflow_o,

  input  logic               add_valid_i,
  input  logic [31:0]        add_a_i,
  input  logic [31:0]        add_b_i,
  output logic               add_valid_o,
  output logic [31:0]        add_result_o,
  output logic               add_invalid_o,
  output logic               add_overflow_o,
  output logic               add_underflow_o,

  input  logic               pack_valid_i,
  input  logic [31:0]        pack_fp32_i,
  input  logic [15:0]        pack_scale_i,
  output logic               pack_valid_o,
  output logic [15:0]        pack_fp16_o,
  output logic               pack_invalid_o,
  output logic               pack_overflow_o,
  output logic               pack_underflow_o
);

  p3llm_dequant_fixed32_fp16_mul_pipe u_fixed_mul (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid_i   (fixed_valid_i),
    .fixed_i      (fixed_i),
    .scale_i      (fixed_scale_i),
    .binary_exp_i (fixed_binary_exp_i),
    .out_valid_o  (fixed_valid_o),
    .fp32_o       (fixed_fp32_o),
    .invalid_o    (fixed_invalid_o),
    .overflow_o   (fixed_overflow_o),
    .underflow_o  (fixed_underflow_o)
  );

  p3llm_dequant_fp32_add_pipe u_add (
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

  p3llm_dequant_fp32_fp16_mul_pack_pipe u_pack (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_valid_i  (pack_valid_i),
    .fp32_i      (pack_fp32_i),
    .scale_i     (pack_scale_i),
    .out_valid_o (pack_valid_o),
    .fp16_o      (pack_fp16_o),
    .invalid_o   (pack_invalid_o),
    .overflow_o  (pack_overflow_o),
    .underflow_o (pack_underflow_o)
  );

endmodule
