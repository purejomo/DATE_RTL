"""Golden model for the SpinQuant PCU-local dequantizer and requantizer.

Two axes are covered:

    axis 3   rtl/5_spinquant_dequant_rne        -> binary16
    axis 4   rtl/5_spinquant_dequant_requant    -> unsigned INT4

The floating-point primitives are not re-derived here. Both directories
instantiate the same two pipes the AWQ dequantizer uses, renamed and otherwise
untouched, so this module imports their references from awq_dequant_model and
adds only what SpinQuant contributes: the integer bias fold, the INT4
requantization, and the local min/max reduction.

The arithmetic, from docs/spinquant_pcu_spec.md:

    A~ = s_a*A_q + beta        W = s_w*W_q        beta = -s_a*zp_a

    y[i] = s_w[i]*s_a*acc[i] + s_w[i]*beta*sum(W_q_row[i])
         = s[i] * ( acc[i] + bias_int[i] )

    s[i]        = s_w[i]*s_a                      16-bit float
    bias_int[i] = -zp_a*sum(W_q_row[i])           INTEGER

so the activation zero point never leaves the integer domain and the whole
dequantization is one integer add, one exact multiply-and-round, and one pack.
"""

from __future__ import annotations

import struct
from decimal import Decimal

from awq_dequant_model import (
    BF16,
    FP16,
    fp32_to_float16,
    int32_scale_to_fp32,
    scale_is_legal,
)

__all__ = [
    "BF16",
    "FP16",
    "bias_add",
    "dequant_lane",
    "fp32_bits_to_float",
    "minmax",
    "requant_lane",
    "requant_int4",
    "scale_is_legal",
    "total_order_key",
]

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


def bias_add(acc: int, bias_int: int) -> tuple[int, bool]:
    """``acc + bias_int`` at 32 bits, with the carry-out reported.

    The RTL reports rather than saturates, matching the raw PE. At K = 14336
    both terms reach 22 bits, so the sum needs 23 and the report is a guard on
    a violated assumption, not an expected event.
    """

    total = acc + bias_int
    overflow = total < INT32_MIN or total > INT32_MAX
    if overflow:
        total = ((total - INT32_MIN) & 0xFFFFFFFF) + INT32_MIN
    return total, overflow


def dequant_lane(acc: int, bias_int: int, scale_bits: int,
                 fmt: tuple[int, int] = FP16) -> tuple[int, bool]:
    """The binary32 the multiply pipe produces for one lane."""

    fixed, overflow = bias_add(acc, bias_int)
    # exp_offset is zero: the raw accumulator is a plain integer with no block
    # exponent, unlike the AWQ one.
    return int32_scale_to_fp32(fixed, scale_bits, 0, fmt), overflow


def fp32_bits_to_float(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def total_order_key(bits: int) -> int:
    """The unsigned key spinquant_rq_minmax compares on."""

    return (~bits) & 0xFFFFFFFF if bits >> 31 else bits | 0x80000000


def minmax(stream) -> tuple[int, int]:
    """(min, max) of a binary32 stream, as the RTL reduces it."""

    values = list(stream)
    if not values:
        return (0, 0)
    lo = hi = values[0]
    for bits in values[1:]:
        if total_order_key(bits) < total_order_key(lo):
            lo = bits
        if total_order_key(bits) > total_order_key(hi):
            hi = bits
    return (lo, hi)


def requant_int4(fp32_bits: int, zp: int) -> tuple[int, bool, bool]:
    """(q4, clamped, invalid) for spinquant_rq_fp32_to_int4.

    Decimal is exact on a binary32, so nothing here rounds twice.
    """

    exponent = (fp32_bits >> 23) & 0xFF
    sign = fp32_bits >> 31
    if exponent == 0xFF:
        invalid = True
        magnitude = -32 if sign else 32
    else:
        invalid = False
        magnitude = int(
            Decimal(fp32_bits_to_float(fp32_bits)).to_integral_value(
                rounding="ROUND_HALF_EVEN"
            )
        )
        magnitude = max(-32, min(32, magnitude))
    shifted = magnitude + zp
    clamped = shifted < 0 or shifted > 15
    return max(0, min(15, shifted)), clamped, invalid


def requant_lane(acc: int, bias_int: int, scale_bits: int, zp: int,
                 fmt: tuple[int, int] = FP16):
    """One lane of pass 2: dequantize with t[i], then requantize to INT4.

    ``scale_bits`` is t[i] = s[i]/s_a', not s[i]: the division by the new
    activation scale is folded into the scale the driver supplies, which is why
    there is no second multiplier in the hardware.
    """

    fp32_bits, bias_ovf = dequant_lane(acc, bias_int, scale_bits, fmt)
    q4, clamped, invalid = requant_int4(fp32_bits, zp)
    return q4, fp32_bits, bias_ovf, clamped, invalid
