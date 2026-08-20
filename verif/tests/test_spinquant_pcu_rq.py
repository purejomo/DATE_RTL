"""Regression for the SpinQuant PCU-local dequantizer + requantizer (axis 4).

This is the row that closes the loop, so the test walks the two-pass protocol it
depends on:

    pass 1   drive with s[i]; the engine reduces its own lanes to one binary32
             min and one max, which is all the NPU needs to finish the
             per-token reduction across banks
    pass 2   drive with t[i] = s[i]/s_a'; the engine emits unsigned INT4

The test checks min/max, UINT4 RNE/zero-point/clamp, and the raw accumulator.
The optional binary16 output is compared with axis 3 when enabled and checked
as zero when disabled.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from spinquant_model import NWAY, SpinQuantPcu, pack_acts, pack_beat
from awq_dequant_model import fp32_to_float16
from spinquant_dequant_model import (
    FP16,
    dequant_lane,
    minmax,
    requant_int4,
)

NPE = int(os.environ.get("SPINQUANT_NPE", "16"))
KEEP_FP16 = int(os.environ.get("SPINQUANT_KEEP_FP16", "1"))
NLANE = NPE
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
    dut.rq_zp_i.value = 0
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


async def run_drain(dut, entry, scales, biases, zp):
    """Drive one pass and collect (lane, q4, fp16) in issue order."""

    await FallingEdge(dut.clk)
    dut.dq_req_i.value = 1
    dut.dq_entry_i.value = entry
    dut.rq_zp_i.value = zp
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
            collected.append((int(dut.y_lane_o.value),
                              int(dut.y_q4_o.value),
                              int(dut.y_fp16_o.value)))
        if len(collected) == NLANE:
            break

    assert issued == NLANE, f"only {issued} of {NLANE} lanes were issued"
    assert len(collected) == NLANE, (
        f"only {len(collected)} of {NLANE} results came back"
    )
    return collected


def dequant_stream(acc, scales, biases):
    """The binary32 the multiply pipe produces, lane by lane."""

    return [dequant_lane(acc[lane], biases[lane], scales[lane], FP16)[0]
            for lane in range(NLANE)]


@cocotb.test()
async def test_requant_two_pass(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset(dut)
    rng = random.Random(0x4011)

    rounds = int(os.environ.get("SPINQUANT_RQ_ROUNDS", "12"))
    for round_index in range(rounds):
        model = SpinQuantPcu(npe=NPE, nrow=1, nentry=NENTRY)
        entry = rng.randrange(NENTRY)
        await load_entry(dut, model, rng, entry, rng.randint(1, 6))
        acc = list(model.read(entry))

        # ---- pass 1: the local reduction ------------------------------
        scales = [rng.choice(SCALE_POOL) for _ in range(NLANE)]
        biases = [0 if rng.random() < 0.3 else rng.randint(-4000, 4000)
                  for _ in range(NLANE)]
        await run_drain(dut, entry, scales, biases, 0)

        await ReadOnly()
        got = (int(dut.mm_min_o.value), int(dut.mm_max_o.value))
        want = minmax(dequant_stream(acc, scales, biases))
        assert got == want, (
            f"round {round_index}: pass-1 reduction gave "
            f"(0x{got[0]:08x}, 0x{got[1]:08x}), expected "
            f"(0x{want[0]:08x}, 0x{want[1]:08x})"
        )

        # ---- pass 2: the requantization -------------------------------
        #
        # t[i] and zp' are whatever the NPU computed; the hardware contract is
        # independent of how. Driving them randomly covers more of the clamp
        # and tie behaviour than a realistic pair would.
        tscales = [rng.choice(SCALE_POOL) for _ in range(NLANE)]
        zp = rng.randrange(16)
        collected = await run_drain(dut, entry, tscales, biases, zp)

        fp32s = dequant_stream(acc, tscales, biases)
        for position, (lane, q4, fp16) in enumerate(collected):
            assert lane == position, (
                f"round {round_index}: result {position} carried lane tag {lane}"
            )
            want_q4, _, _ = requant_int4(fp32s[lane], zp)
            assert q4 == want_q4, (
                f"round {round_index} lane {lane}: acc={acc[lane]} "
                f"bias={biases[lane]} t=0x{tscales[lane]:04x} zp={zp}: "
                f"got INT4 {q4}, expected {want_q4}"
            )
            want_fp16 = fp32_to_float16(fp32s[lane], FP16)
            if KEEP_FP16:
                assert fp16 == want_fp16, (
                    f"round {round_index} lane {lane}: retained binary16 "
                    f"0x{fp16:04x} does not match the axis-3 value "
                    f"0x{want_fp16:04x}"
                )
            else:
                assert fp16 == 0, (
                    f"round {round_index} lane {lane}: disabled binary16 "
                    f"output is 0x{fp16:04x}"
                )

        # The raw drain must be untouched by either pass.
        await FallingEdge(dut.clk)
        dut.drain_entry_i.value = entry
        await RisingEdge(dut.clk)
        await ReadOnly()
        raw = int(dut.drain_data_o.value)
        for lane in range(NLANE):
            field = (raw >> (lane * 32)) & 0xFFFFFFFF
            signed = field - (1 << 32) if field >> 31 else field
            assert signed == acc[lane], (
                f"round {round_index}: a postprocess pass disturbed raw "
                f"lane {lane}"
            )

    dut._log.info("spinquant_pcu_rq: %d two-pass drains checked", rounds)
