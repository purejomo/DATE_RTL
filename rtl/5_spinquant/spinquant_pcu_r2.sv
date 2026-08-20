`timescale 1ns/1ps
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
