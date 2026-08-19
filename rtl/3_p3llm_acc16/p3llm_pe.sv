// One P3-LLM processing element: four signed 6x6 multiplier lanes,
// exponent shifts, a carry-save four-input reduction, and a signed ACC_W-bit
// fixed-point accumulator.
//
// Axis-2 (acc16) build. Against rtl/3_p3llm the decoders, the four physical
// 6x6 multipliers, the exponent shifters, the 4:2 compressor and the final CPA
// are bit-identical; the single change is that the 28-bit partial sum is
// rounded to nearest, ties to even, down to ACC_W bits before it is added, and
// the architectural accumulator holds ACC_W bits instead of 32.
//
//   narrow(x, n):
//       round_bit = x[n-1]
//       sticky    = |x[n-2:0]
//       round_up  = round_bit & (sticky | x[n])      // tie -> even
//       y         = (x >>> n) + round_up             // arithmetic shift
//       return saturate_to_signed(y, ACC_W)
//
// Rounding rather than truncating matters because the discarded bits are
// discarded on every accumulation: truncation biases each one toward -inf by
// up to one LSB and the bias is systematic, so it accumulates in one direction
// over a whole quantization group. The accumulate itself still saturates, and
// no new status bit is exported -- the 32-bit build saturates silently too, and
// the three axes are only comparable if they report the same thing.
//
// ACC_RSH is one value for all three op modes rather than one per mode. A
// per-mode shift would need a mux in the accumulate path, which is exactly the
// logic this axis is trying to price; the shift amount itself is wiring.
//
// Deriving the default. The binary point differs per mode (OP_LINEAR 2^-12,
// OP_QK 2^-11, OP_PV 2^-19), but ACC_RSH is a shift on the raw integer, so what
// bounds it is the raw integer's worst case, which is nearly the same in all
// three modes:
//
//   OP_LINEAR  |E4M3 mantissa| <= 30, shift <= 15, |BitMoD FP4| <= 16
//              => |shifted product| <= 480 << 15, and a 128-element group
//                 (4 lanes x 32 accepted tiles) <= 2,013,265,920 < 2^31
//   OP_QK      |INT4 asym| <= 15  => group <= 1,887,436,800
//   OP_PV      |S0E4M4 mantissa| <= 31, |INT4 asym| <= 15
//                                  => group <= 1,950,351,360
//
// 2,013,265,920 >> 16 = 30,720, which fits signed 16 bits; >> 15 would not.
// So ACC_RSH = 16 is the smallest shift for which a full group can never
// saturate in any mode -- equivalently, acc16 keeps the top 16 bits of the
// 32-bit build's accumulator. That is a worst-case bound, not an accuracy
// optimum: real activations are far below it and a smaller shift would keep
// more low-order precision. Sweeping it is an accuracy question and costs no
// area, since the shift is wiring.
module p3llm_pe #(
  parameter int unsigned ACC_W   = 32'd16,
  parameter int unsigned ACC_RSH = 32'd16
) (
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
  output logic signed [ACC_W-32'd1:32'd0]  acc_out_o
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

  // Stage 3: one final CPA, the RNE narrow, then the architectural
  // accumulator.
  localparam int unsigned PSUM_W = 32'd28;

  logic signed [PSUM_W-32'd1:32'd0] partial_sum_comb;
  logic        [PSUM_W-32'd1:32'd0] partial_bits_comb;
  logic                             narrow_round_bit;
  logic                             narrow_sticky;
  logic                             narrow_round_up;
  logic signed [PSUM_W-32'd1:32'd0] narrow_shifted_comb;
  logic signed [PSUM_W:32'd0]       narrow_wide_comb;
  logic                             narrow_overflow;
  logic signed [ACC_W-32'd1:32'd0]  narrowed_comb;
  logic signed [ACC_W:32'd0]        accumulator_add_comb;
  logic signed [ACC_W-32'd1:32'd0]  accumulator_next_comb;
  logic                             accumulator_overflow;

  // Low bits the accumulator does not keep, for the sticky term.
  localparam logic [PSUM_W-32'd1:32'd0] STICKY_MASK =
    ((PSUM_W'(32'd1) << (ACC_RSH - 32'd1)) - PSUM_W'(32'd1));

  always_comb begin
    partial_sum_comb  = s2_sum_q + s2_carry_q;
    partial_bits_comb = partial_sum_comb;

    narrow_round_bit = partial_bits_comb[ACC_RSH - 32'd1];
    narrow_sticky    = |(partial_bits_comb & STICKY_MASK);
    narrow_round_up  =
      narrow_round_bit & (narrow_sticky | partial_bits_comb[ACC_RSH]);

    narrow_shifted_comb = partial_sum_comb >>> ACC_RSH;
    narrow_wide_comb =
      $signed({narrow_shifted_comb[PSUM_W-32'd1], narrow_shifted_comb}) +
      $signed({{PSUM_W{1'b0}}, narrow_round_up});

    // The rounded value fits ACC_W bits only when every bit above the
    // destination sign position repeats it.
    narrow_overflow = ~((&narrow_wide_comb[PSUM_W:ACC_W-32'd1]) |
                        (~|narrow_wide_comb[PSUM_W:ACC_W-32'd1]));
    if (narrow_overflow) begin
      narrowed_comb = narrow_wide_comb[PSUM_W]
        ? {1'b1, {(ACC_W-32'd1){1'b0}}}
        : {1'b0, {(ACC_W-32'd1){1'b1}}};
    end else begin
      narrowed_comb = narrow_wide_comb[ACC_W-32'd1:32'd0];
    end

    accumulator_add_comb =
      $signed({acc_out_o[ACC_W-32'd1], acc_out_o}) +
      $signed({narrowed_comb[ACC_W-32'd1], narrowed_comb});
    accumulator_overflow =
      accumulator_add_comb[ACC_W] ^ accumulator_add_comb[ACC_W-32'd1];
    // The wide sum is not truncated back: an overflow saturates, which bounds
    // the error instead of inverting the result.
    if (accumulator_overflow) begin
      accumulator_next_comb = accumulator_add_comb[ACC_W]
        ? {1'b1, {(ACC_W-32'd1){1'b0}}}
        : {1'b0, {(ACC_W-32'd1){1'b1}}};
    end else begin
      accumulator_next_comb = accumulator_add_comb[ACC_W-32'd1:32'd0];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_o <= 1'b0;
      acc_out_o   <= {ACC_W{1'b0}};
    end else begin
      out_valid_o <= s2_valid_q;
      if (s2_valid_q) begin
        if (s2_acc_clear_q) begin
          acc_out_o <= narrowed_comb;
        end else if (s2_acc_enable_q) begin
          acc_out_o <= accumulator_next_comb;
        end
      end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
      if (s2_valid_q && !s2_acc_clear_q && s2_acc_enable_q) begin
        assert (!accumulator_overflow)
          else $error("p3llm_pe: signed narrow accumulator overflow");
      end
`endif
`endif
    end
  end

`ifdef P3LLM_ASSERTIONS
`ifndef SYNTHESIS
  logic              hold_check_q;
  logic signed [ACC_W-32'd1:32'd0] hold_value_q;
  logic              reset_sampled_q;
  integer assertion_index;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hold_check_q    <= 1'b0;
      hold_value_q    <= {ACC_W{1'b0}};
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
      assert (acc_out_o == {ACC_W{1'b0}})
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
