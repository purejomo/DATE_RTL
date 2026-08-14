// OCP FP8-E4M3FN decoder.
//
// Output representation:
//   value = mantissa_o * 2 ** (shift_o - 11)
// mantissa_o is signed Q1.4-like integer data in six-bit two's complement.
// NaN encodings 0x7f/0xff contribute zero and assert invalid_o.
module fp8_e4m3_decoder (
  input  logic [32'd7:32'd0]        code_i,
  output logic signed [32'd5:32'd0] mantissa_o,
  output logic [32'd3:32'd0]        shift_o,
  output logic              zero_o,
  output logic              invalid_o
);

  logic       sign;
  logic [32'd3:32'd0] exponent;
  logic [32'd2:32'd0] fraction;
  logic [32'd4:32'd0] magnitude;

  always_comb begin
    sign       = code_i[32'd7];
    exponent   = code_i[32'd6:32'd3];
    fraction   = code_i[32'd2:32'd0];
    magnitude  = 5'b00000;
    mantissa_o = 6'sd0;
    shift_o    = 4'd0;
    zero_o     = 1'b0;
    invalid_o  = 1'b0;

    if ((exponent == 4'hf) && (fraction == 3'h7)) begin
      zero_o    = 1'b1;
      invalid_o = 1'b1;
    end else if ((exponent == 4'h0) && (fraction == 3'h0)) begin
      zero_o = 1'b1;
    end else begin
      if (exponent == 4'h0) begin
        // Gradual underflow: hidden bit is zero. The effective exponent is
        // the same as the minimum normal exponent.
        magnitude = {1'b0, fraction, 1'b0};
        shift_o   = 4'd1;
      end else begin
        magnitude = {1'b1, fraction, 1'b0};
        shift_o   = exponent;
      end

      if (sign) begin
        mantissa_o = -$signed({1'b0, magnitude});
      end else begin
        mantissa_o = $signed({1'b0, magnitude});
      end
    end
  end

endmodule
