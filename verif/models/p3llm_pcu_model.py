"""Bit-accurate, integer-only golden model for the P3-LLM arithmetic PCU."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from p3llm_formats import (
    DecodedFP8,
    decode_bitmod4,
    decode_fp8_e4m3,
    decode_fp8_s0e4m4,
    decode_int4_asym,
    narrow_rne,
    saturate_signed,
    wrap_signed,
)

OP_LINEAR = 0
OP_QK = 1
OP_PV = 2

NUM_PES = 16
LANES = 4
PIPELINE_EDGE_LATENCY = 3
PIPELINE_STAGES = 4


@dataclass(frozen=True)
class PeTrace:
    lhs_mantissas: tuple[int, ...]
    rhs_values: tuple[int, ...]
    shifts: tuple[int, ...]
    raw_products: tuple[int, ...]
    shifted_products: tuple[int, ...]
    partial_sum: int
    invalid_fp8: bool


def _check_len(values: Sequence[int], length: int, name: str) -> None:
    if len(values) != length:
        raise ValueError(f"{name} must contain {length} elements, got {len(values)}")


def pe_dot(
    input_fp8: Sequence[int],
    rhs_q4: Sequence[int],
    op_mode: int,
    *,
    bitmod_special_sel: int = 0,
    zp_by_pe: int = 0,
    zp_by_lane: Sequence[int] = (0, 0, 0, 0),
) -> PeTrace:
    """Compute one four-lane PE partial sum and all integer intermediates."""

    _check_len(input_fp8, LANES, "input_fp8")
    _check_len(rhs_q4, LANES, "rhs_q4")
    _check_len(zp_by_lane, LANES, "zp_by_lane")
    if op_mode not in (OP_LINEAR, OP_QK, OP_PV, 3):
        raise ValueError(f"op_mode must be a two-bit value, got {op_mode}")

    lhs_decoded: list[DecodedFP8] = []
    rhs_values: list[int] = []
    raw_products: list[int] = []
    shifted_products: list[int] = []

    for lane in range(LANES):
        if op_mode == 3:
            lhs_decoded.append(
                DecodedFP8(
                    mantissa=0,
                    shift=0,
                    fraction_bits=11,
                    zero=True,
                    invalid=True,
                )
            )
            rhs_values.append(0)
            raw_products.append(0)
            shifted_products.append(0)
            continue

        lhs = (
            decode_fp8_s0e4m4(input_fp8[lane])
            if op_mode == OP_PV
            else decode_fp8_e4m3(input_fp8[lane])
        )
        if op_mode == OP_LINEAR:
            rhs = decode_bitmod4(rhs_q4[lane], bitmod_special_sel)
        elif op_mode == OP_QK:
            rhs = decode_int4_asym(rhs_q4[lane], zp_by_pe)
        else:
            rhs = decode_int4_asym(rhs_q4[lane], zp_by_lane[lane])

        raw = lhs.mantissa * rhs
        if raw != wrap_signed(raw, 12):
            raise OverflowError(f"legal raw product {raw} does not fit 12 bits")
        # fixed_product_shift saturates at 26 bits instead of dropping the
        # overflowing bit, so the model clamps here rather than raising.
        shifted = saturate_signed(raw << lhs.shift, 26)

        lhs_decoded.append(lhs)
        rhs_values.append(rhs)
        raw_products.append(raw)
        shifted_products.append(shifted)

    partial_sum = sum(shifted_products)
    if partial_sum != wrap_signed(partial_sum, 28):
        raise OverflowError(f"legal PE partial {partial_sum} does not fit 28 bits")

    return PeTrace(
        lhs_mantissas=tuple(item.mantissa for item in lhs_decoded),
        rhs_values=tuple(rhs_values),
        shifts=tuple(item.shift for item in lhs_decoded),
        raw_products=tuple(raw_products),
        shifted_products=tuple(shifted_products),
        partial_sum=partial_sum,
        invalid_fp8=any(item.invalid for item in lhs_decoded),
    )


@dataclass
class PcuGolden:
    """Stateful model of the 16 architectural accumulators."""

    accumulators: list[int]

    def __init__(self, *, acc_bits: int = 32, acc_rsh: int = 0) -> None:
        # acc_bits/acc_rsh select the acc16 axis (rtl/3_p3llm_acc16): the
        # 28-bit partial sum is RNE-narrowed by acc_rsh before it reaches the
        # accumulator, which then holds acc_bits and saturates. The defaults
        # reproduce the 32-bit base build exactly.
        self.acc_bits = acc_bits
        self.acc_rsh = acc_rsh
        self.accumulators = [0] * NUM_PES

    def reset(self) -> None:
        self.accumulators[:] = [0] * NUM_PES

    def transaction(
        self,
        input_fp8: Sequence[int],
        rhs_q4: Sequence[Sequence[int]],
        op_mode: int,
        *,
        acc_clear: bool,
        acc_enable: bool,
        bitmod_special_sel: Sequence[int] = (0,) * NUM_PES,
        zp_by_pe: Sequence[int] = (0,) * NUM_PES,
        zp_by_lane: Sequence[int] = (0,) * LANES,
    ) -> tuple[tuple[int, ...], tuple[PeTrace, ...]]:
        """Accept one valid transaction and return post-update accumulators."""

        _check_len(input_fp8, LANES, "input_fp8")
        _check_len(rhs_q4, NUM_PES, "rhs_q4")
        _check_len(bitmod_special_sel, NUM_PES, "bitmod_special_sel")
        _check_len(zp_by_pe, NUM_PES, "zp_by_pe")
        _check_len(zp_by_lane, LANES, "zp_by_lane")

        traces: list[PeTrace] = []
        next_acc = list(self.accumulators)
        for pe in range(NUM_PES):
            _check_len(rhs_q4[pe], LANES, f"rhs_q4[{pe}]")
            trace = pe_dot(
                input_fp8,
                rhs_q4[pe],
                op_mode,
                bitmod_special_sel=bitmod_special_sel[pe],
                zp_by_pe=zp_by_pe[pe],
                zp_by_lane=zp_by_lane,
            )
            traces.append(trace)
            if self.acc_rsh:
                narrowed = narrow_rne(
                    trace.partial_sum, self.acc_rsh, self.acc_bits
                )
                if acc_clear:
                    next_acc[pe] = narrowed
                elif acc_enable:
                    next_acc[pe] = saturate_signed(
                        self.accumulators[pe] + narrowed, self.acc_bits)
            elif acc_clear:
                next_acc[pe] = wrap_signed(trace.partial_sum, 32)
            elif acc_enable:
                # p3llm_pe saturates rather than wrapping: an overflow used to
                # flip the sign with nothing in silicon able to report it.
                next_acc[pe] = saturate_signed(
                    self.accumulators[pe] + trace.partial_sum, 32)

        self.accumulators[:] = next_acc
        return tuple(self.accumulators), tuple(traces)


def pack_lanes(values: Sequence[int], width: int) -> int:
    """Pack little-indexed lanes using the RTL ``i*width +: width`` rule."""

    if width <= 0:
        raise ValueError(f"width must be positive, got {width}")
    result = 0
    mask = (1 << width) - 1
    for index, value in enumerate(values):
        if not (-(1 << (width - 1)) <= value <= mask):
            raise ValueError(f"lane {index} value {value} does not fit {width} bits")
        result |= (value & mask) << (index * width)
    return result


def pack_rhs(rhs_q4: Sequence[Sequence[int]]) -> int:
    _check_len(rhs_q4, NUM_PES, "rhs_q4")
    flat: list[int] = []
    for pe, lanes in enumerate(rhs_q4):
        _check_len(lanes, LANES, f"rhs_q4[{pe}]")
        flat.extend(lanes)
    return pack_lanes(flat, 4)
