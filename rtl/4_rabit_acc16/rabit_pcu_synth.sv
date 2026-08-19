`timescale 1ns/1ps

// Synthesis wrapper for the axis-2 (acc16) RaBiT PCU.
//
// rabit_pcu_top already excludes the input GRF and the CRF -- both live in the
// testbench as behavioural models -- so the synthesis boundary is the top
// itself with its parameters frozen. This directory carries exactly one
// wrapper, unlike rtl/4_rabit which carries the delivered configuration plus
// its whole parameter sweep; the acc16 row is a single design point.
//
//   rabit_pcu_acc16   ACC_W 16, MANT_W 10, shifter on, SHIFT_RND on
//
// Why these three parameters move together.
//
//   ACC_W = 16      is the axis definition: the architectural accumulator
//                   holds 16 bits instead of 32.
//   MANT_W = 10     is forced, not chosen. rabit_align_shift asserts
//                   ACC_W > PSUM_W and PSUM_W = MANT_W + 1 + clog2(NIN)
//                   = MANT_W + 5. MANT_W = 12 gives PSUM_W = 17 > 16 and the
//                   elaboration guard fires; MANT_W = 10 gives 15 < 16. The
//                   MANT_W = 10 point is already covered by the rabit_pcu_m10
//                   regression in verif/, so this is a validated combination
//                   rather than a new one.
//   SHIFT_RND = 1   turns on the round-to-nearest-even path that
//                   rabit_align_shift already contains. That is what makes
//                   this build comparable with the other two acc16 designs:
//                   "RNE on every accumulation" is obtained here with no new
//                   logic, because the aligner's right shift is exactly where
//                   the bits are discarded.
//
// Derived widths follow: BLK_W = 16*11 + 6 = 182 (cvt_blk_o), NPATH*BLK_W =
// 364 (grf_blk_i), and DRAIN_W = NOUT_PER_WORD*ACC_W = 8*16 = 128 (drain_data_o)
// instead of 256.
//
// Where the area comes back. rabit_acc_regfile is NSLOT x NPE x ACC_W =
// 8 x 8 x 32 = 2048 bits in the base build and 1024 bits here. It is the
// largest storage array inside the RaBiT synthesis boundary, so the saving
// lands directly in the area table.

module rabit_pcu_acc16 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [5:0]   cfg_e0_i,
    input  wire         wr_valid_i,
    output wire         wr_ready_o,
    input  wire [1:0]   wr_entry_i,
    input  wire [255:0] wr_fp16_i,
    output wire         cvt_we_o,
    output wire [1:0]   cvt_entry_o,
    output wire [181:0] cvt_blk_o,
    input  wire         rd_valid_i,
    output wire         rd_ready_o,
    input  wire [1:0]   rd_group_i,
    input  wire         rd_pair_i,
    input  wire [255:0] rd_word_i,
    output wire         grf_pair_o,
    input  wire [363:0] grf_blk_i,
    output wire         rd_done_o,
    input  wire         drain_req_i,
    input  wire [1:0]   drain_group_i,
    output wire         drain_ready_o,
    output wire         drain_valid_o,
    output wire [1:0]   drain_group_o,
    output wire         drain_path_o,
    output wire         drain_last_o,
    output wire [127:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (10),
        .SHIFTER_EN    (1),
        .SHIFT_RND     (1),
        .ACC_W         (16),
        .NOUT_PER_WORD (8),
        .NPATH         (2)
    ) u_pcu (.*);
endmodule
