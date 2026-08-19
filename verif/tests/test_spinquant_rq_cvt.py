"""Exhaustive-by-construction regression for the SpinQuant requantizer's
binary32 -> unsigned INT4 converter.

The reference is Python's ``Decimal.to_integral_value(ROUND_HALF_EVEN)``, which
is exact: the input is a binary32 and every binary32 is a Decimal, so no host
floating point rounds anywhere in the comparison. That matters because the
whole claim about this module is that it rounds the same way the rest of the
repository does.

Coverage is aimed at where the module's case analysis switches:

    exponent >= 132   saturate to magnitude 32
    exponent <= 125   flush to zero
    126 .. 131        the six real shift arms, one per case

so the sweep deliberately over-samples 118..137 and walks every one of the six
arms with random fractions, ties included. Ties are the interesting inputs:
half-even is the one rule a naive implementation gets wrong.
"""

from __future__ import annotations

import os
import random
import struct
from decimal import Decimal

import cocotb
from cocotb.triggers import Timer


def bits_of(value: float) -> int:
    return struct.unpack(">I", struct.pack(">f", value))[0]


def float_of(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def reference(bits: int, zp: int) -> tuple[int, int, int]:
    """(q4, clamped, invalid) the RTL must produce."""

    exponent = (bits >> 23) & 0xFF
    sign = bits >> 31
    if exponent == 0xFF:                       # inf or NaN
        invalid = 1
        magnitude = -32 if sign else 32
    else:
        invalid = 0
        magnitude = int(
            Decimal(float_of(bits)).to_integral_value(rounding="ROUND_HALF_EVEN")
        )
        magnitude = max(-32, min(32, magnitude))
    shifted = magnitude + zp
    clamped = 1 if (shifted < 0 or shifted > 15) else 0
    return (max(0, min(15, shifted)), clamped, invalid)


def stimulus(count: int):
    rng = random.Random(0xB16B00B5)
    # every boundary exponent, both signs, fraction 0 and fraction all-ones
    for exponent in range(118, 138):
        for sign in (0, 1):
            for fraction in (0, 1, 0x400000, 0x7FFFFF):
                yield (sign << 31) | (exponent << 23) | fraction
    # the exact ties: x.5 for every representable half in the clamp window
    for half in range(-64, 65):
        value = half / 2.0
        yield bits_of(value)
    # zero, infinities, one NaN
    yield 0x00000000
    yield 0x80000000
    yield 0x7F800000
    yield 0xFF800000
    yield 0x7FC00000
    # subnormals, which must flush
    yield 0x00000001
    yield 0x807FFFFF
    for _ in range(count):
        pick = rng.random()
        if pick < 0.5:
            exponent = rng.randint(124, 133)
        elif pick < 0.8:
            exponent = rng.randint(100, 160)
        else:
            exponent = rng.randint(0, 255)
        yield (rng.getrandbits(1) << 31) | (exponent << 23) | rng.getrandbits(23)


@cocotb.test()
async def test_fp32_to_int4(dut):
    count = int(os.environ.get("SPINQUANT_RQ_ITERS", "20000"))
    rng = random.Random(0x5EED)
    checked = 0

    for bits in stimulus(count):
        for zp in ((0, 8, 15) if checked % 97 == 0 else (rng.randrange(16),)):
            dut.fp32_i.value = bits
            dut.zp_i.value = zp
            await Timer(1, units="ns")

            expected = reference(bits, zp)
            actual = (
                int(dut.q4_o.value),
                int(dut.clamped_o.value),
                int(dut.invalid_o.value),
            )
            assert actual == expected, (
                f"fp32=0x{bits:08x} ({float_of(bits)!r}) zp={zp}: "
                f"got {actual}, expected {expected}"
            )
            checked += 1

    dut._log.info("spinquant_rq_cvt: %d (value, zero point) pairs checked",
                  checked)
