from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common import unpack_signed_bus

# The acc16 axis (rtl/3_p3llm_acc16) narrows the 28-bit partial sum by ACC_RSH
# with RNE before accumulating, and holds ACC_W bits. The defaults reproduce
# the 32-bit base build.
ACC_W = int(os.environ.get("P3LLM_ACC_W", "32"))
ACC_RSH = int(os.environ.get("P3LLM_ACC_RSH", "0"))
from p3llm_pcu_model import (
    LANES,
    NUM_PES,
    OP_LINEAR,
    OP_PV,
    OP_QK,
    PIPELINE_EDGE_LATENCY,
    PcuGolden,
    pack_lanes,
    pack_rhs,
)


def drive_idle(dut):
    dut.in_valid.value = 0
    dut.op_mode.value = OP_LINEAR
    dut.acc_clear.value = 0
    dut.acc_enable.value = 0
    dut.input_fp8.value = 0
    dut.rhs_q4.value = 0
    dut.bitmod_special_sel.value = 0
    dut.zp_by_pe.value = 0
    dut.zp_by_lane.value = 0


async def reset_pcu(dut, cycles=3):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_idle(dut)
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.out_valid.value) == 0
        assert int(dut.acc_out.value) == 0
        assert int(dut.in_ready.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.in_ready.value) == 1
    assert int(dut.out_valid.value) == 0


def drive_pcu(dut, transaction):
    if transaction is None:
        drive_idle(dut)
        return
    dut.in_valid.value = 1
    dut.op_mode.value = transaction["op_mode"]
    dut.acc_clear.value = transaction["acc_clear"]
    dut.acc_enable.value = transaction["acc_enable"]
    dut.input_fp8.value = pack_lanes(transaction["input_fp8"], 8)
    dut.rhs_q4.value = pack_rhs(transaction["rhs_q4"])
    dut.bitmod_special_sel.value = pack_lanes(
        transaction.get("special_sel", (0,) * NUM_PES), 2
    )
    dut.zp_by_pe.value = pack_lanes(
        transaction.get("zp_by_pe", (0,) * NUM_PES), 4
    )
    dut.zp_by_lane.value = pack_lanes(
        transaction.get("zp_by_lane", (0,) * LANES), 4
    )


def golden_accept(model, transaction):
    return model.transaction(
        transaction["input_fp8"],
        transaction["rhs_q4"],
        transaction["op_mode"],
        acc_clear=transaction["acc_clear"],
        acc_enable=transaction["acc_enable"],
        bitmod_special_sel=transaction.get("special_sel", (0,) * NUM_PES),
        zp_by_pe=transaction.get("zp_by_pe", (0,) * NUM_PES),
        zp_by_lane=transaction.get("zp_by_lane", (0,) * LANES),
    )[0]


async def run_pcu_stream(dut, transactions, count, model):
    expected_by_cycle = {}
    iterator = iter(transactions)
    total_cycles = count + PIPELINE_EDGE_LATENCY + 1

    for cycle in range(total_cycles):
        await FallingEdge(dut.clk)
        transaction = next(iterator) if cycle < count else None
        drive_pcu(dut, transaction)
        if transaction is not None:
            expected_by_cycle[cycle + PIPELINE_EDGE_LATENCY] = golden_accept(
                model, transaction
            )

        await RisingEdge(dut.clk)
        await ReadOnly()
        due = expected_by_cycle.pop(cycle, None)
        assert int(dut.out_valid.value) == (due is not None), (
            f"out_valid mismatch at PCU stream cycle {cycle}"
        )
        if due is not None:
            actual = unpack_signed_bus(int(dut.acc_out.value), ACC_W, NUM_PES)
            assert actual == due, (
                f"PCU mismatch at cycle {cycle}\n"
                f"actual  ={actual}\nexpected={due}"
            )


