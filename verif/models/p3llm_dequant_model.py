"""Bit-exact model of the shared P3-LLM in-PCU dequantizer.

The model deliberately does not use Python or NumPy floating point.  Every
finite IEEE value is represented as an integer coefficient times a power of
two, and every format conversion uses an explicit round-to-nearest-even step.
That makes binary16 subnormals and halfway cases deterministic on every host.

Arithmetic contract implemented here::

    product32[p] = RNE32(raw_int32[p] * vector_scale16[p] * 2**mode_offset)
    fp_acc32[p]  = RNE32(fp_acc32[p] + product32[p])
    result8[p]   = RNE_E4M3(fp_acc32[p] * final_scale16)

where the mode offsets are LINEAR=-12, QK=-11, and PV=-19.

The final output is OCP FP8-E4M3FN, not binary16: P3-LLM's activations are
FP8, so the PCU ends the dequantization in the format the next layer reads.
E4M3FN has no infinity, so an overflow saturates to the largest finite code
rather than producing one -- 0x7f/0xff are the NaN encodings and emitting one
would make fp8_e4m3_decoder read a NaN where the arithmetic produced a large
finite number.
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

# OCP FP8-E4M3FN, as fp8_e4m3_decoder.sv defines it.
FP8_EXP_BITS = 4
FP8_FRAC_BITS = 3
FP8_BIAS = 7
FP8_MAX_EXPONENT = 8            # 0xf - bias; 0xf/0x7 is NaN, not infinity
FP8_MAX_FINITE = 0x7E           # magnitude 448 = 14 * 2**5
FP8_NAN = 0x7F


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
    result8: tuple[int, ...] | None
    # Per-lane pack exception flags, populated alongside result8.  E4M3's
    # range is much narrower than binary16's, so whether a given stimulus
    # saturates is a property of the data rather than something a test can
    # assume away.
    result_overflow: tuple[int, ...] | None = None
    result_underflow: tuple[int, ...] | None = None


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
    """Compute RNE16(binary32(accumulator) * binary16(scale)).

    Retained because the AWQ regression and the arithmetic boundary tests still
    reason in binary16; the P3-LLM PCU itself now ends in E4M3.
    """

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


def unpack_fp8_e4m3(bits: int) -> BinaryValue:
    """Decode one E4M3FN code exactly, matching fp8_e4m3_decoder.sv.

    ``0x7f``/``0xff`` are NaN.  Every other code is finite, including the
    all-ones exponent, which is why this cannot reuse :func:`unpack_ieee`.
    """

    bits = _check_unsigned(bits, 8, "bits")
    sign = bits >> 7
    exponent_field = (bits >> FP8_FRAC_BITS) & 0xF
    fraction = bits & 0x7

    if exponent_field == 0xF and fraction == 0x7:
        return BinaryValue("nan", sign)
    if exponent_field == 0 and fraction == 0:
        return BinaryValue("zero", sign)
    if exponent_field == 0:
        # subnormal = fraction * 2**(1 - bias - frac_bits)
        coefficient = -fraction if sign else fraction
        return BinaryValue(
            "finite", sign, coefficient, 1 - FP8_BIAS - FP8_FRAC_BITS
        )
    significand = (1 << FP8_FRAC_BITS) | fraction
    coefficient = -significand if sign else significand
    return BinaryValue(
        "finite", sign, coefficient, exponent_field - FP8_BIAS - FP8_FRAC_BITS
    )


def pack_fp8_e4m3_exact(coefficient: int, exponent: int, *, zero_sign: int = 0) -> int:
    """Round ``coefficient * 2**exponent`` to E4M3FN with RNE and saturation.

    This is the exact inverse of :func:`unpack_fp8_e4m3` on every finite code.
    It cannot reuse :func:`pack_exact`, which reserves the all-ones exponent
    for infinity: E4M3FN keeps that binade finite except for the single NaN
    encoding, and overflow saturates to 448 instead of producing an infinity.
    """

    sign = 1 if coefficient < 0 else 0
    if coefficient == 0:
        return (zero_sign & 1) << 7
    sign_field = sign << 7

    magnitude = abs(coefficient)
    precision = FP8_FRAC_BITS + 1
    minimum_normal_exponent = 1 - FP8_BIAS
    leading_exponent = magnitude.bit_length() - 1 + exponent

    if leading_exponent >= minimum_normal_exponent:
        shift = magnitude.bit_length() - precision
        significand = _round_right_even(magnitude, shift)
        rounded_exponent = leading_exponent
        if significand == (1 << precision):
            significand >>= 1
            rounded_exponent += 1
        # {0xf, 0x7} is NaN, so it is not a legal rounding destination.
        if rounded_exponent > FP8_MAX_EXPONENT or (
            rounded_exponent == FP8_MAX_EXPONENT
            and significand == (1 << precision) - 1
        ):
            return sign_field | FP8_MAX_FINITE
        exponent_field = rounded_exponent + FP8_BIAS
        fraction_field = significand - (1 << FP8_FRAC_BITS)
        return sign_field | (exponent_field << FP8_FRAC_BITS) | fraction_field

    quantum_exponent = minimum_normal_exponent - FP8_FRAC_BITS
    units = _round_right_even(magnitude, quantum_exponent - exponent)
    if units == 0:
        return sign_field
    if units >= (1 << FP8_FRAC_BITS):
        return sign_field | (1 << FP8_FRAC_BITS)  # minimum normal
    return sign_field | units


def fp32_scale_to_fp8(accumulator32: int, scale16: int) -> int:
    """Compute RNE_E4M3(binary32(accumulator) * binary16(scale))."""

    return fp32_scale_to_fp8_flags(accumulator32, scale16)[0]


def fp32_scale_to_fp8_flags(
    accumulator32: int, scale16: int
) -> tuple[int, int, int, int]:
    """Return ``(code, invalid, overflow, underflow)`` for the final pack.

    The flags follow the RTL's contract rather than IEEE's, because E4M3FN
    differs from an IEEE interchange format in the two places that matter:

    * ``overflow`` means the exact product was at or past the rounding boundary
      of the largest finite code, so the result saturated to 448.  E4M3FN has
      no infinity to signal it with.
    * ``underflow`` is tininess after rounding: it is asserted whenever a
      nonzero product lands below the smallest normal and does not round back
      up to it -- including a product that rounds all the way to zero.
    """

    accumulator = unpack_fp32(accumulator32)
    scale = _require_finite_scale(scale16, "scale16")
    result_sign = accumulator.sign ^ scale.sign

    if accumulator.kind in ("nan", "inf"):
        # E4M3FN has no infinity: a non-finite binary32 is reported invalid and
        # emitted as the canonical NaN.
        return FP8_NAN, 1, 0, 0
    if accumulator.kind == "zero" or scale.kind == "zero":
        return result_sign << 7, 0, 0, 0

    coefficient = accumulator.coefficient * scale.coefficient
    exponent = accumulator.exponent + scale.exponent
    code = pack_fp8_e4m3_exact(coefficient, exponent)

    magnitude = abs(coefficient)
    leading_exponent = magnitude.bit_length() - 1 + exponent
    minimum_normal_exponent = 1 - FP8_BIAS

    if leading_exponent >= minimum_normal_exponent:
        # Normal branch: overflow iff saturation actually replaced the rounded
        # value, i.e. the code came back as the largest finite one while the
        # unsaturated rounding would have gone past it.
        precision = FP8_FRAC_BITS + 1
        shift = magnitude.bit_length() - precision
        significand = _round_right_even(magnitude, shift)
        rounded_exponent = leading_exponent
        if significand == (1 << precision):
            significand >>= 1
            rounded_exponent += 1
        overflow = int(
            rounded_exponent > FP8_MAX_EXPONENT
            or (
                rounded_exponent == FP8_MAX_EXPONENT
                and significand == (1 << precision) - 1
            )
        )
        return code, 0, overflow, 0

    # Subnormal branch: underflow unless rounding promoted to the min normal.
    underflow = int((code & 0x78) == 0)
    return code, 0, 0, underflow


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
        """Consume a complete raw group and optionally produce an FP8 vector."""

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
        overflow = None
        underflow = None
        if dot_last:
            packed = tuple(
                fp32_scale_to_fp8_flags(acc, final_scale16)
                for acc in self.accumulators32
            )
            result = tuple(entry[0] for entry in packed)
            overflow = tuple(entry[2] for entry in packed)
            underflow = tuple(entry[3] for entry in packed)
        return DequantGroupTrace(
            raw_int32=tuple(raw_int32),
            vector_scale16=tuple(vector_scale16),
            products32=tuple(products),
            accumulators32=tuple(self.accumulators32),
            result8=result,
            result_overflow=overflow,
            result_underflow=underflow,
        )


def pack_u16_lanes(values: Sequence[int]) -> int:
    """Pack lane zero in bits [15:0], matching SystemVerilog ``+:`` buses."""

    result = 0
    for index, value in enumerate(values):
        result |= _check_unsigned(value, 16, f"values[{index}]") << (16 * index)
    return result


def unpack_u16_lanes(bus: int, count: int = NUM_PES) -> tuple[int, ...]:
    return tuple((bus >> (16 * index)) & 0xFFFF for index in range(count))


def pack_u8_lanes(values: Sequence[int]) -> int:
    """Pack lane zero in bits [7:0], matching the FP8 result bus."""

    result = 0
    for index, value in enumerate(values):
        result |= _check_unsigned(value, 8, f"values[{index}]") << (8 * index)
    return result


def unpack_u8_lanes(bus: int, count: int = NUM_PES) -> tuple[int, ...]:
    return tuple((bus >> (8 * index)) & 0xFF for index in range(count))
