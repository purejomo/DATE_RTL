`timescale 1ns/1ps
// ---- per-module breakdown wrappers ---------------------------------------

// Purely combinational, exactly as it sits in the top: the converter drives the
// GRF write port directly. No wrapper registers, so the reported area is the
// convert logic and nothing else; constraint.sdc falls back to a virtual clock
// for a block with no clock port and still budgets the input-to-output path.
module rabit_blk_cvt (
    input  wire [255:0] fp16_i,
    input  wire [5:0]   e0_i,
    output wire [207:0] blk_o,
    output wire [5:0]   e_ent_o,
    output wire         ovf_o
);
    rabit_cvt_fp16_blk #(.NIN(16), .MANT_W(12), .EXP_W(6), .SHIFTER_EN(1))
        u_cvt (
            .fp16_i  (fp16_i),
            .e0_i    (e0_i),
            .blk_o   (blk_o),
            .e_ent_o (e_ent_o),
            .ovf_o   (ovf_o)
        );
endmodule
