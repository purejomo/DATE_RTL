"""Bit-exact model of the shared P3-LLM in-PCU dequantizer.

The model deliberately does not use Python or NumPy floating point.  Every
finite IEEE value is represented as an integer coefficient times a power of
two, and every format conversion uses an explicit round-to-nearest-even step.
That makes binary16 subnormals and halfway cases deterministic on every host.

Arithmetic contract implemented here::

    product32[p] = RNE32(raw_int32[p] * vector_scale16[p] * 2**mode_offset)
    fp_acc32[p]  = RNE32(fp_acc32[p] + product32[p])
    result16[p]  = RNE16(fp_acc32[p] * final_scale16)

where the mode offsets are LINEAR=-12, QK=-11, and PV=-19.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from p3llm_pcu_model import NUM_PES, OP_LINEAR, OP_PV, OP_QK


MODE_BINARY_OFFSETS = {
    OP_LINEAR: -12,
    OP_QK: -11,
    OP_PV: -19,
}

FP16_EXP_BITS = 5
FP16_FRAC_BITS = 10
FP32_EXP_BITS = 8
FP32_FRAC_BITS = 23


@dataclass(frozen=True)
class BinaryValue:
    """An unpacked IEEE value.

    For ``kind == "finite"``, the exact value is
    ``coefficient * 2**exponent``.  Zero has a separate kind so its sign can
    be retained when needed by a boundary test.
    """

    kind: str
    sign: int
    coefficient: int = 0
    exponent: int = 0


@dataclass(frozen=True)
class DequantGroupTrace:
    raw_int32: tuple[int, ...]
    vector_scale16: tuple[int, ...]
    products32: tuple[int, ...]
    accumulators32: tuple[int, ...]
    result16: tuple[int, ...] | None


def _check_unsigned(value: int, width: int, name: str) -> int:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be int, got {type(value).__name__}")
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{name}=0x{value:x} does not fit {width} bits")
    return value


def _check_length(values: Sequence[int], expected: int, name: str) -> None:
    if len(values) != expected:
        raise ValueError(f"{name} must contain {expected} values, got {len(values)}")


def unpack_ieee(bits: int, exponent_bits: int, fraction_bits: int) -> BinaryValue:
    """Decode an IEEE interchange-format bit pattern exactly."""

    width = 1 + exponent_bits + fraction_bits
    bits = _check_unsigned(bits, width, "bits")
    sign = bits >> (exponent_bits + fraction_bits)
    exponent_mask = (1 << exponent_bits) - 1
    exponent_field = (bits >> fraction_bits) & exponent_mask
    fraction = bits & ((1 << fraction_bits) - 1)
    bias = (1 << (exponent_bits - 1)) - 1

    if exponent_field == exponent_mask:
        return BinaryValue("inf" if fraction == 0 else "nan", sign)
    if exponent_field == 0:
        if fraction == 0:
            return BinaryValue("zero", sign)
        # subnormal = fraction * 2**(1-bias-fraction_bits)
        coefficient = -fraction if sign else fraction
        return BinaryValue(
            "finite", sign, coefficient, 1 - bias - fraction_bits
        )

    significand = (1 << fraction_bits) | fraction
    coefficient = -significand if sign else significand
    return BinaryValue(
        "finite", sign, coefficient, exponent_field - bias - fraction_bits
    )


def unpack_fp16(bits: int) -> BinaryValue:
    return unpack_ieee(bits, FP16_EXP_BITS, FP16_FRAC_BITS)


def unpack_fp32(bits: int) -> BinaryValue:
    return unpack_ieee(bits, FP32_EXP_BITS, FP32_FRAC_BITS)


def _round_right_even(magnitude: int, shift: int) -> int:
    """Return RNE(magnitude / 2**shift) for a non-negative integer."""

    if magnitude < 0:
        raise ValueError("magnitude must be non-negative")
    if shift <= 0:
        return magnitude << -shift
    quotient = magnitude >> shift
    remainder = magnitude & ((1 << shift) - 1)
    halfway = 1 << (shift - 1)
    if remainder > halfway or (remainder == halfway and (quotient & 1)):
        quotient += 1
    return quotient


def pack_exact(
    coefficient: int,
    exponent: int,
    exponent_bits: int,
    fraction_bits: int,
    *,
    zero_sign: int = 0,
) -> int:
    """Round ``coefficient * 2**exponent`` to an IEEE format using RNE."""

    if not isinstance(coefficient, int) or not isinstance(exponent, int):
        raise TypeError("coefficient and exponent must be integers")
    sign = 1 if coefficient < 0 else 0
    sign_field = sign << (exponent_bits + fraction_bits)
    if coefficient == 0:
        return (zero_sign & 1) << (exponent_bits + fraction_bits)

    magnitude = abs(coefficient)
    precision = fraction_bits + 1
    bias = (1 << (exponent_bits - 1)) - 1
    minimum_normal_exponent = 1 - bias
    maximum_normal_exponent = ((1 << exponent_bits) - 2) - bias
    leading_exponent = magnitude.bit_length() - 1 + exponent

    if leading_exponent >= minimum_normal_exponent:
        shift = magnitude.bit_length() - precision
        significand = _round_right_even(magnitude, shift)
        rounded_exponent = leading_exponent
        if significand == (1 << precision):
            significand >>= 1
            rounded_exponent += 1
        if rounded_exponent > maximum_normal_exponent:
            return sign_field | (((1 << exponent_bits) - 1) << fraction_bits)
        exponent_field = rounded_exponent + bias
        fraction_field = significand - (1 << fraction_bits)
        return sign_field | (exponent_field << fraction_bits) | fraction_field

    # Subnormals are integer multiples of this fixed quantum.  Performing one
    # direct rounding here also handles a value that rounds up to min-normal.
    quantum_exponent = minimum_normal_exponent - fraction_bits
    units = _round_right_even(magnitude, quantum_exponent - exponent)
    if units == 0:
        return sign_field
    if units >= (1 << fraction_bits):
        return sign_field | (1 << fraction_bits)  # minimum normal
    return sign_field | units


def pack_fp16_exact(coefficient: int, exponent: int) -> int:
    return pack_exact(
        coefficient, exponent, FP16_EXP_BITS, FP16_FRAC_BITS
    )


def pack_fp32_exact(coefficient: int, exponent: int) -> int:
    return pack_exact(
        coefficient, exponent, FP32_EXP_BITS, FP32_FRAC_BITS
    )


def _canonical_nan(exponent_bits: int, fraction_bits: int) -> int:
    return (((1 << exponent_bits) - 1) << fraction_bits) | (1 << (fraction_bits - 1))


def _infinity(sign: int, exponent_bits: int, fraction_bits: int) -> int:
    return (
        ((sign & 1) << (exponent_bits + fraction_bits))
        | (((1 << exponent_bits) - 1) << fraction_bits)
    )


def _require_finite_scale(scale16: int, name: str) -> BinaryValue:
    decoded = unpack_fp16(scale16)
    if decoded.sign or decoded.kind in ("nan", "inf"):
        raise ValueError(
            f"{name}=0x{scale16:04x} must be non-negative finite binary16"
        )
    return decoded


def int32_scale_to_fp32(raw_int32: int, scale16: int, binary_offset: int) -> int:
    """Compute RNE32(raw_int32 * binary16(scale) * 2**offset)."""

    if raw_int32 < -(1 << 31) or raw_int32 >= (1 << 31):
        raise ValueError(f"raw_int32={raw_int32} does not fit signed 32 bits")
    scale = _require_finite_scale(scale16, "scale16")
    if raw_int32 == 0 or scale.kind == "zero":
        zero_sign = raw_int32 < 0
        return zero_sign << 31
    return pack_fp32_exact(
        raw_int32 * scale.coefficient, scale.exponent + binary_offset
    )


def add_fp32_rne(lhs_bits: int, rhs_bits: int) -> int:
    """IEEE binary32 addition for finite values, rounded once with RNE."""

    lhs = unpack_fp32(lhs_bits)
    rhs = unpack_fp32(rhs_bits)
    if lhs.kind == "nan" or rhs.kind == "nan":
        return _canonical_nan(FP32_EXP_BITS, FP32_FRAC_BITS)
    if lhs.kind == "inf" or rhs.kind == "inf":
        if lhs.kind == rhs.kind == "inf" and lhs.sign != rhs.sign:
            return _canonical_nan(FP32_EXP_BITS, FP32_FRAC_BITS)
        selected = lhs if lhs.kind == "inf" else rhs
        return _infinity(selected.sign, FP32_EXP_BITS, FP32_FRAC_BITS)
    if lhs.kind == "zero" and rhs.kind == "zero":
        # Under round-to-nearest, opposite signed zeros add to +0.
        return (lhs.sign & rhs.sign) << 31
    if lhs.kind == "zero":
        return rhs_bits
    if rhs.kind == "zero":
        return lhs_bits

    common_exponent = min(lhs.exponent, rhs.exponent)
    exact_sum = (
        (lhs.coefficient << (lhs.exponent - common_exponent))
        + (rhs.coefficient << (rhs.exponent - common_exponent))
    )
    return pack_fp32_exact(exact_sum, common_exponent)


def fp32_scale_to_fp16(accumulator32: int, scale16: int) -> int:
    """Compute RNE16(binary32(accumulator) * binary16(scale))."""

    accumulator = unpack_fp32(accumulator32)
    scale = _require_finite_scale(scale16, "scale16")
    result_sign = accumulator.sign ^ scale.sign

    if accumulator.kind == "nan":
        return _canonical_nan(FP16_EXP_BITS, FP16_FRAC_BITS)
    if accumulator.kind == "inf":
        if scale.kind == "zero":
            return _canonical_nan(FP16_EXP_BITS, FP16_FRAC_BITS)
        return _infinity(result_sign, FP16_EXP_BITS, FP16_FRAC_BITS)
    if accumulator.kind == "zero" or scale.kind == "zero":
        return result_sign << 15
    return pack_fp16_exact(
        accumulator.coefficient * scale.coefficient,
        accumulator.exponent + scale.exponent,
    )


class DequantGolden:
    """Stateful, sixteen-lane group dequantization model."""

    def __init__(self) -> None:
        self.accumulators32 = [0] * NUM_PES

    def reset(self) -> None:
        self.accumulators32[:] = [0] * NUM_PES

    def accept_group(
        self,
        raw_int32: Sequence[int],
        vector_scale16: Sequence[int],
        op_mode: int,
        *,
        fp_acc_clear: bool,
        dot_last: bool,
        final_scale16: int,
    ) -> DequantGroupTrace:
        """Consume a complete raw group and optionally produce a FP16 vector."""

        _check_length(raw_int32, NUM_PES, "raw_int32")
        _check_length(vector_scale16, NUM_PES, "vector_scale16")
        if op_mode not in MODE_BINARY_OFFSETS:
            raise ValueError(f"unsupported op_mode {op_mode}")
        _require_finite_scale(final_scale16, "final_scale16")

        if fp_acc_clear:
            self.reset()

        products: list[int] = []
        for pe in range(NUM_PES):
            product = int32_scale_to_fp32(
                raw_int32[pe], vector_scale16[pe], MODE_BINARY_OFFSETS[op_mode]
            )
            products.append(product)
            self.accumulators32[pe] = add_fp32_rne(
                self.accumulators32[pe], product
            )

        result = None
        if dot_last:
            result = tuple(
                fp32_scale_to_fp16(acc, final_scale16)
                for acc in self.accumulators32
            )
        return DequantGroupTrace(
            raw_int32=tuple(raw_int32),
            vector_scale16=tuple(vector_scale16),
            products32=tuple(products),
            accumulators32=tuple(self.accumulators32),
            result16=result,
        )


def pack_u16_lanes(values: Sequence[int]) -> int:
    """Pack lane zero in bits [15:0], matching SystemVerilog ``+:`` buses."""

    result = 0
    for index, value in enumerate(values):
        result |= _check_unsigned(value, 16, f"values[{index}]") << (16 * index)
    return result


def unpack_u16_lanes(bus: int, count: int = NUM_PES) -> tuple[int, ...]:
    return tuple((bus >> (16 * index)) & 0xFFFF for index in range(count))
