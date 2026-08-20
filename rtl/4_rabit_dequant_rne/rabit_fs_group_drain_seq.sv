`timescale 1ns/1ps
// Drains one selected 8-output group.  The order is half then path, so the
// path-0 partial is consumed by path 1 on the immediately following cycle.
module rabit_fs_group_drain_seq #(
    parameter int NGROUP        = 4,
    parameter int NPATH         = 2,
    parameter int NOUT_PER_WORD = 8,
    parameter int DQ_LANES      = 1,
    parameter int NHALF         = NOUT_PER_WORD / DQ_LANES,
    parameter int HW            = (NHALF > 1) ? $clog2(NHALF) : 1,
    parameter int GW            = $clog2(NGROUP),
    parameter int PW            = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int SEL_W         = GW + PW,
    parameter int NCYC          = NPATH*NHALF,
    parameter int CW            = $clog2(NCYC),
    parameter int BEAT_W        = $clog2(NGROUP*NHALF),
    parameter int TAIL          = 3
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 req_i,
    input  logic [GW-1:0]        group_i,
    input  logic                 pipe_idle_i,
    output logic                 ready_o,
    output logic                 start_o,
    output logic                 busy_o,
    output logic                 acc_busy_o,
    output logic [SEL_W-1:0]     acc_rd_sel_o,
    output logic                 acc_wr_en_o,
    output logic [SEL_W-1:0]     acc_wr_sel_o,
    output logic                 lane_valid_o,
    output logic [HW-1:0]        half_o,
    output logic                 path_o,
    output logic [HW-1:0]        g_base_o,
    output logic [PW-1:0]        g_path_o,
    output logic [BEAT_W-1:0]    beat_o,
    output logic                 last_o
);
    localparam int TW = $clog2(TAIL + 1);

    logic             run_q;
    logic [CW-1:0]    cnt_q;
    logic [TW-1:0]    tail_q;
    logic [GW-1:0]    group_q;
    logic             last_c;
    logic [HW-1:0]    half_c;
    logic [PW-1:0]    path_c;

    assign busy_o  = run_q || (tail_q != {TW{1'b0}});
    assign last_c  = run_q && (cnt_q == CW'(NCYC-1));
    assign ready_o = !busy_o && pipe_idle_i;
    assign start_o = req_i && ready_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_q   <= 1'b0;
            cnt_q   <= {CW{1'b0}};
            tail_q  <= {TW{1'b0}};
            group_q <= {GW{1'b0}};
        end else begin
            if (start_o) begin
                run_q   <= 1'b1;
                cnt_q   <= {CW{1'b0}};
                group_q <= group_i;
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

    always_comb begin
        path_c = PW'(cnt_q[0]);
        half_c = HW'(cnt_q >> 1);

        acc_busy_o   = run_q;
        acc_rd_sel_o = {group_q, path_c};
        acc_wr_sel_o = {group_q, path_c};
        acc_wr_en_o  = run_q && (half_c == HW'(NHALF-1));

        lane_valid_o = run_q;
        half_o       = half_c;
        path_o       = path_c;
        g_base_o     = half_c * HW'(DQ_LANES);
        g_path_o     = path_c;
        beat_o       = BEAT_W'({group_q, half_c});
        last_o       = last_c && (group_q == GW'(NGROUP-1));
    end
endmodule
