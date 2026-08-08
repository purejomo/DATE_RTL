"""Exact binary floating-point reference parameterized by field widths.

The HBM-PIM baseline ships an binary16-specific oracle
(`fp16_reference.py`). This project also needs bfloat16, and later FP8, so the
same arithmetic is expressed once with the exponent and mantissa widths as
parameters.

Only Python integers are used: a finite value is decoded as an integer
magnitude times an integral power of two, the product is formed exactly, and
the result is rounded once with round-to-nearest, ties-to-even. There is no
host floating-point arithmetic anywhere in the path.

`self_check_against_fp16` validates the generic implementation against the
baseline's independent binary16 oracle, so bfloat16 results rest on code that
has been shown to reproduce a separately written model bit for bit.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FloatFormat:
    """An IEEE-754-style binary interchange format."""

    exponent_bits: int
    mantissa_bits: int

    @property
    def width(self) -> int:
        return 1 + self.exponent_bits + self.mantissa_bits

    @property
    def bias(self) -> int:
        return (1 << (self.exponent_bits - 1)) - 1

    @property
    def exponent_max(self) -> int:
        return (1 << self.exponent_bits) - 1

    @property
    def mantissa_mask(self) -> int:
        return (1 << self.mantissa_bits) - 1

    @property
    def word_mask(self) -> int:
        return (1 << self.width) - 1

    @property
    def canonical_nan(self) -> int:
        """Quiet NaN with the sign clear and only the top payload bit set."""
        return (self.exponent_max << self.mantissa_bits) | (
            1 << (self.mantissa_bits - 1)
        )

    def encode(self, sign: int, biased_exponent: int, mantissa: int) -> int:
        return (
            (sign << (self.width - 1))
            | (biased_exponent << self.mantissa_bits)
            | mantissa
        )

    def infinity(self, sign: int) -> int:
        return self.encode(sign, self.exponent_max, 0)

    def zero(self, sign: int) -> int:
        return self.encode(sign, 0, 0)


FP16 = FloatFormat(exponent_bits=5, mantissa_bits=10)
BF16 = FloatFormat(exponent_bits=8, mantissa_bits=7)


def _fields(fmt: FloatFormat, value: int) -> tuple[int, int, int]:
    if not 0 <= value <= fmt.word_mask:
        raise ValueError(f"word outside the {fmt.width}-bit range: {value!r}")
    sign = value >> (fmt.width - 1)
    exponent = (value >> fmt.mantissa_bits) & fmt.exponent_max
    mantissa = value & fmt.mantissa_mask
    return sign, exponent, mantissa


def classify(fmt: FloatFormat, value: int) -> str:
    _, exponent, mantissa = _fields(fmt, value)
    if exponent == fmt.exponent_max:
        return "nan" if mantissa else "inf"
    if exponent == 0 and mantissa == 0:
        return "zero"
    return "finite"


def _decode_finite(fmt: FloatFormat, value: int) -> tuple[int, int, int]:
    """Return ``(sign, significand, exponent)`` with the hidden bit applied.

    The exact value is ``(-1)**sign * significand * 2**exponent``. Subnormals
    share the minimum normal exponent and simply lack the hidden bit.
    """
    sign, exponent, mantissa = _fields(fmt, value)
    if exponent == 0:
        significand = mantissa
        binary_exponent = 1 - fmt.bias - fmt.mantissa_bits
    else:
        significand = (1 << fmt.mantissa_bits) | mantissa
        binary_exponent = exponent - fmt.bias - fmt.mantissa_bits
    return sign, significand, binary_exponent


def _round_to_format(
    fmt: FloatFormat, sign: int, significand: int, exponent: int
) -> int:
    """Round an exact ``significand * 2**exponent`` once, ties to even."""
    if significand == 0:
        return fmt.zero(sign)

    # Normalize so the leading one sits at bit position `mantissa_bits`.
    leading = significand.bit_length() - 1
    shift = leading - fmt.mantissa_bits
    result_exponent = exponent + shift

    min_exponent = 1 - fmt.bias - fmt.mantissa_bits
    if result_exponent < min_exponent:
        # Subnormal: round at the fixed minimum exponent instead.
        shift += min_exponent - result_exponent
        result_exponent = min_exponent

    if shift > 0:
        retained = significand >> shift
        guard = (significand >> (shift - 1)) & 1
        sticky = 1 if (significand & ((1 << (shift - 1)) - 1)) else 0
    else:
        retained = significand << -shift
        guard = 0
        sticky = 0

    if guard and (sticky or (retained & 1)):
        retained += 1
        if retained.bit_length() - 1 > fmt.mantissa_bits:
            retained >>= 1
            result_exponent += 1

    biased = result_exponent + fmt.bias + fmt.mantissa_bits
    if retained >> fmt.mantissa_bits:
        # Normal result: the hidden bit is implicit in the encoding.
        if biased >= fmt.exponent_max:
            return fmt.infinity(sign)
        return fmt.encode(sign, biased, retained & fmt.mantissa_mask)

    # Subnormal or zero result.
    if retained == 0:
        return fmt.zero(sign)
    return fmt.encode(sign, 0, retained)


def multiply(fmt: FloatFormat, a: int, b: int) -> int:
    """Correctly rounded product of two ``fmt`` words."""
    a_class = classify(fmt, a)
    b_class = classify(fmt, b)
    sign = (a >> (fmt.width - 1)) ^ (b >> (fmt.width - 1))

    if a_class == "nan" or b_class == "nan":
        return fmt.canonical_nan
    if a_class == "inf" or b_class == "inf":
        if a_class == "zero" or b_class == "zero":
            return fmt.canonical_nan
        return fmt.infinity(sign)
    if a_class == "zero" or b_class == "zero":
        return fmt.zero(sign)

    _, sig_a, exp_a = _decode_finite(fmt, a)
    _, sig_b, exp_b = _decode_finite(fmt, b)
    return _round_to_format(fmt, sign, sig_a * sig_b, exp_a + exp_b)


def add(fmt: FloatFormat, a: int, b: int) -> int:
    """Correctly rounded sum of two ``fmt`` words.

    Both operands are decoded to exact integer significands at a common
    exponent, added as signed integers, and rounded once. Working at the lower
    of the two exponents makes the intermediate sum exact, so there is no
    double rounding.
    """
    a_class = classify(fmt, a)
    b_class = classify(fmt, b)
    a_sign = a >> (fmt.width - 1)
    b_sign = b >> (fmt.width - 1)

    if a_class == "nan" or b_class == "nan":
        return fmt.canonical_nan
    if a_class == "inf" and b_class == "inf":
        return fmt.canonical_nan if a_sign != b_sign else fmt.infinity(a_sign)
    if a_class == "inf":
        return fmt.infinity(a_sign)
    if b_class == "inf":
        return fmt.infinity(b_sign)
    if a_class == "zero" and b_class == "zero":
        # Exact zero sums keep the sign only when both addends are negative.
        return fmt.zero(a_sign & b_sign)

    _, sig_a, exp_a = _decode_finite(fmt, a)
    _, sig_b, exp_b = _decode_finite(fmt, b)
    common = min(exp_a, exp_b)
    total = ((sig_a << (exp_a - common)) * (-1 if a_sign else 1)) + (
        (sig_b << (exp_b - common)) * (-1 if b_sign else 1)
    )

    if total == 0:
        return fmt.zero(a_sign & b_sign)
    sign = 1 if total < 0 else 0
    return _round_to_format(fmt, sign, abs(total), common)


def encode_small_integer(fmt: FloatFormat, value: int) -> int:
    """Encode an integer that the format represents exactly.

    Used for INT4 weights, whose range is [-15, 15] and therefore needs at
    most four significand bits.
    """
    if value == 0:
        return fmt.zero(0)
    sign = 1 if value < 0 else 0
    magnitude = abs(value)
    if magnitude.bit_length() - 1 > fmt.mantissa_bits:
        raise ValueError(f"{value} is not exactly representable in {fmt}")
    exponent = magnitude.bit_length() - 1
    mantissa = (magnitude << (fmt.mantissa_bits - exponent)) & fmt.mantissa_mask
    return fmt.encode(sign, exponent + fmt.bias, mantissa)


def self_check_against_fp16() -> int:
    """Reproduce the baseline binary16 oracle exhaustively over one operand.

    The generic model is only trustworthy for bfloat16 if it reproduces an
    independently written binary16 model. Every binary16 word is checked
    against every INT4 weight, which is exactly the workload this project runs
    through the FP16 lane.
    """
    from fp16_reference import fp16_mul  # noqa: PLC0415 - test-time import

    checked = 0
    for weight in range(-15, 16):
        encoded = encode_small_integer(FP16, weight)
        for word in range(1 << 16):
            mine = multiply(FP16, word, encoded)
            theirs = fp16_mul(word, encoded)
            if mine != theirs:
                raise AssertionError(
                    f"generic model disagrees with fp16_reference: "
                    f"word=0x{word:04x} weight={weight} "
                    f"got 0x{mine:04x}, expected 0x{theirs:04x}"
                )
            checked += 1
    return checked


if __name__ == "__main__":
    print(f"{self_check_against_fp16()} binary16 cases matched fp16_reference")
