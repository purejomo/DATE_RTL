`timescale 1ns/1ps

// Drain sequencer for the dequantizing drain.
//
// The base variant drains one accumulator group per command, NPATH beats of raw
// integers, and leaves the scaling to the NPU. The full-scale variant drains a
// whole stripe in one request and hands back finished binary16, so it owns the
// accumulator port for NGROUP * NPATH * NHALF cycles -- 16 with the defaults --
// and walks it in the order rabit_fs_dq_unit needs:
//
//     cnt      3 2   1     0
//              group path  half
//
// so the two halves of a slot are consecutive (the slot is read twice, which
// costs nothing on a register file) and the two paths of a group are adjacent
// (which is what lets the unit park path 0 and finish on path 1).
//
// The slot is cleared on the second of its two read cycles: the read is
// combinational and the write lands at the end of the cycle, so the same cycle
// can do both, exactly as the base drain does.
//
// acc_busy_o is asserted only while the sequencer needs the port. The three
// pipeline stages behind it keep running for three more cycles under busy_o,
// but column commands may already restart, so the drain stall is the 16 port
// cycles and not the pipeline latency.
module rabit_fs_drain_seq #(
    parameter int NGROUP        = 4,
    parameter int NPATH         = 2,
    parameter int NOUT_PER_WORD = 8,
    parameter int DQ_LANES      = 4,
    // derived; do not override
    parameter int NHALF   = NOUT_PER_WORD / DQ_LANES,
    parameter int HW      = (NHALF > 1) ? $clog2(NHALF) : 1,
    parameter int GW      = $clog2(NGROUP),
    parameter int PW      = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int SEL_W   = GW + PW,
    parameter int NCYC    = NGROUP*NPATH*NHALF,
    parameter int CW      = $clog2(NCYC),
    parameter int NBEAT   = NGROUP*NHALF,
    parameter int BEAT_W  = $clog2(NBEAT),
    parameter int IDX_W   = $clog2(NGROUP*NOUT_PER_WORD),
    parameter int TAIL    = 3
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---- request -----------------------------------------------------------
    input  logic              req_i,
    input  logic              pipe_idle_i,   // rabit_pcu_ctrl has nothing in flight
    output logic              ready_o,
    output logic              start_o,
    output logic              busy_o,        // request or pipeline still live
    output logic              acc_busy_o,    // sequencer owns the accumulator port

    // ---- accumulator port --------------------------------------------------
    output logic [SEL_W-1:0]  acc_rd_sel_o,
    output logic              acc_wr_en_o,
    output logic [SEL_W-1:0]  acc_wr_sel_o,

    // ---- dequantizer control ----------------------------------------------
    output logic              lane_valid_o,
    output logic [HW-1:0]     half_o,
    output logic              path_o,
    output logic [IDX_W-1:0]  g_base_o,
    output logic [PW-1:0]     g_path_o,
    output logic [BEAT_W-1:0] beat_o,
    output logic              last_o
);

    localparam int TW = $clog2(TAIL + 1);

    logic          run_q;
    logic [CW-1:0] cnt_q;
    logic [TW-1:0] tail_q;

    logic          last_c;

    // busy_o is a function of state alone and is kept in its own block: it
    // gates the request the base sequencer sees, and lumping it with the
    // pipe_idle_i term would make that look like a combinational loop.
    always_comb busy_o = run_q || (tail_q != {TW{1'b0}});

    always_comb begin
        last_c  = run_q && (cnt_q == CW'(NCYC-1));
        ready_o = !busy_o && pipe_idle_i;
        start_o = req_i && ready_o;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_q  <= 1'b0;
            cnt_q  <= {CW{1'b0}};
            tail_q <= {TW{1'b0}};
        end else begin
            if (start_o) begin
                run_q <= 1'b1;
                cnt_q <= {CW{1'b0}};
            end else if (run_q) begin
                if (last_c) begin
                    run_q  <= 1'b0;
                    cnt_q  <= {CW{1'b0}};
                    tail_q <= TW'(TAIL);
                end else begin
                    cnt_q <= cnt_q + CW'(1);
                end
            end else if (tail_q != {TW{1'b0}}) begin
                tail_q <= tail_q - TW'(1);
            end
        end
    end

    // ---- decode the counter ------------------------------------------------
    logic [HW-1:0] half_c;
    logic          path_c;
    logic [GW-1:0] group_c;

    always_comb begin
        half_c  = (NHALF > 1) ? cnt_q[HW-1:0] : {HW{1'b0}};
        path_c  = cnt_q[(NHALF > 1) ? HW : 0];
        group_c = cnt_q[CW-1 -: GW];

        acc_busy_o   = run_q;
        acc_rd_sel_o = {group_c, path_c};
        acc_wr_sel_o = {group_c, path_c};
        // Clear the slot on the last cycle that reads it.
        acc_wr_en_o  = run_q && (half_c == HW'(NHALF-1));

        lane_valid_o = run_q;
        half_o       = half_c;
        path_o       = path_c;
        g_path_o     = path_c;
        g_base_o     = IDX_W'(group_c) * IDX_W'(NOUT_PER_WORD) +
                       IDX_W'(half_c) * IDX_W'(DQ_LANES);
        beat_o       = BEAT_W'({group_c, half_c});
        last_o       = last_c;
    end

`ifndef SYNTHESIS
    initial begin
        if (NPATH != 2)
            $fatal(1, "rabit_fs_drain_seq: the counter decode assumes NPATH = 2");
        if (NCYC != (1 << CW))
            $fatal(1, "rabit_fs_drain_seq: NGROUP * NPATH * NHALF must be a power of two");
    end
`endif

endmodule
