`timescale 1ns/1ps

// Exposes three convert-on-write configurations at once so one cocotb test can
// exercise the MANT_W sweep and the SHIFTER_EN = 0 alignment mode against the
// same stimulus.
module rabit_cvt_tb (
    input  logic [255:0] fp16_i,
    input  logic [5:0]   e0_i,

    // MANT_W = 12, per-entry shared exponent (the delivered configuration)
    output logic [207:0] m12_blk_o,
    output logic [5:0]   m12_eent_o,
    output logic         m12_ovf_o,

    // MANT_W = 10, per-entry shared exponent
    output logic [175:0] m10_blk_o,
    output logic [5:0]   m10_eent_o,
    output logic         m10_ovf_o,

    // MANT_W = 12, aligned to the global reference instead
    output logic [207:0] g12_blk_o,
    output logic [5:0]   g12_eent_o,
    output logic         g12_ovf_o
);

    rabit_cvt_fp16_blk #(.NIN(16), .MANT_W(12), .EXP_W(6), .SHIFTER_EN(1))
        u_m12 (
            .fp16_i  (fp16_i),
            .e0_i    (e0_i),
            .blk_o   (m12_blk_o),
            .e_ent_o (m12_eent_o),
            .ovf_o   (m12_ovf_o)
        );

    rabit_cvt_fp16_blk #(.NIN(16), .MANT_W(10), .EXP_W(6), .SHIFTER_EN(1))
        u_m10 (
            .fp16_i  (fp16_i),
            .e0_i    (e0_i),
            .blk_o   (m10_blk_o),
            .e_ent_o (m10_eent_o),
            .ovf_o   (m10_ovf_o)
        );

    rabit_cvt_fp16_blk #(.NIN(16), .MANT_W(12), .EXP_W(6), .SHIFTER_EN(0))
        u_g12 (
            .fp16_i  (fp16_i),
            .e0_i    (e0_i),
            .blk_o   (g12_blk_o),
            .e_ent_o (g12_eent_o),
            .ovf_o   (g12_ovf_o)
        );

endmodule
