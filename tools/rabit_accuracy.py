#!/usr/bin/env python3
"""Accuracy sweep for the RaBiT PCU at real projection-layer shapes.

The RTL regression (verif, TEST=rabit_pcu*) proves the golden model and the RTL
agree transaction by transaction. This script then drives the same model over
matrices too large to simulate -- 4096x4096 and 11008x4096 -- and reports the
error against an exact reference, so the MANT_W and SHIFTER_EN table in the
paper comes from the same arithmetic the silicon implements.

Two error columns, because they answer different questions:

  quant     ||y_hat - y_fp16|| / ||y_fp16||
            what the whole 2-bit pipeline costs against the unquantized layer.
            Dominated by residual binarization itself, not by the PCU.

  pcu       ||y_hat - y_exact|| / ||y_exact||
            what the PCU's fixed-point datapath costs against an exact
            evaluation of the same binarized weights. This is the number the
            MANT_W / SHIFTER_EN knobs actually move.

Everything streams one output row at a time, so peak memory is O(din) rather
than O(dout*din) and an 11008x4096 sweep fits comfortably.

    python3 tools/rabit_accuracy.py                  # default sweep, markdown
    python3 tools/rabit_accuracy.py --shapes 4096x4096 --seeds 0,1,2
"""

from __future__ import annotations

import argparse
import math
import os
import random
import sys
from fractions import Fraction

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "..", "verif", "models"))

import pack_rabit  # noqa: E402
import rabit_model as rm  # noqa: E402

NIN = pack_rabit.NIN
NPATH = pack_rabit.NPATH


def _fit_row(row, npath, iterations=2):
    """Per-row RaBiT derivation with a fixed h, returning (bits, g) per path.

    Fitting h needs the whole matrix, so a streaming sweep keeps h = 1 and fits
    g per output row. That is the degenerate dual-scale case (XNOR-Net style
    row scaling); it changes how good the *quantization* is, not how the PCU
    behaves, and the PCU column is what this script measures.
    """

    residual = list(row)
    out = []
    for _ in range(npath):
        bits = [1 if value < 0.0 else 0 for value in residual]
        signs = [-1.0 if bit else 1.0 for bit in bits]
        g = sum(residual[k] * signs[k] for k in range(len(row))) / len(row)
        for k in range(len(row)):
            residual[k] -= g * signs[k]
        out.append((bits, g))
    del iterations
    return out


def sweep_one(
    dout: int,
    din: int,
    seed: int,
    *,
    mant_w: int,
    shifter_en: int,
    shift_rnd: int,
    rows: int,
):
    """Run `rows` sampled output rows of a dout x din projection layer."""

    rng = random.Random(seed)
    x = [rng.gauss(0.0, 1.0) for _ in range(din)]
    h = [1.0] * din

    # u_p = h_p (*) x as binary16, exactly what the NPU writes.
    u_codes = [[pack_rabit.fp16_code(h[k] * x[k]) for k in range(din)]
               for _ in range(NPATH)]
    e0 = pack_rabit.choose_e0(u_codes)

    # Convert every k chunk once: the entries are shared by all output rows.
    blocks = []
    for p in range(NPATH):
        per_path = []
        for start in range(0, din, NIN):
            per_path.append(
                rm.convert_block(
                    u_codes[p][start:start + NIN],
                    mant_w=mant_w,
                    shifter_en=shifter_en,
                    e0=e0,
                )
            )
        blocks.append(per_path)

    acc_weight = Fraction(2) ** (e0 - 14 - mant_w)
    psum_w = rm.psum_width(mant_w, NIN)

    num_q = num_p = den_q = den_p = 0.0
    sat = False
    # dout only replicates stripes, so it cannot change the arithmetic. Sampling
    # each shape from its own stream keeps that an observation rather than an
    # artefact of reusing one row set.
    row_rng = random.Random((seed << 24) ^ (dout << 12) ^ din)
    scale = 1.0 / math.sqrt(din)

    for _ in range(rows):
        row = [row_rng.gauss(0.0, scale) for _ in range(din)]
        paths = _fit_row(row, NPATH)

        y_fp = sum(row[k] * x[k] for k in range(din))

        y_exact = 0.0
        y_hat = 0.0
        for p, (bits, g) in enumerate(paths):
            exact = Fraction(0)
            acc = 0
            for chunk, block in enumerate(blocks[p]):
                lo = chunk * NIN
                chunk_bits = bits[lo:lo + NIN]
                exact += rm.exact_path_partial(chunk_bits, u_codes[p][lo:lo + NIN])
                aligned, chunk_sat = rm.align(
                    rm.pe_partial(chunk_bits, block),
                    block.e_ent - e0,
                    psum_w=psum_w,
                    shift_rnd=shift_rnd,
                )
                sat = sat or chunk_sat
                acc = rm.saturate_signed(acc + aligned, rm.ACC_W)
            y_exact += g * float(exact)
            y_hat += g * float(Fraction(acc) * acc_weight)

        num_q += (y_hat - y_fp) ** 2
        den_q += y_fp * y_fp
        num_p += (y_hat - y_exact) ** 2
        den_p += y_exact * y_exact

    # The mean alignment shift is the explanatory variable for the truncating
    # configurations: the arithmetic right shift floors, so every chunk biases
    # the accumulator the same way and the total grows with both the chunk
    # count and this depth. Round-to-nearest flattens it.
    mean_shift = sum(
        e0 - block.e_ent for path in blocks for block in path
    ) / (NPATH * len(blocks[0]))

    return {
        "e0": e0,
        "shift": mean_shift,
        "quant": math.sqrt(num_q / den_q) if den_q else 0.0,
        "pcu": math.sqrt(num_p / den_p) if den_p else 0.0,
        "sat": sat,
    }


