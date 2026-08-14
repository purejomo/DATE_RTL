#!/usr/bin/env python3
"""Data mapping, command schedule and measurement for the full-scale RaBiT PCU.

This is the increment on ``pack_rabit.py``. The weight packing and the column
address map are identical and are imported, not copied; what changes is the
activation side of the schedule and what the drain produces.

    base        NPU sends u_p = h_p (*) x           WR u1, WR u2, RD x4
                PCU returns raw A_1, A_2            NGROUP drain commands
    full scale  NPU sends raw x and raw h           WR h, WR x,   RD x4
                PCU returns finished binary16 y     one drain, 16 port cycles
                plus one g load per stripe          WR_G x4

Two things are measured here rather than asserted, because both are claims the
report has to stand behind:

  throughput  a slot-level simulation of both schedules, counting the column
              slots the bank cannot use, so the g load and the drain stall show
              up as a real ratio instead of an estimate;

  accuracy    the cost of quantizing h to FP8-E4M3, isolated from the cost of
              the PCU datapath, against an exact rational reference.

Usage
    python3 tools/pack_rabit_fs.py --self-test
    python3 tools/pack_rabit_fs.py --throughput --dout 4096 --din 4096
    python3 tools/pack_rabit_fs.py --accuracy --dout 64 --din 256
"""

from __future__ import annotations

import argparse
import os
import random
import sys
from dataclasses import dataclass
from fractions import Fraction
from typing import Iterator, Sequence

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "verif", "models"))

import pack_rabit as base
from pack_rabit import (
    NGROUP,
    NIN,
    NOUT,
    NPATH,
    OUT_PER_STRIPE,
    Packing,
    Scales,
    address_of,
    build_packing,
    fp16_code,
    random_matrix,
)

import rabit_fs_model as fs
from rabit_fs_model import (
    ALIGN_MAX,
    G_WORDS,
    H_FMT_FP8,
    H_FMT_FP16,
    PcuFsGolden,
    fp8_e4m3_code,
    fp8_to_fraction,
    fp16_to_fraction,
    h_scale_chunk,
    relative_errors,
)
from rabit_model import PcuGolden, dequantize

# One column command occupies one column slot, and tCCD_S makes a slot two PCU
# cycles. The dequantizing drain holds the accumulator port for DRAIN_CYCLES
# cycles after its request, which is DRAIN_CYCLES/2 slots the bank loses.
CYCLES_PER_SLOT = 2
DRAIN_PORT_CYCLES = fs.DRAIN_CYCLES


# ---------------------------------------------------------------------------
# scale quantization
# ---------------------------------------------------------------------------


def quantize_h_fp8(scales: Scales) -> list[list[int]]:
    """h_p -> FP8-E4M3 codes, one per input channel per path."""

    return [[fp8_e4m3_code(v) for v in scales.h[p]] for p in range(len(scales.h))]


def quantize_h_fp16(scales: Scales) -> list[list[int]]:
    return [[fp16_code(v) for v in scales.h[p]] for p in range(len(scales.h))]


def quantize_g_fp16(scales: Scales) -> list[list[int]]:
    return [[fp16_code(v) for v in scales.g[p]] for p in range(len(scales.g))]


def choose_e0_fs(
    x_codes: Sequence[int],
    h_codes: Sequence[Sequence[int]],
    h_fmt: int = H_FMT_FP8,
) -> int:
    """The reference exponent for the full-scale variant.

    The PCU forms u itself, so the host can no longer read the block exponent
    off the values it is about to send. It runs the multiply array's model
    instead -- which is cheap, and is what the packer is for.
    """

    best = 0
    for k0 in range(0, len(x_codes), NIN):
        for p in range(len(h_codes)):
            u_codes, _, _ = h_scale_chunk(
                x_codes[k0:k0 + NIN], h_codes[p][k0:k0 + NIN], h_fmt
            )
            for code in u_codes:
                exp = (code >> 10) & 0x1F
                best = max(best, 1 if exp == 0 else exp)
    return best


