`timescale 1ns/1ps

// Synthesis wrappers.
//
// rabit_pcu_top already excludes the input GRF and the CRF -- both live in the
// testbench as behavioural models -- so the synthesis boundary is the top
// itself with its parameters frozen. These wrappers exist so the flow has a
// stable module name per configuration, the same way int4fp16_pcu32 wraps
// int4float_pcu in rtl/3_awq_p3llm_8pe.
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


module rabit_pcu_m10 (
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
    output wire [255:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (10),
        .SHIFTER_EN    (1),
        .NOUT_PER_WORD (8),
        .NPATH         (2)
    ) u_pcu (.*);
endmodule


module rabit_pcu_noshift (
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
        .SHIFTER_EN    (0),
        .NOUT_PER_WORD (8),
        .NPATH         (2)
    ) u_pcu (.*);
endmodule


module rabit_pcu_m10_noshift (
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
    output wire [255:0] drain_data_o,
    input  wire         status_clr_i,
    output wire [2:0]   status_sticky_o
);
    rabit_pcu_top #(
        .MANT_W        (10),
        .SHIFTER_EN    (0),
        .NOUT_PER_WORD (8),
        .NPATH         (2)
    ) u_pcu (.*);
endmodule


// ---- per-module breakdown wrappers ---------------------------------------

// Purely combinational, exactly as it sits in the top: the converter drives the
// GRF write port directly. No wrapper registers, so the reported area is the
// convert logic and nothing else; constraint.sdc falls back to a virtual clock
// for a block with no clock port and still budgets the input-to-output path.
module rabit_blk_cvt (
    input  wire [255:0] fp16_i,
    input  wire [5:0]   e0_i,
    output wire [207:0] blk_o,
    output wire [5:0]   e_ent_o,
    output wire         ovf_o
);
    rabit_cvt_fp16_blk #(.NIN(16), .MANT_W(12), .EXP_W(6), .SHIFTER_EN(1))
        u_cvt (
            .fp16_i  (fp16_i),
            .e0_i    (e0_i),
            .blk_o   (blk_o),
            .e_ent_o (e_ent_o),
            .ovf_o   (ovf_o)
        );
endmodule


module rabit_blk_pe (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                ce_i,
    input  wire [15:0]         b_bits_i,
    input  wire [207:0]        blk_i,
    input  wire signed [6:0]   shift_i,
    input  wire signed [31:0]  acc_cur_i,
    output wire signed [31:0]  acc_next_o,
    output wire                acc_sat_o,
    output wire                shift_sat_o
);
    rabit_pe #(.NIN(16), .MANT_W(12), .ACC_W(32), .SH_W(7), .SHIFTER_EN(1))
        u_pe (
            .clk         (clk),
            .rst_n       (rst_n),
            .ce_i        (ce_i),
            .b_bits_i    (b_bits_i),
            .blk_i       (blk_i),
            .shift_i     (shift_i),
            .acc_cur_i   (acc_cur_i),
            .acc_next_o  (acc_next_o),
            .acc_sat_o   (acc_sat_o),
            .shift_sat_o (shift_sat_o),
            .psum_o      ()
        );
endmodule


module rabit_blk_acc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [2:0]   rd_sel_i,
    output wire [255:0] rd_data_o,
    input  wire         wr_en_i,
    input  wire [2:0]   wr_sel_i,
    input  wire [255:0] wr_data_i
);
    rabit_acc_regfile #(.NPE(8), .NSLOT(8), .ACC_W(32))
        u_acc (.*);
endmodule
