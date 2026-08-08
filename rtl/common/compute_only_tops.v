`timescale 1ns/1ps

// Compute-only synthesis boundaries.
//
// The comparison table needs arithmetic area with no register file, no control
// and no buffers. These wrappers expose exactly the multiplier and adder banks
// of each SIMD design so that every row is measured at the same boundary.
//
// The P3-LLM-organized designs are measured at their PCU boundary instead
// (int4fp16_pcu_top, int4bf16_pcu_top, p3llm_pcu), because their accumulators
// live inside the processing elements and cannot be separated from the
// arithmetic without changing the architecture. That asymmetry is reported
// alongside the numbers rather than hidden.
//
// This file intentionally holds several synthesis tops, like the baseline's
// hbmpim_block_synth_tops.v, so the filename cannot match every module name.
/* verilator lint_off DECLFILENAME */

// HBM-PIM FP16: sixteen multiplier lanes and sixteen adder lanes.
module hbmpim_compute_16 (
    input  wire [255:0] i_mul_a,
    input  wire [255:0] i_mul_b,
    input  wire [255:0] i_add_a,
    input  wire [255:0] i_add_b,
    output wire [255:0] o_product,
    output wire [255:0] o_sum
);
    hbmpim_simd_mul u_mul (.i_a(i_mul_a), .i_b(i_mul_b), .o_result(o_product));
    hbmpim_simd_add u_add (.i_a(i_add_a), .i_b(i_add_b), .o_result(o_sum));
endmodule

// INT4 x binary16: sixteen multiplier lanes and sixteen adder lanes. This is
// the iso-operator-count point against the FP16 baseline: the same lane count,
// the same organization, only the multiplier's weight operand narrowed to four
// bits. It isolates what the precision change alone costs, before any lane
// scaling is credited to it.
module int4fp16_compute_16 (
    input  wire [255:0] i_act,
    input  wire [63:0]  i_weight_q,
    input  wire [3:0]   i_weight_zp,
    input  wire [255:0] i_add_a,
    input  wire [255:0] i_add_b,
    output wire [255:0] o_product,
    output wire [255:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
            int4fp16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            hbmpim_fp16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule

// INT4 x bfloat16: sixteen multiplier lanes and sixteen adder lanes.
module int4bf16_compute_16 (
    input  wire [255:0] i_act,
    input  wire [63:0]  i_weight_q,
    input  wire [3:0]   i_weight_zp,
    input  wire [255:0] i_add_a,
    input  wire [255:0] i_add_b,
    output wire [255:0] o_product,
    output wire [255:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
            int4bf16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            bf16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule

// INT4 x binary16: thirty-two multiplier lanes and thirty-two adder lanes.
module int4fp16_compute_32 (
    input  wire [511:0] i_act,
    input  wire [127:0] i_weight_q,
    input  wire [3:0]   i_weight_zp,
    input  wire [511:0] i_add_a,
    input  wire [511:0] i_add_b,
    output wire [511:0] o_product,
    output wire [511:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 32; lane = lane + 1) begin : g_lane
            int4fp16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            hbmpim_fp16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule

// INT4 x bfloat16: thirty-two multiplier lanes and thirty-two adder lanes.
module int4bf16_compute_32 (
    input  wire [511:0] i_act,
    input  wire [127:0] i_weight_q,
    input  wire [3:0]   i_weight_zp,
    input  wire [511:0] i_add_a,
    input  wire [511:0] i_add_b,
    output wire [511:0] o_product,
    output wire [511:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 32; lane = lane + 1) begin : g_lane
            int4bf16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            bf16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule

// INT4 x binary16: sixty-four multiplier and adder lanes.
module int4fp16_compute_64 (
    input  wire [1023:0] i_act,
    input  wire [255:0]  i_weight_q,
    input  wire [3:0]    i_weight_zp,
    input  wire [1023:0] i_add_a,
    input  wire [1023:0] i_add_b,
    output wire [1023:0] o_product,
    output wire [1023:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 64; lane = lane + 1) begin : g_lane
            int4fp16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            hbmpim_fp16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule

// INT4 x bfloat16: sixty-four multiplier and adder lanes.
module int4bf16_compute_64 (
    input  wire [1023:0] i_act,
    input  wire [255:0]  i_weight_q,
    input  wire [3:0]    i_weight_zp,
    input  wire [1023:0] i_add_a,
    input  wire [1023:0] i_add_b,
    output wire [1023:0] o_product,
    output wire [1023:0] o_sum
);
    genvar lane;
    generate
        for (lane = 0; lane < 64; lane = lane + 1) begin : g_lane
            int4bf16_mul_lane u_mul (
                .i_act       (i_act[lane*16 +: 16]),
                .i_weight_q  (i_weight_q[lane*4 +: 4]),
                .i_weight_zp (i_weight_zp),
                .o_result    (o_product[lane*16 +: 16])
            );
            bf16_add_lane u_add (
                .i_a      (i_add_a[lane*16 +: 16]),
                .i_b      (i_add_b[lane*16 +: 16]),
                .o_result (o_sum[lane*16 +: 16])
            );
        end
    endgenerate
endmodule
