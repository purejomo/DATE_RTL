module compressor_tb (
  input  logic signed [25:0] in0,
  input  logic signed [25:0] in1,
  input  logic signed [25:0] in2,
  input  logic signed [25:0] in3,
  output logic signed [27:0] sum,
  output logic signed [27:0] carry,
  output logic signed [27:0] result
);

  compressor_4to2 u_dut (
    .in0_i   (in0),
    .in1_i   (in1),
    .in2_i   (in2),
    .in3_i   (in3),
    .sum_o   (sum),
    .carry_o (carry)
  );

  always_comb begin
    result = sum + carry;
  end

endmodule

