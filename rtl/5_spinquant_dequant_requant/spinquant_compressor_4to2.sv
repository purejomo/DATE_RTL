`timescale 1ns/1ps

// Four-input carry-save reduction, parameterized in width.
//
// Two explicit 3:2 compressor levels. carry_o is already shifted left by one
// bit, so a downstream adder computes sum_o + carry_o. Both outputs are W bits
// wide and the left shifts drop the top bit, which makes the whole reduction
// modulo 2**W. That is what the PE wants: every partial sum a W4A4 dot product
// can legally produce fits in W bits, so the wrapping intermediates cancel.
//
// Same shape as rtl/4_rabit/rabit_compressor_4to2.sv. It is copied rather than
// shared because every design directory in this repo is self-contained -- the
// synthesis flow hands sv2v one directory's file list at a time.
module spinquant_compressor_4to2 #(
    parameter int W = 10
) (
    input  logic [W-1:0] in0_i,
    input  logic [W-1:0] in1_i,
    input  logic [W-1:0] in2_i,
    input  logic [W-1:0] in3_i,
    output logic [W-1:0] sum_o,
    output logic [W-1:0] carry_o
);

    logic [W-1:0] level1_sum;
    logic [W-1:0] level1_carry;

    always_comb begin
        level1_sum   = in0_i ^ in1_i ^ in2_i;
        level1_carry = ((in0_i & in1_i) |
                        (in0_i & in2_i) |
                        (in1_i & in2_i)) << 1;

        sum_o   = level1_sum ^ level1_carry ^ in3_i;
        carry_o = ((level1_sum & level1_carry) |
                   (level1_sum & in3_i) |
                   (level1_carry & in3_i)) << 1;
    end

endmodule
