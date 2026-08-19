"""Regression for the SpinQuant PCU-local dequantizer (axis 3).

The raw integer engine is rtl/5_spinquant unchanged and already has its own
suite, so this file does not re-verify it. What it checks is the drain-path
engine: the integer bias fold, the exact multiply, the RNE pack, the streaming
protocol, and the fact that the raw accumulators are left alone.

Protocol under test. One lane is issued per cycle in ascending order starting
the cycle after dq_req_i is accepted, metadata is streamed in that same order,
and results come back in that order tagged with y_lane_o. The test drives
metadata off its own counter rather than off dq_lane_o and then asserts that
dq_lane_o agreed -- if the two ever diverge, a driver written to the documented
order would be feeding the wrong scale to the wrong channel.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from spinquant_model import NWAY, SpinQuantPcu, pack_acts, pack_beat
from awq_dequant_model import fp32_to_float16
from spinquant_dequant_model import FP16, dequant_lane

NPE = 16
NLANE = 16
NENTRY = 4
A_MAX = 15
W_MIN = -8
W_MAX = 7

# binary16 patterns that exercise the multiply: one, a half, a small
# denormalised-exponent value, a large one, and zero.
SCALE_POOL = [0x3C00, 0x3800, 0x1400, 0x5640, 0x0000, 0x2E66, 0x4900]


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.w_load_i.value = 0
    dut.w_beat_i.value = 0
    dut.mac_valid_i.value = 0
    dut.a_q4_i.value = 0
    dut.acc_entry_i.value = 0
    dut.acc_clear_i.value = 0
    dut.drain_entry_i.value = 0
    dut.status_clr_i.value = 0
    dut.dq_req_i.value = 0
    dut.dq_entry_i.value = 0
    dut.dq_scale_i.value = 0
    dut.dq_bias_i.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue_mac(dut, model, weights, acts, entry, clear) -> None:
    """One MAC, weight load pipelined a cycle ahead as the schedule requires."""

    await FallingEdge(dut.clk)
    dut.w_load_i.value = 1
    dut.w_beat_i.value = pack_beat(weights, npe=NPE)
    dut.mac_valid_i.value = 0
    await RisingEdge(dut.clk)

    await FallingEdge(dut.clk)
    dut.w_load_i.value = 0
    dut.mac_valid_i.value = 1
    dut.a_q4_i.value = pack_acts(acts)
    dut.acc_entry_i.value = entry
    dut.acc_clear_i.value = 1 if clear else 0
    await RisingEdge(dut.clk)

    await FallingEdge(dut.clk)
    dut.mac_valid_i.value = 0
    model.mac(weights, [acts], entry, clear)


async def load_entry(dut, model, rng, entry, beats) -> None:
    for index in range(beats):
        weights = [[rng.randint(W_MIN, W_MAX) for _ in range(NWAY)]
                   for _ in range(NPE)]
        acts = [rng.randint(0, A_MAX) for _ in range(NWAY)]
        await issue_mac(dut, model, weights, acts, entry, index == 0)


async def run_drain(dut, entry, scales, biases):
    """Drive one dequantizing pass and collect (lane, value) in issue order."""

    await FallingEdge(dut.clk)
    dut.dq_req_i.value = 1
    dut.dq_entry_i.value = entry
    # The edge below accepts the request, so the cycle after it is the one that
    # issues lane 0. Metadata is driven on that cycle's falling edge, which is
    # the first thing the loop does.
    await RisingEdge(dut.clk)

    collected = []
    issued = 0
    for _ in range(NLANE * 4 + 32):
        await FallingEdge(dut.clk)
        dut.dq_req_i.value = 0
        if int(dut.dq_issue_o.value):
            assert int(dut.dq_lane_o.value) == issued, (
                f"dq_lane_o said {int(dut.dq_lane_o.value)} on the cycle the "
                f"documented order says lane {issued}"
            )
            dut.dq_scale_i.value = scales[issued]
            dut.dq_bias_i.value = biases[issued] & 0xFFFFFFFF
            issued += 1
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.y_valid_o.value):
            collected.append((int(dut.y_lane_o.value), int(dut.y_data_o.value)))
        if len(collected) == NLANE:
            break

    assert issued == NLANE, f"only {issued} of {NLANE} lanes were issued"
    assert len(collected) == NLANE, (
        f"only {len(collected)} of {NLANE} results came back"
    )
    return collected


def golden(acc, scales, biases):
    out = []
    for lane in range(NLANE):
        fp32_bits, _ = dequant_lane(acc[lane], biases[lane], scales[lane], FP16)
        out.append(fp32_to_float16(fp32_bits, FP16))
    return out


@cocotb.test()
async def test_dequant_drain(dut) -> None:
    """Random accumulator contents through the engine, against the model."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset(dut)
    rng = random.Random(0x5013)

    rounds = int(os.environ.get("SPINQUANT_DQ_ROUNDS", "12"))
    for round_index in range(rounds):
        model = SpinQuantPcu(npe=NPE, nrow=1, nentry=NENTRY)
        entry = rng.randrange(NENTRY)
        await load_entry(dut, model, rng, entry, rng.randint(1, 6))

        acc = list(model.read(entry))
        scales = [rng.choice(SCALE_POOL) for _ in range(NLANE)]
        # bias_int = -zp_a * sum(W_q_row): an integer of either sign, and zero
        # often enough that the no-bias path is covered too.
        biases = [0 if rng.random() < 0.3 else rng.randint(-4000, 4000)
                  for _ in range(NLANE)]

        collected = await run_drain(dut, entry, scales, biases)
        expected = golden(acc, scales, biases)

        for position, (lane, value) in enumerate(collected):
            assert lane == position, (
                f"round {round_index}: result {position} carried lane tag {lane}"
            )
            assert value == expected[lane], (
                f"round {round_index} lane {lane}: acc={acc[lane]} "
                f"bias={biases[lane]} scale=0x{scales[lane]:04x}: "
                f"got 0x{value:04x}, expected 0x{expected[lane]:04x}"
            )

        # The raw drain must be untouched by the pass that just read it.
        await FallingEdge(dut.clk)
        dut.drain_entry_i.value = entry
        await RisingEdge(dut.clk)
        await ReadOnly()
        raw = int(dut.drain_data_o.value)
        for lane in range(NLANE):
            field = (raw >> (lane * 32)) & 0xFFFFFFFF
            signed = field - (1 << 32) if field >> 31 else field
            assert signed == acc[lane], (
                f"round {round_index}: the dequantizing pass disturbed raw "
                f"lane {lane}"
            )

    dut._log.info("spinquant_pcu_dq: %d drains checked", rounds)
