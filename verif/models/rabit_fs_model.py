"""Bit-accurate, integer-only golden model for the RaBiT full-scale PCU.

This is the increment on ``rabit_model``: same convert-on-write, same PE, same
alignment and accumulation, plus the two things the full-scale variant moved
inside the PCU.

    u_p[k] = h_p[k] * x[k]                       rabit_fs_h_scale_unit
    y[j]   = fp16(g_1[j]*A_1[j] + g_2[j]*A_2[j]) rabit_fs_dq_unit

Every number on the comparison path is a Python integer, so a match against the
RTL is a statement about the design and not about the host's FPU. Only the
accuracy study at the bottom leaves that discipline, and it uses
``fractions.Fraction`` rather than float wherever the value has to stay exact.

Formats
-------

FP8-E4M3, OCP FN: bias 7, no infinity, 0x7F / 0xFF are NaN. Decoded the same way
the RTL does it, so that a NaN code is an ordinary number plus a status bit:

    h = (-1)**s * sig_h * 2**(e_h - 10),  sig_h = {exp != 0, man},
                                          e_h   = (exp == 0) ? 1 : exp

binary16, unchanged from ``rabit_model``:

    x = (-1)**s * sig_x * 2**(e_x - 25),  sig_x = {exp != 0, frac},
                                          e_x   = (exp == 0) ? 1 : exp
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Iterable, Sequence

from rabit_model import (  # noqa: F401  (re-exported for the tests)
    ACC_W,
    EXP_W,
    NGROUP,
    NIN,
    NOUT_PER_WORD,
    NPATH,
    Block,
    PcuGolden,
    align,
    blk_width,
    convert_block,
    decode_fp16,
    fp16_from_float,
    fp16_to_fraction,
    pe_partial,
    psum_width,
    saturate_signed,
    word_width,
)

# ---------------------------------------------------------------------------
# geometry, mirroring the RTL defaults
# ---------------------------------------------------------------------------

DQ_LANES = 4
ALIGN_MAX = 16
NOUT_STRIPE = NGROUP * NOUT_PER_WORD          # 32 outputs resident per stripe
NHALF = NOUT_PER_WORD // DQ_LANES
DRAIN_CYCLES = NGROUP * NPATH * NHALF         # accumulator-port cycles per drain
G_WORDS = (NOUT_STRIPE * NPATH * 16) // 256   # 256-bit writes to fill g_buffer

H_FMT_FP8 = 0
H_FMT_FP16 = 1

FP8_NAN = 0x7F
FP8_MAX_CODE = 0x7E        # 448, the largest finite FP8-E4M3
FP16_MAX_CODE = 0x7BFF     # 65504, the largest finite binary16


# ---------------------------------------------------------------------------
# FP8-E4M3
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fp8:
    """One decoded FP8-E4M3 code, in the same shape as ``Fp16``."""

    sign: int
    e_eff: int
    sig: int
    nan: bool

    @property
    def value(self) -> Fraction:
        magnitude = Fraction(self.sig) * Fraction(2) ** (self.e_eff - 10)
        return -magnitude if self.sign else magnitude


def decode_fp8_e4m3(code: int) -> Fp8:
    """Decode exactly as rabit_fs_h_scale_unit does.

    NaN codes are not special cased: 0x7F decodes as sig 15, e_eff 15 -- the
    same "no special cases" rule rabit_cvt_fp16_blk applies to binary16
    exp == 31 -- and the nan flag exists so the status bit can be checked.
    """

    if not 0 <= code < 256:
        raise ValueError(f"FP8 code {code} does not fit 8 bits")
    sign = (code >> 7) & 1
    exp = (code >> 3) & 0xF
    man = code & 0x7
    return Fp8(
        sign=sign,
        e_eff=1 if exp == 0 else exp,
        sig=((1 if exp else 0) << 3) | man,
        nan=(exp == 0xF and man == 0x7),
    )


def _rne_quotient(numer: Fraction, unit: Fraction) -> int:
    """round-to-nearest-even of numer / unit, both non-negative."""

    ratio = numer / unit
    floor = ratio.numerator // ratio.denominator
    rest = ratio - floor
    if rest > Fraction(1, 2):
        return floor + 1
    if rest < Fraction(1, 2):
        return floor
    return floor + (floor & 1)


def fp8_e4m3_code(value) -> int:
    """Round a real value to the nearest FP8-E4M3 code, ties to even.

    Saturates at +-448 rather than producing a NaN, which is the policy the
    packer needs: an h scale that overflows the format is a quantization
    decision, not an exception.
    """

    if isinstance(value, float) and math.isnan(value):
        return FP8_NAN
    fr = Fraction(value)
    sign = 1 if fr < 0 else 0
    a = -fr if fr < 0 else fr
    if a == 0:
        return sign << 7

    exp = 15
    while exp >= 1 and a < Fraction(2) ** (exp - 7):
        exp -= 1

    if exp >= 1:
        sig = _rne_quotient(a, Fraction(2) ** (exp - 10))
        if sig >= 16:
            exp += 1
            sig = 8
        if exp > 15 or (exp == 15 and sig > 14):
            return (sign << 7) | FP8_MAX_CODE
        return (sign << 7) | (exp << 3) | (sig - 8)

    sig = _rne_quotient(a, Fraction(2) ** -9)
    if sig >= 8:
        return (sign << 7) | (1 << 3) | (sig - 8)
    return (sign << 7) | sig


def fp8_to_fraction(code: int) -> Fraction:
    return decode_fp8_e4m3(code).value


def pack_h_word(h1: Sequence[int], h2: Sequence[int]) -> int:
    """Pack one chunk of FP8 scales: bit[k*16 + p*8 +: 8] = h_(p+1)[k]."""

    if len(h1) != NIN or len(h2) != NIN:
        raise ValueError(f"pack_h_word needs {NIN} codes per path")
    word = 0
    for k in range(NIN):
        word |= (h1[k] & 0xFF) << (k * 16)
        word |= (h2[k] & 0xFF) << (k * 16 + 8)
    return word


def pack_fp16_word(codes: Sequence[int]) -> int:
    if len(codes) != NIN:
        raise ValueError(f"pack_fp16_word needs {NIN} codes")
    word = 0
    for k, code in enumerate(codes):
        word |= (code & 0xFFFF) << (k * 16)
    return word


def pack_g_word(g_paths: Sequence[Sequence[int]], quarter: int) -> int:
    """One quarter of the g table: bit[j_local*32 + p*16 +: 16].

    ``g_paths[p][j]`` is indexed by the output's position inside the stripe.
    """

    word = 0
    for j_local in range(NOUT_PER_WORD):
        j = quarter * NOUT_PER_WORD + j_local
        for p in range(NPATH):
            word |= (g_paths[p][j] & 0xFFFF) << (j_local * (NPATH * 16) + p * 16)
    return word


# ---------------------------------------------------------------------------
# rabit_fs_fp16_pack
# ---------------------------------------------------------------------------


def fp16_pack(sign: int, mag: int, exp_lsb: int, mag_w: int) -> tuple[int, bool]:
    """(-1)**sign * mag * 2**exp_lsb  ->  one binary16 code, RNE.

    Returns (code, saturated). Mirrors rabit_fs_fp16_pack exactly, including the
    saturation to 0x7BFF and the "subnormal that rounds up is the smallest
    normal" identity that lets one 15-bit field cover both cases.
    """

    if mag < 0 or mag >= (1 << mag_w):
        raise ValueError(f"magnitude {mag} does not fit {mag_w} bits")
    if mag == 0:
        return (sign << 15), False

    sr_max = mag_w + 1
    n = mag.bit_length() - 1
    e_biased = exp_lsb + n + 15
    subnormal = e_biased <= 0

    shift = -(exp_lsb + 24) if subnormal else (n - 10)
    shift = max(-10, min(shift, sr_max))

    if shift < 0:
        # The magnitude is below bit 11 here, so the 12-bit field is exact.
        rounded = ((mag & 0xFFF) << (-shift)) & 0xFFF
    else:
        quotient = mag >> shift
        if shift > 0:
            round_bit = (mag >> (shift - 1)) & 1
            sticky = 1 if (mag & ((1 << (shift - 1)) - 1)) else 0
        else:
            round_bit = 0
            sticky = 0
        rounded = (quotient + (round_bit & (sticky | (quotient & 1)))) & 0xFFF

    if subnormal:
        return (sign << 15) | (rounded & 0x7FF), False

    if rounded & 0x800:
        e_final = e_biased + 1
        frac = 0
    else:
        e_final = e_biased
        frac = rounded & 0x3FF

    if e_final >= 31:
        return (sign << 15) | FP16_MAX_CODE, True
    return (sign << 15) | (e_final << 10) | frac, False


# ---------------------------------------------------------------------------
# rabit_fs_h_scale_unit
# ---------------------------------------------------------------------------


def h_scale_lane(x_code: int, h_code: int, h_fmt: int = H_FMT_FP8) -> tuple[int, bool, bool]:
    """One lane of the multiply array. Returns (u binary16 code, nan, sat)."""

    x = decode_fp16(x_code)
    if h_fmt == H_FMT_FP8:
        h = decode_fp8_e4m3(h_code)
        h_off = 10
        mag_w = 15
        nan = h.nan
    else:
        h = decode_fp16(h_code)
        h_off = 25
        mag_w = 22
        nan = False

    prod = x.sig * h.sig
    exp_lsb = x.e_eff + h.e_eff - 25 - h_off
    code, sat = fp16_pack(x.sign ^ h.sign, prod, exp_lsb, mag_w)
    return code, nan, sat


def h_scale_chunk(
    x_codes: Sequence[int],
    h_codes: Sequence[int],
    h_fmt: int = H_FMT_FP8,
) -> tuple[list[int], bool, bool]:
    """One PCU cycle of the array: NIN lanes for one residual path."""

    out: list[int] = []
    nan = False
    sat = False
    for x_code, h_code in zip(x_codes, h_codes):
        code, lane_nan, lane_sat = h_scale_lane(x_code, h_code, h_fmt)
        out.append(code)
        nan = nan or lane_nan
        sat = sat or lane_sat
    return out, nan, sat


# ---------------------------------------------------------------------------
# rabit_fs_dq_lane / rabit_fs_dq_add
# ---------------------------------------------------------------------------

FW = 10
F_ZERO = -(1 << (FW - 1))


def dq_lane(
    acc: int,
    g_code: int,
    e0: int,
    *,
    mant_w: int = 12,
) -> tuple[int, int, int]:
    """(sign, 23-bit product, exponent of its LSB) for one accumulator."""

    sign_a = 1 if acc < 0 else 0
    mag_a = -acc if acc < 0 else acc

    sign_g = (g_code >> 15) & 1
    exp_g = (g_code >> 10) & 0x1F
    frac_g = g_code & 0x3FF
    g_nz = (exp_g != 0) or (frac_g != 0)

    sign = sign_a ^ sign_g
    if mag_a == 0 or not g_nz:
        return sign, 0, F_ZERO

    # normalize the accumulator to mant_w bits, leading one at bit mant_w-1
    top = mant_w - 1
    n_a = mag_a.bit_length() - 1
    if n_a > top:
        shift = n_a - top
        quotient = mag_a >> shift
        round_bit = (mag_a >> (shift - 1)) & 1
        sticky = 1 if (mag_a & ((1 << (shift - 1)) - 1)) else 0
        norm = quotient + (round_bit & (sticky | (quotient & 1)))
    else:
        norm = mag_a << (top - n_a)

    if norm >> mant_w:
        m_mant = norm >> 1
        n_adj = n_a + 1
    else:
        m_mant = norm
        n_adj = n_a

    # normalize the scale, leading one at bit 10
    if exp_g != 0:
        sig_g = 0x400 | frac_g
        e_g = exp_g
    else:
        lz = 9 - (frac_g.bit_length() - 1)
        sig_g = ((frac_g << 1) << lz) & 0x7FF
        e_g = 1 - lz

    return sign, m_mant * sig_g, n_adj + e0 + e_g - (2 * mant_w + 38)


def dq_add(
    lane1: tuple[int, int, int],
    lane2: tuple[int, int, int],
    *,
    qw: int = 23,
    align_max: int = ALIGN_MAX,
) -> tuple[int, int, int]:
    """Align the two paths to the larger exponent and add. -> (sign, mag, exp)."""

    field_w = qw + align_max
    s1, q1, f1 = lane1
    s2, q2, f2 = lane2

    fmax = max(f1, f2)
    d1 = min(fmax - f1, field_w)
    d2 = min(fmax - f2, field_w)

    a1 = (q1 << align_max) >> d1
    a2 = (q2 << align_max) >> d2
    total = (-a1 if s1 else a1) + (-a2 if s2 else a2)

    sign = 1 if total < 0 else 0
    return sign, (-total if total < 0 else total), fmax - align_max


def dequantize_output(
    acc1: int,
    acc2: int,
    g1_code: int,
    g2_code: int,
    e0: int,
    *,
    mant_w: int = 12,
    align_max: int = ALIGN_MAX,
) -> tuple[int, bool]:
    """The whole drain datapath for one output. -> (binary16 code, saturated)."""

    qw = (mant_w + 1) + 11
    lane1 = dq_lane(acc1, g1_code, e0, mant_w=mant_w)
    lane2 = dq_lane(acc2, g2_code, e0, mant_w=mant_w)
    sign, mag, exp_lsb = dq_add(lane1, lane2, qw=qw, align_max=align_max)
    return fp16_pack(sign, mag, exp_lsb, qw + align_max + 1)


# ---------------------------------------------------------------------------
# full PCU
# ---------------------------------------------------------------------------


@dataclass
class PcuFsGolden(PcuGolden):
    """Transaction-level model of rabit_pcu_fs_top.

    Inherits the accumulator array, the PE and the raw drain from ``PcuGolden``
    and adds the h latch, the g buffer and the dequantizing drain. Commands
    mirror the RTL's write kinds:

        write_h  one 256-bit FP8 chunk (or one binary16 vector when h_fmt = 1)
        write_x  one 256-bit binary16 chunk, expands to NPATH GRF entries
        write_g  one quarter of the stripe's g table
        read     unchanged from the base variant
        dq_drain the whole stripe, returning NOUT_STRIPE binary16 codes
    """

    h_fmt: int = H_FMT_FP8
    align_max: int = ALIGN_MAX

    h_latch: list = field(default_factory=list)
    g_buffer: list = field(default_factory=list)
    g_filled: set = field(default_factory=set)
    fs_sticky: int = 0

    def __post_init__(self) -> None:
        super().__post_init__()
        self.h_latch = [None] * (1 if self.h_fmt == H_FMT_FP8 else self.npath)
        self.g_buffer = [[0] * (self.ngroup * self.nout) for _ in range(self.npath)]
        self.g_filled = set()
        self.fs_sticky = 0

    # -- state ------------------------------------------------------------
    def clear_status(self) -> None:
        super().clear_status()
        self.fs_sticky = 0

    @property
    def g_loaded(self) -> bool:
        return len(self.g_filled) == G_WORDS

    # -- commands ---------------------------------------------------------
    def write_h(self, codes, sel: int = 0) -> None:
        """WR slot B. ``codes`` is 2*NIN FP8 codes, or NIN binary16 codes."""

        if self.h_fmt == H_FMT_FP8:
            if len(codes) != 2 * self.nin:
                raise ValueError(f"FP8 h chunk needs {2*self.nin} codes")
            self.h_latch[0] = list(codes)
        else:
            if len(codes) != self.nin:
                raise ValueError(f"binary16 h vector needs {self.nin} codes")
            self.h_latch[sel] = list(codes)

    def h_for_path(self, path: int) -> list[int]:
        if self.h_fmt == H_FMT_FP8:
            latched = self.h_latch[0]
            if latched is None:
                raise AssertionError("x write with no h write before it")
            return [latched[k * 2 + path] for k in range(self.nin)]
        latched = self.h_latch[path]
        if latched is None:
            raise AssertionError(f"x write with no h write for path {path}")
        return latched

    def write_x(self, pair: int, x_codes: Sequence[int]) -> list[Block]:
        """WR slot A. NPATH cycles: cycle p forms u_(p+1) and converts it."""

        if len(x_codes) != self.nin:
            raise ValueError(f"x chunk needs {self.nin} codes")
        blocks = []
        for path in range(self.npath):
            u_codes, nan, sat = h_scale_chunk(
                x_codes, self.h_for_path(path), self.h_fmt
            )
            if nan:
                self.fs_sticky |= 0b0001
            if sat:
                self.fs_sticky |= 0b0010
            blocks.append(super().write(pair * self.npath + path, u_codes))
        return blocks

    def write_g(self, quarter: int, g_paths: Sequence[Sequence[int]]) -> None:
        """WR_G. ``g_paths[p]`` is NOUT_PER_WORD codes for this quarter."""

        if quarter == 0:
            self.g_filled = set()
        self.g_filled.add(quarter)
        for p in range(self.npath):
            for j_local in range(self.nout):
                self.g_buffer[p][quarter * self.nout + j_local] = g_paths[p][j_local]

    def dq_drain(self) -> list[int]:
        """Drain the whole stripe through the dequantizer, clearing as it goes.

        Returns NOUT_STRIPE binary16 codes in output order, which is also the
        order the y beats leave the RTL: beat b carries outputs
        b*DQ_LANES .. b*DQ_LANES + DQ_LANES - 1.
        """

        if not self.g_loaded:
            self.fs_sticky |= 0b1000

        out: list[int] = []
        for group in range(self.ngroup):
            for j_local in range(self.nout):
                j = group * self.nout + j_local
                acc1 = self.accumulators[group * self.npath + 0][j_local]
                acc2 = self.accumulators[group * self.npath + 1][j_local]
                code, sat = dequantize_output(
                    acc1,
                    acc2,
                    self.g_buffer[0][j],
                    self.g_buffer[1][j],
                    self.e0,
                    mant_w=self.mant_w,
                    align_max=self.align_max,
                )
                if sat:
                    self.fs_sticky |= 0b0100
                out.append(code)
            for path in range(self.npath):
                self.accumulators[group * self.npath + path] = [0] * self.nout
        return out


# ---------------------------------------------------------------------------
# accuracy references
# ---------------------------------------------------------------------------


def exact_projection(
    b_paths: Sequence[Sequence[Sequence[int]]],
    x_codes: Sequence[int],
    h_values: Sequence[Sequence[Fraction]],
    g_values: Sequence[Fraction],
) -> Fraction:
    """One output, computed exactly: sum_p g_p * sum_k B_p[k] * h_p[k] * x[k].

    Every input is a dyadic rational, so this reference has no rounding of its
    own. It is the number the PCU is trying to approximate, and the only thing
    that changes between the two references the accuracy study needs is which
    h values are passed in: the binary16 ones, or the same values after FP8
    quantization.
    """

    total = Fraction(0)
    for p, bits in enumerate(b_paths):
        path_sum = Fraction(0)
        for k, bit in enumerate(bits):
            term = h_values[p][k] * fp16_to_fraction(x_codes[k])
            path_sum += -term if bit else term
        total += g_values[p] * path_sum
    return total


def reference_fp16_h(
    b_paths, x_codes, h_codes, g_codes
) -> Fraction:
    """Reference (a): h kept in binary16."""

    h_values = [[fp16_to_fraction(c) for c in path] for path in h_codes]
    g_values = [fp16_to_fraction(c) for c in g_codes]
    return exact_projection(b_paths, x_codes, h_values, g_values)


def reference_fp8_h(
    b_paths, x_codes, h_fp8_codes, g_codes
) -> Fraction:
    """Reference (b'): h quantized to FP8-E4M3, everything else exact.

    This isolates the cost of the h format from the cost of the PCU datapath.
    The PCU itself is compared bit for bit against ``PcuFsGolden``, not against
    this.
    """

    h_values = [[fp8_to_fraction(c) for c in path] for path in h_fp8_codes]
    g_values = [fp16_to_fraction(c) for c in g_codes]
    return exact_projection(b_paths, x_codes, h_values, g_values)


def relative_errors(actual: Iterable[float], reference: Iterable[float]):
    """(max |rel err|, mean |rel err|, L2 rel err) over the non-zero references."""

    actual = list(actual)
    reference = list(reference)
    worst = 0.0
    total = 0.0
    count = 0
    num = 0.0
    den = 0.0
    for a, r in zip(actual, reference):
        num += (a - r) * (a - r)
        den += r * r
        if r == 0.0:
            continue
        err = abs(a - r) / abs(r)
        worst = max(worst, err)
        total += err
        count += 1
    mean = total / count if count else 0.0
    l2 = (num / den) ** 0.5 if den else 0.0
    return worst, mean, l2
