`timescale 1ns/1ps

// Synthesis wrappers.
//
// rabit_pcu_top already excludes the input GRF and the CRF -- both live in the
// testbench as behavioural models -- so the synthesis boundary is the top
// itself with its parameters frozen. These wrappers exist so the flow has a
// stable module name per configuration, the same way int4fp16_pcu32 wraps
// int4float_pcu in rtl/2_awq_p3llm_8pe.
//
//   rabit_pcu          the delivered configuration: MANT_W 12, shifter on
//   rabit_pcu_m10      MANT_W 10, shifter on
//   rabit_pcu_noshift  MANT_W 12, shifter off (convert aligns to E0 instead)
//   rabit_pcu_m10_noshift
//
// The three rabit_blk_* wrappers below synthesize one sub-block at a time so
// the area report can be broken down by module. Their sum does not have to
// equal the flat top: the flow flattens everything, so the top gets
// cross-boundary optimization the isolated blocks do not.

module rabit_pcu (
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
    input  wire [1:0]   rd_group_i,
    input  wire         rd_pair_i,
    input  wire [255:0] rd_word_i,
    output wire         grf_pair_o,
    input  wire [427:0] grf_blk_i,
    output wire         rd_done_o,
    input  wire         drain_req_i,
    input  wire [1:0]   drain_group_i,
    output wire         drain_ready_o,
    output wire         drain_valid_o,
    output wire [1:0]   drain_group_o,
    output wire         drain_path_o,
    output wire         drain_last_o,
    output wire [255:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (12),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (8),
        .NPATH         (2)
    ) u_pcu (.*);
endmodule
