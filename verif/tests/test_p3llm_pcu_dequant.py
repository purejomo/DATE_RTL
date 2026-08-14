"""End-to-end cocotb regression for ``p3llm_pcu_dequant``.

The test is latency-independent: accepted raw-PCU transactions and completed
FP16 vectors are score-boarded through their valid/ready interfaces.  It
therefore remains valid when the shared dequant engine is re-pipelined.
"""

from __future__ import annotations

from collections import deque
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from common import unpack_signed_bus
from p3llm_dequant_model import (
    DequantGolden,
    pack_u16_lanes,
    unpack_u16_lanes,
)
from p3llm_pcu_model import (
    LANES,
    NUM_PES,
    OP_LINEAR,
    OP_PV,
    OP_QK,
    PcuGolden,
    pack_lanes,
    pack_rhs,
)


def _port(dut, *names):
    """Return a port while tolerating the old unsuffixed naming convention."""

    for name in names:
        if hasattr(dut, name):
            return getattr(dut, name)
    raise AttributeError(f"none of these DUT ports exists: {', '.join(names)}")


def _optional_port(dut, *names):
    for name in names:
        if hasattr(dut, name):
            return getattr(dut, name)
    return None


def _set(dut, value, suffixed: str, unsuffixed: str) -> None:
    _port(dut, suffixed, unsuffixed).value = value


def drive_idle(dut) -> None:
    _set(dut, 0, "in_valid_i", "in_valid")
    _set(dut, OP_LINEAR, "op_mode_i", "op_mode")
    _set(dut, 0, "acc_clear_i", "acc_clear")
    _set(dut, 0, "acc_enable_i", "acc_enable")
    _set(dut, 0, "input_fp8_i", "input_fp8")
    _set(dut, 0, "rhs_q4_i", "rhs_q4")
    _set(dut, 0, "bitmod_special_sel_i", "bitmod_special_sel")
    _set(dut, 0, "zp_by_pe_i", "zp_by_pe")
    _set(dut, 0, "zp_by_lane_i", "zp_by_lane")
    _set(dut, 0, "group_last_i", "group_last")
    _set(dut, 0, "fp_acc_clear_i", "fp_acc_clear")
    _set(dut, 0, "dot_last_i", "dot_last")
    _set(dut, 0, "vector_scale_by_pe_i", "vector_scale_by_pe")
    _set(dut, 0x3C00, "final_scale_i", "final_scale")


def drive_transaction(dut, transaction: dict | None) -> None:
    if transaction is None:
        drive_idle(dut)
        return
    _set(dut, 1, "in_valid_i", "in_valid")
    _set(dut, transaction["op_mode"], "op_mode_i", "op_mode")
    _set(dut, transaction["acc_clear"], "acc_clear_i", "acc_clear")
    _set(dut, transaction["acc_enable"], "acc_enable_i", "acc_enable")
    _set(
        dut,
        pack_lanes(transaction["input_fp8"], 8),
        "input_fp8_i",
        "input_fp8",
    )
    _set(dut, pack_rhs(transaction["rhs_q4"]), "rhs_q4_i", "rhs_q4")
    _set(
        dut,
        pack_lanes(transaction["special_sel"], 2),
        "bitmod_special_sel_i",
        "bitmod_special_sel",
    )
    _set(
        dut,
        pack_lanes(transaction["zp_by_pe"], 4),
        "zp_by_pe_i",
        "zp_by_pe",
    )
    _set(
        dut,
        pack_lanes(transaction["zp_by_lane"], 4),
        "zp_by_lane_i",
        "zp_by_lane",
    )
    _set(dut, transaction["group_last"], "group_last_i", "group_last")
    _set(
        dut,
        transaction["fp_acc_clear"],
        "fp_acc_clear_i",
        "fp_acc_clear",
    )
    _set(dut, transaction["dot_last"], "dot_last_i", "dot_last")
    _set(
        dut,
        pack_u16_lanes(transaction["vector_scale16"]),
        "vector_scale_by_pe_i",
        "vector_scale_by_pe",
    )
    _set(
        dut,
        transaction["final_scale16"],
        "final_scale_i",
        "final_scale",
    )


