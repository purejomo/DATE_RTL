"""Directed boundary regression for the three shared dequant FP pipes."""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from p3llm_dequant_model import (
    add_fp32_rne,
    fp32_scale_to_fp16,
    int32_scale_to_fp32,
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
    overflow: int = 0,
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
            assert int(dut.pack_fp16_o.value) == expected
            assert int(dut.pack_invalid_o.value) == invalid
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

    pack_cases = (
        (0x3F800000, 0x3C00, None),
        (0x33800000, 0x3C00, 1),  # exact minimum FP16 subnormal
        (0x33000000, 0x3C00, 1),  # halfway to zero, underflow after rounding
        (0x477FE000, 0x3C00, None),  # max finite FP16
        (0x477FF000, 0x3C00, None),  # overflow halfway boundary
        (0x3F801000, 0x3C00, None),  # FP16 halfway: retain even 1.0
        (0x3F803000, 0x3C00, None),  # next halfway: round upward
        (0xBF803000, 0x3800, None),
        (0x3F800000, 0x0001, 1),  # subnormal final scale
    )
    for fp32, scale, expected_underflow in pack_cases:
        expected = fp32_scale_to_fp16(fp32, scale)
        await run_pack_case(
            dut,
            fp32,
            scale,
            expected,
            overflow=int(expected & 0x7FFF == 0x7C00),
            underflow=expected_underflow,
        )
    await run_pack_case(dut, 0x3F800000, 0xBC00, 0x7E00, invalid=1)

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
