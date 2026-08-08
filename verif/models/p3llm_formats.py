"""Integer-only decoders for the numerical formats used by the P3-LLM PCU."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class DecodedFP8:
    """Multiplier-facing FP8 representation.

    ``value = mantissa * 2 ** (shift - fraction_bits)``.
    """

    mantissa: int
    shift: int
    fraction_bits: int
    zero: bool
    invalid: bool = False


def _require_uint(value: int, width: int, name: str) -> int:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be int, got {type(value).__name__}")
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{name}={value} does not fit unsigned {width} bits")
    return value


def wrap_signed(value: int, width: int) -> int:
    """Return ``value`` wrapped to a signed two's-complement integer."""

    mask = (1 << width) - 1
    wrapped = value & mask
    sign = 1 << (width - 1)
    return wrapped - (1 << width) if wrapped & sign else wrapped


def decode_fp8_e4m3(code: int) -> DecodedFP8:
    """Decode OCP E4M3FN into the common signed six-bit mantissa."""

    code = _require_uint(code, 8, "code")
    sign = (code >> 7) & 0x1
    exponent = (code >> 3) & 0xF
    fraction = code & 0x7

    if exponent == 0xF and fraction == 0x7:
        return DecodedFP8(0, 0, 11, True, True)
    if exponent == 0 and fraction == 0:
        return DecodedFP8(0, 0, 11, True, False)

    if exponent == 0:
        magnitude = fraction << 1
        shift = 1
    else:
        magnitude = (8 + fraction) << 1
        shift = exponent

    mantissa = -magnitude if sign else magnitude
    assert -32 <= mantissa <= 31
    return DecodedFP8(mantissa, shift, 11, False, False)


def decode_fp8_s0e4m4(code: int) -> DecodedFP8:
    """Decode the unsigned P3-LLM S0E4M4 attention-score format."""

    code = _require_uint(code, 8, "code")
    exponent = (code >> 4) & 0xF
    fraction = code & 0xF

    if exponent == 0 and fraction == 0:
        return DecodedFP8(0, 0, 19, True, False)
    if exponent == 0:
        mantissa = fraction
        shift = 1
    else:
        mantissa = 16 + fraction
        shift = exponent

    assert 0 <= mantissa <= 31
    return DecodedFP8(mantissa, shift, 19, False, False)


_BITMOD_BASE_Q1 = (
    0,
    1,
    2,
    3,
    4,
    6,
    8,
    12,
    0,  # negative zero is replaced below
    -1,
    -2,
    -3,
    -4,
    -6,
    -8,
    -12,
)

_BITMOD_SPECIAL_Q1 = (10, -10, 16, -16)


def decode_bitmod4(code: int, special_sel: int) -> int:
    """Decode a raw BitMoD nibble to a signed six-bit Q*.1 integer."""

    code = _require_uint(code, 4, "code")
    special_sel = _require_uint(special_sel, 2, "special_sel")
    value = _BITMOD_SPECIAL_Q1[special_sel] if code == 0x8 else _BITMOD_BASE_Q1[code]
    assert -32 <= value <= 31
    return value


def decode_int4_asym(code: int, zero_point: int) -> int:
    """Decode unsigned INT4-Asymmetric as the exact integer ``q-zp``."""

    code = _require_uint(code, 4, "code")
    zero_point = _require_uint(zero_point, 4, "zero_point")
    value = code - zero_point
    assert -15 <= value <= 15
    return value