async def reset_dut(dut) -> None:
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    drive_idle(dut)
    _port(dut, "result_ready_i", "result_ready").value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(_port(dut, "result_valid_o", "result_valid").value) == 0
        assert int(_port(dut, "fp16_out_o", "fp16_out").value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def _scales_for(mode: int, group_index: int) -> tuple[int, ...]:
    # Includes minimum-normal and minimum-subnormal binary16.  Rotation makes
    # scale-to-PE ordering different in every group.
    palette = (0x3C00, 0x3800, 0x4000, 0x3400, 0x4400, 0x0400, 0x0001, 0x3555)
    return tuple(
        palette[(pe * 3 + group_index + mode) % len(palette)]
        for pe in range(NUM_PES)
    )


def _tile_operands(mode: int, group_index: int, tile_index: int) -> dict:
    if mode == OP_PV:
        lhs_palette = (0xF0, 0xE8, 0xD0, 0xC4, 0xB0, 0x91, 0x40, 0x01)
    else:
        # Valid E4M3 values with both signs and a broad exponent range.
        lhs_palette = (0x38, 0xB8, 0x40, 0x30, 0x70, 0xF0, 0x28, 0xC8)
    inputs = tuple(
        lhs_palette[(lane + tile_index + 2 * group_index) % len(lhs_palette)]
        for lane in range(LANES)
    )
    rhs = tuple(
        tuple(
            (1 + pe * 5 + lane * 3 + tile_index * 7 + group_index) & 0xF
            for lane in range(LANES)
        )
        for pe in range(NUM_PES)
    )
    return {
        "input_fp8": inputs,
        "rhs_q4": rhs,
        "special_sel": tuple((pe + group_index) & 0x3 for pe in range(NUM_PES)),
        "zp_by_pe": tuple((pe * 3 + group_index) & 0xF for pe in range(NUM_PES)),
        "zp_by_lane": tuple(
            (lane * 4 + tile_index + group_index) & 0xF for lane in range(LANES)
        ),
    }


def make_dot(mode: int) -> list[dict]:
    """Build three scale groups with nonuniform, PE-distinct data."""

    transactions: list[dict] = []
    group_count = 3
    final_scale = {OP_LINEAR: 0x3C00, OP_QK: 0x3800, OP_PV: 0x4400}[mode]
    for group_index in range(group_count):
        tile_count = 3 + group_index
        scales = _scales_for(mode, group_index)
        for tile_index in range(tile_count):
            transaction = _tile_operands(mode, group_index, tile_index)
            transaction.update(
                op_mode=mode,
                acc_clear=(tile_index == 0),
                acc_enable=True,
                group_last=(tile_index == tile_count - 1),
                fp_acc_clear=(
                    group_index == 0 and tile_index == tile_count - 1
                ),
                dot_last=(
                    group_index == group_count - 1
                    and tile_index == tile_count - 1
                ),
                vector_scale16=scales,
                final_scale16=final_scale,
            )
            transactions.append(transaction)
    return transactions


def _accept_models(
    pcu_model: PcuGolden,
    dequant_model: DequantGolden,
    transaction: dict,
):
    raw, _ = pcu_model.transaction(
        transaction["input_fp8"],
        transaction["rhs_q4"],
        transaction["op_mode"],
        acc_clear=transaction["acc_clear"],
        acc_enable=transaction["acc_enable"],
        bitmod_special_sel=transaction["special_sel"],
        zp_by_pe=transaction["zp_by_pe"],
        zp_by_lane=transaction["zp_by_lane"],
    )
    result = None
    if transaction["group_last"]:
        trace = dequant_model.accept_group(
            raw,
            transaction["vector_scale16"],
            transaction["op_mode"],
            fp_acc_clear=transaction["fp_acc_clear"],
            dot_last=transaction["dot_last"],
            final_scale16=transaction["final_scale16"],
        )
        result = trace.result16
    return raw, result


async def run_dot(dut, mode: int, *, seed: int) -> None:
    transactions = make_dot(mode)
    pcu_model = PcuGolden()
    dequant_model = DequantGolden()
    expected_raw = deque()
    expected_result = None
    current = None
    next_index = 0
    gap_cycles = 0
    result_stall_cycles = 0
    result_consumed = False
    held_result = None
    rng = random.Random(seed)

    raw_valid = _optional_port(dut, "raw_out_valid_o", "raw_out_valid")
    raw_bus = _optional_port(dut, "raw_acc_out_o", "raw_acc_out")
    in_ready = _port(dut, "in_ready_o", "in_ready")
    result_valid = _port(dut, "result_valid_o", "result_valid")
    result_ready = _port(dut, "result_ready_i", "result_ready")
    fp16_out = _port(dut, "fp16_out_o", "fp16_out")

    for cycle in range(4000):
        await FallingEdge(dut.clk)

        if current is None and next_index < len(transactions):
            if gap_cycles:
                gap_cycles -= 1
            else:
                current = transactions[next_index]
        drive_transaction(dut, current)

        # Deliberately hold every completed vector for four cycles.  This
        # checks valid/data stability, not just a lucky one-cycle pulse.
        if int(result_valid.value):
            ready_value = int(result_stall_cycles >= 4)
            result_stall_cycles += 1
        else:
            ready_value = 0
        result_ready.value = ready_value
        await Timer(1, units="ps")

        input_accept = current is not None and int(in_ready.value)
        result_accept = int(result_valid.value) and int(result_ready.value)
        if int(result_valid.value):
            actual_result = unpack_u16_lanes(int(fp16_out.value))
            assert expected_result is not None, "DUT produced an unexpected result"
            assert actual_result == expected_result, (
                f"mode {mode} FP16 vector mismatch at cycle {cycle}\n"
                f"actual  ={tuple(hex(x) for x in actual_result)}\n"
                f"expected={tuple(hex(x) for x in expected_result)}"
            )
            if held_result is None:
                held_result = int(fp16_out.value)
            else:
                assert int(fp16_out.value) == held_result, (
                    "fp16_out changed while result_valid=1 and result_ready=0"
                )

        if input_accept:
            raw, maybe_result = _accept_models(pcu_model, dequant_model, current)
            expected_raw.append(raw)
            if maybe_result is not None:
                assert expected_result is None
                expected_result = maybe_result
                # A lane-permuted implementation cannot pass this comparison:
                # the generated vector contains many distinct bit patterns.
                assert len(set(expected_result)) >= 6
            next_index += 1
            current = None
            gap_cycles = rng.randrange(3)  # explicit in_valid bubbles

        await RisingEdge(dut.clk)
        await ReadOnly()

        if raw_valid is not None:
            assert raw_bus is not None
            if int(raw_valid.value):
                assert expected_raw, "unexpected raw_out_valid_o pulse"
                actual_raw = unpack_signed_bus(int(raw_bus.value), 32, NUM_PES)
                wanted_raw = expected_raw.popleft()
                assert actual_raw == wanted_raw, (
                    f"mode {mode} raw PCU mismatch at cycle {cycle}\n"
                    f"actual  ={actual_raw}\nexpected={wanted_raw}"
                )

        if result_accept:
            result_consumed = True

        if (
            result_consumed
            and next_index == len(transactions)
            and current is None
            and (raw_valid is None or not expected_raw)
        ):
            break
    else:
        raise AssertionError(f"mode {mode} timed out")

    assert result_stall_cycles >= 5


@cocotb.test()
async def test_pcu_dequant_all_modes(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await reset_dut(dut)

    for mode, seed in (
        (OP_LINEAR, 0xD001),
        (OP_QK, 0xD002),
        (OP_PV, 0xD003),
    ):
        await run_dot(dut, mode, seed=seed)

    # Invalid/overflow status must remain clear for this finite, bounded test.
    for names in (
        ("status_invalid_o", "fp_invalid_o", "invalid_o"),
        ("status_overflow_o", "status_fp_overflow_o", "fp_overflow_o"),
        ("status_int_overflow_o", "int_overflow_o"),
        ("status_protocol_error_o", "protocol_error_o"),
    ):
        signal = _optional_port(dut, *names)
        if signal is not None:
            assert int(signal.value) == 0, f"unexpected status flag {signal._name}"
