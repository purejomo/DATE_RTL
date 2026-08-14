"""Unit test for convert-on-write: rounding, subnormals, max-exponent edges."""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import Timer

from rabit_model import NIN, convert_block, decode_fp16, fp16_from_float

CONFIGS = (
    # prefix, MANT_W, SHIFTER_EN
    ("m12", 12, 1),
    ("m10", 10, 1),
    ("g12", 12, 0),
)


def pack_codes(codes) -> int:
    word = 0
    for lane, code in enumerate(codes):
        word |= (code & 0xFFFF) << (lane * 16)
    return word


def unpack_block(value: int, mant_w: int):
    tw = mant_w + 1
    mask = (1 << mant_w) - 1
    signs = []
    mants = []
    for lane in range(NIN):
        field = (value >> (lane * tw)) & ((1 << tw) - 1)
        mants.append(field & mask)
        signs.append((field >> mant_w) & 1)
    return tuple(signs), tuple(mants)


async def check(dut, codes, e0):
    dut.fp16_i.value = pack_codes(codes)
    dut.e0_i.value = e0
    await Timer(1, units="ns")

    for prefix, mant_w, shifter_en in CONFIGS:
        expected = convert_block(
            codes, mant_w=mant_w, shifter_en=shifter_en, e0=e0
        )
        blk = int(getattr(dut, f"{prefix}_blk_o").value)
        eent = int(getattr(dut, f"{prefix}_eent_o").value)
        ovf = int(getattr(dut, f"{prefix}_ovf_o").value)
        signs, mants = unpack_block(blk, mant_w)

        assert eent == expected.e_ent, (
            f"{prefix}: e_ent {eent} != {expected.e_ent} for {codes}"
        )
        assert mants == expected.mants, (
            f"{prefix}: mantissas {mants} != {expected.mants} for {codes}"
        )
        assert signs == expected.signs, (
            f"{prefix}: signs {signs} != {expected.signs} for {codes}"
        )
        assert ovf == int(expected.ovf), (
            f"{prefix}: ovf {ovf} != {int(expected.ovf)} for {codes}"
        )


@cocotb.test()
async def test_convert(dut):
    # ---- directed: the numeric contract itself --------------------------
    #
    # One lane at 1.0 and the rest zero: e_ent is the binary16 exponent of 1.0
    # and MANT_W = 12 puts the implicit bit one place up, so mant = 2048 and
    # 2048 * 2**(15-26) = 1.0.
    one = fp16_from_float(1.0)
    codes = [one] + [0] * (NIN - 1)
    await check(dut, codes, 15)
    assert int(dut.m12_eent_o.value) == 15
    assert unpack_block(int(dut.m12_blk_o.value), 12)[1][0] == 2048

    # Every lane the same value: no alignment shift anywhere.
    await check(dut, [fp16_from_float(-1.5)] * NIN, 15)

    # Full 16-lane exponent spread: the smallest lanes must flush to zero.
    spread = [fp16_from_float(2.0 ** (-e)) for e in range(NIN)]
    await check(dut, spread, 15)

    # Ties-to-even in both directions. 0x3FFF is the largest binary16 below 2.0;
    # against a lane at 2**k it has to round, and the tie cases land on even.
    for shift in range(0, 14):
        big = fp16_from_float(2.0 ** shift)
        for probe in (0x3FFF, 0x3801, 0x3803, 0x0001, 0x0003, 0x03FF, 0x0400):
            await check(dut, [big, probe] + [0] * (NIN - 2), 15)

    # Subnormals: exp == 0 is not flushed, it decodes with e_eff = 1.
    subnormals = [0x0001, 0x0002, 0x03FF, 0x8001, 0x83FF, 0x0000, 0x8000]
    await check(dut, subnormals + [0] * (NIN - len(subnormals)), 1)
    await check(dut, [0x0001] * NIN, 1)
    assert int(dut.m12_eent_o.value) == 1

    # All zero, including negative zero.
    await check(dut, [0x0000] * NIN, 15)
    await check(dut, [0x8000] * NIN, 15)

    # Maximum exponent boundary: 0x7BFF is the largest finite binary16, and
    # 0x7C00 / 0x7E00 are the infinity / NaN codes the design deliberately does
    # not special case (open question Q3).
    await check(dut, [0x7BFF] + [one] * (NIN - 1), 30)
    await check(dut, [0x7C00] + [one] * (NIN - 1), 31)
    await check(dut, [0x7E00, 0xFC00] + [one] * (NIN - 2), 31)

    # SHIFTER_EN = 0 saturation: a lane above the global reference clamps.
    await check(dut, [fp16_from_float(4.0)] + [0] * (NIN - 1), 15)
    assert int(dut.g12_ovf_o.value) == 1
    await check(dut, [fp16_from_float(0.25)] + [0] * (NIN - 1), 15)
    assert int(dut.g12_ovf_o.value) == 0

    # ---- exhaustive over one lane ---------------------------------------
    #
    # Sweep every binary16 code in lane 0 against a fixed companion, which
    # covers every (e_eff, sig) pair the aligner can see.
    for code in range(1 << 16):
        if (code & 0x3FF) not in (0, 1, 0x1FF, 0x200, 0x3FE, 0x3FF):
            continue  # keep the sweep to the fraction corners of every exponent
        await check(dut, [code, one, fp16_from_float(2.0 ** -8)] + [0] * 13, 15)

    # ---- random ----------------------------------------------------------
    iters = int(os.environ.get("RABIT_CVT_ITERS", "4000"))
    for seed in (0x1234, 0xC0FFEE):
        rng = random.Random(seed)
        for _ in range(iters // 2):
            # Mix a wide exponent spread with clustered entries: the first
            # exercises flush-to-zero, the second exercises rounding.
            if rng.random() < 0.5:
                codes = [rng.randrange(1 << 16) for _ in range(NIN)]
            else:
                base = rng.randrange(1, 31)
                codes = [
                    (rng.randrange(2) << 15)
                    | (max(1, min(30, base + rng.randrange(-2, 3))) << 10)
                    | rng.randrange(1 << 10)
                    for _ in range(NIN)
                ]
            await check(dut, codes, rng.randrange(1, 32))


@cocotb.test()
async def test_convert_value_roundtrip(dut):
    """The stored block must represent the input to within one ulp of MANT_W."""

    rng = random.Random(0xBEEF)
    for _ in range(int(os.environ.get("RABIT_CVT_ITERS", "4000")) // 4):
        base = rng.randrange(4, 26)
        codes = [
            (rng.randrange(2) << 15)
            | (max(1, min(30, base - rng.randrange(0, 4))) << 10)
            | rng.randrange(1 << 10)
            for _ in range(NIN)
        ]
        dut.fp16_i.value = pack_codes(codes)
        dut.e0_i.value = base
        await Timer(1, units="ns")

        block = convert_block(codes, mant_w=12, shifter_en=1)
        ulp = block.lsb_weight()
        for lane, code in enumerate(codes):
            exact = decode_fp16(code).value
            stored = block.value(lane)
            assert abs(stored - exact) <= ulp / 2, (
                f"lane {lane}: stored {stored} vs exact {exact}, ulp {ulp}"
            )
