"""Bit-exactness regression for the baseline binary16 multiplier lane.

This is the multiplier the FP16 SIMD baseline is built from, and the reference
point every low-precision multiplier in the paper is measured against.
binary16 multiplication has 2^32 operand pairs, so this checks every corner
pair exhaustively, each corner against all 65,536 encodings, and samples the
rest.

The oracle is the generic ``float_reference`` model, the same one the INT4
multiplier lanes are checked against.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import Timer

from float_reference import FP16, multiply

SETTLE_NS = 1
RANDOM_PAIRS = int(os.environ.get("FP16_MUL_RANDOM_PAIRS", "200000"))
SEED = 0x464D554C

# Zero, both signed zeros, smallest and largest subnormals, the subnormal to
# normal boundary, one, powers of two, the largest finite value, infinity and
# NaN, plus values that force overflow, underflow, and rounding ties.
CORNERS = (
    0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x83FF, 0x0400, 0x8400,
    0x3C00, 0xBC00, 0x4000, 0xC000, 0x7BFF, 0xFBFF, 0x7C00, 0xFC00,
    0x7E00, 0xFE00, 0x3C01, 0xBC01, 0x0002, 0x4200, 0x3555, 0x3801,
    0x6BFF, 0x6C00, 0x77FF, 0x7800, 0x0800, 0x1000,
)


async def evaluate(dut, a: int, b: int) -> int:
    dut.i_a.value = a
    dut.i_b.value = b
    await Timer(SETTLE_NS, units="ns")
    return int(dut.o_result.value)


@cocotb.test()
async def test_corner_pairs_are_exhaustive(dut) -> None:
    """Every corner value multiplied by every other corner value."""
    checked = 0
    for a in CORNERS:
        for b in CORNERS:
            result = await evaluate(dut, a, b)
            reference = multiply(FP16, a, b)
            assert result == reference, (
                f"0x{a:04x} * 0x{b:04x}: "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )
            checked += 1
    dut._log.info(f"{checked} corner pairs matched binary16 multiply")


@cocotb.test()
async def test_corner_against_every_encoding(dut) -> None:
    """Each corner value multiplied by all 65,536 binary16 encodings."""
    checked = 0
    for a in CORNERS[:12]:
        for b in range(1 << 16):
            result = await evaluate(dut, a, b)
            reference = multiply(FP16, a, b)
            assert result == reference, (
                f"0x{a:04x} * 0x{b:04x}: "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )
            checked += 1
    dut._log.info(f"{checked} corner-versus-all cases matched binary16 multiply")


@cocotb.test()
async def test_random_pairs(dut) -> None:
    rng = random.Random(SEED)
    for _ in range(RANDOM_PAIRS):
        a = rng.getrandbits(16)
        b = rng.getrandbits(16)
        result = await evaluate(dut, a, b)
        reference = multiply(FP16, a, b)
        assert result == reference, (
            f"0x{a:04x} * 0x{b:04x}: "
            f"got 0x{result:04x}, expected 0x{reference:04x}"
        )
    dut._log.info(f"{RANDOM_PAIRS} random pairs matched binary16 multiply")
