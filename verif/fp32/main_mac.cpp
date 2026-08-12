// Pipeline check for the SIMD MAC lanes.
//
// The multipliers already have their own regressions and the binary32 adders
// are checked separately. Format widening is now internal to each MAC lane, so
// this run covers it together with the four-stage plumbing. It models the
// pipeline in C -- an input applied in
// cycle N lands in the accumulator at the posedge ending cycle N+3 and is
// observable together with o_valid during cycle N+4 -- and drives randomized
// streams that interleave clear, enable and idle beats.
#include "Vtb_mac.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>

static uint32_t bits_of(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }
static float float_of(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }
static bool is_nan32(uint32_t u) { return ((u >> 23) & 0xff) == 0xff && (u & 0x7fffff) != 0; }

static uint32_t half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)((h >> 15) & 1u);
    uint32_t exp = (uint32_t)((h >> 10) & 0x1fu);
    uint32_t frac = (uint32_t)(h & 0x3ffu);
    if (exp == 0) {
        if (frac == 0) return sign << 31;
        int s = 0; uint32_t f = frac;
        while (!(f & 0x400u)) { f <<= 1; s++; }
        f &= 0x3ffu;
        return (sign << 31) | ((uint32_t)(127 - 15 + 1 - s) << 23) | (f << 13);
    }
    if (exp == 0x1f) return (sign << 31) | (0xffu << 23) | (frac << 13);
    return (sign << 31) | ((exp - 15 + 127) << 23) | (frac << 13);
}
static uint32_t bf16_to_float(uint16_t b) { return ((uint32_t)b) << 16; }

struct Op { bool valid, clear, enable; uint16_t prod; };

