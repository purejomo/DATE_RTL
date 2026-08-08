// P3-LLM unsigned FP8-S0E4M4 decoder.
//
// code_i = {exponent[3:0], fraction[3:0]}
// value  = mantissa_o * 2 ** (shift_o - 19)
// All 256 raw codes have a finite mathematical interpretation. The intended
// attention-score workload is bounded by code 8'hf0 (1.0).
module fp8_s0e4m4_decoder (
  input  logic [32'd7:32'd0]        code_i,
  output logic signed [32'd5:32'd0] mantissa_o,
  output logic [32'd3:32'd0]        shift_o,
  output logic              zero_o
);

  logic [32'd3:32'd0] exponent;
  logic [32'd3:32'd0] fraction;

  always_comb begin
    exponent   = code_i[32'd7:32'd4];
    fraction   = code_i[32'd3:32'd0];
    mantissa_o = 6'sd0;
    shift_o    = 4'd0;
    zero_o     = 1'b0;

    if ((exponent == 4'h0) && (fraction == 4'h0)) begin
      zero_o = 1'b1;
    end else if (exponent == 4'h0) begin
      mantissa_o = $signed({2'b00, fraction});
      shift_o    = 4'd1;
    end else begin
      mantissa_o = $signed({1'b0, 1'b1, fraction});
      shift_o    = exponent;
    end
  end

endmodule
