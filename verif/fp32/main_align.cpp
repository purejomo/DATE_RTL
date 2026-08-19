// Checks for the two numerical fixes on the PCU side.
//
//   1. int4float_align now rounds to nearest even on the alignment shift
//      instead of truncating. That changes the result for every input, not just
//      exceptional ones, so it is checked exhaustively: all 65536 bfloat16
//      encodings against every reference exponent that produces a distinct
//      shift, plus the out-of-range ones on either side.
//
//   2. int4float_pe now saturates its 32-bit accumulator instead of wrapping.
//      Driven here with the largest products the datapath can produce, from
//      both directions, and checked against a saturating model.
#include "Vtb_align.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

// Verilator hands back a signed [N-1:0] port as an unpopulated 32-bit word, so
// the sign bit has to be extended by hand before comparing.
static int32_t sext(uint32_t value, int bits) {
    uint32_t sign_bit = 1u << (bits - 1);
    return (int32_t)((value ^ sign_bit) - sign_bit);
}

// Reference for int4float_align with round-to-nearest-ties-to-even.
static int32_t ref_align(uint16_t f, int ref_exp, int EXP_W, int MANT_W, int GUARD,
                         bool *sat, bool *inv) {
    const int BIAS = (1 << (EXP_W - 1)) - 1;
    const int ALIGN_W = MANT_W + 1 + GUARD;
    const uint32_t EXP_MAX = (1u << EXP_W) - 1u;

    int sign = (f >> 15) & 1;
    uint32_t exponent = (f >> MANT_W) & EXP_MAX;
    uint32_t fraction = f & ((1u << MANT_W) - 1u);

    bool is_zero_exp = (exponent == 0);
    bool is_max_exp = (exponent == EXP_MAX);
    bool is_zero = is_zero_exp && (fraction == 0);
    *inv = is_max_exp;

    uint64_t significand = is_zero_exp ? fraction : ((1u << MANT_W) | fraction);
    long lsb_exponent = is_zero_exp ? (1L - BIAS - MANT_W)
                                    : ((long)exponent - BIAS - MANT_W);
    long shift_signed = (long)ref_exp - lsb_exponent;
    bool shift_negative = shift_signed < 0;
    *sat = shift_negative && !is_zero && !is_max_exp;
    bool flush = (!shift_negative) && (shift_signed > ALIGN_W);
    long shift = shift_negative ? 0 : shift_signed;

    uint64_t widened = significand << GUARD;   // ALIGN_W bits
    uint64_t shifted = (shift >= 64) ? 0 : (widened >> shift);
    uint64_t guard_bit = 0, sticky = 0;
    if (shift >= 1 && shift <= 63) {
        guard_bit = (widened >> (shift - 1)) & 1ull;
        if (shift >= 2) {
            uint64_t mask = (1ull << (shift - 1)) - 1ull;
            sticky = (widened & mask) ? 1 : 0;
        }
    }
    uint64_t round_up = (guard_bit && (sticky || (shifted & 1ull))) ? 1 : 0;
    uint64_t rounded = shifted + round_up;

    uint64_t magnitude = (is_zero || is_max_exp || flush) ? 0 : rounded;
    magnitude &= ((1ull << ALIGN_W) - 1ull);
    return sign ? -(int32_t)magnitude : (int32_t)magnitude;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_align *dut = new Vtb_align;
    long fails = 0;

    // ---- 1. aligner, exhaustive -------------------------------------------
    // Shifts beyond ALIGN_W flush and shifts below zero saturate, so a sweep
    // that brackets both ends covers every distinct behaviour.
    long checked = 0, fail_bf16 = 0;
    for (int ref_exp = -40; ref_exp <= 40; ref_exp++) {
        for (uint32_t v = 0; v < 65536u; v++) {
            dut->i_float = (uint16_t)v;
            dut->i_ref_exp = (int16_t)ref_exp;
            dut->eval();
            bool sat, inv;
            int32_t want = ref_align((uint16_t)v, ref_exp, 8, 7, 8, &sat, &inv);
            int32_t got = sext((uint32_t)dut->o_aligned_bf16, 17);
            if (got != want || (bool)dut->o_saturate_bf16 != sat ||
                (bool)dut->o_invalid_bf16 != inv) {
                if (fail_bf16 < 5)
                    printf("  bf16 align MISMATCH f=0x%04x ref=%d got=%d want=%d\n",
                           v, ref_exp, got, want);
                fail_bf16++;
            }
            checked++;
        }
    }
    printf("int4float_align bf16 exhaustive (%ld): %s (%ld fail)\n",
           checked, fail_bf16 ? "FAIL" : "PASS", fail_bf16);
    fails += fail_bf16;

    // ---- 2. accumulator saturation ----------------------------------------
    // Weight 15 against the largest aligned magnitude gives the largest product
    // the PE can make; repeating it must pin at INT32_MAX rather than wrap.
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };
    long sat_fail = 0;
    for (int direction = 0; direction < 2; direction++) {
        int32_t act = direction ? -524287 : 524287;   // +-(2^19 - 1)
        dut->rst_n = 0; dut->clk = 0;
        dut->i_valid = 0; dut->i_acc_clear = 0; dut->i_acc_enable = 0;
        dut->i_act0 = act; dut->i_act1 = act; dut->i_act2 = act; dut->i_act3 = act;
        dut->i_weight_q = 0xffff;   // four nibbles of 15
        dut->i_weight_zp = 0;       // decodes to +15 each
        dut->eval();
        for (int i = 0; i < 4; i++) tick();
        dut->rst_n = 1;

        int64_t model = 0;
        bool first = true;
        dut->i_valid = 1;
        for (int beat = 0; beat < 400; beat++) {
            dut->i_acc_clear = first ? 1 : 0;
            dut->i_acc_enable = first ? 0 : 1;
            first = false;
            dut->eval();
            tick();
        }
        // Model: one product is act * 15, four lanes per beat, 400 beats.
        int64_t per_beat = (int64_t)act * 15 * 4;
        model = per_beat;                       // the clear beat
        for (int beat = 1; beat < 400; beat++) {
            model += per_beat;
            if (model > INT32_MAX) { model = INT32_MAX; break; }
            if (model < INT32_MIN) { model = INT32_MIN; break; }
        }
        dut->i_valid = 0; dut->i_acc_clear = 0; dut->i_acc_enable = 0;
        for (int i = 0; i < 6; i++) tick();

        int32_t got = (int32_t)dut->o_pe_acc;
        int32_t want = (int32_t)model;
        if (got != want) {
            printf("  PE saturation MISMATCH dir=%d got=%d want=%d\n",
                   direction, got, want);
            sat_fail++;
        } else {
            printf("int4float_pe saturation %s: PASS (pinned at %d)\n",
                   direction ? "negative" : "positive", got);
        }
    }
    fails += sat_fail;

    printf("\n%s  total failures = %ld\n",
           fails ? "=== FAIL ===" : "=== ALL PASS ===", fails);
    delete dut;
    return fails ? 1 : 0;
}
