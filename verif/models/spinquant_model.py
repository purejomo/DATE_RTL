"""Bit-accurate, integer-only golden model for the SpinQuant W4A4 PIM PCU.

Everything here is pure Python integer arithmetic. There is no host floating
point anywhere, which is the point: the design under test is an integer
dot-product engine, so a match is a statement about the RTL rather than about
the simulator's FPU.

Geometry (rtl/5_spinquant/spinquant_pcu_top.sv defaults)

    NPE     16   output channels per 256-bit bank beat
    NWAY     4   k-elements per output channel per beat
    NENTRY   4   accumulator entries = 2 input rows x 2 output-channel groups
    ACC_W   32   architectural accumulator register width
    CHAIN_W 24   carry chain actually implemented inside that register

Numeric contract. The PCU computes only the integer dot product

    acc[e][i] += sum_j W_q[i][j] * A_q[j]      W_q signed, A_q unsigned

The SpinQuant dequantization

    W . A~ = s_a * (W_q . A_q) + beta * sum(W_row)

is finished by the NPU: s_w (per output channel), s_a (per token) and the
beta * sum(W_row) bias term never enter this model because they never enter the
hardware.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

NPE = 16
NWAY = 4
NENTRY = 4
ACC_W = 32
ACC_CHAIN_W = 24
Q_W = 4
PROD_W = 8
PSUM_W = 10

# A MAC driven in testbench iteration t updates its accumulator entry on the
# edge that ends iteration t+1: stage 1 registers the reduced partial sum,
# stage 2 registers the accumulate. mac_done_o rises on the same edge.
PIPELINE_EDGE_LATENCY = 1

W_MIN = -(1 << (Q_W - 1))       # -8
W_MAX = (1 << (Q_W - 1)) - 1    #  7
A_MIN = 0
A_MAX = (1 << Q_W) - 1          # 15

# The most negative product a beat can hold, used by the corner cases.
PROD_MIN = W_MIN * A_MAX        # -120
PROD_MAX = W_MAX * A_MAX        #  105


def wrap_signed(value: int, width: int) -> int:
    """Reduce ``value`` to ``width``-bit two's complement, as the RTL does."""

    mask = (1 << width) - 1
    value &= mask
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def _check_len(values: Sequence, length: int, name: str) -> None:
    if len(values) != length:
        raise ValueError(f"{name} must hold {length} elements, got {len(values)}")


def _check_weight(value: int, name: str) -> int:
    if not (W_MIN <= value <= W_MAX):
        raise ValueError(f"{name}={value} is not a signed INT4 weight")
    return value


def _check_activation(value: int, name: str) -> int:
    if not (A_MIN <= value <= A_MAX):
        raise ValueError(f"{name}={value} is not an unsigned INT4 activation")
    return value


# --------------------------------------------------------------------------
# bus packing -- mirrors the RTL's `index*width +: width` slicing exactly
# --------------------------------------------------------------------------


def pack_beat(weights: Sequence[Sequence[int]], npe: int = NPE,
              nway: int = NWAY) -> int:
    """Pack ``weights[pe][way]`` into one ``NPE*NWAY*4``-bit bank beat."""

    _check_len(weights, npe, "weights")
    mask = (1 << Q_W) - 1
    packed = 0
    for pe, lanes in enumerate(weights):
        _check_len(lanes, nway, f"weights[{pe}]")
        for way, value in enumerate(lanes):
            _check_weight(value, f"weights[{pe}][{way}]")
            packed |= (value & mask) << ((pe * nway + way) * Q_W)
    return packed


def pack_acts(acts: Sequence[int]) -> int:
    """Pack a flat activation slice into the bus the input GRF select drives.

    One row is ``NWAY`` codes. With ``NROW`` rows sharing a weight beat the
    caller passes them flattened row-major, matching the RTL's
    ``(r*NWAY + j)*Q_W`` slicing.
    """

    packed = 0
    for index, value in enumerate(acts):
        _check_activation(value, f"acts[{index}]")
        packed |= value << (index * Q_W)
    return packed


def flatten_rows(act_rows: Sequence[Sequence[int]]) -> list[int]:
    """Row-major flatten of ``act_rows[row][way]`` for :func:`pack_acts`."""

    flat: list[int] = []
    for row in act_rows:
        flat.extend(row)
    return flat


def unpack_drain(value: int, nlane: int = NPE, acc_w: int = ACC_W) -> tuple[int, ...]:
    """Split one drain word into ``nlane`` signed accumulators.

    Lane ``r*NPE + i`` is input row ``r``, output channel ``i``.
    """

    mask = (1 << acc_w) - 1
    return tuple(
        wrap_signed((value >> (lane * acc_w)) & mask, acc_w) for lane in range(nlane)
    )


# --------------------------------------------------------------------------
# reference arithmetic
# --------------------------------------------------------------------------


def dot_w4a4(weights: Sequence[int], acts: Sequence[int]) -> int:
    """One PE partial sum: exact, unbounded Python integers."""

    _check_len(weights, len(acts), "weights")
    return sum(
        _check_weight(w, "weight") * _check_activation(a, "activation")
        for w, a in zip(weights, acts)
    )


