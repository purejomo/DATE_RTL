`timescale 1ns/1ps

// The architectural accumulator file: NENTRY entries of NLANE x ACC_W bits.
//
// NLANE is NROW*NPE at the top: every activation row that shares a weight beat
// spatially needs accumulators of its own, so the file grows with the reuse
// factor rather than with the multiplier count.
//
// With the delivered geometry that is 4 entries x 16 lanes x 32 bits, which is
// the accumulator half of the HBM-PIM GRF as P3-LLM reads it (input register
// 16b x 16 lane x 4 entry, accumulator register 32b x 16 lane x 4 entry). It is
// inside the synthesis boundary because a k sweep has to keep every partial sum
// resident from the first RD of a row-buffer streak to the MAC-drain at the end
// of it: that is arithmetic state, not a buffer that could be argued away.
//
// Three ports, all entry-granular:
//
//   rd_sel_i / rd_data_o        the accumulate read. Combinational out of the
//                               registers, so a read-modify-write costs one
//                               cycle and back-to-back MACs into the same entry
//                               need no bypass -- the write lands on the edge
//                               that ends the cycle and the next read sees it.
//   drain_sel_i / drain_data_o  a second, non-destructive read used by
//                               MAC-drain. It is separate from the accumulate
//                               read so a drain never has to displace a compute
//                               cycle; the four entries are what let the two
//                               2-pump input rows drain independently.
//   wr_en_i / wr_sel_i / wr_data_i   the accumulate write-back.
//
// Entry allocation with the delivered geometry is 2 input rows x 2 output
// channel groups; see docs/spinquant_pcu_spec.md.
module spinquant_acc_regfile #(
    parameter int NLANE  = 16,
    parameter int NENTRY = 4,
    parameter int ACC_W  = 32,
    // derived; do not override
    parameter int SEL_W  = $clog2(NENTRY),
    parameter int ENT_W  = NLANE*ACC_W
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic [SEL_W-1:0]    rd_sel_i,
    output logic [ENT_W-1:0]    rd_data_o,

    input  logic [SEL_W-1:0]    drain_sel_i,
    output logic [ENT_W-1:0]    drain_data_o,

    input  logic                wr_en_i,
    input  logic [SEL_W-1:0]    wr_sel_i,
    input  logic [ENT_W-1:0]    wr_data_i
);

    logic [ENT_W-1:0] entry [0:NENTRY-1];

    always_comb rd_data_o    = entry[rd_sel_i];
    always_comb drain_data_o = entry[drain_sel_i];

    integer ei;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (ei = 0; ei < NENTRY; ei = ei + 1) begin
                entry[ei] <= {ENT_W{1'b0}};
            end
        end else if (wr_en_i) begin
            entry[wr_sel_i] <= wr_data_i;
        end
    end

endmodule
