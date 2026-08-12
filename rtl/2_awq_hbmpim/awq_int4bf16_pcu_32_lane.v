`timescale 1ns/1ps

// AWQ-HBM-PIM PCU with thirty-two independent INT4 x bfloat16 MAC lanes.
module awq_int4bf16_pcu_32_lane (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          i_valid,
    input  wire          i_acc_clear,
    input  wire          i_acc_enable,
    input  wire [511:0]  i_act,
    input  wire [127:0]  i_weight_q,
    input  wire [3:0]    i_weight_zp,
    output wire          o_valid,
    output wire [1023:0] o_acc
);
    wire [31:0] lane_valid;

    genvar lane;
    generate
        for (lane = 0; lane < 32; lane = lane + 1) begin : g_lane
            awq_int4bf16_mac_1_lane u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                .i_valid      (i_valid),
                .i_acc_clear  (i_acc_clear),
                .i_acc_enable (i_acc_enable),
                .i_act        (i_act[lane*16 +: 16]),
                .i_weight_q   (i_weight_q[lane*4 +: 4]),
                .i_weight_zp  (i_weight_zp),
                .o_valid      (lane_valid[lane]),
                .o_acc        (o_acc[lane*32 +: 32])
            );
        end
    endgenerate

    assign o_valid = &lane_valid;

endmodule
