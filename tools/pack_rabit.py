#!/usr/bin/env python3
"""Offline data-mapping packer for the RaBiT 2-bit PIM PCU.

Takes a binary16 weight matrix and the RaBiT per-channel scales, derives the two
residual binary cores the way the paper's forward pass does, and emits the
256-bit column words plus the DRAM addresses the PCU expects.

    W  ~  sum_p  g_p (x) B_p (x) h_p,      B_p in {+1,-1}^(dout x din)
    B_1 = sign(W)                          W_1 = g_1 (x) B_1 (x) h_1
    R_1 = W - W_1
    B_2 = sign(R_1)

Word format, 256 bits = 16 inputs x 8 outputs x 2 paths:

    bit[j*32 + p*16 + k] = B_(p+1)[out j][in k],   +1 -> 0, -1 -> 1

which is the packing the RaBiT GPU kernel already uses (see the paper, appendix
E.1: "each group of 32 columns is mapped to a uint32_t, with +1 -> 0 and
-1 -> 1"), so the PE reads its sixteen weight bits as one contiguous slice.

Column address:

    CA = { k_chunk_in_row, out_group[1:0] }

so out_group 0..3 -- 32 outputs -- sit in consecutive columns at the same
k_chunk, and the next k_chunk follows. A row therefore covers COLS_PER_ROW/4
k chunks of one 32-output stripe; the stripe's whole k sweep runs to completion
before the next stripe starts, which is what keeps the accumulators resident.
Banks are partitioned along dout, one stripe set per bank; that only shows up in
the address, never in the RTL.

Usage
    python3 tools/pack_rabit.py --self-test
    python3 tools/pack_rabit.py --dout 128 --din 256 --dump-words out.txt

As a library: build_packing(), schedule(), pack_activations().
"""

from __future__ import annotations

import argparse
import math
import random
import struct
import sys
from dataclasses import dataclass, field
from typing import Iterator, Sequence

# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

NIN = 16  # inputs per column word and per GRF entry
NOUT = 8  # outputs per column word, one per PE
NPATH = 2  # residual binary paths
NGROUP = 4  # accumulator groups, i.e. out_groups per k chunk
COLS_PER_ROW = 32  # 256-bit columns in one DRAM row (1 KB row, 32 B column)

OUT_PER_STRIPE = NOUT * NGROUP  # 32 outputs held in the accumulator array
K_CHUNKS_PER_ROW = COLS_PER_ROW // NGROUP


# ---------------------------------------------------------------------------
# binary16 helpers
# ---------------------------------------------------------------------------


def fp16_code(value: float) -> int:
    """Round to the nearest binary16 code (ties to even), saturating on range."""

    if math.isnan(value):
        return 0x7E00
    return struct.unpack("<H", struct.pack("<e", value))[0]


def fp16_value(code: int) -> float:
    return struct.unpack("<e", struct.pack("<H", code))[0]


def quantize_fp16(values: Sequence[float]) -> list[int]:
    return [fp16_code(v) for v in values]


# ---------------------------------------------------------------------------
# RaBiT residual binarization
# ---------------------------------------------------------------------------


@dataclass
class Scales:
    """RaBiT per-channel scales: g over dout, h over din, one pair per path."""

    g: list[list[float]]  # [path][dout]
    h: list[list[float]]  # [path][din]

    def check(self, dout: int, din: int, npath: int) -> None:
        if len(self.g) != npath or len(self.h) != npath:
            raise ValueError(f"scales must cover {npath} paths")
        for p in range(npath):
            if len(self.g[p]) != dout:
                raise ValueError(f"g[{p}] must have {dout} entries")
            if len(self.h[p]) != din:
                raise ValueError(f"h[{p}] must have {din} entries")


