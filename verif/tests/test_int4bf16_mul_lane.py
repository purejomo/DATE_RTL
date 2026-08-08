"""Exhaustive bit-exactness proof for the INT4 x bfloat16 multiplier lane.

Every asymmetric INT4 weight is an integer in [-15, +15], which bfloat16
represents exactly, so a correctly rounded INT4 x BF16 product must equal the
correctly rounded BF16 x BF16 product. The oracle is the generic
``float_reference`` model, which is itself validated against the baseline's
independently written binary16 model over all 2,031,616 (word, weight) pairs.

bfloat16 has only 65,536 encodings and INT4 only 31 distinct values, so the
whole input space of the arithmetic contract is 2,031,616 cases and is checked
exhaustively rather than sampled.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.triggers import Timer

from float_reference import BF16, encode_small_integer, multiply

SETTLE_NS = 1
WEIGHT_VALUES = tuple(range(-15, 16))
EXHAUSTIVE = os.environ.get("INT4BF16_EXHAUSTIVE", "1") == "1"
SAMPLED_STRIDE = int(os.environ.get("INT4BF16_STRIDE", "97"))


def representative_encoding(weight: int) -> tuple[int, int]:
    """Pick one (q, zero_point) pair that decodes to ``weight``."""
    if weight >= 0:
        return weight, 0
    return 0, -weight


async def evaluate(dut, act: int, q: int, zp: int) -> int:
    dut.i_act.value = act
    dut.i_weight_q.value = q
    dut.i_weight_zp.value = zp
    await Timer(SETTLE_NS, units="ns")
    return int(dut.o_result.value)


@cocotb.test()
async def test_int4_decode_is_exhaustive(dut) -> None:
    """All 256 (q, zero_point) pairs decode to the arithmetic they claim."""
    one = 0x3F80  # bfloat16 1.0
    for q in range(16):
        for zp in range(16):
            result = await evaluate(dut, one, q, zp)
            reference = multiply(BF16, one, encode_small_integer(BF16, q - zp))
            assert result == reference, (
                f"q={q} zp={zp} (weight {q - zp}): "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )


@cocotb.test()
async def test_all_activations_against_all_weights(dut) -> None:
    """Every bfloat16 encoding against every distinct INT4 weight."""
    stride = 1 if EXHAUSTIVE else SAMPLED_STRIDE
    checked = 0
    for weight in WEIGHT_VALUES:
        q, zp = representative_encoding(weight)
        encoded = encode_small_integer(BF16, weight)
        for act in range(0, 1 << 16, stride):
            result = await evaluate(dut, act, q, zp)
            reference = multiply(BF16, act, encoded)
            assert result == reference, (
                f"act=0x{act:04x} weight={weight}: "
                f"got 0x{result:04x}, expected 0x{reference:04x}"
            )
            checked += 1
    scope = "exhaustive" if EXHAUSTIVE else f"strided by {stride}"
    dut._log.info(f"{checked} {scope} cases matched bfloat16 multiply")
