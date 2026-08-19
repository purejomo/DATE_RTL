`timescale 1ns/1ps

// Running minimum and maximum over a stream of binary32 values.
//
// This is the whole of pass 1. SpinQuant quantizes activations per token with
// asymmetric min-max, so the next layer's scale needs the extreme values of the
// entire output row -- which spans banks and PCUs. One PCU sees NLANE of them,
// so it reduces its own lanes and hands two scalars to the NPU, which finishes
// the reduction globally. Two scalars per PCU is nothing next to the row
// itself, which is the point: the wide data never leaves.
//
// Comparison without a floating-point comparator. For binary32 the bit pattern
// read as a signed magnitude is monotonic in the value, so the standard total
// order key
//
//     key = fp32[31] ? ~fp32 : (fp32 | 32'h8000_0000)
//
// turns the comparison into one unsigned compare. It is exact for every finite
// input and for both infinities; NaN sorts above +inf, which is acceptable
// because a NaN anywhere in the row already invalidates the token's scale and
// the dequantizer reports it separately.
module spinquant_rq_minmax (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        clear_i,       // start a new reduction
    input  logic        valid_i,
    input  logic [31:0] fp32_i,

    output logic [31:0] min_o,
    output logic [31:0] max_o
);

    logic [31:0] key;
    logic [31:0] min_q;
    logic [31:0] max_q;
    logic [31:0] min_key_q;
    logic [31:0] max_key_q;
    logic        seen_q;

    always_comb key = fp32_i[31] ? ~fp32_i : (fp32_i | 32'h8000_0000);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            min_q     <= 32'd0;
            max_q     <= 32'd0;
            min_key_q <= 32'd0;
            max_key_q <= 32'd0;
            seen_q    <= 1'b0;
        end else if (clear_i) begin
            seen_q    <= 1'b0;
        end else if (valid_i) begin
            if (!seen_q) begin
                min_q     <= fp32_i;
                max_q     <= fp32_i;
                min_key_q <= key;
                max_key_q <= key;
                seen_q    <= 1'b1;
            end else begin
                if (key < min_key_q) begin
                    min_q     <= fp32_i;
                    min_key_q <= key;
                end
                if (key > max_key_q) begin
                    max_q     <= fp32_i;
                    max_key_q <= key;
                end
            end
        end
    end

    always_comb begin
        min_o = min_q;
        max_o = max_q;
    end

endmodule
