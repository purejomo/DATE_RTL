// Pipeline check for the SIMD MAC lane.
//
// The multiplier already has its own regression and the binary32 adder is
// checked separately. Format widening is internal to the MAC lane, so this run
// covers it together with the four-stage plumbing. It models the pipeline in C
// -- an input applied in cycle N lands in the accumulator at the posedge ending
// cycle N+3 and is observable together with o_valid during cycle N+4 -- and
// drives randomized streams that interleave clear, enable and idle beats.
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

struct Op { bool valid, clear, enable; uint16_t prod; };

static const int LAT = 4;          // input cycle N -> observable in cycle N+4
static const long CYCLES = 300000;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_mac* dut = new Vtb_mac;
    std::mt19937_64 rng(777);

    Op hist_fp16[LAT + 2];
    for (int i = 0; i < LAT + 2; i++) hist_fp16[i] = {false,false,false,0};

    uint32_t model_fp16 = 0;
    bool model_valid_fp16 = false;
    long fails = 0, checks = 0;

    auto tick = [&](void) { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };

    // reset
    dut->rst_n = 0; dut->clk = 0;
    dut->i_valid = 0; dut->i_acc_clear = 0; dut->i_acc_enable = 0;
    dut->i_a = 0; dut->i_b = 0;
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

        dut->i_valid = valid; dut->i_acc_clear = clear; dut->i_acc_enable = enable;
        dut->i_a = a; dut->i_b = b;
        dut->eval();   // settle combinational reference tap

        // ---- shift the model pipeline ------------------------------------
        for (int i = LAT; i > 0; i--) hist_fp16[i] = hist_fp16[i-1];
        hist_fp16[0] = { valid, clear, enable, (uint16_t)dut->o_ref_product_fp16 };

        // The op applied LAT-1 cycles ago updates the accumulator at this edge.
        Op f = hist_fp16[LAT - 1];
        if (f.valid) {
            uint32_t w = half_to_float(f.prod);
            if (f.clear) model_fp16 = w;
            else if (f.enable) model_fp16 = bits_of(float_of(model_fp16) + float_of(w));
        }
        model_valid_fp16 = f.valid;

        tick();

        // ---- compare in the cycle after the edge --------------------------
        if (cycle >= LAT + 2) {
            checks++;
            bool ok_f = (is_nan32(model_fp16) && is_nan32(dut->o_acc_fp16)) ||
                        (model_fp16 == dut->o_acc_fp16);
            bool ok_vf = (dut->o_valid_fp16 != 0) == model_valid_fp16;
            if (!(ok_f && ok_vf)) {
                if (fails < 8)
                    printf("  cycle %ld  fp16 acc got=0x%08x want=0x%08x valid %d/%d\n",
                           cycle, dut->o_acc_fp16, model_fp16,
                           (int)dut->o_valid_fp16, (int)model_valid_fp16);
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
