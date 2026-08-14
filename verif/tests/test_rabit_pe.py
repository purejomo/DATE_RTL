"""Unit test for one RaBiT PE: negation, reduction, alignment, saturation."""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common import signed_from_bits
from rabit_model import ACC_W, NIN, Block, align, pe_partial, saturate_signed

MANT_W = 12
PSUM_W = MANT_W + 1 + 4
SH_W = 7
MANT_MAX = (1 << MANT_W) - 1
SHL_MAX = ACC_W - PSUM_W  # 15: the largest lossless left shift
ACC_MAX = (1 << (ACC_W - 1)) - 1
ACC_MIN = -(1 << (ACC_W - 1))


def pack_blk(signs, mants) -> int:
    word = 0
    for lane, (sign, mant) in enumerate(zip(signs, mants)):
        word |= ((sign << MANT_W) | mant) << (lane * (MANT_W + 1))
    return word


def pack_bits(bits) -> int:
    word = 0
    for lane, bit in enumerate(bits):
        word |= (bit & 1) << lane
    return word


def make_block(signs, mants) -> Block:
    return Block(signs=tuple(signs), mants=tuple(mants), e_ent=15, mant_w=MANT_W)


async def reset(dut):
    dut.ce_i.value = 0
    dut.b_bits_i.value = 0
    dut.blk_i.value = 0
    dut.shift_i.value = 0
    dut.acc_cur_i.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.psum_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def load_stage_a(dut, bits, signs, mants):
    """Drive stage A for one cycle and leave the partial sum in psum_q."""

    await FallingEdge(dut.clk)
    dut.ce_i.value = 1
    dut.b_bits_i.value = pack_bits(bits)
    dut.blk_i.value = pack_blk(signs, mants)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.ce_i.value = 0


async def check_stage_b(dut, psum, shift, acc_cur):
    """Drive stage B combinationally and compare against the model."""

    dut.shift_i.value = shift & ((1 << SH_W) - 1)
    dut.acc_cur_i.value = acc_cur & ((1 << ACC_W) - 1)
    await RisingEdge(dut.clk)
    await ReadOnly()

    aligned, shift_sat = align(psum, shift, psum_w=PSUM_W, acc_w=ACC_W)
    total = acc_cur + aligned
    expected = saturate_signed(total, ACC_W)
    acc_sat = expected != total

    actual = signed_from_bits(int(dut.acc_next_o.value), ACC_W)
    assert actual == expected, (
        f"acc_next {actual} != {expected} "
        f"(psum {psum}, shift {shift}, acc {acc_cur}, aligned {aligned})"
    )
    assert int(dut.shift_sat_o.value) == int(shift_sat), (
        f"shift_sat mismatch at psum {psum}, shift {shift}"
    )
    assert int(dut.acc_sat_o.value) == int(acc_sat), (
        f"acc_sat mismatch at psum {psum}, shift {shift}, acc {acc_cur}"
    )
    await FallingEdge(dut.clk)


async def run_case(dut, bits, signs, mants, shifts, accs):
    block = make_block(signs, mants)
    psum = pe_partial(bits, block)
    await load_stage_a(dut, bits, signs, mants)
    await ReadOnly()
    got = signed_from_bits(int(dut.psum_o.value), PSUM_W)
    assert got == psum, f"psum {got} != {psum}"
    await FallingEdge(dut.clk)
    for shift in shifts:
        for acc in accs:
            await check_stage_b(dut, psum, shift, acc)


