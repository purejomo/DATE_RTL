`timescale 1ns/1ps

// The architectural accumulator array: NSLOT x NPE registers of ACC_W bits.
//
// With the default geometry that is 4 output groups x 2 residual paths = 8
// slots, each slot holding the 8 outputs a column word covers, so 64 x 32b.
// This is the one storage array inside the synthesis boundary: everything the
// PCU accumulates has to stay resident across a whole k sweep, so it is part of
// the arithmetic cost rather than a buffer that could be argued away.
//
// One read port and one write port, both slot-granular. A read-modify-write
// cycle drives rd_sel_i and wr_sel_i with the same slot; the PEs sit in between
// and supply wr_data_i. Draining reuses both ports -- the controller reads a
// slot out and writes zeros back into it in the same cycle -- which is why
// there is no separate drain port here and why a drain may not overlap a
// compute cycle.
module rabit_acc_regfile #(
    parameter int NPE   = 8,
    parameter int NSLOT = 8,
    parameter int ACC_W = 32,
    parameter int SEL_W = $clog2(NSLOT)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [SEL_W-1:0]      rd_sel_i,
    output logic [NPE*ACC_W-1:0]  rd_data_o,

    input  logic                  wr_en_i,
    input  logic [SEL_W-1:0]      wr_sel_i,
    input  logic [NPE*ACC_W-1:0]  wr_data_i
);

    logic [NPE*ACC_W-1:0] slot [0:NSLOT-1];

    always_comb rd_data_o = slot[rd_sel_i];

    integer si;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (si = 0; si < NSLOT; si = si + 1) begin
                slot[si] <= {(NPE*ACC_W){1'b0}};
            end
        end else if (wr_en_i) begin
            slot[wr_sel_i] <= wr_data_i;
        end
    end

endmodule
