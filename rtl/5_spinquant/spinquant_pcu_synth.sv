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


module spinquant_pcu_acc32 (
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
        .ACC_CHAIN_W (32),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule


module spinquant_pcu_nolatch (
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
        .W_LATCH     (0)
    ) u_pcu (.*);
endmodule


// ---- per-module breakdown wrappers ---------------------------------------

module spinquant_blk_pe (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                ce_i,
    input  wire [15:0]         w_q4_i,
    input  wire [15:0]         a_q4_i,
    input  wire                acc_clear_i,
    input  wire signed [31:0]  acc_cur_i,
    output wire signed [31:0]  acc_next_o,
    output wire                acc_ovf_o
);
    spinquant_pe #(
        .NWAY        (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .Q_W         (4)
    ) u_pe (
        .clk         (clk),
        .rst_n       (rst_n),
        .ce_i        (ce_i),
        .w_q4_i      (w_q4_i),
        .a_q4_i      (a_q4_i),
        .acc_clear_i (acc_clear_i),
        .acc_cur_i   (acc_cur_i),
        .acc_next_o  (acc_next_o),
        .acc_ovf_o   (acc_ovf_o),
        .psum_o      ()
    );
endmodule


module spinquant_blk_acc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [1:0]   rd_sel_i,
    output wire [511:0] rd_data_o,
    input  wire [1:0]   drain_sel_i,
    output wire [511:0] drain_data_o,
    input  wire         wr_en_i,
    input  wire [1:0]   wr_sel_i,
    input  wire [511:0] wr_data_i
);
    spinquant_acc_regfile #(
        .NLANE  (16),
        .NENTRY (4),
        .ACC_W  (32)
    ) u_acc (.*);
endmodule


// ---- throughput scale-up points ------------------------------------------
//
// The multiplier array is not what limits this design: it closes at 1.0 ns
// with 46 % of the baseline area left over. What limits sustained MAC/cycle is
// weight supply. One column command delivers 256 bits per tCCD_L, which is
// 128 bits -- 32 INT4 weights -- per tCCD_S cycle, so
//
//     sustained MAC/cycle = 32 x R,    R = activation rows reusing one beat
//
// The delivered configuration is R = 2 (two rows time-multiplexed over the two
// pumps) and therefore 64 MAC/cycle. Raising it means raising R, and every
// resident row needs accumulators of its own -- which is why these rows cost
// what they cost. See docs/spinquant_pcu_spec.md section 8.
//
//   spinquant_pcu_r2      R = 4: two rows spatial x two pumps. 128 mult.
//   spinquant_pcu_r2e2    the same two spatial rows with the output-group
//                         interleave given up, so the accumulator file stays
//                         at the delivered size. Peak 128, sustained 64.
//   spinquant_pcu_r4      R = 8: four rows spatial x two pumps. 256 mult.
//   spinquant_pcu_w512    the other axis: 512-bit beat, one row. Only reachable
//                         if the PCU is given twice the column bandwidth, and
//                         it is the one option that helps batch 1.

module spinquant_pcu_r2 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [255:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [31:0]   a_q4_i,
    input  wire [1:0]    acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire [1:0]    drain_entry_i,
    output wire [1023:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NROW        (2),
        .NENTRY      (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule


module spinquant_pcu_r2e2 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [255:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [31:0]   a_q4_i,
    input  wire          acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire          drain_entry_i,
    output wire [1023:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NROW        (2),
        .NENTRY      (2),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule


module spinquant_pcu_r4 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [255:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [63:0]   a_q4_i,
    input  wire [1:0]    acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire [1:0]    drain_entry_i,
    output wire [2047:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (16),
        .NWAY        (4),
        .NROW        (4),
        .NENTRY      (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule


module spinquant_pcu_w512 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          w_load_i,
    input  wire [511:0]  w_beat_i,
    input  wire          mac_valid_i,
    input  wire [15:0]   a_q4_i,
    input  wire [1:0]    acc_entry_i,
    input  wire          acc_clear_i,
    output wire          mac_done_o,
    input  wire [1:0]    drain_entry_i,
    output wire [1023:0] drain_data_o,
    input  wire          status_clr_i,
    output wire          ovf_sticky_o
);
    spinquant_pcu_top #(
        .NPE         (32),
        .NWAY        (4),
        .NROW        (1),
        .NENTRY      (4),
        .ACC_W       (32),
        .ACC_CHAIN_W (24),
        .W_LATCH     (1)
    ) u_pcu (.*);
endmodule
