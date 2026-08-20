

/* verilator lint_off DECLFILENAME */
module fixed_product_shift (
  input  logic signed [32'd11:32'd0] raw_product_i,
  input  logic [32'd3:32'd0]         shift_i,
  output logic signed [32'd25:32'd0] shifted_product_o
);

  // A left shift that pushes the product past 26 bits used to drop bit 26 and
  // report it only through a simulation assertion, which costs nothing in
  // silicon: the shipped design returned a wrapped value with no way to notice.
  // It now saturates to the extreme representable value instead, so an
  // out-of-range shift degrades the result rather than inverting its sign.
  logic signed [32'd26:32'd0] widened_product;
  logic signed [32'd26:32'd0] shifted_wide;
  logic                       shift_overflow;

  always_comb begin
    widened_product = {{32'd15{raw_product_i[32'd11]}}, raw_product_i};
    shifted_wide    = widened_product <<< shift_i;
    shift_overflow  = shifted_wide[32'd26] ^ shifted_wide[32'd25];
    if (shift_overflow) begin
      shifted_product_o = shifted_wide[32'd26]
        ? {1'b1, {32'd25{1'b0}}}    // most negative
        : {1'b0, {32'd25{1'b1}}};   // most positive
    end else begin
      shifted_product_o = shifted_wide[32'd25:32'd0];
    end
  end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown({raw_product_i, shift_i})) begin
      assert (!shift_overflow)
        else $error("fixed_product_shift: legal product exceeds 26 bits");
    end
  end
`endif
`endif

endmodule