def gemv_w4a4(weights: Sequence[Sequence[int]],
              acts: Sequence[int]) -> tuple[int, ...]:
    """int32 GEMV reference: ``out[i] = sum_k W_q[i][k] * A_q[k]``.

    This is the reference the whole design is measured against. It knows
    nothing about beats, entries or pipelines.
    """

    return tuple(dot_w4a4(row, acts) for row in weights)


def tile_to_beats(weights: Sequence[Sequence[int]],
                  act_rows: Sequence[Sequence[int]],
                  npe: int = NPE, nway: int = NWAY):
    """Cut a ``[npe x K]`` weight tile into the beat stream the bank returns.

    Beat ``b`` carries ``weights[i][nway*b : nway*(b+1)]`` for every output
    channel ``i``, which is the DRAM mapping documented in
    docs/spinquant_pcu_spec.md: one 16-channel group's k stream laid out
    contiguously along a row so an ACT is followed by row-buffer-hit RDs.

    ``act_rows`` is one activation vector per input row sharing the beat, so
    the yielded activation slice is ``[row][way]``. A single-row design passes
    a one-element list.
    """

    _check_len(weights, npe, "weights")
    if not act_rows:
        raise ValueError("act_rows must hold at least one activation vector")
    k = len(act_rows[0])
    if k % nway:
        raise ValueError(f"K={k} must be a multiple of NWAY={nway}")
    for pe, row in enumerate(weights):
        _check_len(row, k, f"weights[{pe}]")
    for index, row in enumerate(act_rows):
        _check_len(row, k, f"act_rows[{index}]")
    for beat in range(k // nway):
        lo = beat * nway
        yield (
            [list(row[lo:lo + nway]) for row in weights],
            [list(row[lo:lo + nway]) for row in act_rows],
        )


# --------------------------------------------------------------------------
# stateful PCU model
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class MacResult:
    """Post-update state of the entry one MAC command touched."""

    entry: int
    acc: tuple[int, ...]
    overflow: bool


class SpinQuantPcu:
    """The NENTRY x (NROW*NPE) accumulator file and the arithmetic feeding it.

    ``nrow`` is how many activation rows share one weight beat spatially. Every
    such row keeps partial sums of its own, which is why the accumulator file
    -- not the multiplier array -- is what scaling throughput actually costs.
    """

    def __init__(self, npe: int = NPE, nway: int = NWAY, nrow: int = 1,
                 nentry: int = NENTRY, acc_w: int = ACC_W,
                 chain_w: int = ACC_CHAIN_W) -> None:
        if chain_w > acc_w:
            raise ValueError("chain_w must not exceed acc_w")
        self.npe = npe
        self.nway = nway
        self.nrow = nrow
        self.nlane = nrow * npe
        self.nentry = nentry
        self.acc_w = acc_w
        self.chain_w = chain_w
        self.acc = [[0] * self.nlane for _ in range(nentry)]
        self.ovf_sticky = False

    def reset(self) -> None:
        self.acc = [[0] * self.nlane for _ in range(self.nentry)]
        self.ovf_sticky = False

    def status_clear(self) -> None:
        self.ovf_sticky = False

    def read(self, entry: int) -> tuple[int, ...]:
        """What drain_data_o shows for ``entry``.

        The stored pattern is the sign extension of the chain, so the signed
        32-bit value the bus carries equals the chain value itself.
        """

        return tuple(self.acc[entry])

    def mac(self, weights: Sequence[Sequence[int]],
            act_rows: Sequence[Sequence[int]],
            entry: int, clear: bool) -> MacResult:
        """Accept one MAC command and return the entry it updated.

        ``act_rows`` is ``[row][way]``; lane ``row*npe + pe`` accumulates
        ``weights[pe] . act_rows[row]``.
        """

        _check_len(weights, self.npe, "weights")
        _check_len(act_rows, self.nrow, "act_rows")
        if not (0 <= entry < self.nentry):
            raise ValueError(f"entry {entry} is outside 0..{self.nentry - 1}")

        overflow = False
        current = self.acc[entry]
        updated = []
        for row in range(self.nrow):
            _check_len(act_rows[row], self.nway, f"act_rows[{row}]")
            for pe in range(self.npe):
                _check_len(weights[pe], self.nway, f"weights[{pe}]")
                psum = dot_w4a4(weights[pe], act_rows[row])
                # The reduction tree is exact by construction; assert the bound
                # the RTL's width proof relies on rather than wrapping here.
                if psum != wrap_signed(psum, PSUM_W):
                    raise OverflowError(
                        f"partial sum {psum} does not fit {PSUM_W} bits")
                lane = row * self.npe + pe
                if clear:
                    updated.append(wrap_signed(psum, self.chain_w))
                else:
                    raw = current[lane] + psum
                    wrapped = wrap_signed(raw, self.chain_w)
                    if wrapped != raw:
                        overflow = True
                    updated.append(wrapped)

        self.acc[entry] = updated
        self.ovf_sticky = self.ovf_sticky or overflow
        return MacResult(entry=entry, acc=tuple(updated), overflow=overflow)
