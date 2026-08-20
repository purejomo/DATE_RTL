`timescale 1ns/1ps

// One output group's scales.  The host loads a 256-bit group word immediately
// before requesting that group's dequant drain.
module rabit_fs_g_group_buffer #(
    parameter int NOUT  = 8,
    parameter int NPATH = 2,
    parameter int NRD   = 1,
    parameter int GW    = 2,
    parameter int IDX_W = $clog2(NOUT),
    parameter int OFF_W = $clog2(NOUT*NPATH),
    parameter int PW    = (NPATH > 1) ? $clog2(NPATH) : 1
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                we_i,
    input  logic [GW-1:0]       group_i,
    input  logic [255:0]        wdata_i,
    input  logic [IDX_W-1:0]    rd_base_i,
    input  logic [PW-1:0]       rd_path_i,
    output logic [NRD*16-1:0]   g_o,
    output logic                loaded_o,
    output logic [GW-1:0]       group_o
);
    logic [255:0] gmem_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            gmem_q   <= 256'd0;
            loaded_o <= 1'b0;
            group_o  <= {GW{1'b0}};
        end else if (we_i) begin
            gmem_q   <= wdata_i;
            loaded_o <= 1'b1;
            group_o  <= group_i;
        end
    end

    genvar r;
    generate
        for (r = 0; r < NRD; r = r + 1) begin : g_read
            logic [IDX_W-1:0] idx;
            logic [OFF_W-1:0] off;
            always_comb begin
                idx = rd_base_i + IDX_W'(r);
                off = OFF_W'(idx) * OFF_W'(NPATH) + OFF_W'(rd_path_i);
                g_o[r*16 +: 16] = gmem_q[off*16 +: 16];
            end
        end
    endgenerate
endmodule
