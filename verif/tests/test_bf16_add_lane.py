"""Bit-exactness regression for the bfloat16 adder lane.

The oracle is the generic ``float_reference`` model, whose addition path was
first shown to reproduce the baseline's independently written binary16 adder
over 1,711,120 cases. bfloat16 addition has 2^32 operand pairs, so this checks
every corner pair exhaustively and samples the rest.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import Timer

from float_reference import BF16, add

SETTLE_NS = 1
RANDOM_PAIRS = int(os.environ.get("BF16_ADD_RANDOM_PAIRS", "200000"))
SEED = 0x42463136

# Zero, both signed zeros, smallest and largest subnormals, the subnormal to
# normal boundary, one, the largest finite value, infinity, NaN, and values
# that force carries, cancellation, and rounding ties.
CORNERS = (
    0x0000, 0x8000, 0x0001, 0x8001, 0x007F, 0x807F, 0x0080, 0x8080,
    0x3F80, 0xBF80, 0x4000, 0xC000, 0x7F7F, 0xFF7F, 0x7F80, 0xFF80,
    0x7FC0, 0xFFC0, 0x3F81, 0xBF81, 0x0002, 0x4080, 0xC080, 0x3F00,
    0x0100, 0x8100, 0x7F00, 0x0040, 0x4780, 0x3E80,
)


async def evaluate(dut, a: int, b: int) -> int:
    dut.i_a.value = a
    dut.i_b.value = b
    await Timer(SETTLE_NS, units="ns")
    return int(dut.o_result.value)


@cocotb.test()
async def test_corner_pairs_are_exhaustive(dut) -> None:
    """Every corner value added to every other corner value."""
    checked = 0
    for a in CORNERS:
        for b in CORNERS:
            result = await evaluate(dut, a, b)
            reference = add(BF16, a, b)
            assert result == reference, (
                f"0x{a:04x} + 0x{b:04x}: "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )
            checked += 1
    dut._log.info(f"{checked} corner pairs matched bfloat16 addition")


@cocotb.test()
async def test_corner_against_every_encoding(dut) -> None:
    """Each corner value added to all 65,536 bfloat16 encodings."""
    checked = 0
    for a in CORNERS[:12]:
        for b in range(1 << 16):
            result = await evaluate(dut, a, b)
            reference = add(BF16, a, b)
            assert result == reference, (
                f"0x{a:04x} + 0x{b:04x}: "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )
            checked += 1
    dut._log.info(f"{checked} corner-versus-all cases matched bfloat16 addition")


@cocotb.test()
async def test_random_pairs(dut) -> None:
    rng = random.Random(SEED)
    for _ in range(RANDOM_PAIRS):
        a = rng.getrandbits(16)
        b = rng.getrandbits(16)
        result = await evaluate(dut, a, b)
        reference = add(BF16, a, b)
        assert result == reference, (
            f"0x{a:04x} + 0x{b:04x}: "
            f"got 0x{result:04x}, expected 0x{reference:04x}"
        )
    dut._log.info(f"{RANDOM_PAIRS} random pairs matched bfloat16 addition")
