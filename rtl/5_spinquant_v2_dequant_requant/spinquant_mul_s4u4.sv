`timescale 1ns/1ps

// One SpinQuant W4A4 product: signed INT4 weight times unsigned INT4
// activation.
//
//     w in [-8, 7]   GPTQ per-channel symmetric weight, R1/R2 already merged
//     a in [0, 15]   per-token asymmetric min-max activation, zero point folded
//                    into the NPU bias
//     w*a in [-120, 105]
//
// The whole product range fits a signed 8-bit result, so the 9-bit result of
// the 4x5 signed multiply is truncated to 8 bits and that truncation is exact.
// SPINQUANT_ASSERTIONS checks the discarded bit is the sign it claims to be.
//
// This is the only arithmetic primitive in the design. There is no exponent, no
// mantissa alignment, no zero-point subtract and no scale multiply anywhere on
// this path: the weight scale s_w, the activation scale s_a and the
// beta * sum(W_row) bias correction are all applied by the NPU after the drain.
module spinquant_mul_s4u4 (
    input  logic signed [3:0] w_i,
    input  logic        [3:0] a_i,
    output logic signed [7:0] p_o
);

    logic signed [8:0] full;

    always_comb begin
        full = $signed(w_i) * $signed({1'b0, a_i});
        p_o  = full[7:0];
    end

`ifdef SPINQUANT_ASSERTIONS
`ifndef SYNTHESIS
    always_comb begin
        if (!$isunknown({w_i, a_i})) begin
            assert (full[8] == full[7])
                else $error("spinquant_mul_s4u4: product %0d exceeds 8 bits",
                            full);
        end
    end
`endif
`endif

endmodule
