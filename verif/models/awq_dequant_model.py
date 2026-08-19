"""Bit-exact model of the shared AWQ in-PCU dequantizer.

Like :mod:`p3llm_dequant_model`, this uses no host floating point anywhere:
every finite IEEE value is an integer coefficient times a power of two, and
every format conversion is an explicit round-to-nearest-even step.  The
unpack/pack primitives are imported from the P3-LLM model rather than
restated, because the two designs share the same rounding rules; what differs
is the arithmetic contract around them.

Contract implemented here, for PE ``p`` and weight group ``g``::

    prod32[p]   = RNE32(acc_int32[p] * scale16[p, g] * 2**(ref_exp - GUARD))
    fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])
    out16[p]    = RNE16(fp_acc32[p])

There is no second scale and no requantization step: AWQ activations are
already bfloat16/binary16, so the weight group scale is the only scale and the
output format is the input format of the next layer.
"""

from __future__ import annotations

from typing import Sequence

from p3llm_dequant_model import (
    BinaryValue,
    add_fp32_rne,
    pack_exact,
    pack_fp32_exact,
    unpack_fp32,
    unpack_ieee,
)


# (exponent_bits, fraction_bits) for the two activation formats AWQ uses.
BF16 = (8, 7)
FP16 = (5, 10)

GUARD_DEFAULT = 8


def _canonical_nan(exponent_bits: int, fraction_bits: int) -> int:
    return (((1 << exponent_bits) - 1) << fraction_bits) | (
        1 << (fraction_bits - 1)
    )


def _infinity(sign: int, exponent_bits: int, fraction_bits: int) -> int:
    return ((sign & 1) << (exponent_bits + fraction_bits)) | (
        ((1 << exponent_bits) - 1) << fraction_bits
    )


def unpack_float16(bits: int, fmt: tuple[int, int]) -> BinaryValue:
    """Decode a 16-bit bfloat16 or binary16 pattern exactly."""

    return unpack_ieee(bits, fmt[0], fmt[1])


def scale_is_legal(scale_bits: int, fmt: tuple[int, int]) -> bool:
    """The multiplier's scale contract: positive and finite (+0 allowed)."""

    decoded = unpack_float16(scale_bits, fmt)
    return not decoded.sign and decoded.kind not in ("nan", "inf")


def int32_scale_to_fp32(
    raw_int32: int,
    scale_bits: int,
    exp_offset: int,
    fmt: tuple[int, int] = BF16,
) -> int:
    """RNE32(raw_int32 * float16(scale) * 2**exp_offset).

    An out-of-contract scale (negative, infinite, or NaN) returns the canonical
    binary32 quiet NaN, which is what the RTL produces alongside ``invalid_o``.
    """

    if raw_int32 < -(1 << 31) or raw_int32 >= (1 << 31):
        raise ValueError(f"raw_int32={raw_int32} does not fit signed 32 bits")
    if not scale_is_legal(scale_bits, fmt):
        return 0x7FC00000
    scale = unpack_float16(scale_bits, fmt)
    if raw_int32 == 0 or scale.kind == "zero":
        # A +0 scale keeps the integer's sign, as an ordinary FP multiply does.
        return (1 << 31) if raw_int32 < 0 else 0
    return pack_fp32_exact(
        raw_int32 * scale.coefficient, scale.exponent + exp_offset
    )


def fp32_to_float16(fp32_bits: int, fmt: tuple[int, int] = BF16) -> int:
    """RNE to bfloat16/binary16 with gradual underflow, no scale applied."""

    exponent_bits, fraction_bits = fmt
    value = unpack_fp32(fp32_bits)
    if value.kind == "nan" or value.kind == "inf":
        # The pack stage reports any non-finite binary32 as invalid and emits
        # the canonical quiet NaN rather than propagating an infinity.
        return _canonical_nan(exponent_bits, fraction_bits)
    if value.kind == "zero":
        return value.sign << (exponent_bits + fraction_bits)
    return pack_exact(
        value.coefficient, value.exponent, exponent_bits, fraction_bits
    )


def exp_offset(ref_exp: int, guard: int = GUARD_DEFAULT) -> int:
    """The block-floating-point offset the PCU applies: ref_exp - GUARD."""

    return ref_exp - guard


def _fp32_class(bits: int) -> str:
    """'normal', 'zero', 'subnormal', 'inf' or 'nan' for a binary32 pattern."""

    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    if exponent == 0xFF:
        return "inf" if fraction == 0 else "nan"
    if exponent == 0:
        return "zero" if fraction == 0 else "subnormal"
    return "normal"


class AwqDequantGolden:
    """Stateful per-PE FP32 accumulation across weight groups.

    ``sticky_invalid`` and ``sticky_overflow`` mirror the RTL's sticky status
    bits so a test can require agreement instead of assuming the stimulus stays
    in range. They are not decoration: with activations spread over the whole
    bfloat16 exponent range, ``acc * scale * 2**(ref_exp - GUARD)`` genuinely
    reaches binary32 infinity, and the adder's input contract then reports the
    non-finite operand as invalid.
    """

    def __init__(self, num_pes: int, fmt: tuple[int, int] = BF16) -> None:
        self.num_pes = num_pes
        self.fmt = fmt
        self.accumulators32 = [0] * num_pes
        self.sticky_invalid = 0
        self.sticky_overflow = 0

    def reset(self) -> None:
        self.accumulators32[:] = [0] * self.num_pes

    def accept_group(
        self,
        raw_int32: Sequence[int],
        scale_bits: Sequence[int],
        ref_exp: int,
        *,
        fp_acc_clear: bool,
        dot_last: bool,
        guard: int = GUARD_DEFAULT,
    ) -> tuple[int, ...] | None:
        """Consume one weight group; return the output vector on ``dot_last``."""

        if len(raw_int32) != self.num_pes:
            raise ValueError(f"raw_int32 must have {self.num_pes} entries")
        if len(scale_bits) != self.num_pes:
            raise ValueError(f"scale_bits must have {self.num_pes} entries")

        if fp_acc_clear:
            self.reset()

        offset = exp_offset(ref_exp, guard)
        for pe in range(self.num_pes):
            product = int32_scale_to_fp32(
                raw_int32[pe], scale_bits[pe], offset, self.fmt
            )
            # The multiplier reports overflow when it packs an infinity.
            if _fp32_class(product) == "inf":
                self.sticky_overflow = 1

            # The adder's contract is finite normal binary32 or signed zero;
            # anything else asserts invalid and produces a quiet NaN.
            operands = (self.accumulators32[pe], product)
            if any(_fp32_class(v) in ("inf", "nan", "subnormal")
                   for v in operands):
                self.sticky_invalid = 1

            self.accumulators32[pe] = add_fp32_rne(
                self.accumulators32[pe], product
            )
            if _fp32_class(self.accumulators32[pe]) == "inf":
                self.sticky_overflow = 1

        if not dot_last:
            return None

        results = []
        for acc in self.accumulators32:
            if _fp32_class(acc) in ("inf", "nan"):
                self.sticky_invalid = 1
            packed = fp32_to_float16(acc, self.fmt)
            exponent_bits, fraction_bits = self.fmt
            infinity = ((1 << exponent_bits) - 1) << fraction_bits
            if (_fp32_class(acc) not in ("inf", "nan")
                    and (packed & ~(1 << (exponent_bits + fraction_bits)))
                    == infinity):
                self.sticky_overflow = 1
            results.append(packed)
        return tuple(results)
