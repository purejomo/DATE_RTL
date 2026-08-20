`timescale 1ns/1ps

// Synthesis wrapper for the acc16 variant.
//
// One wrapper only. rtl/5_spinquant carries spinquant_pcu, spinquant_pcu_acc32,
// spinquant_pcu_nolatch and the spinquant_blk_* breakdown; this directory adds
// exactly one top so the axis-2 row cannot collide with any of them. Two rows
// that share a top module name overwrite each other's sv2v output and each
// other's power report -- see synth/run_block_synth.sh and synth/run_all.sh.
//
// Geometry is the delivered configuration, unchanged: 16 PE x 4 ways, four
// accumulator entries, bank read latch in. Only the accumulator changes.
//
//   ACC_W = 16       the axis definition
//   ACC_CHAIN_W = 16 no sign-extension headroom left to exploit, so the carry
//                    chain is the whole register
//   ACC_RSH = 7      keeps the MSBs: the 22-bit live value of a K = 14336
//                    projection layer lands inside 16 signed bits
//
// Port width that follows: drain_data_o is NLANE*ACC_W = 16*16 = 256 bits,
// half of the base design's 512.
//
// Where the area comes back: spinquant_acc_regfile is NENTRY x NLANE x ACC_W =
// 4 x 16 x 16 = 1024 bits against the base design's 2048.
module spinquant_pcu_acc16 (
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
    output wire [255:0] drain_data_o,
    input  wire         status_clr_i,
    output wire         ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NENTRY      (4),
        .ACC_W       (16),
        .ACC_CHAIN_W (16),
        .ACC_RSH     (7),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule
