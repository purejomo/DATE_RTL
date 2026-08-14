`timescale 1ns/1ps

// PCU sequencer: 2-pump word consumption, accumulator slot select, drain FSM.
//
// One column command delivers one 256-bit weight word and the PCU spends NPATH
// internal cycles on it -- pump p reduces the path-p bit plane against the
// path-p input entry and lands in the path-p accumulator slot of the requested
// output group. That is the whole reason the compute port runs at half rate:
// tCCD_S gives the PCU two cycles per column command, and the design spends
// them on the two residual paths instead of on two words.
//
// Handshake. rd_ready_o is asserted only on the final pump of a word, so a
// source that follows the usual "hold valid and data until ready" rule holds
// them for exactly NPATH cycles, which is what the datapath needs. rd_ready_o
// is a function of state alone, never of rd_valid_i, so there is no
// combinational loop across the interface.
//
// Drain shares the accumulator's single read and write port with the compute
// path, so it may only start once the pipeline is empty (no word in flight and
// no stage-B write pending). A drain request wins a tie against a new word: the
// source is holding rd_valid_i anyway and will be served as soon as the drain
// finishes, so neither side can starve.
module rabit_pcu_ctrl #(
    parameter int NPATH  = 2,
    parameter int NGROUP = 4,
    parameter int GW     = $clog2(NGROUP),
    parameter int PW     = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int SEL_W  = GW + PW
) (
    input  logic             clk,
    input  logic             rst_n,

    // compute command
    input  logic             rd_valid_i,
    input  logic [GW-1:0]    rd_group_i,
    output logic             rd_ready_o,

    // drain command
    input  logic             drain_req_i,
    input  logic [GW-1:0]    drain_group_i,
    output logic             drain_ready_o,

    // stage A
    output logic             word_start_o,
    output logic             stage_a_en_o,
    output logic [PW-1:0]    path_sel_o,

    // accumulator port control (stage B and drain share it)
    output logic [SEL_W-1:0] acc_rd_sel_o,
    output logic             acc_wr_en_o,
    output logic [SEL_W-1:0] acc_wr_sel_o,
    output logic             acc_wr_zero_o,
    output logic             acc_wr_pe_o,

    // drain stream
    output logic             drain_valid_o,
    output logic [GW-1:0]    drain_group_o,
    output logic [PW-1:0]    drain_path_o,
    output logic             drain_last_o,

    // completion pulse: the last pump of a word has retired into the file
    output logic             rd_done_o
);

    localparam logic [PW-1:0] LAST_PATH = PW'(NPATH - 1);

    // ---- word consumption state ------------------------------------------
    logic             busy_q;
    logic [PW-1:0]    pump_q;
    logic [GW-1:0]    group_q;

    // ---- stage B state ---------------------------------------------------
    logic             b_valid_q;
    logic             b_last_q;
    logic [SEL_W-1:0] b_slot_q;

    // ---- drain state -----------------------------------------------------
    logic             dr_busy_q;
    logic [GW-1:0]    dr_group_q;
    logic [PW-1:0]    dr_path_q;

    // ---- combinational schedule ------------------------------------------
    logic             drain_start_c;
    logic             start_c;
    logic             active_c;
    logic [PW-1:0]    pump_c;
    logic [GW-1:0]    group_c;
    logic             last_c;

    always_comb begin
        drain_ready_o = !busy_q && !b_valid_q && !dr_busy_q;
        drain_start_c = drain_req_i && drain_ready_o;

        start_c  = !busy_q && rd_valid_i && !dr_busy_q && !drain_start_c;
        active_c = busy_q || start_c;
        pump_c   = start_c ? {PW{1'b0}} : pump_q;
        group_c  = start_c ? rd_group_i : group_q;
        last_c   = active_c && (pump_c == LAST_PATH);

        rd_ready_o   = last_c;
        word_start_o = start_c;
        stage_a_en_o = active_c;
        path_sel_o   = pump_c;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy_q  <= 1'b0;
            pump_q  <= {PW{1'b0}};
            group_q <= {GW{1'b0}};
        end else if (start_c) begin
            group_q <= rd_group_i;
            if (NPATH > 1) begin
                busy_q <= 1'b1;
                pump_q <= PW'(1);
            end
        end else if (busy_q) begin
            if (pump_q == LAST_PATH) begin
                busy_q <= 1'b0;
                pump_q <= {PW{1'b0}};
            end else begin
                pump_q <= pump_q + PW'(1);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            b_valid_q <= 1'b0;
            b_last_q  <= 1'b0;
            b_slot_q  <= {SEL_W{1'b0}};
        end else begin
            b_valid_q <= active_c;
            b_last_q  <= last_c;
            if (active_c) begin
                b_slot_q <= {group_c, pump_c};
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dr_busy_q  <= 1'b0;
            dr_group_q <= {GW{1'b0}};
            dr_path_q  <= {PW{1'b0}};
        end else if (drain_start_c) begin
            dr_busy_q  <= 1'b1;
            dr_group_q <= drain_group_i;
            dr_path_q  <= {PW{1'b0}};
        end else if (dr_busy_q) begin
            if (dr_path_q == LAST_PATH) begin
                dr_busy_q <= 1'b0;
                dr_path_q <= {PW{1'b0}};
            end else begin
                dr_path_q <= dr_path_q + PW'(1);
            end
        end
    end

    // ---- accumulator port arbitration ------------------------------------
    always_comb begin
        drain_valid_o = dr_busy_q;
        drain_group_o = dr_group_q;
        drain_path_o  = dr_path_q;
        drain_last_o  = dr_busy_q && (dr_path_q == LAST_PATH);

        acc_wr_zero_o = dr_busy_q;
        acc_wr_pe_o   = b_valid_q && !dr_busy_q;

        if (dr_busy_q) begin
            acc_rd_sel_o = {dr_group_q, dr_path_q};
            acc_wr_sel_o = {dr_group_q, dr_path_q};
            acc_wr_en_o  = 1'b1;
        end else begin
            acc_rd_sel_o = b_slot_q;
            acc_wr_sel_o = b_slot_q;
            acc_wr_en_o  = b_valid_q;
        end

        rd_done_o = b_valid_q && b_last_q && !dr_busy_q;
    end

`ifdef RABIT_ASSERTIONS
`ifndef SYNTHESIS
    // A stage-B write can never collide with a drain beat: drain only starts
    // once the pipeline has emptied.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(b_valid_q && dr_busy_q))
                else $error("rabit_pcu_ctrl: accumulator write during drain");
            assert (!(drain_start_c && (busy_q || b_valid_q)))
                else $error("rabit_pcu_ctrl: drain accepted with work in flight");
            assert (!(rd_ready_o && dr_busy_q))
                else $error("rabit_pcu_ctrl: read accepted during drain");
        end
    end
`endif
`endif

endmodule
