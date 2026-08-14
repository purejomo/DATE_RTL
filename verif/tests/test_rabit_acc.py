"""Unit test for the architectural accumulator array: read, write, clear, reset.

The read port is combinational, so every check drives the select at the falling
edge and samples before the next rising edge. That is the same order the PEs
see: read the slot, add, write it back at the edge.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

NPE = 8
NSLOT = 8
ACC_W = 32
ACC_MASK = (1 << ACC_W) - 1


def pack(values) -> int:
    word = 0
    for pe, value in enumerate(values):
        word |= (value & ACC_MASK) << (pe * ACC_W)
    return word


def unpack(word: int):
    return tuple((word >> (pe * ACC_W)) & ACC_MASK for pe in range(NPE))


async def cycle(dut, rd_sel, wr_en=0, wr_sel=0, wr_data=0):
    """One clock cycle: returns what the read port showed before the edge."""

    await FallingEdge(dut.clk)
    dut.rd_sel_i.value = rd_sel
    dut.wr_en_i.value = wr_en
    dut.wr_sel_i.value = wr_sel
    dut.wr_data_i.value = wr_data
    await Timer(1, units="ns")  # settle inside the same clock cycle
    observed = unpack(int(dut.rd_data_o.value))
    await RisingEdge(dut.clk)
    return observed


async def reset(dut):
    dut.rd_sel_i.value = 0
    dut.wr_en_i.value = 0
    dut.wr_sel_i.value = 0
    dut.wr_data_i.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.rd_data_o.value) == 0, "reset did not hold the array at zero"
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def test_acc(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset(dut)

    model = [[0] * NPE for _ in range(NSLOT)]

    # Reset must have zeroed every slot.
    for slot in range(NSLOT):
        assert await cycle(dut, slot) == tuple(model[slot]), (
            f"slot {slot} nonzero after reset"
        )

    # Distinct payload per slot: a write may only land where it was addressed.
    for slot in range(NSLOT):
        values = [(slot << 24) | (pe << 8) | 0xA5 for pe in range(NPE)]
        await cycle(dut, slot, wr_en=1, wr_sel=slot, wr_data=pack(values))
        model[slot] = values
        for other in range(NSLOT):
            assert await cycle(dut, other) == tuple(model[other]), (
                f"writing slot {slot} disturbed slot {other}"
            )

    # wr_en low must leave everything alone even with a live address and data.
    for _ in range(4):
        await cycle(dut, 0, wr_en=0, wr_sel=3, wr_data=pack([0xDEADBEEF] * NPE))
    for slot in range(NSLOT):
        assert await cycle(dut, slot) == tuple(model[slot]), (
            "a slot changed while wr_en_i was low"
        )

    # Clearing is an ordinary write of zeros -- the drain path reuses the port.
    for slot in range(NSLOT):
        await cycle(dut, slot, wr_en=1, wr_sel=slot, wr_data=0)
        model[slot] = [0] * NPE
        assert await cycle(dut, slot) == tuple(model[slot])

    # Back-to-back read-modify-write, which is what a RD burst does. Reading and
    # writing the same slot in one cycle must return the pre-write value.
    rng = random.Random(0xACC0)
    iters = int(os.environ.get("RABIT_ACC_ITERS", "2000"))
    slot = 0
    for _ in range(iters):
        addend = [rng.randrange(1 << 16) for _ in range(NPE)]
        nxt = [(model[slot][pe] + addend[pe]) & ACC_MASK for pe in range(NPE)]
        observed = await cycle(dut, slot, wr_en=1, wr_sel=slot, wr_data=pack(nxt))
        assert observed == tuple(model[slot]), (
            f"slot {slot} read {observed} expected {tuple(model[slot])} "
            "during read-modify-write"
        )
        model[slot] = nxt
        slot = rng.randrange(NSLOT)

    for slot in range(NSLOT):
        assert await cycle(dut, slot) == tuple(model[slot])

    # Reset in the middle must clear everything again.
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    for slot in range(NSLOT):
        assert await cycle(dut, slot) == (0,) * NPE, f"slot {slot} survived reset"
