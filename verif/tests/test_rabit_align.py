"""Unit test for the exponent aligner, both rounding modes.

The aligner is a pure function of (psum, shift), so this sweeps the entire
shift range against every interesting partial sum instead of sampling.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import Timer

from common import signed_from_bits
from rabit_model import ACC_W, align

PSUM_W = 17
SH_W = 7
PSUM_MAX = (1 << (PSUM_W - 1)) - 1
PSUM_MIN = -(1 << (PSUM_W - 1))
SHL_MAX = ACC_W - PSUM_W  # 15
SHIFT_RANGE = range(-(1 << (SH_W - 1)), 1 << (SH_W - 1))  # -64 .. 63


async def check(dut, psum, shift):
    dut.psum_i.value = psum & ((1 << PSUM_W) - 1)
    dut.shift_i.value = shift & ((1 << SH_W) - 1)
    await Timer(1, units="ns")

    for prefix, rnd in (("trunc", 0), ("round", 1)):
        expected, sat = align(
            psum, shift, psum_w=PSUM_W, acc_w=ACC_W, shift_rnd=rnd
        )
        got = signed_from_bits(int(getattr(dut, f"{prefix}_o").value), ACC_W)
        got_sat = int(getattr(dut, f"{prefix}_sat_o").value)
        assert got == expected, (
            f"{prefix}: psum {psum} shift {shift} -> {got}, expected {expected}"
        )
        assert got_sat == int(sat), (
            f"{prefix}: psum {psum} shift {shift} -> sat {got_sat}, "
            f"expected {int(sat)}"
        )


@cocotb.test()
async def test_align(dut):
    # Corners of the partial-sum range plus the values that make rounding
    # decisions interesting: exact halves, one either side of a half, and the
    # boundary where an arithmetic right shift bottoms out at -1.
    corners = [
        0, 1, -1, 2, -2, 3, -3,
        PSUM_MAX, PSUM_MIN, PSUM_MAX - 1, PSUM_MIN + 1,
        65504, -65504,          # the largest magnitudes a 12-bit block yields
        1 << 16, -(1 << 16),    # exact half at the largest right shift
        (1 << 16) - 1, -((1 << 16) - 1),
        (1 << 15), -(1 << 15),
        0x5555, -0x5555, 0x2AAA, -0x2AAA,
    ]
    for psum in corners:
        if not PSUM_MIN <= psum <= PSUM_MAX:
            continue
        for shift in SHIFT_RANGE:
            await check(dut, psum, shift)

    # Every shift magnitude against a value that has a set bit at each position,
    # which walks the round/sticky boundary across the whole barrel shifter.
    for bit in range(PSUM_W - 1):
        for psum in ((1 << bit), -(1 << bit), (1 << bit) | 1, -((1 << bit) | 1)):
            if not PSUM_MIN <= psum <= PSUM_MAX:
                continue
            for shift in range(-PSUM_W - 2, SHL_MAX + 3):
                await check(dut, psum, shift)

    iters = int(os.environ.get("RABIT_ALIGN_ITERS", "4000"))
    rng = random.Random(0xA11)
    for _ in range(iters):
        psum = rng.randrange(PSUM_MIN, PSUM_MAX + 1)
        shift = rng.choice(
            [rng.randrange(-64, 64), rng.randrange(-20, 20), 0, SHL_MAX, SHL_MAX + 1]
        )
        await check(dut, psum, shift)
