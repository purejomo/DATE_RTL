module decoder_tb (
  input  logic [7:0]        e4m3_code,
  output logic signed [5:0] e4m3_mantissa,
  output logic [3:0]        e4m3_shift,
  output logic              e4m3_zero,
  output logic              e4m3_invalid,

  input  logic [7:0]        s0e4m4_code,
  output logic signed [5:0] s0e4m4_mantissa,
  output logic [3:0]        s0e4m4_shift,
  output logic              s0e4m4_zero,

  input  logic [3:0]        bitmod_code,
  input  logic [1:0]        bitmod_special_sel,
  output logic signed [5:0] bitmod_decoded,

  input  logic [3:0]        int4_code,
  input  logic [3:0]        int4_zero_point,
  output logic signed [5:0] int4_decoded
);

  fp8_e4m3_decoder u_e4m3 (
    .code_i     (e4m3_code),
    .mantissa_o (e4m3_mantissa),
    .shift_o    (e4m3_shift),
    .zero_o     (e4m3_zero),
    .invalid_o  (e4m3_invalid)
  );

  fp8_s0e4m4_decoder u_s0e4m4 (
    .code_i     (s0e4m4_code),
    .mantissa_o (s0e4m4_mantissa),
    .shift_o    (s0e4m4_shift),
    .zero_o     (s0e4m4_zero)
  );

  bitmod4_decoder u_bitmod (
    .code_i        (bitmod_code),
    .special_sel_i (bitmod_special_sel),
    .decoded_o     (bitmod_decoded)
  );

  int4_asym_decoder u_int4 (
    .code_i       (int4_code),
    .zero_point_i (int4_zero_point),
    .decoded_o    (int4_decoded)
  );

endmodule

