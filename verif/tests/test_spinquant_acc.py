"""The SpinQuant accumulator file: NENTRY x NPE x ACC_W with two read ports.

The second read port is what lets a MAC-drain run without displacing a compute
cycle, so the thing this test has to prove is not just that a write lands, but
that the two reads are independent of each other and of the write.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from spinquant_model import ACC_W, NENTRY, NPE

ENT_W = NPE * ACC_W


def pack_entry(lanes):
    packed = 0
    mask = (1 << ACC_W) - 1
    for index, value in enumerate(lanes):
        packed |= (value & mask) << (index * ACC_W)
    return packed


async def reset_acc(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.rd_sel_i.value = 0
    dut.drain_sel_i.value = 0
    dut.wr_en_i.value = 0
    dut.wr_sel_i.value = 0
    dut.wr_data_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.rd_data_o.value) == 0
        assert int(dut.drain_data_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def write_entry(dut, entry, value):
    await FallingEdge(dut.clk)
    dut.wr_en_i.value = 1
    dut.wr_sel_i.value = entry
    dut.wr_data_i.value = value
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.wr_en_i.value = 0
    dut.wr_data_i.value = 0


async def check_all(dut, model):
    """Sweep both read ports over every entry pair and compare."""

    for rd in range(NENTRY):
        for drain in range(NENTRY):
            await FallingEdge(dut.clk)
            dut.rd_sel_i.value = rd
            dut.drain_sel_i.value = drain
            await RisingEdge(dut.clk)
            await ReadOnly()
            assert int(dut.rd_data_o.value) == model[rd], (
                f"read port mismatch on entry {rd}"
            )
            assert int(dut.drain_data_o.value) == model[drain], (
                f"drain port mismatch on entry {drain}"
            )


@cocotb.test()
async def test_acc_regfile(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_acc(dut)

    model = [0] * NENTRY

    # A distinct pattern per entry and per lane: a swapped entry select or a
    # mis-sliced lane cannot survive it.
    for entry in range(NENTRY):
        lanes = [(entry << 24) | (lane << 8) | 0xA5 for lane in range(NPE)]
        value = pack_entry(lanes)
        await write_entry(dut, entry, value)
        model[entry] = value
        await check_all(dut, model)

    # wr_en_i low must hold every entry.
    await FallingEdge(dut.clk)
    dut.wr_en_i.value = 0
    dut.wr_sel_i.value = 1
    dut.wr_data_i.value = (1 << ENT_W) - 1
    for _ in range(3):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
    dut.wr_data_i.value = 0
    await check_all(dut, model)

    rng = random.Random(0xACC5)
    for _ in range(200):
        entry = rng.randrange(NENTRY)
        value = rng.getrandbits(ENT_W)
        await write_entry(dut, entry, value)
        model[entry] = value
        await check_all(dut, model)

    # Reset must clear the whole array, not just the entry last written.
    await reset_acc(dut)
    await check_all(dut, [0] * NENTRY)
