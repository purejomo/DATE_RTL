"""One SpinQuant W4A4 processing element against the integer golden model.

The PE is the whole arithmetic story of the design: four signed4 x unsigned4
multipliers, one 4:2 reduction, one CPA, and a 24-bit accumulate inside a
32-bit register. Everything else in the PCU is routing and state.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common import signed_from_bits
from spinquant_model import (
    ACC_CHAIN_W,
    ACC_W,
    A_MAX,
    NWAY,
    PSUM_W,
    W_MAX,
    W_MIN,
    dot_w4a4,
    pack_acts,
    wrap_signed,
)


def pack_ways(values, width=4):
    packed = 0
    mask = (1 << width) - 1
    for index, value in enumerate(values):
        packed |= (value & mask) << (index * width)
    return packed


def expected_acc_next(psum, acc_cur, clear):
    """What acc_next_o must be, given the stage-1 partial sum."""

    if clear:
        return wrap_signed(psum, ACC_CHAIN_W)
    chain_cur = wrap_signed(acc_cur, ACC_CHAIN_W)
    return wrap_signed(chain_cur + psum, ACC_CHAIN_W)


def expected_overflow(psum, acc_cur, clear):
    if clear:
        return False
    chain_cur = wrap_signed(acc_cur, ACC_CHAIN_W)
    raw = chain_cur + psum
    return raw != wrap_signed(raw, ACC_CHAIN_W)


def drive_idle(dut):
    dut.ce_i.value = 0
    dut.w_q4_i.value = 0
    dut.a_q4_i.value = 0
    dut.acc_clear_i.value = 0
    dut.acc_cur_i.value = 0


async def reset_pe(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_idle(dut)
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert signed_from_bits(int(dut.psum_o.value), PSUM_W) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def apply_vector(dut, weights, acts, acc_cur, clear):
    """Drive one stage-1 vector plus its stage-2 operands and check both."""

    await FallingEdge(dut.clk)
    dut.ce_i.value = 1
    dut.w_q4_i.value = pack_ways(weights)
    dut.a_q4_i.value = pack_acts(acts)
    dut.acc_clear_i.value = int(clear)
    dut.acc_cur_i.value = acc_cur & ((1 << ACC_W) - 1)

    await RisingEdge(dut.clk)
    await ReadOnly()

    psum = dot_w4a4(weights, acts)
    actual_psum = signed_from_bits(int(dut.psum_o.value), PSUM_W)
    assert actual_psum == psum, (
        f"psum mismatch for w={weights} a={acts}: "
        f"actual={actual_psum} expected={psum}"
    )

    actual_next = signed_from_bits(int(dut.acc_next_o.value), ACC_W)
    expected_next = expected_acc_next(psum, acc_cur, clear)
    assert actual_next == expected_next, (
        f"acc_next mismatch for w={weights} a={acts} acc={acc_cur} "
        f"clear={clear}: actual={actual_next} expected={expected_next}"
    )

    actual_ovf = bool(int(dut.acc_ovf_o.value))
    expected_ovf = expected_overflow(psum, acc_cur, clear)
    assert actual_ovf == expected_ovf, (
        f"acc_ovf mismatch for psum={psum} acc={acc_cur}: "
        f"actual={actual_ovf} expected={expected_ovf}"
    )


@cocotb.test()
async def test_pe_arithmetic(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pe(dut)

    # Every (weight, activation) code pair, broadcast across all four ways.
    # 16 x 16 covers each multiplier's full input space including the extremes
    # that set the 8-bit product bound: -8 * 15 = -120 and 7 * 15 = 105.
    for w in range(W_MIN, W_MAX + 1):
        for a in range(A_MAX + 1):
            await apply_vector(dut, [w] * NWAY, [a] * NWAY, 0, True)

    # One-hot each way so a way that is wired to the wrong slice cannot hide
    # behind a symmetric vector.
    for way in range(NWAY):
        for w in range(W_MIN, W_MAX + 1):
            weights = [0] * NWAY
            acts = [0] * NWAY
            weights[way] = w
            acts[way] = A_MAX
            await apply_vector(dut, weights, acts, 0, True)

    # The accumulate path: the 24-bit chain lives inside a 32-bit register, so
    # whatever sits above bit 23 on acc_cur_i must not reach the result.
    for garbage in (0x00000000, 0xFF000000, 0x5A000000):
        acc_cur = garbage | 0x0000_1234
        await apply_vector(dut, [1] * NWAY, [1] * NWAY, acc_cur, False)

    # Both ends of the chain, and the wrap the design reports rather than
    # saturates.
    chain_max = (1 << (ACC_CHAIN_W - 1)) - 1
    chain_min = -(1 << (ACC_CHAIN_W - 1))
    await apply_vector(dut, [W_MAX] * NWAY, [A_MAX] * NWAY, chain_max, False)
    await apply_vector(dut, [W_MIN] * NWAY, [A_MAX] * NWAY, chain_min, False)
    await apply_vector(dut, [W_MAX] * NWAY, [A_MAX] * NWAY, chain_max, True)
    await apply_vector(dut, [W_MIN] * NWAY, [A_MAX] * NWAY, chain_min, True)

    # ce_i low must freeze stage 1: drive a different vector with the enable
    # off and the previous partial sum has to survive it.
    await FallingEdge(dut.clk)
    dut.ce_i.value = 0
    dut.w_q4_i.value = pack_ways([W_MAX] * NWAY)
    dut.a_q4_i.value = pack_acts([A_MAX] * NWAY)
    held = dot_w4a4([W_MIN] * NWAY, [A_MAX] * NWAY)
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert signed_from_bits(int(dut.psum_o.value), PSUM_W) == held, (
            "stage 1 advanced while ce_i was low"
        )
        await FallingEdge(dut.clk)

    rng = random.Random(0x5417)
    iterations = int(os.environ.get("SPINQUANT_PE_ITERS", "20000"))
    for _ in range(iterations):
        weights = [rng.randint(W_MIN, W_MAX) for _ in range(NWAY)]
        acts = [rng.randint(0, A_MAX) for _ in range(NWAY)]
        acc_cur = wrap_signed(rng.getrandbits(ACC_CHAIN_W), ACC_CHAIN_W)
        await apply_vector(dut, weights, acts, acc_cur, rng.random() < 0.1)
