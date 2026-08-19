"""End-to-end regression for the AWQ PCU with in-PCU dequantization.

The three shared FP pipes are checked on their own by ``awq_dequant_arith``.
What this test covers is the wrapper around them: the two group snapshot slots,
the three tag FIFOs, the batch sequencer, and the per-PE FP32 accumulator bank
-- everything whose sizing moves with NUM_PES.

Two oracles run side by side and neither uses host floating point:

    int4float_pcu_model.PcuModel   the unchanged raw INT32 datapath
    awq_dequant_model.AwqDequantGolden   the FP32 chain and the final pack

The design assumes software holds ``i_ref_exp`` constant across a weight group,
so the stimulus picks one reference exponent per group -- the largest LSB
exponent over every activation in it -- and drives that for every tile of the
group, which is what the assumption means in practice.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from awq_dequant_model import BF16 as DQ_BF16, FP16 as DQ_FP16, AwqDequantGolden
from int4float_pcu_model import BF16, FP16, PcuModel, reference_exponent

FMT_NAME = os.environ.get("PCU_FMT", "bf16")
FMT = FP16 if FMT_NAME == "fp16" else BF16
DQ_FMT = DQ_FP16 if FMT_NAME == "fp16" else DQ_BF16
NUM_PES = int(os.environ.get("PCU_NUM_PES", "8"))
LANES = 4
GUARD = 8
SEED = 0x44513031

# Scale palette: 1.0, 0.5, 2.0, a value with a long significand, the smallest
# subnormal, and +0. All are inside the multiplier's positive-finite contract.
SCALES = {
    "bf16": (0x3F80, 0x3F00, 0x4000, 0x3EAB, 0x0001, 0x0000, 0x4120),
    "fp16": (0x3C00, 0x3800, 0x4000, 0x3555, 0x0001, 0x0000, 0x4900),
}[FMT_NAME]

CORNERS = (0x0000, 0x8000, 0x0001, 0x007F, 0x0080, 0x3F80, 0xBF80,
           0x4000, 0x3F00, 0x4123)


def signed32(value: int) -> int:
    return value - (1 << 32) if value >> 31 else value


async def reset(dut) -> None:
    dut.rst_n.value = 0
    for name in ("i_valid", "i_acc_clear", "i_acc_enable", "i_act", "i_ref_exp",
                 "i_weight_q", "i_weight_zp", "i_group_last", "i_scale",
                 "i_fp_acc_clear", "i_dot_last", "i_result_ready"):
        getattr(dut, name).value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.o_result_valid.value) == 0
    assert int(dut.o_status_sticky.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_tile(dut, tile, ref_exp, *, acc_clear, group_last,
                     scales, fp_acc_clear, dot_last) -> None:
    """Present one tile and hold it until the PCU accepts it."""

    await FallingEdge(dut.clk)
    dut.i_valid.value = 1
    dut.i_acc_clear.value = int(acc_clear)
    dut.i_acc_enable.value = 1
    dut.i_act.value = sum(w << (16 * i) for i, w in enumerate(tile["acts"]))
    dut.i_ref_exp.value = ref_exp & 0x3FF
    dut.i_weight_q.value = sum(
        tile["weights"][pe][lane] << ((pe * LANES + lane) * 4)
        for pe in range(NUM_PES) for lane in range(LANES)
    )
    dut.i_weight_zp.value = sum(
        z << (4 * pe) for pe, z in enumerate(tile["zp"])
    )
    dut.i_group_last.value = int(group_last)
    dut.i_scale.value = sum(s << (16 * pe) for pe, s in enumerate(scales))
    dut.i_fp_acc_clear.value = int(fp_acc_clear)
    dut.i_dot_last.value = int(dot_last)

    # Hold the payload until i_ready is high on a rising edge.
    for _ in range(64):
        await ReadOnly()
        accepted = int(dut.i_ready.value) == 1
        await RisingEdge(dut.clk)
        if accepted:
            break
        await FallingEdge(dut.clk)
    else:
        raise AssertionError("PCU never asserted i_ready")

    await FallingEdge(dut.clk)
    dut.i_valid.value = 0
    dut.i_group_last.value = 0
    dut.i_fp_acc_clear.value = 0
    dut.i_dot_last.value = 0


def make_tile(rng) -> dict:
    return {
        "acts": [rng.choice(CORNERS) if rng.random() < 0.35
                 else rng.getrandbits(16) for _ in range(LANES)],
        "weights": [[rng.randrange(16) for _ in range(LANES)]
                    for _ in range(NUM_PES)],
        "zp": [rng.randrange(16) for _ in range(NUM_PES)],
    }


async def run_dot(dut, rng, dq_model, *, group_count: int,
                  stall_result: bool) -> None:
    raw_model = PcuModel(FMT, NUM_PES)
    expected_result = None

    for group_index in range(group_count):
        tile_count = 2 + group_index
        tiles = [make_tile(rng) for _ in range(tile_count)]
        # One reference exponent for the whole group, as the design requires.
        ref_exp = max(reference_exponent(FMT, tile["acts"]) for tile in tiles)
        scales = [rng.choice(SCALES) for _ in range(NUM_PES)]
        fp_acc_clear = group_index == 0
        dot_last = group_index == group_count - 1

        raw = None
        for tile_index, tile in enumerate(tiles):
            last = tile_index == tile_count - 1
            raw, _, _ = raw_model.transaction(
                tile["acts"], tile["weights"], tile["zp"], ref_exp,
                acc_clear=(tile_index == 0), acc_enable=True,
            )
            await drive_tile(
                dut, tile, ref_exp,
                acc_clear=(tile_index == 0),
                group_last=last,
                scales=scales,
                fp_acc_clear=fp_acc_clear,
                dot_last=dot_last,
            )

        # The raw pipeline is four stages deep; let it settle, then check the
        # integer accumulators the snapshot is taken from.
        for _ in range(6):
            await RisingEdge(dut.clk)
        await ReadOnly()
        drained = int(dut.o_acc.value)
        for pe in range(NUM_PES):
            got = signed32((drained >> (32 * pe)) & 0xFFFFFFFF)
            assert got == raw[pe], (
                f"group {group_index} PE {pe}: raw acc {got} != {raw[pe]}"
            )

        result = dq_model.accept_group(
            raw, scales, ref_exp,
            fp_acc_clear=fp_acc_clear, dot_last=dot_last,
        )
        if result is not None:
            expected_result = result

    assert expected_result is not None

    # Optionally hold i_result_ready low to prove the result vector is retained.
    stalled = 0
    if stall_result:
        await FallingEdge(dut.clk)
        dut.i_result_ready.value = 0

    held = None
    for _ in range(600):
        await ReadOnly()
        if int(dut.o_result_valid.value):
            value = int(dut.o_result.value)
            if held is None:
                held = value
            else:
                assert value == held, "o_result moved while stalled"
            stalled += 1
            if not stall_result or stalled > 6:
                break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("o_result_valid never asserted")

    actual = tuple((held >> (16 * pe)) & 0xFFFF for pe in range(NUM_PES))
    assert actual == expected_result, (
        "result vector mismatch\n"
        f"  got      {[hex(v) for v in actual]}\n"
        f"  expected {[hex(v) for v in expected_result]}"
    )

    # Consume the result so the next dot product can start.
    await FallingEdge(dut.clk)
    dut.i_result_ready.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.i_result_ready.value = 0
    await ReadOnly()

    # The protocol bit must stay clear for any legal ready/valid sequence, and
    # the arithmetic bits must agree with the model rather than be assumed
    # clear: full-range bfloat16 activations do reach binary32 infinity.
    sticky = int(dut.o_status_sticky.value)
    assert sticky & 0b1000 == 0, "protocol error"
    assert sticky & 0b0001 == dq_model.sticky_invalid, (
        f"sticky invalid {sticky & 1} != model {dq_model.sticky_invalid}"
    )
    assert sticky & 0b0010 == (dq_model.sticky_overflow << 1), (
        f"sticky overflow {(sticky >> 1) & 1} != "
        f"model {dq_model.sticky_overflow}"
    )


@cocotb.test()
async def test_pcu_dq_dot_products(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset(dut)
    rng = random.Random(SEED)

    # The sticky bits never clear, so one model instance spans every dot
    # product, exactly as the hardware's status register does.
    dq_model = AwqDequantGolden(NUM_PES, DQ_FMT)
    dots = int(os.environ.get("PCU_DQ_DOTS", "6"))
    for index in range(dots):
        await run_dot(
            dut, rng, dq_model,
            group_count=1 + (index % 3),
            stall_result=(index % 2 == 1),
        )
