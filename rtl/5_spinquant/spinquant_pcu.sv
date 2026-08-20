`timescale 1ns/1ps

// Synthesis wrappers.
//
// spinquant_pcu_top already excludes the input GRF, the CRF and the bank -- all
// three live in the testbench as behavioural models -- so the synthesis
// boundary is the top itself with its parameters frozen. These wrappers exist
// so the flow has a stable module name per configuration, the same way
// rabit_pcu wraps rabit_pcu_top in rtl/4_rabit.
//
//   spinquant_pcu          the delivered configuration: 24-bit carry chain in
//                          32-bit accumulator registers, bank read latch in
//   spinquant_pcu_acc32    32-bit carry chain, that is, the chain the
//                          architectural register width would imply if the
//                          K bound were not exploited
//   spinquant_pcu_nolatch  the 256-bit bank read latch moved outside the
//                          boundary, which is where P3-LLM and the SIMD rows
//                          take their weights from
//
// The two spinquant_blk_* wrappers synthesize one sub-block at a time so the
// area report can be split into arithmetic and accumulator state. Their sum
// does not have to equal the flat top: the flow flattens everything, so the top
// gets cross-boundary optimization the isolated blocks do not.

module spinquant_pcu (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         w_load_i,
    input  wire [255:0] w_beat_i,
    input  wire         mac_valid_i,
    input  wire [15:0]  a_q4_i,
    input  wire [1:0]   acc_entry_i,
    input  wire         acc_clear_i,
    output wire         mac_done_o,
    input  wire [1:0]   drain_entry_i,
    output wire [511:0] drain_data_o,
    input  wire         status_clr_i,
    output wire         ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NENTRY      (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule
