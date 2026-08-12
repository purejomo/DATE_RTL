// Four-input carry-save reduction.
//
// Inputs are signed 26-bit two's-complement numbers. They are sign-extended
// to 28 bits, then reduced by two explicit 3:2 compressor levels. carry_o is
// already shifted left by one bit. A downstream CPA computes sum_o + carry_o.
module compressor_4to2 (
  input  logic signed [25:0] in0_i,
  input  logic signed [25:0] in1_i,
  input  logic signed [25:0] in2_i,
  input  logic signed [25:0] in3_i,
  output logic signed [27:0] sum_o,
  output logic signed [27:0] carry_o
);

  logic [27:0] operand0;
  logic [27:0] operand1;
  logic [27:0] operand2;
  logic [27:0] operand3;
  logic [27:0] level1_sum;
  logic [27:0] level1_carry;

  always_comb begin
    operand0 = {{32'd2{in0_i[32'd25]}}, in0_i};
    operand1 = {{32'd2{in1_i[32'd25]}}, in1_i};
    operand2 = {{32'd2{in2_i[32'd25]}}, in2_i};
    operand3 = {{32'd2{in3_i[32'd25]}}, in3_i};

    level1_sum   = operand0 ^ operand1 ^ operand2;
    level1_carry = ((operand0 & operand1) |
                    (operand0 & operand2) |
                    (operand1 & operand2)) << 5'd1;

    sum_o   = level1_sum ^ level1_carry ^ operand3;
    carry_o = ((level1_sum & level1_carry) |
               (level1_sum & operand3) |
               (level1_carry & operand3)) << 5'd1;
  end

endmodule
