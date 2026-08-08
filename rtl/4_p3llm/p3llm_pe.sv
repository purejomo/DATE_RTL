// One P3-LLM processing element: four signed 6x6 multiplier lanes,
// exponent shifts, a carry-save four-input reduction, and a signed 32-bit
// fixed-point accumulator.
module p3llm_pe (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                in_valid_i,
  input  logic [32'd1:32'd0]          op_mode_i,
  input  logic                acc_clear_i,
  input  logic                acc_enable_i,
  input  logic [32'd31:32'd0]         input_fp8_i,
  input  logic [32'd15:32'd0]         rhs_q4_i,
  input  logic [32'd1:32'd0]          bitmod_special_sel_i,
  input  logic [32'd3:32'd0]          zp_by_pe_i,
  input  logic [32'd15:32'd0]         zp_by_lane_i,
  output logic                out_valid_o,
  output logic signed [32'd31:32'd0]  acc_out_o
`ifdef P3LLM_DEBUG
  ,
  output logic [32'd23:32'd0]         debug_lhs_mantissa_o,
  output logic [32'd23:32'd0]         debug_rhs_value_o,
  output logic [32'd15:32'd0]         debug_shift_o,
  output logic [32'd47:32'd0]         debug_raw_product_o,
  output logic [32'd103:32'd0]        debug_shifted_product_o,
  output logic [32'd27:32'd0]         debug_partial_sum_o
`endif
);

  import p3llm_pkg::*;

  logic signed [32'd5:32'd0] e4m3_mantissa
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]        e4m3_shift
    [32'd0:PE_NUM_LANES-32'd1];
  logic              e4m3_zero
    [32'd0:PE_NUM_LANES-32'd1];
  logic              e4m3_invalid
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd5:32'd0] s0e4m4_mantissa
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]        s0e4m4_shift
    [32'd0:PE_NUM_LANES-32'd1];
  logic              s0e4m4_zero
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd5:32'd0] bitmod_value
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd5:32'd0] int4_value
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]        selected_zero_point
    [32'd0:PE_NUM_LANES-32'd1];

  logic signed [32'd5:32'd0] decoded_lhs
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd5:32'd0] decoded_rhs
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]        decoded_shift
    [32'd0:PE_NUM_LANES-32'd1];
  logic              decoded_invalid
    [32'd0:PE_NUM_LANES-32'd1];

  genvar decoder_lane;
  generate
    for (decoder_lane = 32'd0;
         decoder_lane < PE_NUM_LANES;
         decoder_lane = decoder_lane + 32'd1) begin : g_decoder
      fp8_e4m3_decoder u_e4m3_decoder (
        .code_i     (input_fp8_i[decoder_lane*32'd8 +: 32'd8]),
        .mantissa_o (e4m3_mantissa[decoder_lane]),
        .shift_o    (e4m3_shift[decoder_lane]),
        .zero_o     (e4m3_zero[decoder_lane]),
        .invalid_o  (e4m3_invalid[decoder_lane])
      );

      fp8_s0e4m4_decoder u_s0e4m4_decoder (
        .code_i     (input_fp8_i[decoder_lane*32'd8 +: 32'd8]),
        .mantissa_o (s0e4m4_mantissa[decoder_lane]),
        .shift_o    (s0e4m4_shift[decoder_lane]),
        .zero_o     (s0e4m4_zero[decoder_lane])
      );

      bitmod4_decoder u_bitmod_decoder (
        .code_i        (rhs_q4_i[decoder_lane*32'd4 +: 32'd4]),
        .special_sel_i (bitmod_special_sel_i),
        .decoded_o     (bitmod_value[decoder_lane])
      );

      int4_asym_decoder u_int4_decoder (
        .code_i       (rhs_q4_i[decoder_lane*32'd4 +: 32'd4]),
        .zero_point_i (selected_zero_point[decoder_lane]),
        .decoded_o    (int4_value[decoder_lane])
      );
    end
  endgenerate

  integer decode_index;
  always_comb begin
    for (decode_index = 32'd0;
         decode_index < PE_NUM_LANES;
         decode_index = decode_index + 32'd1) begin
      if (op_mode_i == OP_QK) begin
        selected_zero_point[decode_index] = zp_by_pe_i;
      end else begin
        selected_zero_point[decode_index] =
          zp_by_lane_i[decode_index*32'd4 +: 32'd4];
      end

      decoded_lhs[decode_index]     = 6'sd0;
      decoded_rhs[decode_index]     = 6'sd0;
      decoded_shift[decode_index]   = 4'd0;
      decoded_invalid[decode_index] = 1'b0;

      case (op_mode_i)
        OP_LINEAR: begin
          decoded_lhs[decode_index]     = e4m3_mantissa[decode_index];
          decoded_rhs[decode_index]     = bitmod_value[decode_index];
          decoded_shift[decode_index]   = e4m3_shift[decode_index];
          decoded_invalid[decode_index] = e4m3_invalid[decode_index];
        end
        OP_QK: begin
          decoded_lhs[decode_index]     = e4m3_mantissa[decode_index];
          decoded_rhs[decode_index]     = int4_value[decode_index];
          decoded_shift[decode_index]   = e4m3_shift[decode_index];
          decoded_invalid[decode_index] = e4m3_invalid[decode_index];
        end
        OP_PV: begin
          decoded_lhs[decode_index]     = s0e4m4_mantissa[decode_index];
          decoded_rhs[decode_index]     = int4_value[decode_index];
          decoded_shift[decode_index]   = s0e4m4_shift[decode_index];
          decoded_invalid[decode_index] = 1'b0;
        end
        default: begin
          decoded_lhs[decode_index]     = 6'sd0;
          decoded_rhs[decode_index]     = 6'sd0;
          decoded_shift[decode_index]   = 4'd0;
          decoded_invalid[decode_index] = 1'b1;
        end
      endcase
    end
  end

  // Stage 0: decoded operand and control registers.
  logic              s0_valid_q;
  logic              s0_acc_clear_q;
  logic              s0_acc_enable_q;
  logic signed [32'd5:32'd0] s0_lhs_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd5:32'd0] s0_rhs_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]        s0_shift_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic              s0_invalid_q
    [32'd0:PE_NUM_LANES-32'd1];

  integer s0_index;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s0_valid_q      <= 1'b0;
      s0_acc_clear_q  <= 1'b0;
      s0_acc_enable_q <= 1'b0;
      for (s0_index = 32'd0;
           s0_index < PE_NUM_LANES;
           s0_index = s0_index + 32'd1) begin
        s0_lhs_q[s0_index]     <= 6'sd0;
        s0_rhs_q[s0_index]     <= 6'sd0;
        s0_shift_q[s0_index]   <= 4'd0;
        s0_invalid_q[s0_index] <= 1'b0;
      end
    end else begin
      s0_valid_q      <= in_valid_i;
      s0_acc_clear_q  <= acc_clear_i;
      s0_acc_enable_q <= acc_enable_i;
      for (s0_index = 32'd0;
           s0_index < PE_NUM_LANES;
           s0_index = s0_index + 32'd1) begin
        s0_lhs_q[s0_index]     <= decoded_lhs[s0_index];
        s0_rhs_q[s0_index]     <= decoded_rhs[s0_index];
        s0_shift_q[s0_index]   <= decoded_shift[s0_index];
        s0_invalid_q[s0_index] <= decoded_invalid[s0_index];
      end
    end
  end

  // Stage 1: four physical signed 6x6 multipliers.
  logic signed [32'd11:32'd0] raw_product_comb
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd11:32'd0] s1_raw_product_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic [32'd3:32'd0]         s1_shift_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic               s1_invalid_q
    [32'd0:PE_NUM_LANES-32'd1];
  logic               s1_valid_q;
  logic               s1_acc_clear_q;
  logic               s1_acc_enable_q;

  genvar multiplier_lane;
  generate
    for (multiplier_lane = 32'd0;
         multiplier_lane < PE_NUM_LANES;
         multiplier_lane = multiplier_lane + 32'd1) begin : g_multiplier
      fixed_mul_shift u_fixed_mul (
        .lhs_i         (s0_lhs_q[multiplier_lane]),
        .rhs_i         (s0_rhs_q[multiplier_lane]),
        .raw_product_o (raw_product_comb[multiplier_lane])
      );
    end
  endgenerate

  integer s1_index;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid_q      <= 1'b0;
      s1_acc_clear_q  <= 1'b0;
      s1_acc_enable_q <= 1'b0;
      for (s1_index = 32'd0;
           s1_index < PE_NUM_LANES;
           s1_index = s1_index + 32'd1) begin
        s1_raw_product_q[s1_index] <= 12'sd0;
        s1_shift_q[s1_index]       <= 4'd0;
        s1_invalid_q[s1_index]     <= 1'b0;
      end
    end else begin
      s1_valid_q      <= s0_valid_q;
      s1_acc_clear_q  <= s0_acc_clear_q;
      s1_acc_enable_q <= s0_acc_enable_q;
      for (s1_index = 32'd0;
           s1_index < PE_NUM_LANES;
           s1_index = s1_index + 32'd1) begin
        s1_raw_product_q[s1_index] <= raw_product_comb[s1_index];
        s1_shift_q[s1_index]       <= s0_shift_q[s1_index];
        s1_invalid_q[s1_index]     <= s0_invalid_q[s1_index];
      end
    end
  end

  // Stage 2: exact exponent shifts and carry-save compression.
  logic signed [32'd25:32'd0] shifted_product_comb
    [32'd0:PE_NUM_LANES-32'd1];
  logic signed [32'd27:32'd0] compressor_sum_comb;
  logic signed [32'd27:32'd0] compressor_carry_comb;
  logic signed [32'd27:32'd0] s2_sum_q;
  logic signed [32'd27:32'd0] s2_carry_q;
  logic               s2_valid_q;
  logic               s2_acc_clear_q;
  logic               s2_acc_enable_q;

  genvar shifter_lane;
  generate
    for (shifter_lane = 32'd0;
         shifter_lane < PE_NUM_LANES;
         shifter_lane = shifter_lane + 32'd1) begin : g_shifter
      fixed_product_shift u_product_shift (
        .raw_product_i     (s1_raw_product_q[shifter_lane]),
        .shift_i           (s1_shift_q[shifter_lane]),
        .shifted_product_o (shifted_product_comb[shifter_lane])
      );
    end
  endgenerate

  compressor_4to2 u_compressor (
    .in0_i   (shifted_product_comb[32'd0]),
    .in1_i   (shifted_product_comb[32'd1]),
    .in2_i   (shifted_product_comb[32'd2]),
    .in3_i   (shifted_product_comb[32'd3]),
    .sum_o   (compressor_sum_comb),
    .carry_o (compressor_carry_comb)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_valid_q      <= 1'b0;
      s2_acc_clear_q  <= 1'b0;
      s2_acc_enable_q <= 1'b0;
      s2_sum_q        <= 28'sd0;
      s2_carry_q      <= 28'sd0;
    end else begin
      s2_valid_q      <= s1_valid_q;
      s2_acc_clear_q  <= s1_acc_clear_q;
      s2_acc_enable_q <= s1_acc_enable_q;
      s2_sum_q        <= compressor_sum_comb;
      s2_carry_q      <= compressor_carry_comb;
    end
  end

  // Stage 3: one final CPA followed by the architectural accumulator.
  logic signed [32'd27:32'd0] partial_sum_comb;
  logic signed [32'd31:32'd0] partial_sum_32_comb;
  logic signed [32'd32:32'd0] accumulator_add_comb;
  logic               unused_accumulator_overflow;

  always_comb begin
    partial_sum_comb    = s2_sum_q + s2_carry_q;
    partial_sum_32_comb =
      {{32'd4{partial_sum_comb[32'd27]}}, partial_sum_comb};
    accumulator_add_comb =
      $signed({acc_out_o[32'd31], acc_out_o}) +
      $signed({
        partial_sum_32_comb[32'd31],
        partial_sum_32_comb
      });
    unused_accumulator_overflow =
      accumulator_add_comb[32'd32] ^ accumulator_add_comb[32'd31];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_o <= 1'b0;
      acc_out_o   <= 32'sd0;
    end else begin
      out_valid_o <= s2_valid_q;
      if (s2_valid_q) begin
        if (s2_acc_clear_q) begin
          acc_out_o <= partial_sum_32_comb;
        end else if (s2_acc_enable_q) begin
          acc_out_o <= accumulator_add_comb[32'd31:32'd0];
        end
      end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
      if (s2_valid_q && !s2_acc_clear_q && s2_acc_enable_q) begin
        assert (!unused_accumulator_overflow)
          else $error("p3llm_pe: signed 32-bit accumulator overflow");
      end
`endif
`endif
    end
  end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  logic              hold_check_q;
  logic signed [32'd31:32'd0] hold_value_q;
  logic              reset_sampled_q;
  integer assertion_index;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hold_check_q    <= 1'b0;
      hold_value_q    <= 32'sd0;
      reset_sampled_q <= 1'b1;
    end else begin
      hold_check_q    <= s2_valid_q && !s2_acc_clear_q && !s2_acc_enable_q;
      hold_value_q    <= acc_out_o;
      reset_sampled_q <= 1'b0;
      if (s1_valid_q) begin
        for (assertion_index = 32'd0;
             assertion_index < PE_NUM_LANES;
             assertion_index = assertion_index + 32'd1) begin
          if (s1_invalid_q[assertion_index]) begin
            assert (s1_raw_product_q[assertion_index] == 12'sd0)
              else $error("p3llm_pe: invalid FP8 did not map to zero");
          end
        end
      end
    end
  end

  always @(negedge clk) begin
    if (!rst_n && reset_sampled_q) begin
      assert (acc_out_o == 32'sd0)
        else $error("p3llm_pe: accumulator is nonzero during reset");
    end else if (rst_n && hold_check_q) begin
      assert (acc_out_o == hold_value_q)
        else $error("p3llm_pe: accumulator changed while disabled");
    end
  end
`endif
`endif

`ifdef P3LLM_DEBUG
  genvar debug_lane;
  generate
    for (debug_lane = 32'd0;
         debug_lane < PE_NUM_LANES;
         debug_lane = debug_lane + 32'd1) begin : g_debug
      always_comb begin
        debug_lhs_mantissa_o[debug_lane*32'd6 +: 32'd6] =
          s0_lhs_q[debug_lane];
        debug_rhs_value_o[debug_lane*32'd6 +: 32'd6] =
          s0_rhs_q[debug_lane];
        debug_shift_o[debug_lane*32'd4 +: 32'd4] =
          s0_shift_q[debug_lane];
        debug_raw_product_o[debug_lane*32'd12 +: 32'd12] =
          s1_raw_product_q[debug_lane];
        debug_shifted_product_o[debug_lane*32'd26 +: 32'd26] =
          shifted_product_comb[debug_lane];
      end
    end
  endgenerate

  always_comb begin
    debug_partial_sum_o = partial_sum_comb;
  end
`endif

  // Keep decoder zero outputs visible to lint without adding functional logic.
  logic unused_decoder_zero;
  always_comb begin
    unused_decoder_zero = e4m3_zero[32'd0] ^ e4m3_zero[32'd1] ^
                          e4m3_zero[32'd2] ^ e4m3_zero[32'd3] ^
                          s0e4m4_zero[32'd0] ^ s0e4m4_zero[32'd1] ^
                          s0e4m4_zero[32'd2] ^ s0e4m4_zero[32'd3] ^
                          s1_invalid_q[32'd0] ^ s1_invalid_q[32'd1] ^
                          s1_invalid_q[32'd2] ^ s1_invalid_q[32'd3];
  end

endmodule
