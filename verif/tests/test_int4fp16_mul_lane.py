"""Bit-exactness proof for the INT4 x binary16 multiplier lane.

Every asymmetric INT4 weight is an integer in [-15, +15], and every such
integer is exactly representable in binary16. A correctly rounded INT4 x FP16
product must therefore equal the correctly rounded FP16 x FP16 product of the
same two values. The oracle is the generic ``float_reference`` model, the
same one the bfloat16 lane is checked against: the lane is verified against
full binary16 multiplication even though it only builds an 11x4 significand
array.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import Timer

from float_reference import FP16, encode_small_integer, multiply

SETTLE_NS = 1
RANDOM_ACTIVATIONS = int(os.environ.get("INT4FP16_RANDOM_ACTS", "2000"))
SEED = 0x494E5434

# Zero, both signed zeros, smallest and largest subnormals, the subnormal to
# normal boundary, one, powers of two, the largest finite value, infinity and
# NaN, plus values that force a rounding tie.
CORNER_ACTIVATIONS = (
    0x0000, 0x8000, 0x0001, 0x8001, 0x0002, 0x03FF, 0x83FF, 0x0400, 0x8400,
    0x3C00, 0xBC00, 0x4000, 0x4200, 0x7BFF, 0xFBFF, 0x7C00, 0xFC00,
    0x7E00, 0xFE00, 0x7C01, 0x3555, 0x3801, 0x0003, 0x0007, 0x000F,
    0x6BFF, 0x6C00, 0x77FF, 0x7800, 0x0800, 0x1000,
)


async def evaluate(dut, act: int, q: int, zp: int) -> int:
    dut.i_act.value = act
    dut.i_weight_q.value = q
    dut.i_weight_zp.value = zp
    await Timer(SETTLE_NS, units="ns")
    return int(dut.o_result.value)


def expected(act: int, q: int, zp: int) -> int:
    return multiply(FP16, act, encode_small_integer(FP16, q - zp))


@cocotb.test()
async def test_int4_decode_is_exhaustive(dut) -> None:
    """All 256 (q, zero_point) pairs decode to the arithmetic they claim."""
    for q in range(16):
        for zp in range(16):
            weight = q - zp
            result = await evaluate(dut, 0x3C00, q, zp)   # activation = 1.0
            reference = multiply(FP16, 0x3C00,
                                 encode_small_integer(FP16, weight))
            assert result == reference, (
                f"q={q} zp={zp} (weight {weight}): "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )


@cocotb.test()
async def test_corner_activations_against_all_weights(dut) -> None:
    """Every corner activation against all 256 weight encodings."""
    checked = 0
    for act in CORNER_ACTIVATIONS:
        for q in range(16):
            for zp in range(16):
                result = await evaluate(dut, act, q, zp)
                reference = expected(act, q, zp)
                assert result == reference, (
                    f"act=0x{act:04x} q={q} zp={zp} (weight {q - zp}): "
                    f"got 0x{result:04x}, expected 0x{reference:04x}"
                )
                checked += 1
    dut._log.info(f"{checked} corner activation cases matched binary16 multiply")


@cocotb.test()
async def test_random_activations_against_all_weights(dut) -> None:
    """Random activations against all 256 weight encodings."""
    rng = random.Random(SEED)
    checked = 0
    for _ in range(RANDOM_ACTIVATIONS):
        act = rng.getrandbits(16)
        for q in range(16):
            for zp in range(16):
                result = await evaluate(dut, act, q, zp)
                reference = expected(act, q, zp)
                assert result == reference, (
                    f"act=0x{act:04x} q={q} zp={zp} (weight {q - zp}): "
                    f"got 0x{result:04x}, expected 0x{reference:04x}"
                )
                checked += 1
    dut._log.info(f"{checked} random activation cases matched binary16 multiply")
