"""Bit-exact regression for the INT4 x float PCU in P3-LLM's organization.

The datapath is fixed point end to end, so the oracle is the pure-integer
`int4float_pcu_model`, the same style of model the P3-LLM PCU is verified
against. Format, lane count and zero-point layout all come from the
environment, so one test module covers every AWQ PCU row:

    PCU_NUM_PES    8 for the pcu32 tops, 16 for the pcu_top build
    Zero point      one four-bit value per PE, matching every current AWQ top
    PCU_FMT        bf16 or fp16
    PCU_ACC_W      accumulator width: 32 for the base builds, 16 for acc16
    PCU_ACC_RSH    RNE shift applied before accumulating; 0 for the base
                   builds, 12 (BF16) or 15 (FP16) for acc16
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from int4float_pcu_model import BF16, FP16, PcuModel, reference_exponent

FMT = FP16 if os.environ.get("PCU_FMT", "bf16") == "fp16" else BF16
ITERATIONS = int(os.environ.get("PCU_ITERS", "4000"))
SEED = 0x50435530
LANES = 4
NUM_PES = int(os.environ.get("PCU_NUM_PES", "16"))
ACC_W = int(os.environ.get("PCU_ACC_W", "32"))
ACC_RSH = int(os.environ.get("PCU_ACC_RSH", "0"))
ACC_MASK = (1 << ACC_W) - 1
LATENCY = 4          # accept edge to o_valid

# bfloat16 encodings: zero, negative zero, the smallest subnormal, the
# subnormal/normal boundary, +-1, 2, the largest finite, +-inf, a NaN, and two
# ordinary values. The same words are legal fp16 encodings, so the sweep hits
# that format's corners too even though they name different values there.
CORNERS = (0x0000, 0x8000, 0x0001, 0x007F, 0x0080, 0x3F80, 0xBF80,
           0x4000, 0x7F7F, 0x7F80, 0xFF80, 0x7FC0, 0x3F00, 0x4123)


def signed_acc(value: int) -> int:
    return value - (1 << ACC_W) if value >> (ACC_W - 1) else value


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
    model = PcuModel(FMT, NUM_PES, acc_bits=ACC_W, acc_rsh=ACC_RSH)
    rng = random.Random(SEED)
    await reset(dut)
    model.reset()

    for iteration in range(ITERATIONS):
        acts = [rng.choice(CORNERS) if rng.random() < 0.3 else rng.getrandbits(16)
                for _ in range(LANES)]
        weights = [[rng.randrange(16) for _ in range(LANES)]
                   for _ in range(NUM_PES)]
        zp = [rng.randrange(16) for _ in range(NUM_PES)]
        zp_word = sum(z << (4 * pe) for pe, z in enumerate(zp))
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
        dut.i_weight_zp.value = zp_word

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
            got = signed_acc((raw >> (ACC_W * pe)) & ACC_MASK)
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
        f"({os.environ.get('PCU_FMT', 'bf16')} activations, "
        f"{NUM_PES} PEs, per-PE zp)"
    )
