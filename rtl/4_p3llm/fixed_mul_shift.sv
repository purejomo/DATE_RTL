// Combinational primitives used on either side of the stage-1 product
// register. Keeping multiply and shift as separate modules makes the pipeline
// cut explicit while retaining one source file for the lane arithmetic.

module fixed_mul_shift (
  input  logic signed [32'd5:32'd0]  lhs_i,
  input  logic signed [32'd5:32'd0]  rhs_i,
  output logic signed [32'd11:32'd0] raw_product_o
);

  always_comb begin
    raw_product_o = lhs_i * rhs_i;
  end

endmodule


/* verilator lint_off DECLFILENAME */
module fixed_product_shift (
  input  logic signed [32'd11:32'd0] raw_product_i,
  input  logic [32'd3:32'd0]         shift_i,
  output logic signed [32'd25:32'd0] shifted_product_o
);

  logic signed [32'd26:32'd0] widened_product;
  logic signed [32'd26:32'd0] shifted_wide;
  logic               unused_shift_overflow;

  always_comb begin
    widened_product   = {{32'd15{raw_product_i[32'd11]}}, raw_product_i};
    shifted_wide      = widened_product <<< shift_i;
    shifted_product_o = shifted_wide[32'd25:32'd0];
    unused_shift_overflow =
      shifted_wide[32'd26] ^ shifted_wide[32'd25];
  end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown({raw_product_i, shift_i})) begin
      assert (!unused_shift_overflow)
        else $error("fixed_product_shift: legal product exceeds 26 bits");
    end
  end
`endif
`endif

endmodule
/* verilator lint_on DECLFILENAME */
