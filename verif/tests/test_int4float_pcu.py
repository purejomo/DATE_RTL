"""Bit-exact regression for the INT4 x float PCU in P3-LLM's organization.

The datapath is fixed point end to end, so the oracle is the pure-integer
`int4float_pcu_model`, the same style of model the P3-LLM PCU is verified
against. Activation format and lane widths come from the environment so one
test module covers both the binary16 and bfloat16 rows.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from int4float_pcu_model import BF16, FP16, PcuModel, reference_exponent

FMT = BF16 if os.environ.get("PCU_FORMAT", "fp16") == "bf16" else FP16
ITERATIONS = int(os.environ.get("PCU_ITERS", "4000"))
SEED = 0x50435530
LANES = 4
NUM_PES = int(os.environ.get("PCU_NUM_PES", "16"))
LATENCY = 4          # accept edge to o_valid

FP16_CORNERS = (0x0000, 0x8000, 0x0001, 0x03FF, 0x0400, 0x3C00, 0xBC00,
                0x4000, 0x7BFF, 0x7C00, 0xFC00, 0x7E00, 0x3555, 0x1234)
BF16_CORNERS = (0x0000, 0x8000, 0x0001, 0x007F, 0x0080, 0x3F80, 0xBF80,
                0x4000, 0x7F7F, 0x7F80, 0xFF80, 0x7FC0, 0x3F00, 0x4123)
CORNERS = BF16_CORNERS if FMT is BF16 else FP16_CORNERS


def signed32(value: int) -> int:
    return value - (1 << 32) if value >> 31 else value


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("i_valid", "i_acc_clear", "i_acc_enable", "i_act",
                 "i_ref_exp", "i_weight_q", "i_weight_zp"):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_random_tiles(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    model = PcuModel(FMT, NUM_PES)
    rng = random.Random(SEED)
    await reset(dut)
    model.reset()

    for iteration in range(ITERATIONS):
        acts = [rng.choice(CORNERS) if rng.random() < 0.3 else rng.getrandbits(16)
                for _ in range(LANES)]
        weights = [[rng.randrange(16) for _ in range(LANES)]
                   for _ in range(NUM_PES)]
        zp = rng.randrange(16)
        ref = reference_exponent(FMT, acts)
        clear = iteration % 64 == 0
        enable = True

        expected, sat, inv = model.transaction(
            acts, weights, zp, ref, acc_clear=clear, acc_enable=enable
        )

        dut.i_valid.value = 1
        dut.i_acc_clear.value = int(clear)
        dut.i_acc_enable.value = int(enable)
        dut.i_act.value = sum(w << (16 * i) for i, w in enumerate(acts))
        dut.i_ref_exp.value = ref & 0x3FF
        dut.i_weight_q.value = sum(
            weights[pe][lane] << ((pe * LANES + lane) * 4)
            for pe in range(NUM_PES) for lane in range(LANES)
        )
        dut.i_weight_zp.value = zp

        await ReadOnly()
        assert int(dut.i_ready.value) == 1, "PCU not ready"
        await RisingEdge(dut.clk)
        dut.i_valid.value = 0

        for _ in range(LATENCY - 1):
            await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.o_valid.value) == 1, (
            f"iteration {iteration}: o_valid missing at N+{LATENCY}"
        )
        raw = int(dut.o_acc.value)
        for pe in range(NUM_PES):
            got = signed32((raw >> (32 * pe)) & 0xFFFFFFFF)
            assert got == expected[pe], (
                f"iteration {iteration} PE {pe}: got {got}, "
                f"expected {expected[pe]} (ref_exp={ref}, zp={zp})"
            )
        assert int(dut.o_saturate.value) == int(sat), \
            f"iteration {iteration}: o_saturate mismatch"
        assert int(dut.o_invalid.value) == int(inv), \
            f"iteration {iteration}: o_invalid mismatch"
        await RisingEdge(dut.clk)

    dut._log.info(
        f"{ITERATIONS} tiles matched the reference "
        f"({'bf16' if FMT is BF16 else 'fp16'} activations)"
    )