# ---------------------------------------------------------------------------
# the full-scale command schedule
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class FsCommand:
    """One column command in the full-scale schedule."""

    kind: str            # "WR_G", "WR_H", "WR_X", "RD", "DQ"
    sel: int = 0         # WR_G quarter, WR_H path (H_FMT=1), WR_X GRF pair
    codes: tuple = ()
    pair: int = 0
    group: int = 0
    word: int = 0
    k_chunk: int = 0
    stripe: int = 0


def schedule_fs(
    packing: Packing,
    x_codes: Sequence[int],
    h_codes: Sequence[Sequence[int]],
    g_codes: Sequence[Sequence[int]],
    *,
    stripes: Sequence[int] | None = None,
    h_fmt: int = H_FMT_FP8,
) -> Iterator[FsCommand]:
    """Emit the full-scale command stream.

    Per stripe:  WR_G x G_WORDS,  then the k sweep,  then one DQ.
    Per chunk:   WR_H (x1 for FP8, xNPATH for the binary16 fallback),
                 WR_X, RD og0..og3.

    The h write has to precede the x write of the same chunk: the x write is
    the column slot that consumes the latch.
    """

    if stripes is None:
        stripes = range(packing.n_stripes)

    for stripe in stripes:
        for quarter in range(G_WORDS):
            lo = stripe * OUT_PER_STRIPE + quarter * NOUT
            yield FsCommand(
                kind="WR_G",
                sel=quarter,
                codes=tuple(
                    tuple(g_codes[p][lo:lo + NOUT]) for p in range(packing.npath)
                ),
                stripe=stripe,
            )

        for k_chunk in range(packing.n_kchunks):
            pair = k_chunk % 2
            lo = k_chunk * NIN

            if h_fmt == H_FMT_FP8:
                yield FsCommand(
                    kind="WR_H",
                    sel=0,
                    codes=tuple(
                        tuple(h_codes[p][lo:lo + NIN]) for p in range(packing.npath)
                    ),
                    k_chunk=k_chunk,
                    stripe=stripe,
                )
            else:
                for p in range(packing.npath):
                    yield FsCommand(
                        kind="WR_H",
                        sel=p,
                        codes=(tuple(h_codes[p][lo:lo + NIN]),),
                        k_chunk=k_chunk,
                        stripe=stripe,
                    )

            yield FsCommand(
                kind="WR_X",
                sel=pair,
                codes=(tuple(x_codes[lo:lo + NIN]),),
                pair=pair,
                k_chunk=k_chunk,
                stripe=stripe,
            )

            for out_group in range(NGROUP):
                # word_at() carries rows_per_stripe, which address_of() defaults
                # to 1; a multi-row stripe needs the packing's own value.
                yield FsCommand(
                    kind="RD",
                    pair=pair,
                    group=out_group,
                    word=packing.word_at(stripe, k_chunk, out_group),
                    k_chunk=k_chunk,
                    stripe=stripe,
                )

        yield FsCommand(kind="DQ", stripe=stripe)


# ---------------------------------------------------------------------------
# slot-level cost
# ---------------------------------------------------------------------------


def slot_cost_base(n_kchunks: int, n_stripes: int) -> dict:
    """Column slots the base schedule occupies.

    Per chunk: WR u1, WR u2, RD og0..og3 -- six commands. Per stripe: NGROUP
    drain commands, each NPATH PCU cycles, which is one column slot each.
    """

    write = 2 * n_kchunks * n_stripes
    read = NGROUP * n_kchunks * n_stripes
    drain = NGROUP * n_stripes
    total = write + read + drain
    return {
        "write": write,
        "read": read,
        "g_load": 0,
        "drain_cmd": drain,
        "drain_stall": 0,
        "total_slots": total,
        "total_cycles": total * CYCLES_PER_SLOT,
    }