def derive_scales(
    weights: Sequence[Sequence[float]],
    *,
    npath: int = NPATH,
    iterations: int = 3,
) -> Scales:
    """Fit (g, h) per path by alternating least squares.

    RaBiT learns g and h during QAT; this is only a stand-in so the packer and
    its tests can run on a matrix that arrives without them. Given B, the
    minimizer of ||W - g (x) B (x) h||_F alternates

        g_i = sum_j W_ij B_ij h_j / sum_j h_j^2
        h_j = sum_i W_ij B_ij g_i / sum_i g_i^2

    starting from h = 1. Supply real trained scales through --scales / the
    ``scales`` argument whenever they exist.
    """

    dout = len(weights)
    din = len(weights[0])
    residual = [list(row) for row in weights]
    g_all: list[list[float]] = []
    h_all: list[list[float]] = []

    for _ in range(npath):
        cores = [[1 if value < 0.0 else 0 for value in row] for row in residual]
        signs = [[-1.0 if bit else 1.0 for bit in row] for row in cores]

        h = [1.0] * din
        g = [0.0] * dout
        for _ in range(iterations):
            denom = sum(value * value for value in h)
            if denom == 0.0:
                denom = 1.0
            for i in range(dout):
                w_row = residual[i]
                s_row = signs[i]
                g[i] = sum(
                    w_row[j] * s_row[j] * h[j] for j in range(din)
                ) / denom

            denom = sum(value * value for value in g)
            if denom == 0.0:
                denom = 1.0
            for j in range(din):
                h[j] = sum(
                    residual[i][j] * signs[i][j] * g[i] for i in range(dout)
                ) / denom

        for i in range(dout):
            w_row = residual[i]
            s_row = signs[i]
            gi = g[i]
            for j in range(din):
                w_row[j] -= gi * s_row[j] * h[j]

        g_all.append(g)
        h_all.append(h)

    return Scales(g=g_all, h=h_all)


def binarize(
    weights: Sequence[Sequence[float]],
    scales: Scales,
    *,
    npath: int = NPATH,
) -> list[list[list[int]]]:
    """Derive the residual binary cores. Returns cores[path][dout][din] in bits.

    Bit 0 means +1 and bit 1 means -1, matching both the RaBiT kernel and the
    PCU word format.
    """

    dout = len(weights)
    din = len(weights[0])
    scales.check(dout, din, npath)

    residual = [list(row) for row in weights]
    cores: list[list[list[int]]] = []
    for p in range(npath):
        core = [[1 if value < 0.0 else 0 for value in row] for row in residual]
        cores.append(core)
        g_p = scales.g[p]
        h_p = scales.h[p]
        for i in range(dout):
            row = residual[i]
            core_row = core[i]
            gi = g_p[i]
            for j in range(din):
                row[j] -= gi * (-1.0 if core_row[j] else 1.0) * h_p[j]
    return cores


# ---------------------------------------------------------------------------
# word and address packing
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class WordAddr:
    """Where one 256-bit column word lives, and what it covers."""

    bank: int
    row: int
    col: int
    stripe: int
    k_chunk: int
    out_group: int

    @property
    def ca(self) -> int:
        """CA = {k_chunk_in_row, out_group}."""

        return self.col