static const int LAT = 4;          // input cycle N -> observable in cycle N+4
static const long CYCLES = 300000;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_mac* dut = new Vtb_mac;
    std::mt19937_64 rng(777);

    Op hist_fp16[LAT + 2], hist_bf16[LAT + 2], hist_i4f[LAT + 2];
    for (int i = 0; i < LAT + 2; i++) {
        hist_fp16[i] = {false,false,false,0};
        hist_bf16[i] = {false,false,false,0};
        hist_i4f[i]  = {false,false,false,0};
    }

    uint32_t model_fp16 = 0, model_bf16 = 0, model_i4f = 0;
    bool model_valid_fp16 = false, model_valid_bf16 = false, model_valid_i4f = false;
    long fails = 0, checks = 0;

    auto tick = [&](void) { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };

    // reset
    dut->rst_n = 0; dut->clk = 0;
    dut->i_valid = 0; dut->i_acc_clear = 0; dut->i_acc_enable = 0;
    dut->i_a = 0; dut->i_b = 0; dut->i_act = 0; dut->i_act_fp16 = 0;
    dut->i_weight_q = 0; dut->i_weight_zp = 0;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1;

    for (long cycle = 0; cycle < CYCLES; cycle++) {
        // ---- drive inputs for this cycle ---------------------------------
        bool valid = (rng() % 10) != 0;              // occasional bubble
        bool clear = valid && ((rng() % 16) == 0);   // start a fresh sum
        bool enable = valid && !clear;
        // Keep magnitudes in a range where long float sums stay finite.
        uint16_t a = (uint16_t)((rng() & 0x83ffu) | (uint16_t)(((rng() % 8) + 12) << 10));
        uint16_t b = (uint16_t)((rng() & 0x83ffu) | (uint16_t)(((rng() % 8) + 12) << 10));
        uint16_t act = (uint16_t)((rng() & 0x807fu) | (uint16_t)(((rng() % 8) + 124) << 7));
        uint16_t act_fp16 = (uint16_t)((rng() & 0x83ffu) | (uint16_t)(((rng() % 8) + 12) << 10));
        uint8_t wq = (uint8_t)(rng() & 0xf), wz = (uint8_t)(rng() & 0xf);

        dut->i_valid = valid; dut->i_acc_clear = clear; dut->i_acc_enable = enable;
        dut->i_a = a; dut->i_b = b;
        dut->i_act = act; dut->i_act_fp16 = act_fp16;
        dut->i_weight_q = wq; dut->i_weight_zp = wz;
        dut->eval();   // settle combinational reference taps

        // ---- shift the model pipeline ------------------------------------
        for (int i = LAT; i > 0; i--) {
            hist_fp16[i] = hist_fp16[i-1];
            hist_bf16[i] = hist_bf16[i-1];
            hist_i4f[i]  = hist_i4f[i-1];
        }
        hist_fp16[0] = { valid, clear, enable, (uint16_t)dut->o_ref_product_fp16 };
        hist_bf16[0] = { valid, clear, enable, (uint16_t)dut->o_ref_product_bf16 };
        hist_i4f[0]  = { valid, clear, enable, (uint16_t)dut->o_ref_product_int4fp16 };

        // The op applied LAT-1 cycles ago updates the accumulator at this edge.
        Op f = hist_fp16[LAT - 1], g = hist_bf16[LAT - 1], h = hist_i4f[LAT - 1];
        if (f.valid) {
            uint32_t w = half_to_float(f.prod);
            if (f.clear) model_fp16 = w;
            else if (f.enable) model_fp16 = bits_of(float_of(model_fp16) + float_of(w));
        }
        if (g.valid) {
            uint32_t w = bf16_to_float(g.prod);
            if (g.clear) model_bf16 = w;
            else if (g.enable) model_bf16 = bits_of(float_of(model_bf16) + float_of(w));
        }
        if (h.valid) {
            uint32_t w = half_to_float(h.prod);
            if (h.clear) model_i4f = w;
            else if (h.enable) model_i4f = bits_of(float_of(model_i4f) + float_of(w));
        }
        model_valid_fp16 = f.valid;
        model_valid_bf16 = g.valid;
        model_valid_i4f  = h.valid;

        tick();

        // ---- compare in the cycle after the edge --------------------------
        if (cycle >= LAT + 2) {
            checks++;
            bool ok_f = (is_nan32(model_fp16) && is_nan32(dut->o_acc_fp16)) ||
                        (model_fp16 == dut->o_acc_fp16);
            bool ok_g = (is_nan32(model_bf16) && is_nan32(dut->o_acc_bf16)) ||
                        (model_bf16 == dut->o_acc_bf16);
            bool ok_h = (is_nan32(model_i4f) && is_nan32(dut->o_acc_int4fp16)) ||
                        (model_i4f == dut->o_acc_int4fp16);
            bool ok_vf = (dut->o_valid_fp16 != 0) == model_valid_fp16;
            bool ok_vg = (dut->o_valid_bf16 != 0) == model_valid_bf16;
            bool ok_vh = (dut->o_valid_int4fp16 != 0) == model_valid_i4f;
            if (!(ok_f && ok_g && ok_h && ok_vf && ok_vg && ok_vh)) {
                if (fails < 8)
                    printf("  cycle %ld  fp16 acc got=0x%08x want=0x%08x valid %d/%d | "
                           "bf16 acc got=0x%08x want=0x%08x valid %d/%d | "
                           "int4fp16 acc got=0x%08x want=0x%08x valid %d/%d\n",
                           cycle, dut->o_acc_fp16, model_fp16,
                           (int)dut->o_valid_fp16, (int)model_valid_fp16,
                           dut->o_acc_bf16, model_bf16,
                           (int)dut->o_valid_bf16, (int)model_valid_bf16,
                           dut->o_acc_int4fp16, model_i4f,
                           (int)dut->o_valid_int4fp16, (int)model_valid_i4f);
                fails++;
            }
        }
    }

    printf("MAC lane pipeline, %ld cycles checked: %s (%ld fail)\n",
           checks, fails ? "FAIL" : "PASS", fails);
    printf("\n%s  total failures = %ld\n", fails ? "=== FAIL ===" : "=== ALL PASS ===", fails);
    delete dut;
    return fails ? 1 : 0;
}
