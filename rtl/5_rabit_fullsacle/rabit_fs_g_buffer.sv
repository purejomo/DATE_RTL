`timescale 1ns/1ps

// g_buffer: the per-output scales for the stripe currently resident in the
// accumulator array.
//
// One stripe is NGROUP * NOUT_PER_WORD outputs (32 with the defaults) and each
// output needs one binary16 scale per residual path, so the buffer is
// 32 x 2 x 16b = 1024 bits of flip-flops. The host fills it with NWORD = 4
// ordinary 256-bit column writes at the start of a stripe, which is the only
// command traffic the full-scale variant adds to the inner loop -- four slots
// against the stripe's whole k sweep. README.md quantifies it.
//
// Word layout mirrors the weight word, so the packer builds it with the same
// index arithmetic it already uses for the binary cores:
//
//     word q, bit[j_local*(NPATH*16) + p*16 +: 16] = g_(p+1)[q*NOUT + j_local]
//
// which flattens to one contiguous store indexed by (output, path).
//
// Read port. The drain sequencer asks for NRD consecutive outputs of one path
// per cycle. rd_base_i is a multiple of NRD, so all NRD lanes come from the same
// quarter and the mux is a word select followed by a fixed slice.
//
// loaded_o is what the "no drain before the scales arrive" assertion watches.
// Writing word 0 restarts the count, so a stripe that only reloads part of the
// buffer cannot look complete.
module rabit_fs_g_buffer #(
    parameter int NOUT   = 32,   // outputs per stripe
    parameter int NPATH  = 2,
    parameter int NRD    = 4,    // outputs served per read
    // derived; do not override
    parameter int NWORD  = (NOUT*NPATH*16) / 256,
    parameter int IDX_W  = $clog2(NOUT),
    parameter int PW     = (NPATH > 1) ? $clog2(NPATH) : 1,
    parameter int WSEL_W = $clog2(NWORD)
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---- fill --------------------------------------------------------------
    input  logic                we_i,
    input  logic [WSEL_W-1:0]   wsel_i,
    input  logic [255:0]        wdata_i,

    // ---- read --------------------------------------------------------------
    input  logic [IDX_W-1:0]    rd_base_i,
    input  logic [PW-1:0]       rd_path_i,
    output logic [NRD*16-1:0]   g_o,

    output logic                loaded_o
);

    localparam int MEM_W = NOUT*NPATH*16;

    logic [MEM_W-1:0]  gmem_q;
    logic [NWORD-1:0]  fill_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            gmem_q <= {MEM_W{1'b0}};
            fill_q <= {NWORD{1'b0}};
        end else if (we_i) begin
            gmem_q[wsel_i*256 +: 256] <= wdata_i;
            // Word 0 starts a fresh stripe: drop whatever the previous stripe
            // left behind so a partial reload never reads as complete.
            fill_q <= (wsel_i == {WSEL_W{1'b0}})
                    ? {{(NWORD-1){1'b0}}, 1'b1}
                    : (fill_q | (NWORD'(1) << wsel_i));
        end
    end

    always_comb loaded_o = &fill_q;

    genvar r;
    generate
        for (r = 0; r < NRD; r = r + 1) begin : g_read
            integer idx;
            integer off;
            always_comb begin
                idx = {{(32-IDX_W){1'b0}}, rd_base_i} + r;
                off = idx*NPATH + {{(32-PW){1'b0}}, rd_path_i};
                g_o[r*16 +: 16] = gmem_q[off*16 +: 16];
            end
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (MEM_W != NWORD*256)
            $fatal(1, "rabit_fs_g_buffer: the stripe's scales must be a whole number of 256-bit writes");
        if ((NOUT % NRD) != 0)
            $fatal(1, "rabit_fs_g_buffer: NRD must divide NOUT");
    end
`endif

endmodule
