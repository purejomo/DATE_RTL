// Combinational primitives used on either side of the stage-1 product
// register. Keeping multiply and shift as separate modules makes the pipeline
// cut explicit. The product-only companion is fixed_product_shift.sv.

module fixed_mul_shift (
  input  logic signed [32'd5:32'd0]  lhs_i,
  input  logic signed [32'd5:32'd0]  rhs_i,
  output logic signed [32'd11:32'd0] raw_product_o
);

  always_comb begin
    raw_product_o = lhs_i * rhs_i;
  end

endmodule