async def phase_directed(dut):
    zero = (0,)

    # Every combination the XOR of (binary16 sign, weight bit) can produce.
    await run_case(dut, [0] * NIN, [0] * NIN, [1] * NIN, zero, zero)
    await run_case(dut, [1] * NIN, [0] * NIN, [1] * NIN, zero, zero)
    await run_case(dut, [0] * NIN, [1] * NIN, [1] * NIN, zero, zero)
    await run_case(dut, [1] * NIN, [1] * NIN, [1] * NIN, zero, zero)

    # One-hot: every lane must reach the reduction tree, and only its own slot.
    for lane in range(NIN):
        mants = [0] * NIN
        mants[lane] = 1 << (lane % MANT_W)
        for weight_bit in (0, 1):
            bits = [0] * NIN
            bits[lane] = weight_bit
            await run_case(dut, bits, [0] * NIN, mants, zero, zero)

    # Extreme partial sums. 16 * 4095 = 65520 is the largest magnitude a 12-bit
    # block can produce and it has to stay exact in a 17-bit wrapping tree.
    await run_case(dut, [0] * NIN, [0] * NIN, [MANT_MAX] * NIN, zero, zero)
    await run_case(dut, [1] * NIN, [0] * NIN, [MANT_MAX] * NIN, zero, zero)
    await run_case(
        dut, [i & 1 for i in range(NIN)], [0] * NIN, [MANT_MAX] * NIN, zero, zero
    )

    # Alignment boundaries. SHL_MAX is the largest lossless left shift; one past
    # it must saturate whenever the partial sum is nonzero.
    shifts = (
        0, 1, 2, SHL_MAX - 1, SHL_MAX, SHL_MAX + 1, SHL_MAX + 2, 31, 63,
        -1, -2, -11, -16, -17, -18, -31, -63, -64,
    )
    for mants, bits in (
        ([MANT_MAX] * NIN, [0] * NIN),          # largest positive
        ([MANT_MAX] * NIN, [1] * NIN),          # largest negative
        ([1] + [0] * (NIN - 1), [0] * NIN),     # smallest positive
        ([1] + [0] * (NIN - 1), [1] * NIN),     # smallest negative
        ([0] * NIN, [0] * NIN),                 # zero never saturates
    ):
        await run_case(dut, bits, [0] * NIN, mants, shifts, (0,))

    # Accumulator saturation in both directions.
    for acc in (ACC_MAX, ACC_MAX - 1, ACC_MIN, ACC_MIN + 1, 0, -1):
        for bits in ([0] * NIN, [1] * NIN):
            await run_case(
                dut, bits, [0] * NIN, [MANT_MAX] * NIN, (0, 4, SHL_MAX), (acc,)
            )

    # The negative-shift path floors toward -inf; check the sign asymmetry.
    await run_case(dut, [1] * NIN, [0] * NIN, [1] * NIN, (-1, -5), (0,))
    await run_case(dut, [0] * NIN, [0] * NIN, [1] * NIN, (-1, -5), (0,))


async def phase_random(dut):
    iters = int(os.environ.get("RABIT_PE_ITERS", "3000"))
    rng = random.Random(0x5A17)

    for _ in range(iters):
        signs = [rng.randrange(2) for _ in range(NIN)]
        bits = [rng.randrange(2) for _ in range(NIN)]
        if rng.random() < 0.25:
            mants = [
                rng.choice((0, 1, MANT_MAX, MANT_MAX - 1)) for _ in range(NIN)
            ]
        else:
            mants = [rng.randrange(1 << MANT_W) for _ in range(NIN)]

        shift = rng.choice([rng.randrange(-64, 64), rng.randrange(-20, 20), 0])
        acc = rng.choice(
            [
                rng.randrange(ACC_MIN, ACC_MAX + 1),
                rng.randrange(-(1 << 20), 1 << 20),
                ACC_MAX,
                ACC_MIN,
                0,
            ]
        )
        await run_case(dut, bits, signs, mants, (shift,), (acc,))


async def phase_hold(dut):
    """psum_q must hold while ce_i is low, and reset must clear it."""

    mants = [7] * NIN
    await load_stage_a(dut, [0] * NIN, [0] * NIN, mants)
    await ReadOnly()
    held = int(dut.psum_o.value)
    assert held == 7 * NIN
    await FallingEdge(dut.clk)

    dut.b_bits_i.value = pack_bits([1] * NIN)
    dut.blk_i.value = pack_blk([1] * NIN, [MANT_MAX] * NIN)
    for _ in range(4):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.psum_o.value) == held, "psum_q moved while ce_i was low"
        await FallingEdge(dut.clk)

    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.psum_o.value) == 0, "reset did not clear psum_q"
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def test_pe(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset(dut)
    await phase_directed(dut)
    await phase_random(dut)
    await phase_hold(dut)
