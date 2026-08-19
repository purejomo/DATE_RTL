"""Exact integer model of the INT4 x float PCU.

The datapath is fixed point end to end, so the model uses Python integers only:
activations are decoded to an integer significand and a binary exponent,
aligned to the block exponent by a right shift, multiplied by the decoded INT4
weight, summed, and accumulated with 32-bit two's-complement wrap. No host
floating point is involved anywhere.

Alignment is lossy by construction -- that is what block floating point is --
so this model defines the architecture's numerics rather than approximating an
IEEE result. It mirrors `int4float_align.v` and `int4float_pe.v`
statement for statement.

The zero point is per output PE: AutoAWQ stores one zero point per output
channel and group, so `transaction` takes either one nibble (the v1 broadcast
contract, which no RTL in the tree implements any more) or one nibble per PE
(the v2 contract both AWQ builds now use).

`PcuModel` also covers the acc16 axis. With `acc_bits=16` the 4-lane partial
sum is rounded to nearest, ties to even, by `acc_rsh` bits before it is
accumulated, and the accumulator saturates at 16 bits -- mirroring
rtl/2_awq_p3llm_*_acc16/int4float_pe.v statement for statement. The default
`acc_bits=32, acc_rsh=0` reproduces the base build exactly.
"""

from __future__ import annotations

from dataclasses import dataclass

LANES = 4
NUM_PES = 16
ACC_BITS = 32
ACC_MASK = (1 << ACC_BITS) - 1


@dataclass(frozen=True)
class ActFormat:
    """A 16-bit floating-point activation format."""

    exp_bits: int
    mant_bits: int
    guard: int = 8

    @property
    def bias(self) -> int:
        return (1 << (self.exp_bits - 1)) - 1

    @property
    def exp_max(self) -> int:
        return (1 << self.exp_bits) - 1

    @property
    def align_width(self) -> int:
        """Width of the aligned magnitude, before the sign."""
        return self.mant_bits + 1 + self.guard

    @property
    def aligned_width(self) -> int:
        """Signed width the RTL carries between align and multiply."""
        return self.mant_bits + self.guard + 2


FP16 = ActFormat(exp_bits=5, mant_bits=10)
BF16 = ActFormat(exp_bits=8, mant_bits=7)


def align_activation(fmt: ActFormat, word: int, ref_exp: int) -> tuple[int, bool, bool]:
    """Return ``(aligned, saturated, invalid)`` for one activation word."""
    if not 0 <= word <= 0xFFFF:
        raise ValueError(f"activation outside 16 bits: {word!r}")

    sign = word >> 15
    exponent = (word >> fmt.mant_bits) & fmt.exp_max
    fraction = word & ((1 << fmt.mant_bits) - 1)

    is_zero_exp = exponent == 0
    is_max_exp = exponent == fmt.exp_max
    is_zero = is_zero_exp and fraction == 0

    if is_max_exp:                      # infinity and NaN decode to zero
        return 0, False, True

    significand = fraction if is_zero_exp else (1 << fmt.mant_bits) | fraction
    lsb_exponent = (1 - fmt.bias - fmt.mant_bits) if is_zero_exp \
        else (exponent - fmt.bias - fmt.mant_bits)

    shift = ref_exp - lsb_exponent
    saturated = shift < 0 and not is_zero
    if shift < 0:
        shift = 0

    if is_zero or shift > fmt.align_width:
        magnitude = 0
    else:
        # Round to nearest, ties to even, on the bits the shift drops. The RTL
        # used to truncate here, which biased every activation toward zero by
        # up to one LSB in the same direction, so the error accumulated across a
        # group instead of cancelling.
        widened = significand << fmt.guard
        magnitude = widened >> shift
        if shift >= 1:
            guard_bit = (widened >> (shift - 1)) & 1
            sticky = bool(widened & ((1 << (shift - 1)) - 1)) if shift >= 2 else False
            if guard_bit and (sticky or (magnitude & 1)):
                magnitude += 1

    return (-magnitude if sign else magnitude), saturated, False


def decode_weight(nibble: int, zero_point: int) -> int:
    """Asymmetric INT4: the stored nibble minus the zero point, in [-15, 15]."""
    return nibble - zero_point


