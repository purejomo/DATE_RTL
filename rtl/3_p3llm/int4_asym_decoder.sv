// Unsigned INT4-Asymmetric decoder.
//
// The subtraction is explicitly widened to signed five bits before the result
// is sign-extended to the common signed six-bit multiplier input.
module int4_asym_decoder (
  input  logic [32'd3:32'd0]        code_i,
  input  logic [32'd3:32'd0]        zero_point_i,
  output logic signed [32'd5:32'd0] decoded_o
);

  logic signed [32'd4:32'd0] difference;

  always_comb begin
    difference = $signed({1'b0, code_i}) -
                 $signed({1'b0, zero_point_i});
    decoded_o = {difference[32'd4], difference};
  end

endmodule
