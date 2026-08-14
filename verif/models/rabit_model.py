"""Bit-accurate, integer-only golden model for the RaBiT 2-bit PIM PCU.

Every number in here is a Python integer. No host floating point is used
anywhere in the bit-accurate path, so a match against the RTL is a statement
about the design rather than about the simulator's FPU. That is the same rule
the other models in this directory follow.

Reference semantics, matching rtl/5_rabit:

    binary16 code (s, exp, frac) denotes
        (-1)**s * sig * 2**(e_eff - 25)
        sig   = (exp != 0) << 10 | frac        (11 bits)
        e_eff = 1 if exp == 0 else exp

    convert-on-write, per entry of NIN lanes
        e_ent   = max_k e_eff[k]                       (SHIFTER_EN = 1)
                = E0                                   (SHIFTER_EN = 0)
        mant[k] = RNE((sig[k] << LSH) >> (e_ent - e_eff[k] + RSH0)), clamped
        value   = (-1)**sign[k] * mant[k] * 2**(e_ent - 14 - MANT_W)

    PE
        psum  = sum_k (+1 if not neg else -1) * mant[k]
        neg   = sign[k] XOR bit[k]              bit 1 means the weight is -1

    align + accumulate
        aligned = psum << (e_ent - E0)          if e_ent >= E0, saturating
                = psum >> (E0 - e_ent)          arithmetic, floors toward -inf
        acc    += aligned                       saturating in ACC_W bits

    drain
        A_p[j] = acc * 2**(E0 - 14 - MANT_W)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from fractions import Fraction
from typing import Iterable, Sequence

# ---------------------------------------------------------------------------
# geometry, mirroring the RTL defaults
# ---------------------------------------------------------------------------

NIN = 16
NOUT_PER_WORD = 8
NPATH = 2
NGROUP = 4
ACC_W = 32
EXP_W = 6
SIG_W = 11
FP16_BIAS_SHIFT = 25  # value = sig * 2**(e_eff - 25)


def psum_width(mant_w: int = 12, nin: int = NIN) -> int:
    return mant_w + 1 + (nin - 1).bit_length()


def blk_width(mant_w: int = 12, nin: int = NIN, exp_w: int = EXP_W) -> int:
    return nin * (mant_w + 1) + exp_w


def word_width(nin: int = NIN, nout: int = NOUT_PER_WORD, npath: int = NPATH) -> int:
    return nin * nout * npath


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def wrap_signed(value: int, width: int) -> int:
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value >> (width - 1) else value


def saturate_signed(value: int, width: int) -> int:
    high = (1 << (width - 1)) - 1
    low = -(1 << (width - 1))
    if value > high:
        return high
    if value < low:
        return low
    return value


def signed_from_bits(value: int, width: int) -> int:
    return wrap_signed(value, width)


def bits_to_signed_list(value: int, width: int, count: int) -> tuple[int, ...]:
    mask = (1 << width) - 1
    return tuple(
        wrap_signed((value >> (i * width)) & mask, width) for i in range(count)
    )


# ---------------------------------------------------------------------------
# binary16
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fp16:
    """One decoded binary16 code.

    exp == 31 is not special cased: infinities and NaNs decode as ordinary
    numbers with e_eff = 31, exactly as rabit_cvt_fp16_blk does. See open
    question Q3 in docs/rabit_pcu_spec.md.
    """

    sign: int
    e_eff: int
    sig: int

    @property
    def value(self) -> Fraction:
        magnitude = Fraction(self.sig) * Fraction(2) ** (self.e_eff - FP16_BIAS_SHIFT)
        return -magnitude if self.sign else magnitude


def decode_fp16(code: int) -> Fp16:
    if not 0 <= code < (1 << 16):
        raise ValueError(f"binary16 code {code} does not fit 16 bits")
    sign = (code >> 15) & 1
    exp = (code >> 10) & 0x1F
    frac = code & 0x3FF
    sig = ((1 if exp else 0) << 10) | frac
    e_eff = 1 if exp == 0 else exp
    return Fp16(sign=sign, e_eff=e_eff, sig=sig)


def fp16_from_float(value: float) -> int:
    """Round a Python float to the nearest binary16 code, ties to even.

    Used only by stimulus generation and by the packer, never inside the
    bit-accurate comparison path.
    """

    import struct

    packed = struct.pack("<e", value)
    return struct.unpack("<H", packed)[0]


def fp16_to_fraction(code: int) -> Fraction:
    return decode_fp16(code).value


# ---------------------------------------------------------------------------
# convert-on-write
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Block:
    """One converted GRF entry."""

    signs: tuple[int, ...]
    mants: tuple[int, ...]
    e_ent: int
    mant_w: int
    ovf: bool = False

    def packed(self) -> int:
        """Pack as the RTL does: {e_ent, {sign, mant} x NIN}, lane 0 lowest."""

        word = 0
        tw = self.mant_w + 1
        for lane, (sign, mant) in enumerate(zip(self.signs, self.mants)):
            word |= ((sign << self.mant_w) | mant) << (lane * tw)
        word |= self.e_ent << (len(self.mants) * tw)
        return word

    def mant_bus(self) -> int:
        tw = self.mant_w + 1
        word = 0
        for lane, (sign, mant) in enumerate(zip(self.signs, self.mants)):
            word |= ((sign << self.mant_w) | mant) << (lane * tw)
        return word

    def lsb_weight(self) -> Fraction:
        return Fraction(2) ** (self.e_ent - 14 - self.mant_w)

    def value(self, lane: int) -> Fraction:
        magnitude = Fraction(self.mants[lane]) * self.lsb_weight()
        return -magnitude if self.signs[lane] else magnitude


def _rne_shift(value: int, shift: int, out_w: int) -> int:
    """value >> shift with round-to-nearest-even, clamped to out_w bits."""

    if shift <= 0:
        result = value << (-shift)
    else:
        quotient = value >> shift
        round_bit = (value >> (shift - 1)) & 1
        sticky = 1 if (value & ((1 << (shift - 1)) - 1)) else 0
        result = quotient + (round_bit & (sticky | (quotient & 1)))
    limit = (1 << out_w) - 1
    return limit if result > limit else result


def convert_block(
    codes: Sequence[int],
    *,
    mant_w: int = 12,
    shifter_en: int = 1,
    e0: int = 0,
    nin: int = NIN,
) -> Block:
    if len(codes) != nin:
        raise ValueError(f"convert_block needs {nin} codes, got {len(codes)}")

    lsh = max(0, mant_w - SIG_W)
    rsh0 = max(0, SIG_W - mant_w)
    ww = SIG_W + lsh
    dmax = ww + 1

    decoded = [decode_fp16(code) for code in codes]
    e_ent = max(item.e_eff for item in decoded) if shifter_en else e0
    if not 0 <= e_ent < (1 << EXP_W):
        raise ValueError(f"block exponent {e_ent} does not fit {EXP_W} bits")

    signs: list[int] = []
    mants: list[int] = []
    ovf = False
    for item in decoded:
        requested = e_ent - item.e_eff + rsh0
        if requested < 0:
            # Only reachable with shifter_en = 0: the lane sits above the global
            # reference and the converter clamps it.
            ovf = True
            mants.append((1 << mant_w) - 1)
            signs.append(item.sign)
            continue
        used = min(requested, dmax)
        mants.append(_rne_shift(item.sig << lsh, used, mant_w))
        signs.append(item.sign)

    return Block(
        signs=tuple(signs),
        mants=tuple(mants),
        e_ent=e_ent,
        mant_w=mant_w,
        ovf=ovf,
    )


# ---------------------------------------------------------------------------
# PE
# ---------------------------------------------------------------------------


def pe_partial(bits: Sequence[int], block: Block) -> int:
    """One PE stage-A result: sum_k (+/-1) * mant[k]."""

    if len(bits) != len(block.mants):
        raise ValueError("weight bit count does not match the block")
    total = 0
    for bit, sign, mant in zip(bits, block.signs, block.mants):
        total += -mant if (sign ^ bit) else mant
    exact_w = psum_width(block.mant_w, len(block.mants))
    if total != wrap_signed(total, exact_w):
        raise OverflowError(f"partial sum {total} does not fit {exact_w} bits")
    return total


def align(
    psum: int,
    shift: int,
    *,
    psum_w: int = 17,
    acc_w: int = ACC_W,
    shift_rnd: int = 0,
) -> tuple[int, bool]:
    """Arithmetic alignment by ``shift`` = e_ent - E0. Returns (value, sat)."""

    shl_max = acc_w - psum_w
    if shift >= 0:
        if shift > shl_max and psum != 0:
            return (
                (1 << (acc_w - 1)) - 1 if psum > 0 else -(1 << (acc_w - 1)),
                True,
            )
        return psum << min(shift, shl_max), False

    amount = min(-shift, psum_w)
    if shift_rnd:
        quotient = psum >> amount
        round_bit = (psum >> (amount - 1)) & 1 if amount else 0
        sticky = 1 if (amount >= 2 and (psum & ((1 << (amount - 1)) - 1))) else 0
        return quotient + (round_bit & (sticky | (quotient & 1))), False
    return psum >> amount, False


# ---------------------------------------------------------------------------
# full PCU
# ---------------------------------------------------------------------------


@dataclass
class PcuGolden:
    """Transaction-level model of rabit_pcu_top.

    ``accumulators[slot][pe]`` mirrors the register file, where
    ``slot = group * NPATH + path``.
    """

    mant_w: int = 12
    shifter_en: int = 1
    nout: int = NOUT_PER_WORD
    npath: int = NPATH
    ngroup: int = NGROUP
    nin: int = NIN
    acc_w: int = ACC_W
    shift_rnd: int = 0

    e0: int = 0
    grf: list = field(default_factory=list)
    accumulators: list = field(default_factory=list)
    sticky: int = 0

    def __post_init__(self) -> None:
        self.reset()

    # -- state ------------------------------------------------------------
    def reset(self) -> None:
        self.grf = [None] * (2 * self.npath)
        self.accumulators = [
            [0] * self.nout for _ in range(self.ngroup * self.npath)
        ]
        self.sticky = 0

    def clear_status(self) -> None:
        self.sticky = 0

    @property
    def psum_w(self) -> int:
        return psum_width(self.mant_w, self.nin)

    # -- commands ---------------------------------------------------------
    def write(self, entry: int, codes: Sequence[int]) -> Block:
        """WR: convert one binary16 vector and store it in the behavioural GRF."""

        if not 0 <= entry < len(self.grf):
            raise ValueError(f"GRF entry {entry} out of range")
        block = convert_block(
            codes,
            mant_w=self.mant_w,
            shifter_en=self.shifter_en,
            e0=self.e0,
            nin=self.nin,
        )
        self.grf[entry] = block
        if block.ovf:
            self.sticky |= 0b100
        return block

    def read(self, word: int, group: int, pair: int) -> None:
        """RD: consume one column word, NPATH pumps, into accumulator group."""

        if not 0 <= group < self.ngroup:
            raise ValueError(f"output group {group} out of range")
        for path in range(self.npath):
            block = self.grf[pair * self.npath + path]
            if block is None:
                raise AssertionError(
                    f"RD used GRF entry {pair * self.npath + path} before any WR"
                )
            slot = group * self.npath + path
            shift = block.e_ent - self.e0
            for pe in range(self.nout):
                base = pe * (self.npath * self.nin) + path * self.nin
                bits = [(word >> (base + k)) & 1 for k in range(self.nin)]
                psum = pe_partial(bits, block)
                aligned, sat = align(
                    psum,
                    shift,
                    psum_w=self.psum_w,
                    acc_w=self.acc_w,
                    shift_rnd=self.shift_rnd,
                )
                if sat:
                    self.sticky |= 0b010
                total = self.accumulators[slot][pe] + aligned
                clamped = saturate_signed(total, self.acc_w)
                if clamped != total:
                    self.sticky |= 0b001
                self.accumulators[slot][pe] = clamped

    def drain(self, group: int) -> list[tuple[int, tuple[int, ...]]]:
        """Drain one group: NPATH beats of NOUT values each, clearing as it goes."""

        beats = []
        for path in range(self.npath):
            slot = group * self.npath + path
            beats.append((path, tuple(self.accumulators[slot])))
            self.accumulators[slot] = [0] * self.nout
        return beats

    # -- dequantization ---------------------------------------------------
    def acc_lsb_weight(self) -> Fraction:
        return Fraction(2) ** (self.e0 - 14 - self.mant_w)

    def partial_value(self, group: int, path: int, pe: int) -> Fraction:
        slot = group * self.npath + path
        return Fraction(self.accumulators[slot][pe]) * self.acc_lsb_weight()


# ---------------------------------------------------------------------------
# exact reference for the whole projection GEMV
# ---------------------------------------------------------------------------


def exact_path_partial(bits: Sequence[int], codes: Sequence[int]) -> Fraction:
    """sum_k B[k] * u[k], exactly, with u given as binary16 codes.

    Every binary16 value is a dyadic rational, so this reference has no
    rounding of its own: it is the number the PCU is trying to approximate.
    """

    total = Fraction(0)
    for bit, code in zip(bits, codes):
        value = fp16_to_fraction(code)
        total += -value if bit else value
    return total


def gemv_reference(
    b_paths: Sequence[Sequence[Sequence[int]]],
    u_paths: Sequence[Sequence[int]],
    g_paths: Sequence[Sequence[float]],
) -> list[float]:
    """y[j] = sum_p g_p[j] * (B_p (h_p * x))[j], from binary16 u codes.

    b_paths[p][j][k] is the packed weight bit, u_paths[p][k] the binary16 code
    of u_p[k] = h_p[k] * x[k], and g_paths[p][j] the per-output scale. The inner
    dot product is exact; only the final g scaling uses host floating point,
    which is the NPU's job anyway.
    """

    npath = len(b_paths)
    dout = len(b_paths[0])
    out: list[float] = []
    for j in range(dout):
        acc = 0.0
        for p in range(npath):
            partial = exact_path_partial(b_paths[p][j], u_paths[p])
            acc += g_paths[p][j] * float(partial)
        out.append(acc)
    return out


def dequantize(
    partials: Sequence[Sequence[int]],
    g_paths: Sequence[Sequence[float]],
    e0: int,
    mant_w: int = 12,
) -> list[float]:
    """Apply the host-side dequantization to raw PCU integers.

    partials[p][j] is the drained 32-bit accumulator for path p, output j.
    """

    weight = float(Fraction(2) ** (e0 - 14 - mant_w))
    npath = len(partials)
    dout = len(partials[0])
    return [
        sum(g_paths[p][j] * partials[p][j] * weight for p in range(npath))
        for j in range(dout)
    ]


def relative_error(actual: Iterable[float], reference: Iterable[float]) -> float:
    """L2 relative error, the metric the accuracy table reports."""

    num = 0.0
    den = 0.0
    for a, r in zip(actual, reference):
        num += (a - r) * (a - r)
        den += r * r
    if den == 0.0:
        return 0.0
    return (num / den) ** 0.5
