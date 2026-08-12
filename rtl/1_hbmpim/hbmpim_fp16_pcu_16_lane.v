`timescale 1ns/1ps

// Integrated HBM-PIM compute unit with sixteen independent FP16 MAC lanes.
// Every lane multiplies two binary16 operands and accumulates in binary32.
module hbmpim_fp16_pcu_16_lane (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         i_valid,
    input  wire         i_acc_clear,
    input  wire         i_acc_enable,

    input  wire [255:0] i_a,
    input  wire [255:0] i_b,

    output wire         o_valid,
    output wire [511:0] o_acc
);

    wire [15:0] lane_valid;

    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
            hbmpim_fp16_mac_1_lane u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                .i_valid      (i_valid),
                .i_acc_clear  (i_acc_clear),
                .i_acc_enable (i_acc_enable),
                .i_a          (i_a[lane*16 +: 16]),
                .i_b          (i_b[lane*16 +: 16]),
                .o_valid      (lane_valid[lane]),
                .o_acc        (o_acc[lane*32 +: 32])
            );
        end
    endgenerate

    // The lanes are controlled in lockstep.
    assign o_valid = &lane_valid;

endmodule
