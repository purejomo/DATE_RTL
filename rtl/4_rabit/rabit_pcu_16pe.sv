`timescale 1ns/1ps
// ---- PE-count study: 8 PE is set by the column word, not chosen ----------
//
// WORD_W = NIN * NOUT_PER_WORD * NPATH. With the 16-input entry and the two
// residual paths the format fixes, 256 bits of column word leaves exactly
// 256 / (16 * 2) = 8 outputs. Doubling the PE count therefore doubles the
// weight bits the array consumes per cycle, which tCCD_S does not supply --
// see docs/rabit_pcu_spec.md. These two wrappers exist to price
// that, not to propose it.
//
//   rabit_pcu_16pe     NGROUP 2, so the resident stripe stays 32 outputs and
//                      the accumulator array stays 64 x 32b. Isolates the cost
//                      of the PE array alone.
//   rabit_pcu_16pe_g4  NGROUP 4, the naive scaling: the stripe grows to 64
//                      outputs and the accumulator array doubles too.
module rabit_pcu_16pe (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [5:0]   cfg_e0_i,
    input  wire         wr_valid_i,
    output wire         wr_ready_o,
    input  wire [1:0]   wr_entry_i,
    input  wire [255:0] wr_fp16_i,
    output wire         cvt_we_o,
    output wire [1:0]   cvt_entry_o,
    output wire [213:0] cvt_blk_o,
    input  wire         rd_valid_i,
    output wire         rd_ready_o,
    input  wire [0:0]   rd_group_i,
    input  wire         rd_pair_i,
    input  wire [511:0] rd_word_i,
    output wire         grf_pair_o,
    input  wire [427:0] grf_blk_i,
    output wire         rd_done_o,
    input  wire         drain_req_i,
    input  wire [0:0]   drain_group_i,
    output wire         drain_ready_o,
    output wire         drain_valid_o,
    output wire [0:0]   drain_group_o,
    output wire         drain_path_o,
    output wire         drain_last_o,
    output wire [511:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (16),
        .NPATH         (2),
        .NGROUP        (2)
    ) u_pcu (.*);
endmodule
