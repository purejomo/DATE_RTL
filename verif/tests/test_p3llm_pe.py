from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from common import signal_signed
from p3llm_formats import wrap_signed
from p3llm_pcu_model import (
    OP_LINEAR,
    OP_PV,
    OP_QK,
    PIPELINE_EDGE_LATENCY,
    pack_lanes,
    pe_dot,
)


async def reset_pe(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.in_valid_i.value = 0
    dut.op_mode_i.value = OP_LINEAR
    dut.acc_clear_i.value = 0
    dut.acc_enable_i.value = 0
    dut.input_fp8_i.value = 0
    dut.rhs_q4_i.value = 0
    dut.bitmod_special_sel_i.value = 0
    dut.zp_by_pe_i.value = 0
    dut.zp_by_lane_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert signal_signed(dut.acc_out_o, 32) == 0
    assert int(dut.out_valid_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def pe_expected(transaction, accumulator):
    trace = pe_dot(
        transaction["input_fp8"],
        transaction["rhs_q4"],
        transaction["op_mode"],
        bitmod_special_sel=transaction.get("special_sel", 0),
        zp_by_pe=transaction.get("zp_by_pe", 0),
        zp_by_lane=transaction.get("zp_by_lane", (0, 0, 0, 0)),
    )
    if transaction["acc_clear"]:
        accumulator = wrap_signed(trace.partial_sum, 32)
    elif transaction["acc_enable"]:
        accumulator = wrap_signed(accumulator + trace.partial_sum, 32)
    return accumulator, trace


def drive_pe(dut, transaction):
    if transaction is None:
        dut.in_valid_i.value = 0
        dut.acc_clear_i.value = 0
        dut.acc_enable_i.value = 0
        return
    dut.in_valid_i.value = 1
    dut.op_mode_i.value = transaction["op_mode"]
    dut.acc_clear_i.value = transaction["acc_clear"]
    dut.acc_enable_i.value = transaction["acc_enable"]
    dut.input_fp8_i.value = pack_lanes(transaction["input_fp8"], 8)
    dut.rhs_q4_i.value = pack_lanes(transaction["rhs_q4"], 4)
    dut.bitmod_special_sel_i.value = transaction.get("special_sel", 0)
    dut.zp_by_pe_i.value = transaction.get("zp_by_pe", 0)
    dut.zp_by_lane_i.value = pack_lanes(
        transaction.get("zp_by_lane", (0, 0, 0, 0)), 4
    )


async def run_pe_stream(dut, transactions):
    expected_by_cycle = {}
    accumulator = signal_signed(dut.acc_out_o, 32)
    total_cycles = len(transactions) + PIPELINE_EDGE_LATENCY + 1

    for cycle in range(total_cycles):
        await FallingEdge(dut.clk)
        transaction = transactions[cycle] if cycle < len(transactions) else None
        drive_pe(dut, transaction)
        if transaction is not None:
            accumulator, trace = pe_expected(transaction, accumulator)
            expected_by_cycle[cycle + PIPELINE_EDGE_LATENCY] = (
                accumulator,
                trace,
            )

        await RisingEdge(dut.clk)
        await ReadOnly()
        due = expected_by_cycle.get(cycle)
        assert int(dut.out_valid_o.value) == (due is not None), (
            f"out_valid mismatch at stream cycle {cycle}"
        )
        if due is not None:
            expected_acc, _ = due
            actual = signal_signed(dut.acc_out_o, 32)
            assert actual == expected_acc, (
                f"PE accumulator mismatch at cycle {cycle}: "
                f"actual={actual}, expected={expected_acc}"
            )


@cocotb.test()
async def test_compressor(dut):
    """Exercise carry propagation, signed boundaries, and random operands."""

    directed = (
        (0, 0, 0, 0),
        (1, 1, 1, 1),
        (-1, -1, -1, -1),
        ((1 << 25) - 1, (1 << 25) - 1, (1 << 25) - 1, (1 << 25) - 1),
        (-(1 << 25), -(1 << 25), -(1 << 25), -(1 << 25)),
        (0x1555555, 0x0AAAAAA, 0x1333333, 0x0CCCCCC),
        (-0x1555555, 0x0AAAAAA, -0x1333333, 0x0CCCCCC),
    )
    rng = random.Random(0x42C5A)
    vectors = list(directed)
    for _ in range(20_000):
        vectors.append(tuple(rng.randrange(-(1 << 25), 1 << 25) for _ in range(4)))

    for operands in vectors:
        dut.in0.value = operands[0]
        dut.in1.value = operands[1]
        dut.in2.value = operands[2]
        dut.in3.value = operands[3]
        await Timer(1, units="ns")
        expected = wrap_signed(sum(operands), 28)
        sum_value = signal_signed(dut.sum, 28)
        carry_value = signal_signed(dut.carry, 28)
        result = signal_signed(dut.result, 28)
        assert wrap_signed(sum_value + carry_value, 28) == expected
        assert result == expected


@cocotb.test()
async def test_pe_directed(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_pe(dut)

    transactions = [
        # All zero and signed-zero/NaN handling.
        dict(
            input_fp8=(0x00, 0x80, 0x7F, 0xFF),
            rhs_q4=(0x0, 0x8, 0x7, 0xF),
            op_mode=OP_LINEAR,
            special_sel=2,
            acc_clear=True,
            acc_enable=True,
        ),
        # All positive.
        dict(
            input_fp8=(0x38, 0x38, 0x38, 0x38),
            rhs_q4=(0x2, 0x3, 0x4, 0x5),
            op_mode=OP_LINEAR,
            special_sel=0,
            acc_clear=True,
            acc_enable=True,
        ),
        # Mixed sign and both special polarities.
        dict(
            input_fp8=(0x38, 0xB8, 0x40, 0xC0),
            rhs_q4=(0x8, 0x8, 0xF, 0x7),
            op_mode=OP_LINEAR,
            special_sel=1,
            acc_clear=True,
            acc_enable=True,
        ),
        # Maximum finite magnitudes with mixed signs.
        dict(
            input_fp8=(0x7E, 0xFE, 0x7E, 0xFE),
            rhs_q4=(0x8, 0x8, 0x8, 0x8),
            op_mode=OP_LINEAR,
            special_sel=2,
            acc_clear=True,
            acc_enable=True,
        ),
        # Exact positive/negative maximum LINEAR partials: +/-58,720,256.
        dict(
            input_fp8=(0x7E, 0x7E, 0x7E, 0x7E),
            rhs_q4=(0x8, 0x8, 0x8, 0x8),
            op_mode=OP_LINEAR,
            special_sel=2,
            acc_clear=True,
            acc_enable=True,
        ),
        dict(
            input_fp8=(0x7E, 0x7E, 0x7E, 0x7E),
            rhs_q4=(0x8, 0x8, 0x8, 0x8),
            op_mode=OP_LINEAR,
            special_sel=3,
            acc_clear=True,
            acc_enable=True,
        ),
        # Different exponent classes, including subnormal.
        dict(
            input_fp8=(0x01, 0x08, 0x38, 0x77),
            rhs_q4=(0x7, 0x6, 0x5, 0x4),
            op_mode=OP_LINEAR,
            special_sel=3,
            acc_clear=True,
            acc_enable=True,
        ),
        # Carry-heavy compressor pattern.
        dict(
            input_fp8=(0x3F, 0x3F, 0x3F, 0x3F),
            rhs_q4=(0x7, 0x7, 0x7, 0x7),
            op_mode=OP_LINEAR,
            special_sel=0,
            acc_clear=True,
            acc_enable=True,
        ),
        # QK PE-wide zero point.
        dict(
            input_fp8=(0x38, 0xB8, 0x40, 0xC0),
            rhs_q4=(0, 5, 10, 15),
            op_mode=OP_QK,
            zp_by_pe=7,
            zp_by_lane=(0, 1, 2, 3),
            acc_clear=True,
            acc_enable=True,
        ),
        # Exact positive/negative maximum QK partials: +/-55,050,240.
        dict(
            input_fp8=(0x7E, 0x7E, 0x7E, 0x7E),
            rhs_q4=(15, 15, 15, 15),
            op_mode=OP_QK,
            zp_by_pe=0,
            acc_clear=True,
            acc_enable=True,
        ),
        dict(
            input_fp8=(0x7E, 0x7E, 0x7E, 0x7E),
            rhs_q4=(0, 0, 0, 0),
            op_mode=OP_QK,
            zp_by_pe=15,
            acc_clear=True,
            acc_enable=True,
        ),
        # PV lane-wide zero points.
        dict(
            input_fp8=(0x00, 0x70, 0xEF, 0xF0),
            rhs_q4=(0, 5, 10, 15),
            op_mode=OP_PV,
            zp_by_pe=15,
            zp_by_lane=(0, 4, 8, 12),
            acc_clear=True,
            acc_enable=True,
        ),
        # Exact intended-range PV extrema: +/-31,457,280.
        dict(
            input_fp8=(0xF0, 0xF0, 0xF0, 0xF0),
            rhs_q4=(15, 15, 15, 15),
            op_mode=OP_PV,
            zp_by_lane=(0, 0, 0, 0),
            acc_clear=True,
            acc_enable=True,
        ),
        dict(
            input_fp8=(0xF0, 0xF0, 0xF0, 0xF0),
            rhs_q4=(0, 0, 0, 0),
            op_mode=OP_PV,
            zp_by_lane=(15, 15, 15, 15),
            acc_clear=True,
            acc_enable=True,
        ),
        None,  # Valid bubble.
        # Accumulator load followed by back-to-back adds and hold.
        dict(
            input_fp8=(0x38, 0x38, 0x38, 0x38),
            rhs_q4=(0x2, 0x2, 0x2, 0x2),
            op_mode=OP_LINEAR,
            special_sel=0,
            acc_clear=True,
            acc_enable=False,
        ),
        dict(
            input_fp8=(0x38, 0x38, 0x38, 0x38),
            rhs_q4=(0x2, 0x2, 0x2, 0x2),
            op_mode=OP_LINEAR,
            special_sel=0,
            acc_clear=False,
            acc_enable=True,
        ),
        dict(
            input_fp8=(0xB8, 0x38, 0xB8, 0x38),
            rhs_q4=(0x2, 0x2, 0x2, 0x2),
            op_mode=OP_LINEAR,
            special_sel=0,
            acc_clear=False,
            acc_enable=True,
        ),
        dict(
            input_fp8=(0x7E, 0x7E, 0x7E, 0x7E),
            rhs_q4=(0x8, 0x8, 0x8, 0x8),
            op_mode=OP_LINEAR,
            special_sel=2,
            acc_clear=False,
            acc_enable=False,
        ),
    ]
    await run_pe_stream(dut, transactions)

    # Verify the optional stage-aligned debug ports with a clean transaction.
    await reset_pe(dut)
    transaction = dict(
        # Nontrivial sign extension and long carry propagation:
        # shifted = (-216, -156, +216, +156), partial = 0.
        input_fp8=(0x09, 0x0D, 0x09, 0x0D),
        rhs_q4=(0xD, 0xB, 0x5, 0x3),
        op_mode=OP_LINEAR,
        special_sel=0,
        acc_clear=True,
        acc_enable=True,
    )
    _, trace = pe_expected(transaction, 0)
    assert trace.shifted_products == (-216, -156, 216, 156)
    assert trace.partial_sum == 0

    await FallingEdge(dut.clk)
    drive_pe(dut, transaction)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.debug_lhs_mantissa_o.value) == pack_lanes(
        trace.lhs_mantissas, 6
    )
    assert int(dut.debug_rhs_value_o.value) == pack_lanes(trace.rhs_values, 6)
    assert int(dut.debug_shift_o.value) == pack_lanes(trace.shifts, 4)

    await FallingEdge(dut.clk)
    drive_pe(dut, None)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.debug_raw_product_o.value) == pack_lanes(
        trace.raw_products, 12
    )
    assert int(dut.debug_shifted_product_o.value) == pack_lanes(
        trace.shifted_products, 26
    )

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert signal_signed(dut.debug_partial_sum_o, 28) == trace.partial_sum
