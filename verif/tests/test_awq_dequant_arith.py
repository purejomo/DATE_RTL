"""Boundary + randomized regression for the shared AWQ dequant FP pipes.

Both activation formats are covered in one run: the harness instantiates the
multiplier and the packer twice, once with bfloat16 parameters and once with
binary16 parameters.  The binary32 adder is format-independent and is checked
once, against the same model the P3-LLM regression uses.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from awq_dequant_model import (
    BF16,
    FP16,
    fp32_to_float16,
    int32_scale_to_fp32,
)
from p3llm_dequant_model import add_fp32_rne

# name -> (signal prefix, format tuple)
MUL_PORTS = {"bf16": ("bf_mul", BF16), "fp16": ("fp_mul", FP16)}
PACK_PORTS = {"bf16": ("bf_pack", BF16), "fp16": ("fp_pack", FP16)}


def drive_all_idle(dut) -> None:
    for prefix, _ in MUL_PORTS.values():
        getattr(dut, f"{prefix}_valid_i").value = 0
        getattr(dut, f"{prefix}_fixed_i").value = 0
        getattr(dut, f"{prefix}_scale_i").value = 0
        getattr(dut, f"{prefix}_offset_i").value = 0
    for prefix, _ in PACK_PORTS.values():
        getattr(dut, f"{prefix}_valid_i").value = 0
        getattr(dut, f"{prefix}_fp32_i").value = 0
    dut.add_valid_i.value = 0
    dut.add_a_i.value = 0
    dut.add_b_i.value = 0


async def reset_dut(dut) -> None:
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_all_idle(dut)
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        for prefix, _ in list(MUL_PORTS.values()) + list(PACK_PORTS.values()):
            assert int(getattr(dut, f"{prefix}_valid_o").value) == 0
        assert int(dut.add_valid_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_mul_case(dut, kind, fixed, scale, offset, expected, *, invalid=0):
    prefix, _ = MUL_PORTS[kind]
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    getattr(dut, f"{prefix}_fixed_i").value = fixed
    getattr(dut, f"{prefix}_scale_i").value = scale
    getattr(dut, f"{prefix}_offset_i").value = offset
    getattr(dut, f"{prefix}_valid_i").value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(getattr(dut, f"{prefix}_valid_o").value):
            got = int(getattr(dut, f"{prefix}_fp32_o").value)
            assert got == expected, (
                f"{kind} mul fixed={fixed} scale=0x{scale:04x} off={offset}: "
                f"got 0x{got:08x} want 0x{expected:08x}"
            )
            assert int(getattr(dut, f"{prefix}_invalid_o").value) == invalid
            return
    raise AssertionError(f"{kind} multiplier pipeline timed out")


async def run_add_case(dut, lhs, rhs, expected, *, invalid=0):
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    dut.add_a_i.value = lhs
    dut.add_b_i.value = rhs
    dut.add_valid_i.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.add_valid_o.value):
            got = int(dut.add_result_o.value)
            assert got == expected, (
                f"add 0x{lhs:08x}+0x{rhs:08x}: got 0x{got:08x} "
                f"want 0x{expected:08x}"
            )
            assert int(dut.add_invalid_o.value) == invalid
            return
    raise AssertionError("FP32 add pipeline timed out")


async def run_pack_case(dut, kind, fp32, expected, *, invalid=0, overflow=None):
    prefix, fmt = PACK_PORTS[kind]
    exp_bits, frac_bits = fmt
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    getattr(dut, f"{prefix}_fp32_i").value = fp32
    getattr(dut, f"{prefix}_valid_i").value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    infinity = ((1 << exp_bits) - 1) << frac_bits
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(getattr(dut, f"{prefix}_valid_o").value):
            got = int(getattr(dut, f"{prefix}_out_o").value)
            assert got == expected, (
                f"{kind} pack 0x{fp32:08x}: got 0x{got:04x} "
                f"want 0x{expected:04x}"
            )
            assert int(getattr(dut, f"{prefix}_invalid_o").value) == invalid
            if overflow is None:
                overflow = int(not invalid and (got & 0x7FFF) == infinity)
            assert int(getattr(dut, f"{prefix}_overflow_o").value) == overflow
            return
    raise AssertionError(f"{kind} pack pipeline timed out")


# Directed multiplier cases, per format: (fixed, scale_bits, exp_offset).
MUL_CASES = {
    "bf16": (
        (4096, 0x3F80, -8),            # scale 1.0
        (1, 0x3F80, 0),
        (-(1 << 31), 0x3F80, -8),      # INT32_MIN magnitude is representable
        ((1 << 31) - 1, 0x7F7F, 120),  # near the binary32 ceiling
        (1 << 24, 0x0001, -8),         # minimum bfloat16 subnormal scale
        (-123456789, 0x3EAB, -8),
        (12345, 0x0000, -8),           # +0 scale keeps the integer's sign
        (-12345, 0x0000, -8),
        (0, 0x3F80, -8),
        (0x5A5A5A5A, 0x3F81, 503),     # largest offset i_ref_exp - GUARD reaches
        (0x5A5A5A5A, 0x3F81, -520),    # smallest, forcing the subnormal path
    ),
    "fp16": (
        (4096, 0x3C00, -8),
        (-(1 << 31), 0x3C00, -8),
        ((1 << 31) - 1, 0x7BFF, 100),
        (1 << 24, 0x0001, -8),
        (-123456789, 0x3555, -8),
        (12345, 0x0000, -8),
        (0x5A5A5A5A, 0x3C01, 503),
        (0x5A5A5A5A, 0x3C01, -520),
    ),
}

# Directed pack cases: binary32 patterns aimed at the format boundaries.
PACK_CASES = {
    # bfloat16: emin -126, emax 127, 7 fraction bits.
    "bf16": (
        0x3F800000,  # 1.0
        0x3F800080,  # exact halfway, even retained
        0x3F800180,  # exact halfway, odd rounds up
        0x3F8000FF,  # just above halfway
        0x7F7FFFFF,  # binary32 max: rounds up past bfloat16 max -> infinity
        0x7F7F0000,  # bfloat16 max finite
        0x00800000,  # binary32 min normal == bfloat16 min normal
        0x00000001,  # binary32 min subnormal -> bfloat16 subnormal
        0x00400000,  # bfloat16 subnormal region
        0x00008000,  # smallest bfloat16 subnormal
        0x00004000,  # exact halfway to zero, ties to even -> zero
        0x0000C000,  # halfway with odd successor -> rounds up
        0x80000000,  # -0
        0x00000000,
        0xBF800180,
    ),
    # binary16: emin -14, emax 15, 10 fraction bits.
    "fp16": (
        0x3F800000,
        0x33800000,  # exact minimum binary16 subnormal
        0x33000000,  # halfway to zero -> even zero
        0x477FE000,  # max finite binary16
        0x477FF000,  # overflow halfway boundary -> infinity
        0x3F801000,  # halfway, even retained
        0x3F803000,  # halfway, rounds up
        0xBF803000,
        0x38800000,  # binary16 min normal
        0x38000000,  # binary16 subnormal region
        0x00000001,  # far below binary16 range -> zero
        0x80000001,  # ... with sign preserved
        0x7F7FFFFF,  # far above -> infinity
    ),
}


@cocotb.test()
async def test_awq_dequant_arithmetic(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset_dut(dut)

    for kind, cases in MUL_CASES.items():
        fmt = MUL_PORTS[kind][1]
        for fixed, scale, offset in cases:
            await run_mul_case(
                dut,
                kind,
                fixed,
                scale,
                offset,
                int32_scale_to_fp32(fixed, scale, offset, fmt),
            )

    # Out-of-contract scales: negative, infinity, NaN.
    await run_mul_case(dut, "bf16", 17, 0xBF80, -8, 0x7FC00000, invalid=1)
    await run_mul_case(dut, "bf16", 17, 0x7F80, -8, 0x7FC00000, invalid=1)
    await run_mul_case(dut, "bf16", 17, 0x7FC0, -8, 0x7FC00000, invalid=1)
    await run_mul_case(dut, "bf16", 17, 0x8000, -8, 0x7FC00000, invalid=1)
    await run_mul_case(dut, "fp16", 17, 0xBC00, -8, 0x7FC00000, invalid=1)
    await run_mul_case(dut, "fp16", 17, 0x7C00, -8, 0x7FC00000, invalid=1)

    add_cases = (
        (0x3F800000, 0x33800000),  # exact halfway: even 1.0 retained
        (0x3F800001, 0x33800000),  # halfway: odd low endpoint rounds up
        (0x3F800000, 0xBF800000),  # cancellation to +zero
        (0x80000000, 0x80000000),  # -0 + -0 = -0
        (0x40000000, 0xB3800000),  # d=25 downward tie stays at even 2.0
        (0x00800000, 0x80800000),  # min-normal cancellation
        (0x7F7FFFFF, 0x7F7FFFFF),  # overflow to infinity
        (0x00000000, 0x3F800000),  # +0 identity
    )
    for lhs, rhs in add_cases:
        await run_add_case(dut, lhs, rhs, add_fp32_rne(lhs, rhs))

    for kind, cases in PACK_CASES.items():
        fmt = PACK_PORTS[kind][1]
        for fp32 in cases:
            await run_pack_case(dut, kind, fp32, fp32_to_float16(fp32, fmt))

    # A non-finite binary32 is reported invalid rather than propagated.
    for kind in PACK_PORTS:
        fmt = PACK_PORTS[kind][1]
        for pattern in (0x7F800000, 0xFF800000, 0x7FC00000):
            await run_pack_case(
                dut,
                kind,
                pattern,
                fp32_to_float16(pattern, fmt),
                invalid=1,
                overflow=0,
            )

    # Randomized sweep, weighted toward the boundaries the directed cases probe.
    rng = random.Random(0xAB0F)
    for _ in range(400):
        kind = rng.choice(("bf16", "fp16"))
        fmt = MUL_PORTS[kind][1]
        fixed = rng.randrange(-(1 << 31), 1 << 31)
        scale = rng.randrange(0, 0x8000)          # any non-negative pattern
        if not (0 < (scale >> fmt[1]) < ((1 << fmt[0]) - 1)):
            scale = rng.randrange(1 << fmt[1], ((1 << fmt[0]) - 1) << fmt[1])
        offset = rng.randrange(-520, 504)
        await run_mul_case(
            dut, kind, fixed, scale, offset,
            int32_scale_to_fp32(fixed, scale, offset, fmt),
        )

    for _ in range(400):
        kind = rng.choice(("bf16", "fp16"))
        fmt = PACK_PORTS[kind][1]
        pattern = rng.randrange(0, 1 << 32)
        if (pattern >> 23) & 0xFF == 0xFF:
            pattern &= ~(1 << 30)                  # keep it finite
        await run_pack_case(dut, kind, pattern, fp32_to_float16(pattern, fmt))