def directed_transactions():
    rhs_distinct = tuple(
        tuple((pe * LANES + lane) & 0xF for lane in range(LANES))
        for pe in range(NUM_PES)
    )
    yield dict(
        input_fp8=(0x38, 0xB8, 0x40, 0xC0),
        rhs_q4=rhs_distinct,
        special_sel=tuple(pe & 0x3 for pe in range(NUM_PES)),
        op_mode=OP_LINEAR,
        acc_clear=True,
        acc_enable=True,
    )

    # One-hot every physical PE/lane RHS slice. Only the selected PE may
    # receive the nonzero 1.0 x 1.0 contribution.
    for target_pe in range(NUM_PES):
        for target_lane in range(LANES):
            inputs = tuple(
                0x38 if lane == target_lane else 0x00 for lane in range(LANES)
            )
            rhs = [[0] * LANES for _ in range(NUM_PES)]
            rhs[target_pe][target_lane] = 0x2
            yield dict(
                input_fp8=inputs,
                rhs_q4=tuple(tuple(lanes) for lanes in rhs),
                special_sel=(0,) * NUM_PES,
                op_mode=OP_LINEAR,
                acc_clear=True,
                acc_enable=True,
            )

    # QK: each PE uses its own zero point across all lanes.
    yield dict(
        input_fp8=(0x38, 0x38, 0x38, 0x38),
        rhs_q4=tuple((0, 5, 10, 15) for _ in range(NUM_PES)),
        zp_by_pe=tuple(pe & 0xF for pe in range(NUM_PES)),
        zp_by_lane=(15, 15, 15, 15),
        op_mode=OP_QK,
        acc_clear=True,
        acc_enable=True,
    )

    # PV: each reduction lane's zero point is shared by every PE.
    yield dict(
        input_fp8=(0x00, 0x70, 0xEF, 0xF0),
        rhs_q4=rhs_distinct,
        zp_by_pe=(15,) * NUM_PES,
        zp_by_lane=(0, 4, 8, 12),
        op_mode=OP_PV,
        acc_clear=True,
        acc_enable=True,
    )

    yield None

    # Back-to-back accumulator control, including clear priority and hold.
    base = dict(
        input_fp8=(0x38, 0x38, 0x38, 0x38),
        rhs_q4=tuple((0x2, 0x2, 0x2, 0x2) for _ in range(NUM_PES)),
        special_sel=(0,) * NUM_PES,
        op_mode=OP_LINEAR,
    )
    yield dict(base, acc_clear=True, acc_enable=False)
    for _ in range(4):
        yield dict(base, acc_clear=False, acc_enable=True)
    yield dict(base, acc_clear=False, acc_enable=False)


def valid_e4m3_code(rng):
    while True:
        code = rng.randrange(256)
        if code not in (0x7F, 0xFF):
            return code


def random_transactions(mode, count, seed):
    rng = random.Random(seed)
    for index in range(count):
        if mode == OP_PV:
            # 0x00..0xef are below 1.0; 0xf0 is exactly 1.0.
            inputs = tuple(rng.randrange(0xF1) for _ in range(LANES))
        else:
            inputs = tuple(valid_e4m3_code(rng) for _ in range(LANES))
        yield dict(
            input_fp8=inputs,
            rhs_q4=tuple(
                tuple(rng.randrange(16) for _ in range(LANES))
                for _ in range(NUM_PES)
            ),
            special_sel=tuple(rng.randrange(4) for _ in range(NUM_PES)),
            zp_by_pe=tuple(rng.randrange(16) for _ in range(NUM_PES)),
            zp_by_lane=tuple(rng.randrange(16) for _ in range(LANES)),
            op_mode=mode,
            # Bound each accumulation chain to 16 partials. Even 16
            # same-sign mode maxima fit in the signed 32-bit accumulator.
            acc_clear=(index % 16 == 0),
            acc_enable=bool(rng.randrange(2)),
        )


@cocotb.test()
async def test_pcu_regression(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset_pcu(dut)

    model = PcuGolden(acc_bits=ACC_W, acc_rsh=ACC_RSH)
    directed = list(directed_transactions())
    await run_pcu_stream(dut, directed, len(directed), model)

    # Reset must clear state and flush a transaction still in flight.
    await FallingEdge(dut.clk)
    first = next(random_transactions(OP_LINEAR, 1, 0xBAD))
    drive_pcu(dut, first)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_idle(dut)
    model.reset()
    for _ in range(4):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.out_valid.value) == 0
        assert int(dut.acc_out.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    random_count = int(os.environ.get("P3LLM_RANDOM_TILES", "10000"))
    for mode, seed in (
        (OP_LINEAR, 0x1A2B3C),
        (OP_QK, 0x4D5E6F),
        (OP_PV, 0x789ABC),
    ):
        await run_pcu_stream(
            dut,
            random_transactions(mode, random_count, seed),
            random_count,
            model,
        )