CONFIGS = (
    # label, MANT_W, SHIFTER_EN, SHIFT_RND
    ("MANT_W 12, shifter on", 12, 1, 0),
    ("MANT_W 10, shifter on", 10, 1, 0),
    ("MANT_W 12, shifter off", 12, 0, 0),
    ("MANT_W 10, shifter off", 10, 0, 0),
    ("MANT_W 12, shifter on + RNE", 12, 1, 1),
)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--shapes", default="4096x4096,11008x4096")
    parser.add_argument("--seeds", default="0,1,2,3,4")
    parser.add_argument(
        "--rows",
        type=int,
        default=16,
        help="output rows sampled per (shape, seed); the rest only replicate",
    )
    args = parser.parse_args(argv)

    shapes = []
    for item in args.shapes.split(","):
        dout, din = item.lower().split("x")
        shapes.append((int(dout), int(din)))
    seeds = [int(s) for s in args.seeds.split(",")]

    print(
        "| shape | config | mean(E0-e_ent) | PCU rel err (mean) | "
        "PCU rel err (worst seed) | quantization rel err | sat |"
    )
    print("|---|---|---:|---:|---:|---:|:--:|")
    for dout, din in shapes:
        for label, mant_w, shifter_en, shift_rnd in CONFIGS:
            pcu_errs = []
            quant_errs = []
            shifts = []
            sat = False
            for seed in seeds:
                result = sweep_one(
                    dout,
                    din,
                    seed,
                    mant_w=mant_w,
                    shifter_en=shifter_en,
                    shift_rnd=shift_rnd,
                    rows=args.rows,
                )
                pcu_errs.append(result["pcu"])
                quant_errs.append(result["quant"])
                shifts.append(result["shift"])
                sat = sat or result["sat"]
            print(
                f"| {dout}x{din} | {label} | "
                f"{sum(shifts)/len(shifts):.2f} | "
                f"{sum(pcu_errs)/len(pcu_errs):.3e} | "
                f"{max(pcu_errs):.3e} | "
                f"{sum(quant_errs)/len(quant_errs):.3e} | "
                f"{'yes' if sat else 'no'} |"
            )
    print()
    print(
        f"{len(seeds)} seeds x {args.rows} sampled output rows per cell; "
        "errors are L2-relative."
    )
    print()
    print(
        "The worst-seed column is the one to read for the truncating rows: the "
        "arithmetic right shift floors, so its error is a one-sided bias that "
        "grows with mean(E0-e_ent). The `+ RNE` row shows what removing that "
        "bias would buy (proposal P1 in docs/rabit_pcu_spec.md); it is not the "
        "delivered default."
    )
    print()
    print(
        "These rows hold h = 1 (see _fit_row), which keeps the block exponents "
        "close together. Trained per-input-channel h spreads them further and "
        "pushes E0 up, so the truncating rows get worse while the RNE row does "
        "not: the RTL regression, whose stimulus comes from the packer's fitted "
        "h, sees 7.6e-4 to 3.8e-3 at MANT_W 12 for exactly this reason."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
