`timescale 1ns/1ps

// SpinQuant W4A4 PIM compute unit: projection-layer GEMV, compute datapath only.
//
//     acc[e][i] += sum_{j < NWAY} W_q[i][j] * A_q[j]
//
//         W_q  signed INT4    GPTQ per-channel symmetric weight with the R1/R2
//                             rotations already merged offline, read straight
//                             out of the bank
//         A_q  unsigned INT4  per-token asymmetric min-max activation, selected
//                             out of the input GRF by the sequencer
//
// The PCU is a pure integer dot-product engine. Everything that would make it
// anything else has been pushed to the NPU by the SpinQuant numerics:
//
//     W . A~ = s_a * (W_q . A_q) + beta * sum(W_row)
//
// so the activation zero point beta contributes a per-output-channel constant
// that is precomputed offline and fused into the NPU bias, and both scales
// (s_w per channel, s_a per token) are applied after the drain. There is no
// floating point, no exponent alignment, no format decoder and no scale
// multiplier in this file or anything it instantiates -- that absence is the
// whole point of the comparison against the P3-LLM PE.
//
// What is inside this synthesis boundary
//   - the 256-bit bank read latch (W_LATCH = 1), which is what lets one weight
//     beat feed two tCCD_S MAC commands
//   - NROW*NPE processing elements: NROW*NPE*NWAY multipliers, one 4:2
//     reduction and one accumulate adder each
//   - the architectural accumulator file, NENTRY x NROW*NPE x ACC_W
//
// What is outside, modelled behaviourally by the testbench
//   - the input GRF (16b x 16 lane x 4 entry) and the activation select in
//     front of a_q4_i
//   - the CRF / command decode, the DRAM bank and the host NPU
//
// Beat format (WBEAT_W = NPE*NWAY*Q_W = 256 bits), matching the packing the
// bank hands over on one RD:
//
//     w_beat_i[(i*NWAY + j)*Q_W +: Q_W]      = W_q[output channel i][k-elem j]
//     a_q4_i  [(r*NWAY + j)*Q_W +: Q_W]      = A_q[input row r][k-elem j]
//     drain_data_o[(r*NPE + i)*ACC_W +: ACC_W] = acc[entry][row r][channel i]
//
// With the delivered NROW = 1 the activation bus is one row broadcast to every
// PE and the lane index is just the output channel.
//
// Timing. Two compute stages, one MAC per cycle, no backpressure and no stall:
//
//     cycle c    w_load_i captures the beat this MAC's successor will use,
//                mac_valid_i multiplies w_hold x a_q4_i and reduces
//     cycle c+1  the selected accumulator entry is read, added and written
//     cycle c+2  mac_done_o is high and drain_data_o shows the updated entry
//
// Because the load at cycle c only takes effect on the edge that ends cycle c,
// a MAC issued in the same cycle still sees the previous beat. That is what
// makes the 2-pump schedule fall out with no bubble: hold w_load_i low for the
// second pump and change a_q4_i / acc_entry_i instead.
module spinquant_pcu_top #(
    parameter int NPE         = 16,
    parameter int NWAY        = 4,
    parameter int NROW        = 1,
    parameter int NENTRY      = 4,
    parameter int ACC_W       = 32,
    parameter int ACC_CHAIN_W = 24,
    parameter int W_LATCH     = 1,
    parameter int Q_W         = 4,
    // derived; do not override
    parameter int WBEAT_W     = NPE*NWAY*Q_W,
    parameter int ABEAT_W     = NROW*NWAY*Q_W,
    parameter int NLANE       = NROW*NPE,
    parameter int SEL_W       = $clog2(NENTRY),
    parameter int ENT_W       = NLANE*ACC_W
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---- bank read beat ------------------------------------------------
    input  logic                w_load_i,
    input  logic [WBEAT_W-1:0]  w_beat_i,

    // ---- MAC command ---------------------------------------------------
    input  logic                mac_valid_i,
    input  logic [ABEAT_W-1:0]  a_q4_i,
    input  logic [SEL_W-1:0]    acc_entry_i,
    input  logic                acc_clear_i,
    output logic                mac_done_o,

    // ---- MAC-drain -----------------------------------------------------
    input  logic [SEL_W-1:0]    drain_entry_i,
    output logic [ENT_W-1:0]    drain_data_o,

    // ---- status --------------------------------------------------------
    input  logic                status_clr_i,
    output logic                ovf_sticky_o
);

    // ---- bank read latch --------------------------------------------------
    //
    // W_LATCH = 0 moves the latch outside the boundary so the area can be read
    // against designs that take their weights straight off a port; the schedule
    // then has to hold w_beat_i steady for both pumps instead.
    logic [WBEAT_W-1:0] w_hold;

    generate
        if (W_LATCH != 0) begin : g_wlatch
            logic [WBEAT_W-1:0] w_hold_q;
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    w_hold_q <= {WBEAT_W{1'b0}};
                end else if (w_load_i) begin
                    w_hold_q <= w_beat_i;
                end
            end
            always_comb w_hold = w_hold_q;
        end else begin : g_no_wlatch
            logic unused_w_load;
            always_comb begin
                unused_w_load = w_load_i;
                w_hold        = w_beat_i;
            end
        end
    endgenerate

    // ---- stage 1 control --------------------------------------------------
    logic             s1_valid_q;
    logic             s1_clear_q;
    logic [SEL_W-1:0] s1_entry_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid_q <= 1'b0;
            s1_clear_q <= 1'b0;
            s1_entry_q <= {SEL_W{1'b0}};
        end else begin
            s1_valid_q <= mac_valid_i;
            if (mac_valid_i) begin
                s1_clear_q <= acc_clear_i;
                s1_entry_q <= acc_entry_i;
            end
        end
    end

    // ---- PE array ---------------------------------------------------------
    logic [ENT_W-1:0] acc_rd;
    logic [ENT_W-1:0] acc_wr;
    logic [NLANE-1:0] pe_ovf;

    // NROW activation rows share one weight beat spatially: PE[r][i] multiplies
    // weight slice i by activation row r. Weight bandwidth is unchanged and the
    // multiplier count scales with NROW, which is the only way to raise
    // MAC/cycle without asking the bank for more bits -- at the price of NROW
    // times the accumulator file, since every row keeps its own partial sums.
    genvar ri, pi;
    generate
        for (ri = 0; ri < NROW; ri = ri + 1) begin : g_row
            for (pi = 0; pi < NPE; pi = pi + 1) begin : g_pe
                localparam int LANE = ri*NPE + pi;
                spinquant_pe #(
                    .NWAY        (NWAY),
                    .ACC_W       (ACC_W),
                    .ACC_CHAIN_W (ACC_CHAIN_W),
                    .Q_W         (Q_W)
                ) u_pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .ce_i        (mac_valid_i),
                    .w_q4_i      (w_hold[pi*NWAY*Q_W +: NWAY*Q_W]),
                    .a_q4_i      (a_q4_i[ri*NWAY*Q_W +: NWAY*Q_W]),
                    .acc_clear_i (s1_clear_q),
                    .acc_cur_i   (acc_rd[LANE*ACC_W +: ACC_W]),
                    .acc_next_o  (acc_wr[LANE*ACC_W +: ACC_W]),
                    .acc_ovf_o   (pe_ovf[LANE]),
                    .psum_o      ()
                );
            end
        end
    endgenerate

    // ---- accumulator file -------------------------------------------------
    spinquant_acc_regfile #(
        .NLANE  (NLANE),
        .NENTRY (NENTRY),
        .ACC_W  (ACC_W)
    ) u_acc (
        .clk          (clk),
        .rst_n        (rst_n),
        .rd_sel_i     (s1_entry_q),
        .rd_data_o    (acc_rd),
        .drain_sel_i  (drain_entry_i),
        .drain_data_o (drain_data_o),
        .wr_en_i      (s1_valid_q),
        .wr_sel_i     (s1_entry_q),
        .wr_data_i    (acc_wr)
    );

    // ---- completion and status -------------------------------------------
    logic ovf_pulse;
    logic ovf_sticky_q;

    always_comb ovf_pulse = s1_valid_q && (|pe_ovf);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mac_done_o   <= 1'b0;
            ovf_sticky_q <= 1'b0;
        end else begin
            mac_done_o <= s1_valid_q;
            // A clear that lands in the same cycle as an event must not eat it,
            // so the pulse is OR-ed after the clear rather than before it.
            ovf_sticky_q <= (status_clr_i ? 1'b0 : ovf_sticky_q) | ovf_pulse;
        end
    end

    always_comb ovf_sticky_o = ovf_sticky_q;

`ifndef SYNTHESIS
    initial begin
        if ((NPE*NWAY*Q_W) % 256 != 0)
            $fatal(1, "spinquant_pcu_top: the beat must be whole 256-bit words");
        if (NENTRY < 2)
            $fatal(1, "spinquant_pcu_top: 2-pump needs at least two entries");
        if (NROW < 1)
            $fatal(1, "spinquant_pcu_top: NROW must be at least one");
    end
`endif

`ifdef SPINQUANT_ASSERTIONS
`ifndef SYNTHESIS
    logic reset_sampled_q;

    always_ff @(posedge clk) begin
        reset_sampled_q <= !rst_n;
    end

    always @(negedge clk) begin
        if (!rst_n && reset_sampled_q) begin
            assert (drain_data_o == {ENT_W{1'b0}})
                else $error("spinquant_pcu_top: accumulators nonzero in reset");
        end else if (rst_n && !$isunknown(drain_entry_i)) begin
            assert (!$isunknown(drain_data_o))
                else $error("spinquant_pcu_top: X on the drain port");
        end
    end
`endif
`endif

endmodule