def slot_cost_fs(n_kchunks: int, n_stripes: int, *, h_fmt: int = H_FMT_FP8) -> dict:
    """Column slots the full-scale schedule occupies.

    The drain is one command plus the DRAIN_PORT_CYCLES the sequencer holds the
    accumulator port, during which the bank cannot issue a column read. The
    three pipeline stages behind it do not block anything and are not counted.
    """

    per_chunk_writes = 2 if h_fmt == H_FMT_FP8 else 1 + NPATH
    write = per_chunk_writes * n_kchunks * n_stripes
    read = NGROUP * n_kchunks * n_stripes
    g_load = G_WORDS * n_stripes
    drain_cmd = n_stripes
    drain_stall = (DRAIN_PORT_CYCLES // CYCLES_PER_SLOT) * n_stripes
    total = write + read + g_load + drain_cmd + drain_stall
    return {
        "write": write,
        "read": read,
        "g_load": g_load,
        "drain_cmd": drain_cmd,
        "drain_stall": drain_stall,
        "total_slots": total,
        "total_cycles": total * CYCLES_PER_SLOT,
    }


def throughput_report(dout: int, din: int, *, h_fmt: int = H_FMT_FP8) -> dict:
    n_kchunks = din // NIN
    n_stripes = dout // OUT_PER_STRIPE
    base_cost = slot_cost_base(n_kchunks, n_stripes)
    fs_cost = slot_cost_fs(n_kchunks, n_stripes, h_fmt=h_fmt)
    ratio = base_cost["total_slots"] / fs_cost["total_slots"]
    return {
        "dout": dout,
        "din": din,
        "k_chunks": n_kchunks,
        "stripes": n_stripes,
        "base": base_cost,
        "fs": fs_cost,
        "throughput_ratio": ratio,
        "g_load_share": fs_cost["g_load"] / fs_cost["total_slots"],
        "drain_stall_share": (fs_cost["drain_stall"] + fs_cost["drain_cmd"])
        / fs_cost["total_slots"],
        "overhead_share": 1.0 - ratio,
    }


def simulate_slots(cmds: Sequence[FsCommand]) -> dict:
    """Walk a real command stream and count the slots it occupies.

    A cross-check on ``slot_cost_fs``: the closed form and the stream have to
    agree, otherwise one of them is wrong about the schedule.
    """

    counts = {"WR_G": 0, "WR_H": 0, "WR_X": 0, "RD": 0, "DQ": 0}
    for cmd in cmds:
        counts[cmd.kind] += 1
    stall = counts["DQ"] * (DRAIN_PORT_CYCLES // CYCLES_PER_SLOT)
    total = sum(counts.values()) + stall
    return {"counts": counts, "drain_stall": stall, "total_slots": total}


# ---------------------------------------------------------------------------
# accuracy
# ---------------------------------------------------------------------------


def _run_base_pcu(packing, cores, u_codes, e0, dout, din):
    """The base variant plus the NPU's dequantization, as floats."""

    model = PcuGolden()
    model.e0 = e0
    n_kchunks = din // NIN
    partials = [[0] * dout for _ in range(NPATH)]

    for stripe in range(packing.n_stripes):
        for k_chunk in range(n_kchunks):
            pair = k_chunk % 2
            lo = k_chunk * NIN
            for p in range(NPATH):
                model.write(pair * NPATH + p, u_codes[p][lo:lo + NIN])
            for out_group in range(NGROUP):
                model.read(packing.word_at(stripe, k_chunk, out_group), out_group, pair)
        for out_group in range(NGROUP):
            for path, values in model.drain(out_group):
                for pe, value in enumerate(values):
                    j = stripe * OUT_PER_STRIPE + out_group * NOUT + pe
                    partials[path][j] = value
    return partials


def accuracy_report(dout: int, din: int, seed: int = 0) -> dict:
    """Compare base, full-scale and the two exact references on one GEMV."""

    weights = random_matrix(dout, din, seed)
    packing, scales = build_packing(weights)
    cores = base.binarize(weights, scales)

    rng = random.Random(seed + 101)
    x = [rng.gauss(0.0, 1.0) for _ in range(din)]
    x_codes = [fp16_code(v) for v in x]

    h_fp16 = quantize_h_fp16(scales)
    h_fp8 = quantize_h_fp8(scales)
    g_fp16 = quantize_g_fp16(scales)

    # ---- exact references -------------------------------------------------
    ref_fp16 = []
    ref_fp8 = []
    for j in range(dout):
        b_paths = [cores[p][j] for p in range(NPATH)]
        g_j = [g_fp16[p][j] for p in range(NPATH)]
        ref_fp16.append(
            float(fs.reference_fp16_h(b_paths, x_codes, h_fp16, g_j))
        )
        ref_fp8.append(float(fs.reference_fp8_h(b_paths, x_codes, h_fp8, g_j)))

    # ---- base variant: NPU forms u in binary16, NPU dequantizes -----------
    u_codes = [
        [fp16_code(float(fp16_to_fraction(h_fp16[p][k])) * x[k]) for k in range(din)]
        for p in range(NPATH)
    ]
    e0_base = base.choose_e0(u_codes)
    partials = _run_base_pcu(packing, cores, u_codes, e0_base, dout, din)
    g_float = [
        [float(fp16_to_fraction(g_fp16[p][j])) for j in range(dout)]
        for p in range(NPATH)
    ]
    y_base = dequantize(partials, g_float, e0_base)

    # ---- full-scale variant: bit-accurate, straight to binary16 -----------
    e0_fs = choose_e0_fs(x_codes, h_fp8)
    model = PcuFsGolden(h_fmt=H_FMT_FP8, align_max=ALIGN_MAX)
    model.e0 = e0_fs
    y_fs = [0.0] * dout
    n_kchunks = din // NIN

    for stripe in range(packing.n_stripes):
        for quarter in range(G_WORDS):
            lo = stripe * OUT_PER_STRIPE + quarter * NOUT
            model.write_g(
                quarter, [g_fp16[p][lo:lo + NOUT] for p in range(NPATH)]
            )
        for k_chunk in range(n_kchunks):
            pair = k_chunk % 2
            lo = k_chunk * NIN
            model.write_h(
                [c for k in range(NIN)
                 for c in (h_fp8[0][lo + k], h_fp8[1][lo + k])]
            )
            model.write_x(pair, x_codes[lo:lo + NIN])
            for out_group in range(NGROUP):
                model.read(packing.word_at(stripe, k_chunk, out_group), out_group, pair)
        for index, code in enumerate(model.dq_drain()):
            y_fs[stripe * OUT_PER_STRIPE + index] = float(fp16_to_fraction(code))

    return {
        "dout": dout,
        "din": din,
        "seed": seed,
        "e0_base": e0_base,
        "e0_fs": e0_fs,
        "fs_sticky": model.fs_sticky,
        "h_format_only": relative_errors(ref_fp8, ref_fp16),
        "fs_vs_fp8_ref": relative_errors(y_fs, ref_fp8),
        "fs_vs_fp16_ref": relative_errors(y_fs, ref_fp16),
        "base_vs_fp16_ref": relative_errors(y_base, ref_fp16),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _self_test() -> int:
    dout, din = 64, 128
    weights = random_matrix(dout, din, seed=5)
    packing, scales = build_packing(weights)
    h_fp8 = quantize_h_fp8(scales)
    g_fp16 = quantize_g_fp16(scales)
    x_codes = [fp16_code(random.Random(3).gauss(0.0, 1.0)) for _ in range(din)]

    cmds = list(schedule_fs(packing, x_codes, h_fp8, g_fp16, stripes=[0]))
    walked = simulate_slots(cmds)
    closed = slot_cost_fs(packing.n_kchunks, 1)
    if walked["total_slots"] != closed["total_slots"]:
        print(
            f"FAIL: schedule walk {walked['total_slots']} != closed form "
            f"{closed['total_slots']}"
        )
        return 1

    counts = walked["counts"]
    if counts["WR_X"] != packing.n_kchunks or counts["WR_H"] != packing.n_kchunks:
        print(f"FAIL: one h and one x write per chunk expected, got {counts}")
        return 1
    if counts["RD"] != NGROUP * packing.n_kchunks:
        print(f"FAIL: RD count {counts['RD']}")
        return 1
    if counts["WR_G"] != G_WORDS or counts["DQ"] != 1:
        print(f"FAIL: per-stripe overhead {counts}")
        return 1

    # The inner loop must be identical to the base one: six commands per chunk.
    inner = counts["WR_H"] + counts["WR_X"] + counts["RD"]
    if inner != 6 * packing.n_kchunks:
        print(f"FAIL: inner loop is {inner} slots, base is {6*packing.n_kchunks}")
        return 1

    # FP8 round trip of the derived scales.
    for p in range(NPATH):
        for code in h_fp8[p]:
            if fs.decode_fp8_e4m3(code).nan:
                print("FAIL: a derived h scale quantized to NaN")
                return 1

    print(
        f"self-test OK: {dout}x{din}, inner loop {inner} slots "
        f"(base {6*packing.n_kchunks}), stripe overhead "
        f"{closed['g_load']} g + {closed['drain_cmd'] + closed['drain_stall']} drain"
    )
    return 0


def _markdown(args) -> int:
    """The accuracy section of the report, as a standalone markdown file."""

    print("# RaBiT full-scale PCU: what the FP8 h format costs")
    print()
    print("Four quantities, all measured against an exact rational reference so")
    print("that no host floating point enters the comparison:")
    print()
    print("| name | what it isolates |")
    print("|---|---|")
    print("| `h_format_only` | quantizing h to FP8-E4M3, everything else exact |")
    print("| `fs_vs_fp8_ref` | the PCU-FS datapath, given the FP8 h it was handed |")
    print("| `fs_vs_fp16_ref` | the two together: PCU-FS against binary16 h |")
    print("| `base_vs_fp16_ref` | the base variant, whose h stays binary16 on the NPU |")
    print()
    print("`fs_vs_fp8_ref` is the honest measure of the hardware; the other rows")
    print("are the cost of the format decision the write budget forced. The L2")
    print("column is the metric to read: a per-output relative error is dominated")
    print("by outputs that land near zero through cancellation, which is why the")
    print("max column is large and uninformative.")
    print()
    print("| shape | seed | quantity | max rel err | mean rel err | L2 rel err |")
    print("|---|---:|---|---:|---:|---:|")

    shapes = [(args.dout, args.din)]
    for dout, din in shapes:
        for seed in range(args.seed, args.seed + args.seeds):
            r = accuracy_report(dout, din, seed)
            for key in (
                "h_format_only",
                "fs_vs_fp8_ref",
                "fs_vs_fp16_ref",
                "base_vs_fp16_ref",
            ):
                worst, mean, l2 = r[key]
                print(f"| {dout} x {din} | {seed} | `{key}` | {worst:.3e} | "
                      f"{mean:.3e} | {l2:.3e} |")
    print()
    print("Reproduce with:")
    print()
    print("```bash")
    print(f"python3 tools/pack_rabit_fs.py --accuracy --dout {args.dout} "
          f"--din {args.din} --seeds {args.seeds}")
    print("```")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--throughput", action="store_true")
    parser.add_argument("--accuracy", action="store_true")
    parser.add_argument("--dout", type=int, default=64)
    parser.add_argument("--din", type=int, default=256)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--seeds", type=int, default=1)
    parser.add_argument("--markdown", action="store_true",
                        help="emit results/rabit_fs_accuracy.md on stdout")
    args = parser.parse_args(argv)

    if args.markdown:
        return _markdown(args)

    if args.self_test:
        return _self_test()

    if args.throughput:
        print(f"{'dout x din':>14}  {'base slots':>11}  {'FS slots':>9}  "
              f"{'g load':>7}  {'drain':>7}  {'FS/base':>8}  {'cost':>7}")
        shapes = [(args.dout, args.din)] if (args.dout and args.din) else []
        for dout, din in shapes:
            r = throughput_report(dout, din)
            print(
                f"{dout:6d} x {din:<5d}  {r['base']['total_slots']:11d}  "
                f"{r['fs']['total_slots']:9d}  "
                f"{r['g_load_share']*100:6.3f}%  "
                f"{r['drain_stall_share']*100:6.3f}%  "
                f"{r['throughput_ratio']*100:7.3f}%  "
                f"{r['overhead_share']*100:6.3f}%"
            )

    if args.accuracy:
        for seed in range(args.seed, args.seed + args.seeds):
            r = accuracy_report(args.dout, args.din, seed)
            print(f"--- seed {seed}: {r['dout']}x{r['din']}, "
                  f"E0 base {r['e0_base']} / FS {r['e0_fs']}, "
                  f"fs_sticky {r['fs_sticky']:#06b}")
            for key in (
                "h_format_only",
                "fs_vs_fp8_ref",
                "fs_vs_fp16_ref",
                "base_vs_fp16_ref",
            ):
                worst, mean, l2 = r[key]
                print(f"    {key:<18} max {worst:.6e}  mean {mean:.6e}  L2 {l2:.6e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
