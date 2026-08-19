// Standalone P3-LLM arithmetic PCU, axis-2 (acc16) build.
//
// Identical to rtl/3_p3llm/p3llm_pcu.sv except for the accumulator: every PE
// RNE-narrows its 28-bit partial sum to ACC_W bits before accumulating and
// holds ACC_W bits of state, so acc_out is 16 x 16 = 256 bits instead of 512.
// See p3llm_pe.sv for the narrow() definition and the ACC_RSH derivation.
//
// Flat-bus indexing:
//   input lane i       = input_fp8[i*8 +: 8]
//   PE p, RHS lane i   = rhs_q4[(p*4+i)*4 +: 4]
//   output PE p        = acc_out[p*ACC_W +: ACC_W]
module p3llm_pcu_acc16 #(
  parameter int unsigned ACC_W   = 32'd16,
  parameter int unsigned ACC_RSH = 32'd16
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          in_valid,
  output logic          in_ready,
  input  logic [32'd1:32'd0]    op_mode,
  input  logic          acc_clear,
  input  logic          acc_enable,
  input  logic [32'd31:32'd0]   input_fp8,
  input  logic [32'd255:32'd0]  rhs_q4,
  input  logic [32'd31:32'd0]   bitmod_special_sel,
  input  logic [32'd63:32'd0]   zp_by_pe,
  input  logic [32'd15:32'd0]   zp_by_lane,
  output logic          out_valid,
  // 32'd16 is p3llm_pkg::PCU_NUM_PES spelled as a literal: the package is
  // imported in the module body, so its items are not visible in the port
  // list. The 32-bit build writes the fully resolved literal 32'd511 here
  // for the same reason.
  output logic [(32'd16*ACC_W)-32'd1:32'd0]  acc_out
`ifdef P3LLM_DEBUG
  ,
  output logic [32'd383:32'd0]  debug_lhs_mantissa,
  output logic [32'd383:32'd0]  debug_rhs_value,
  output logic [32'd255:32'd0]  debug_shift,
  output logic [32'd767:32'd0]  debug_raw_product,
  output logic [32'd1663:32'd0] debug_shifted_product,
  output logic [32'd447:32'd0]  debug_partial_sum
`endif
);

  import p3llm_pkg::*;

  logic               unused_pe_out_valid
    [32'd0:PCU_NUM_PES-32'd1];
  logic signed [ACC_W-32'd1:32'd0] pe_acc_out
    [32'd0:PCU_NUM_PES-32'd1];
  logic [PCU_PIPELINE_STAGES-32'd1:32'd0] valid_pipeline_q;

  always_comb begin
    in_ready = rst_n;
    out_valid = valid_pipeline_q[PCU_EDGE_LATENCY_CYCLES];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_pipeline_q <= 4'b0000;
    end else begin
      valid_pipeline_q <=
        {
          valid_pipeline_q[
            PCU_EDGE_LATENCY_CYCLES-32'd1:32'd0
          ],
          in_valid
        };
    end
  end

  genvar pe_index;
  generate
    for (pe_index = 32'd0;
         pe_index < PCU_NUM_PES;
         pe_index = pe_index + 32'd1) begin : g_pe
      p3llm_pe #(
        .ACC_W   (ACC_W),
        .ACC_RSH (ACC_RSH)
      ) u_pe (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .in_valid_i               (in_valid),
        .op_mode_i                (op_mode),
        .acc_clear_i              (acc_clear),
        .acc_enable_i             (acc_enable),
        .input_fp8_i              (input_fp8),
        .rhs_q4_i                 (rhs_q4[pe_index*32'd16 +: 32'd16]),
        .bitmod_special_sel_i     (
          bitmod_special_sel[pe_index*32'd2 +: 32'd2]
        ),
        .zp_by_pe_i               (zp_by_pe[pe_index*32'd4 +: 32'd4]),
        .zp_by_lane_i             (zp_by_lane),
        .out_valid_o              (unused_pe_out_valid[pe_index]),
        .acc_out_o                (pe_acc_out[pe_index])
`ifdef P3LLM_DEBUG
        ,
        .debug_lhs_mantissa_o     (
          debug_lhs_mantissa[pe_index*32'd24 +: 32'd24]
        ),
        .debug_rhs_value_o        (
          debug_rhs_value[pe_index*32'd24 +: 32'd24]
        ),
        .debug_shift_o            (
          debug_shift[pe_index*32'd16 +: 32'd16]
        ),
        .debug_raw_product_o      (
          debug_raw_product[pe_index*32'd48 +: 32'd48]
        ),
        .debug_shifted_product_o  (
          debug_shifted_product[pe_index*32'd104 +: 32'd104]
        ),
        .debug_partial_sum_o      (
          debug_partial_sum[pe_index*32'd28 +: 32'd28]
        )
`endif
      );

      always_comb begin
        acc_out[pe_index*ACC_W +: ACC_W] = pe_acc_out[pe_index];
      end
    end
  endgenerate

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  integer valid_index;
  logic   reset_sampled_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      reset_sampled_q <= 1'b1;
    end else begin
      reset_sampled_q <= 1'b0;
      if (in_valid) begin
        assert (op_mode_is_valid(op_mode))
          else $error("p3llm_pcu: reserved op_mode accepted");
      end
    end
  end

  always @(negedge clk) begin
    if (!rst_n && reset_sampled_q) begin
      assert (acc_out == {(PCU_NUM_PES*ACC_W){1'b0}})
        else $error("p3llm_pcu: accumulator outputs nonzero during reset");
    end else if (rst_n) begin
      assert (out_valid == unused_pe_out_valid[32'd0])
        else $error("p3llm_pcu: valid pipeline and PE latency mismatch");
      for (valid_index = 32'd1;
           valid_index < PCU_NUM_PES;
           valid_index = valid_index + 32'd1) begin
        assert (unused_pe_out_valid[valid_index] ==
                unused_pe_out_valid[32'd0])
          else $error("p3llm_pcu: PE valid signals diverged");
      end
      if (out_valid) begin
        assert (!$isunknown(acc_out))
          else $error("p3llm_pcu: X/Z detected on valid accumulator output");
      end
    end
  end
`endif
`endif

endmodule
