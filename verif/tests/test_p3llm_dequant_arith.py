"""Directed boundary regression for the three shared dequant FP pipes."""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from p3llm_dequant_model import (
    FP8_NAN,
    add_fp32_rne,
    fp32_scale_to_fp8,
    fp32_scale_to_fp8_flags,
    int32_scale_to_fp32,
    pack_fp32_exact,
    unpack_fp8_e4m3,
)


def drive_all_idle(dut) -> None:
    dut.fixed_valid_i.value = 0
    dut.fixed_i.value = 0
    dut.fixed_scale_i.value = 0
    dut.fixed_binary_exp_i.value = 0
    dut.add_valid_i.value = 0
    dut.add_a_i.value = 0
    dut.add_b_i.value = 0
    dut.pack_valid_i.value = 0
    dut.pack_fp32_i.value = 0
    dut.pack_scale_i.value = 0


async def reset_dut(dut) -> None:
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_all_idle(dut)
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.fixed_valid_o.value) == 0
        assert int(dut.add_valid_o.value) == 0
        assert int(dut.pack_valid_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_fixed_case(
    dut,
    fixed: int,
    scale: int,
    offset: int,
    expected: int,
    *,
    invalid: int = 0,
) -> None:
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    dut.fixed_i.value = fixed
    dut.fixed_scale_i.value = scale
    dut.fixed_binary_exp_i.value = offset
    dut.fixed_valid_i.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.fixed_valid_o.value):
            assert int(dut.fixed_fp32_o.value) == expected
            assert int(dut.fixed_invalid_o.value) == invalid
            return
    raise AssertionError("fixed*scale pipeline timed out")


async def run_add_case(
    dut,
    lhs: int,
    rhs: int,
    expected: int,
    *,
    invalid: int = 0,
) -> None:
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
            assert int(dut.add_result_o.value) == expected
            assert int(dut.add_invalid_o.value) == invalid
            return
    raise AssertionError("FP32 add pipeline timed out")


async def run_pack_case(
    dut,
    fp32: int,
    scale: int,
    expected: int,
    *,
    invalid: int = 0,
    overflow: int | None = 0,
    underflow: int | None = None,
) -> None:
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    dut.pack_fp32_i.value = fp32
    dut.pack_scale_i.value = scale
    dut.pack_valid_i.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    drive_all_idle(dut)
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.pack_valid_o.value):
            got = int(dut.pack_fp8_o.value)
            assert got == expected, (
                f"pack 0x{fp32:08x} * 0x{scale:04x}: got 0x{got:02x} "
                f"want 0x{expected:02x}"
            )
            assert int(dut.pack_invalid_o.value) == invalid
            if overflow is not None:
                assert int(dut.pack_overflow_o.value) == overflow
            if underflow is not None:
                assert int(dut.pack_underflow_o.value) == underflow
            return
    raise AssertionError("FP32*scale pack pipeline timed out")


