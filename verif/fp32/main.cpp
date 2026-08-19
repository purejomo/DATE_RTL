// Golden-model check for the binary32 accumulation adder.
//
// The adder uses a reduced contract: normal finite inputs use RNE,
// exponent-zero inputs are DAZ, subnormal outputs are FTZ, and NaN/infinity
// inputs are outside the supported domain.
#include "Vtb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

static uint32_t bits_of(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }
static float float_of(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }
static bool supported32(uint32_t u) {
    return ((u >> 23) & 0xffu) != 0xffu;
}
static uint32_t daz32(uint32_t u) {
    return (((u >> 23) & 0xffu) == 0u) ? (u & 0x80000000u) : u;
}
static uint32_t add_ftz(uint32_t a, uint32_t b) {
    uint32_t sum = bits_of(float_of(daz32(a)) + float_of(daz32(b)));
    return (((sum >> 23) & 0xffu) == 0u) ? (sum & 0x80000000u) : sum;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_top* dut = new Vtb_top;
    long fails = 0;

    // ---- adder: corner x corner ------------------------------------------
    std::vector<uint32_t> corners = {
        0x00000000u, 0x80000000u,             // +0 -0
        0x00000001u, 0x80000001u,             // min subnormal
        0x007fffffu, 0x807fffffu,             // max subnormal
        0x00800000u, 0x80800000u,             // min normal
        0x3f800000u, 0xbf800000u,             // +-1
        0x3f800001u, 0xbf800001u,             // 1+ulp
        0x40000000u, 0xc0000000u,             // +-2
        0x7f7fffffu, 0xff7fffffu,             // max finite
        0x7f800000u, 0xff800000u,             // +-inf
        0x7fc00000u, 0xffc00000u,             // quiet NaN
        0x7f800001u,                          // signaling NaN
        0x33800000u, 0xb3800000u,             // 2^-24 (rounding boundary vs 1)
        0x4b800000u, 0xcb800000u,             // 2^24
        0x00000002u, 0x00000003u,
    };
    long hbmpim_corner_fail = 0;
    long supported_corner_n = 0;
    for (uint32_t a : corners) {
        for (uint32_t b : corners) {
            if (!supported32(a) || !supported32(b)) continue;
            dut->i_a = a; dut->i_b = b;
            dut->eval();
            uint32_t want = add_ftz(a, b);
            uint32_t got_hbmpim = dut->o_sum_hbmpim;
            supported_corner_n++;
            if (got_hbmpim != want) {
                if (hbmpim_corner_fail < 8)
                    printf("  hbmpim DAZ/FTZ add MISMATCH "
                           "a=0x%08x b=0x%08x got=0x%08x want=0x%08x\n",
                           a, b, got_hbmpim, want);
                hbmpim_corner_fail++;
            }
        }
    }
    printf("hbmpim_fp32_add supported corners (%ld): %s (%ld fail)\n",
           supported_corner_n, hbmpim_corner_fail ? "FAIL" : "PASS",
           hbmpim_corner_fail);
    fails += hbmpim_corner_fail;

    // ---- adder: random ----------------------------------------------------
    std::mt19937_64 rng(20260811);
    long hbmpim_rand_fail = 0, supported_rand_n = 0;
    const long RAND_N = 4000000;
    for (long i = 0; i < RAND_N; i++) {
        uint32_t a, b;
        int mode = (int)(rng() % 4);
        if (mode == 0) {            // fully random bit patterns
            a = (uint32_t)rng(); b = (uint32_t)rng();
        } else if (mode == 1) {     // same exponent region: exercises cancellation
            uint32_t e = (uint32_t)(rng() % 254u) + 1u;
            a = ((uint32_t)(rng() & 1u) << 31) | (e << 23) | (uint32_t)(rng() & 0x7fffffu);
            b = ((uint32_t)(rng() & 1u) << 31) | (e << 23) | (uint32_t)(rng() & 0x7fffffu);
        } else if (mode == 2) {     // near exponents: exercises alignment + sticky
            uint32_t e = (uint32_t)(rng() % 250u) + 2u;
            uint32_t d = (uint32_t)(rng() % 30u);
            a = ((uint32_t)(rng() & 1u) << 31) | (e << 23) | (uint32_t)(rng() & 0x7fffffu);
            uint32_t e2 = (e > d) ? (e - d) : 1u;
            b = ((uint32_t)(rng() & 1u) << 31) | (e2 << 23) | (uint32_t)(rng() & 0x7fffffu);
        } else {                    // subnormal-heavy
            a = ((uint32_t)(rng() & 1u) << 31) | (uint32_t)(rng() & 0x7fffffu);
            b = ((uint32_t)(rng() & 1u) << 31) | (uint32_t)(rng() & 0x7fffffu);
        }
        if (!supported32(a) || !supported32(b)) continue;
        dut->i_a = a; dut->i_b = b;
        dut->eval();
        uint32_t want = add_ftz(a, b);
        uint32_t got_hbmpim = dut->o_sum_hbmpim;
        supported_rand_n++;
        if (got_hbmpim != want) {
            if (hbmpim_rand_fail < 8)
                printf("  hbmpim DAZ/FTZ add MISMATCH "
                       "a=0x%08x b=0x%08x got=0x%08x want=0x%08x\n",
                       a, b, got_hbmpim, want);
            hbmpim_rand_fail++;
        }
    }
    printf("hbmpim_fp32_add supported random (%ld): %s (%ld fail)\n",
           supported_rand_n, hbmpim_rand_fail ? "FAIL" : "PASS",
           hbmpim_rand_fail);
    fails += hbmpim_rand_fail;

    printf("\n%s  total failures = %ld\n", fails ? "=== FAIL ===" : "=== ALL PASS ===", fails);
    delete dut;
    return fails ? 1 : 0;
}