@dataclass
class Packing:
    dout: int
    din: int
    npath: int
    num_banks: int
    rows_per_stripe: int = 1
    words: dict = field(default_factory=dict)  # WordAddr -> int (256 bits)

    @property
    def n_stripes(self) -> int:
        return self.dout // OUT_PER_STRIPE

    @property
    def n_kchunks(self) -> int:
        return self.din // NIN

    def word_at(self, stripe: int, k_chunk: int, out_group: int) -> int:
        return self.words[
            address_of(
                stripe, k_chunk, out_group, self.num_banks, self.rows_per_stripe
            )
        ]

    def bit(self, path: int, j: int, k: int) -> int:
        """Read one weight bit back out of the packed words."""

        stripe = j // OUT_PER_STRIPE
        out_group = (j % OUT_PER_STRIPE) // NOUT
        j_local = j % NOUT
        word = self.word_at(stripe, k // NIN, out_group)
        return (word >> (j_local * (self.npath * NIN) + path * NIN + (k % NIN))) & 1

    def core_row(self, path: int, j: int) -> list[int]:
        return [self.bit(path, j, k) for k in range(self.din)]


def address_of(
    stripe: int,
    k_chunk: int,
    out_group: int,
    num_banks: int = 1,
    rows_per_stripe: int = 1,
) -> WordAddr:
    """Map (stripe, k_chunk, out_group) to bank / row / column.

    Banks split the dout axis, so a stripe never spans banks and no accumulator
    is ever shared between them. Inside a bank the stripes are laid out one
    after another, each occupying rows_per_stripe consecutive rows, so a stripe's
    whole k sweep finishes before the next stripe begins.
    """

    col = (k_chunk % K_CHUNKS_PER_ROW) * NGROUP + out_group
    bank = stripe % num_banks
    stripe_in_bank = stripe // num_banks
    row = stripe_in_bank * rows_per_stripe + (k_chunk // K_CHUNKS_PER_ROW)
    return WordAddr(
        bank=bank,
        row=row,
        col=col,
        stripe=stripe,
        k_chunk=k_chunk,
        out_group=out_group,
    )


def build_packing(
    weights: Sequence[Sequence[float]],
    scales: Scales | None = None,
    *,
    npath: int = NPATH,
    num_banks: int = 1,
) -> tuple[Packing, Scales]:
    """Binarize and pack a whole weight matrix."""

    dout = len(weights)
    din = len(weights[0])
    if dout % OUT_PER_STRIPE:
        raise ValueError(f"dout {dout} must be a multiple of {OUT_PER_STRIPE}")
    if din % NIN:
        raise ValueError(f"din {din} must be a multiple of {NIN}")

    if scales is None:
        scales = derive_scales(weights, npath=npath)
    cores = binarize(weights, scales, npath=npath)

    n_kchunks = din // NIN
    rows_per_stripe = -(-n_kchunks // K_CHUNKS_PER_ROW)
    packing = Packing(
        dout=dout,
        din=din,
        npath=npath,
        num_banks=num_banks,
        rows_per_stripe=rows_per_stripe,
    )
    for stripe in range(dout // OUT_PER_STRIPE):
        for k_chunk in range(n_kchunks):
            for out_group in range(NGROUP):
                word = 0
                for j_local in range(NOUT):
                    j = stripe * OUT_PER_STRIPE + out_group * NOUT + j_local
                    base_j = j_local * (npath * NIN)
                    for p in range(npath):
                        base = base_j + p * NIN
                        core_row = cores[p][j]
                        for k_local in range(NIN):
                            if core_row[k_chunk * NIN + k_local]:
                                word |= 1 << (base + k_local)
                packing.words[
                    address_of(
                        stripe, k_chunk, out_group, num_banks, rows_per_stripe
                    )
                ] = word
    return packing, scales


# ---------------------------------------------------------------------------
# activations and command schedule
# ---------------------------------------------------------------------------


def pack_activations(
    x: Sequence[float], scales: Scales, *, npath: int = NPATH
) -> list[list[int]]:
    """u_p = h_p (*) x, rounded to binary16. Returns codes[path][din].

    This is the NPU's precomputation, not the PCU's: the PCU never sees h.
    """

    return [
        [fp16_code(scales.h[p][k] * x[k]) for k in range(len(x))]
        for p in range(npath)
    ]


@dataclass(frozen=True)
class Command:
    """One column command in the PCU schedule."""

    kind: str  # "WR", "RD" or "DRAIN"
    entry: int = 0  # WR: GRF entry
    codes: tuple = ()  # WR: NIN binary16 codes
    pair: int = 0  # RD: GRF entry pair
    group: int = 0  # RD/DRAIN: accumulator group
    word: int = 0  # RD: 256-bit column word
    addr: WordAddr | None = None  # RD: where the word came from
    k_chunk: int = 0


def schedule(
    packing: Packing,
    u_codes: Sequence[Sequence[int]],
    *,
    stripes: Sequence[int] | None = None,
) -> Iterator[Command]:
    """Emit the command stream for one or more stripes.

    Per k chunk:  WR u1(k), WR u2(k), RD og0, RD og1, RD og2, RD og3
    which is the 2:4 write-to-read ratio the dataflow assumes. After a stripe's
    whole k sweep, the four accumulator groups drain and the next stripe starts.

    GRF entries are double buffered: chunk c uses pair c % 2, so entries
    {0,1} and {2,3} alternate and a WR never lands on the pair a RD is reading.
    """

    npath = packing.npath
    if stripes is None:
        stripes = range(packing.n_stripes)

    for stripe in stripes:
        for k_chunk in range(packing.n_kchunks):
            pair = k_chunk % 2
            for p in range(npath):
                lo = k_chunk * NIN
                yield Command(
                    kind="WR",
                    entry=pair * npath + p,
                    codes=tuple(u_codes[p][lo:lo + NIN]),
                    k_chunk=k_chunk,
                )
            for out_group in range(NGROUP):
                addr = address_of(
                    stripe,
                    k_chunk,
                    out_group,
                    packing.num_banks,
                    packing.rows_per_stripe,
                )
                yield Command(
                    kind="RD",
                    pair=pair,
                    group=out_group,
                    word=packing.words[addr],
                    addr=addr,
                    k_chunk=k_chunk,
                )
        for out_group in range(NGROUP):
            yield Command(kind="DRAIN", group=out_group)


def outputs_for(stripe: int, group: int) -> range:
    """Which dout indices a drained (stripe, group) beat carries."""

    base = stripe * OUT_PER_STRIPE + group * NOUT
    return range(base, base + NOUT)


# ---------------------------------------------------------------------------
# reference exponent
# ---------------------------------------------------------------------------


def entry_exponent(codes: Sequence[int]) -> int:
    """The shared block exponent the convert unit will pick for one entry."""

    best = 0
    for code in codes:
        exp = (code >> 10) & 0x1F
        e_eff = 1 if exp == 0 else exp
        if e_eff > best:
            best = e_eff
    return best


def choose_e0(u_codes: Sequence[Sequence[int]], *, nin: int = NIN) -> int:
    """Recommended cfg_e0: the largest block exponent over the whole sweep.

    That makes every PE alignment a right shift, so the left-shift saturation
    path stays idle. E0 more than (ACC_W - PSUM_W) = 15 below this value is
    outside the shifter's range and will saturate.
    """

    best = 0
    for path in u_codes:
        for start in range(0, len(path), nin):
            e = entry_exponent(path[start:start + nin])
            if e > best:
                best = e
    return best


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def random_matrix(dout: int, din: int, seed: int) -> list[list[float]]:
    rng = random.Random(seed)
    scale = 1.0 / math.sqrt(din)
    return [[rng.gauss(0.0, scale) for _ in range(din)] for _ in range(dout)]


def _self_test() -> int:
    """Round trip: pack, read the bits back, and check them against binarize()."""

    dout, din = 64, 128
    weights = random_matrix(dout, din, seed=7)
    packing, scales = build_packing(weights, num_banks=2)
    cores = binarize(weights, scales)

    for p in range(NPATH):
        for j in range(dout):
            if packing.core_row(p, j) != cores[p][j]:
                print(f"FAIL: packed bits differ at path {p}, out {j}")
                return 1

    # Address uniqueness and the CA layout. Wider matrices need more than one
    # row per stripe, which is where the row arithmetic actually gets exercised.
    wide, wide_scales = build_packing(random_matrix(64, 1024, seed=9), num_banks=2)
    for packed in (packing, wide):
        seen = set()
        for addr in packed.words:
            key = (addr.bank, addr.row, addr.col)
            if key in seen:
                print(f"FAIL: duplicate address {key}")
                return 1
            seen.add(key)
            if (
                addr.col
                != (addr.k_chunk % K_CHUNKS_PER_ROW) * NGROUP + addr.out_group
            ):
                print(f"FAIL: CA layout broken at {addr}")
                return 1
            if packed.word_at(addr.stripe, addr.k_chunk, addr.out_group) != (
                packed.words[addr]
            ):
                print(f"FAIL: word_at disagrees with the stored address {addr}")
                return 1
    for cmd in schedule(wide, pack_activations([0.5] * 1024, wide_scales)):
        if cmd.kind == "RD" and cmd.word != wide.words[cmd.addr]:
            print(f"FAIL: schedule emitted a word not at {cmd.addr}")
            return 1

    # The schedule keeps the 2:4 write-to-read ratio and drains once per stripe.
    x = [random.Random(11).gauss(0.0, 1.0) for _ in range(din)]
    u_codes = pack_activations(x, scales)
    cmds = list(schedule(packing, u_codes, stripes=[0]))
    n_wr = sum(1 for c in cmds if c.kind == "WR")
    n_rd = sum(1 for c in cmds if c.kind == "RD")
    n_dr = sum(1 for c in cmds if c.kind == "DRAIN")
    if n_rd != 2 * n_wr or n_dr != NGROUP:
        print(f"FAIL: schedule ratio WR={n_wr} RD={n_rd} DRAIN={n_dr}")
        return 1

    # Reconstruction should beat plain sign(W) -- the second path must help.
    err1 = err2 = 0.0
    for j in range(dout):
        for k in range(din):
            approx = sum(
                scales.g[p][j]
                * (-1.0 if packing.bit(p, j, k) else 1.0)
                * scales.h[p][k]
                for p in range(NPATH)
            )
            one = scales.g[0][j] * (
                -1.0 if packing.bit(0, j, k) else 1.0
            ) * scales.h[0][k]
            err2 += (weights[j][k] - approx) ** 2
            err1 += (weights[j][k] - one) ** 2
    if not err2 < err1:
        print(f"FAIL: path 2 did not reduce error ({err2:.6f} >= {err1:.6f})")
        return 1

    print(
        f"self-test OK: {dout}x{din}, {len(packing.words)} words, "
        f"1-path MSE {err1/(dout*din):.6f} -> 2-path {err2/(dout*din):.6f}"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--dout", type=int, default=64)
    parser.add_argument("--din", type=int, default=128)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--banks", type=int, default=1)
    parser.add_argument("--dump-words", type=str, default=None)
    parser.add_argument("--dump-schedule", type=str, default=None)
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    weights = random_matrix(args.dout, args.din, args.seed)
    packing, scales = build_packing(weights, num_banks=args.banks)
    print(
        f"packed {args.dout}x{args.din}: {len(packing.words)} column words, "
        f"{packing.n_stripes} stripes x {packing.n_kchunks} k chunks x {NGROUP} groups"
    )

    if args.dump_words:
        with open(args.dump_words, "w", encoding="utf-8") as handle:
            handle.write("# bank row col stripe k_chunk out_group word_hex\n")
            for addr in sorted(
                packing.words,
                key=lambda a: (a.bank, a.row, a.col),
            ):
                handle.write(
                    f"{addr.bank} {addr.row} {addr.col} {addr.stripe} "
                    f"{addr.k_chunk} {addr.out_group} "
                    f"{packing.words[addr]:064x}\n"
                )
        print(f"wrote {args.dump_words}")

    if args.dump_schedule:
        x = [random.Random(args.seed + 1).gauss(0.0, 1.0) for _ in range(args.din)]
        u_codes = pack_activations(x, scales)
        with open(args.dump_schedule, "w", encoding="utf-8") as handle:
            handle.write(f"# cfg_e0 = {choose_e0(u_codes)}\n")
            for cmd in schedule(packing, u_codes, stripes=[0]):
                if cmd.kind == "WR":
                    codes = "".join(f"{c:04x}" for c in reversed(cmd.codes))
                    handle.write(f"WR {cmd.entry} {codes}\n")
                elif cmd.kind == "RD":
                    handle.write(f"RD {cmd.pair} {cmd.group} {cmd.word:064x}\n")
                else:
                    handle.write(f"DRAIN {cmd.group}\n")
        print(f"wrote {args.dump_schedule}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