@cocotb.test()
async def test_dequant_arithmetic_boundaries(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset_dut(dut)

    fixed_cases = (
        (4096, 0x3C00, -12),
        (2048, 0x3C00, -11),
        (1 << 19, 0x3C00, -19),
        (-(1 << 31), 0x3C00, -12),
        ((1 << 24), 0x0001, -12),  # minimum-subnormal scale is not DAZ
        ((1 << 31) - 1, 0x7BFF, -19),
        (-123456789, 0x3555, -12),
    )
    for fixed, scale, offset in fixed_cases:
        await run_fixed_case(
            dut,
            fixed,
            scale,
            offset,
            int32_scale_to_fp32(fixed, scale, offset),
        )
    # Negative zero is outside the scale contract.
    await run_fixed_case(dut, 17, 0x8000, -12, 0x7FC00000, invalid=1)

    add_cases = (
        (0x3F800000, 0x33800000),  # exact halfway: even 1.0 retained
        (0x3F800001, 0x33800000),  # halfway: odd low endpoint rounds up
        (0x3F800000, 0xBF800000),  # cancellation to +zero
        (0x80000000, 0x80000000),  # -0 + -0 = -0
        (0x40000000, 0xB3800000),  # d=25 downward tie stays at even 2.0
        (0x40000000, 0xB3800001),  # just past tie rounds to predecessor
        (0x00800000, 0x80800000),  # min-normal cancellation
        (0x7F7FFFFF, 0x7F7FFFFF),  # overflow to infinity
    )
    for lhs, rhs in add_cases:
        await run_add_case(dut, lhs, rhs, add_fp32_rne(lhs, rhs))
    await run_add_case(dut, 0x00000001, 0, 0x7FC00000, invalid=1)

    # --- FP8-E4M3 pack -------------------------------------------------
    #
    # The pack stage must be the exact inverse of fp8_e4m3_decoder.sv, so the
    # first check is a round trip over every code the decoder treats as finite:
    # decode the code to an exact value, hand that value to the packer as a
    # binary32 with a unit scale, and require the original code back.
    for code in range(256):
        decoded = unpack_fp8_e4m3(code)
        if decoded.kind == "nan":
            continue
        if decoded.kind == "zero":
            fp32 = decoded.sign << 31
        else:
            fp32 = pack_fp32_exact(decoded.coefficient, decoded.exponent)
        await run_pack_case(dut, fp32, 0x3C00, code, overflow=0)

    # Directed boundaries: E4M3 has bias 7, three fraction bits, gradual
    # underflow, no infinity, and a largest finite magnitude of 448.
    pack_cases = (
        (0x3F800000, 0x3C00),  # 1.0
        (0x3F880000, 0x3C00),  # 1.0625: exact halfway, ties to even 1.0
        (0x3F980000, 0x3C00),  # 1.1875: exact halfway, ties to even 1.25
        (0x43E00000, 0x3C00),  # 448, the largest finite code, exactly
        (0x43E80000, 0x3C00),  # 464: halfway to the NaN code, ties back to 448
        (0x43EB0000, 0x3C00),  # 470: past that halfway, so it must saturate
        (0x461C4000, 0x3C00),  # 10000, far past the top
        (0x3C800000, 0x3C00),  # 2**-6, the smallest normal
        (0x3C000000, 0x3C00),  # 2**-7, already subnormal in E4M3
        (0x3B800000, 0x3C00),  # 2**-8
        (0x3B000000, 0x3C00),  # 2**-9, the smallest subnormal
        (0x3AC00000, 0x3C00),  # 1.5 * 2**-10 rounds up to 2**-9
        (0x3A800000, 0x3C00),  # 2**-10: exact halfway to zero, ties to even
        (0xC3E00000, 0x3C00),  # -448
        (0x00000000, 0x3C00),  # +0
        (0x80000000, 0x3C00),  # -0
        (0x3F800000, 0x0001),  # subnormal final scale
        (0x3F800000, 0x0000),  # +0 final scale
        (0x3F800000, 0x4900),  # scale 10.0
        (0xBF800000, 0x7BFF),  # scale = max binary16, saturates negative
    )
    for fp32, scale in pack_cases:
        code, invalid, overflow, underflow = fp32_scale_to_fp8_flags(fp32, scale)
        await run_pack_case(
            dut,
            fp32,
            scale,
            code,
            invalid=invalid,
            overflow=overflow,
            underflow=underflow,
        )
    # Out-of-contract scale, and a non-finite binary32: both give E4M3 NaN.
    await run_pack_case(dut, 0x3F800000, 0xBC00, FP8_NAN, invalid=1, overflow=0)
    await run_pack_case(dut, 0x7F800000, 0x3C00, FP8_NAN, invalid=1, overflow=0)
    await run_pack_case(dut, 0x7FC00000, 0x3C00, FP8_NAN, invalid=1, overflow=0)

    # Randomized pack sweep across the whole binary32 range.
    pack_rng = random.Random(0x8E4)
    for _ in range(300):
        fp32 = pack_rng.randrange(0, 1 << 32)
        if (fp32 >> 23) & 0xFF == 0xFF:
            fp32 &= ~(1 << 30)
        scale = pack_rng.choice(
            (0x0001, 0x0400, 0x3000, 0x3555, 0x3C00, 0x4900, 0x6400, 0x7BFF)
        )
        code, invalid, overflow, underflow = fp32_scale_to_fp8_flags(fp32, scale)
        await run_pack_case(
            dut,
            fp32,
            scale,
            code,
            invalid=invalid,
            overflow=overflow,
            underflow=underflow,
        )

    # Bubble-heavy randomized normal-value sweep through all three pipes.
    rng = random.Random(0xD3A0)
    for _ in range(50):
        fixed = rng.randrange(-(1 << 31), 1 << 31)
        scale = rng.choice((0x0001, 0x0400, 0x3000, 0x3555, 0x3C00, 0x6400))
        offset = rng.choice((-19, -12, -11))
        await run_fixed_case(
            dut,
            fixed,
            scale,
            offset,
            int32_scale_to_fp32(fixed, scale, offset),
        )
