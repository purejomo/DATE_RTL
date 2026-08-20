`timescale 1ns/1ps

module rabit_fs_y_pack1to4 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid_i,
    input  wire [15:0]  data_i,
    input  wire [4:0]   beat_i,
    input  wire         last_i,
    output logic        valid_o,
    output logic [63:0] data_o,
    output logic [2:0]  beat_o,
    output logic        last_o
);
    logic [15:0] lane0_q;
    logic [15:0] lane1_q;
    logic [15:0] lane2_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lane0_q <= 16'd0;
            lane1_q <= 16'd0;
            lane2_q <= 16'd0;
            valid_o <= 1'b0;
            data_o  <= 64'd0;
            beat_o  <= 3'd0;
            last_o  <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            last_o  <= 1'b0;
            if (valid_i) begin
                case (beat_i[1:0])
                    2'd0: lane0_q <= data_i;
                    2'd1: lane1_q <= data_i;
                    2'd2: lane2_q <= data_i;
                    default: begin
                        valid_o <= 1'b1;
                        data_o  <= {data_i, lane2_q, lane1_q, lane0_q};
                        beat_o  <= beat_i[4:2];
                        last_o  <= last_i;
                    end
                endcase
            end
        end
    end
endmodule