def wrap_signed(value: int, bits: int = ACC_BITS) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def narrow_rne(value: int, shift: int, bits: int) -> int:
    """RNE-narrow a signed partial sum by ``shift`` bits, then saturate.

    Mirrors the acc16 PE's stage 3:

        round_bit = x[n-1]; sticky = |x[n-2:0]
        round_up  = round_bit & (sticky | x[n])      # tie -> even
        y         = (x >>> n) + round_up

    Python's ``>>`` on a negative int already floors, which is what an
    arithmetic shift does, so the two agree bit for bit.
    """

    if shift <= 0:
        return saturate_signed(value, bits)
    quotient = value >> shift
    remainder = value - (quotient << shift)
    halfway = 1 << (shift - 1)
    if remainder > halfway or (remainder == halfway and (quotient & 1)):
        quotient += 1
    return saturate_signed(quotient, bits)


def saturate_signed(value: int, bits: int = ACC_BITS) -> int:
    """Clamp to the signed range instead of wrapping.

    The accumulators used to wrap, which turned an overflow into a sign flip
    with nothing in silicon able to report it. Both PE designs now saturate.
    """
    high = (1 << (bits - 1)) - 1
    low = -(1 << (bits - 1))
    return high if value > high else (low if value < low else value)


class PcuModel:
    """One independent accumulator per PE, updated a tile at a time."""

    def __init__(
        self,
        fmt: ActFormat,
        num_pes: int = NUM_PES,
        *,
        acc_bits: int = ACC_BITS,
        acc_rsh: int = 0,
    ) -> None:
        self.fmt = fmt
        self.num_pes = num_pes
        self.acc_bits = acc_bits
        self.acc_rsh = acc_rsh
        self.acc = [0] * num_pes

    def reset(self) -> None:
        self.acc = [0] * self.num_pes

    def transaction(
        self,
        activations: list[int],
        weights: list[list[int]],
        zero_point: int | list[int],
        ref_exp: int,
        *,
        acc_clear: bool,
        acc_enable: bool,
    ) -> tuple[list[int], bool, bool]:
        if len(activations) != LANES:
            raise ValueError(f"expected {LANES} activations")
        if len(weights) != self.num_pes:
            raise ValueError(f"expected {self.num_pes} weight groups")

        # One nibble broadcasts to every PE (v1); a list gives each PE its own
        # zero point (v2). Both spellings decode identically per PE.
        zero_points = ([zero_point] * self.num_pes
                       if isinstance(zero_point, int) else list(zero_point))
        if len(zero_points) != self.num_pes:
            raise ValueError(f"expected {self.num_pes} zero points")

        aligned = []
        saturated = False
        invalid = False
        for word in activations:
            value, sat, inv = align_activation(self.fmt, word, ref_exp)
            aligned.append(value)
            saturated |= sat
            invalid |= inv

        for pe in range(self.num_pes):
            partial = sum(
                aligned[lane] * decode_weight(weights[pe][lane], zero_points[pe])
                for lane in range(LANES)
            )
            if self.acc_rsh:
                # acc16: narrow before the accumulator, not after.
                narrowed = narrow_rne(partial, self.acc_rsh, self.acc_bits)
                if acc_clear:
                    self.acc[pe] = narrowed
                elif acc_enable:
                    self.acc[pe] = saturate_signed(
                        self.acc[pe] + narrowed, self.acc_bits
                    )
            elif acc_clear:
                # A cleared accumulator takes the sign-extended 28-bit partial,
                # which cannot exceed 32 bits, so no clamping applies here.
                self.acc[pe] = wrap_signed(partial)
            elif acc_enable:
                self.acc[pe] = saturate_signed(self.acc[pe] + partial)

        return list(self.acc), saturated, invalid


def reference_exponent(fmt: ActFormat, activations: list[int]) -> int:
    """Largest LSB exponent among the activations, which is what software sets.

    Zero, infinity and NaN contribute nothing, so a block of only those falls
    back to the minimum normal exponent.
    """
    exponents = []
    for word in activations:
        exponent = (word >> fmt.mant_bits) & fmt.exp_max
        fraction = word & ((1 << fmt.mant_bits) - 1)
        if exponent == fmt.exp_max:
            continue
        if exponent == 0 and fraction == 0:
            continue
        exponents.append((1 - fmt.bias - fmt.mant_bits) if exponent == 0
                         else (exponent - fmt.bias - fmt.mant_bits))
    return max(exponents) if exponents else (1 - fmt.bias - fmt.mant_bits)
