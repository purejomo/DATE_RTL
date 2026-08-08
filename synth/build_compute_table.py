"""Assemble the compute-only comparison table.

The table this feeds is about arithmetic, so every row is synthesized at a
boundary that contains no register file, no control and no buffers.

Two boundaries are unavoidably different in kind, and the table says so rather
than hiding it:

  * The SIMD rows are the multiplier and adder banks alone. They are purely
    combinational and hold no state, because those designs accumulate into the
    GRF, which is excluded here.
  * The P3-LLM-organized rows are the PCU. Their accumulators sit inside the
    processing elements and cannot be separated from the arithmetic without
    changing the architecture, so they are included, as are the pipeline
    registers that let those designs close at 500 MHz.

The sequential share is therefore printed for every row: it is zero for the
SIMD banks and non-zero for the PCUs, which is exactly the architectural
difference the table is trying to show.
"""

from __future__ import annotations

import csv
import pathlib
import re

C = pathlib.Path(__file__).resolve().parent
R = C.parent / "results"   # area.csv / reports/ / power/ live here

# Nangate45 flip-flop cell areas, used to split sequential from combinational.
DFF_AREA = {
    "DFF_X1": 4.522, "DFF_X2": 5.586,
    "DFFR_X1": 5.320, "DFFR_X2": 6.384,
    "DFFS_X1": 5.320, "DFFS_X2": 6.384,
    "DFFRS_X1": 6.118, "DFFRS_X2": 7.182,
    "SDFF_X1": 6.118, "SDFF_X2": 7.182,
    "SDFFR_X1": 6.916, "SDFFR_X2": 7.980,
    "SDFFS_X1": 6.916, "SDFFS_X2": 7.980,
    "SDFFRS_X1": 7.714, "SDFFRS_X2": 8.778,
}

# Two organizations at two operator counts, so the table separates what the
# processing-element organization buys from what more operators buy.
ROWS = [
    ("hbm-pim", "FP16",      "SIMD bank",  16,
     "compute_hbmpim_250",       16, 16,  8, 250, False),

    # Iso-operator-count against the baseline: same lane count, same
    # organization, only the weight operand narrowed. Isolates the cost of the
    # precision change before any lane scaling is credited to it.
    ("awq",     "INT4/FP16", "SIMD bank",  16,
     "int4fp16_compute_16_500",  16, 16,  8, 500, False),
    ("awq",     "INT4/BF16", "SIMD bank",  16,
     "int4bf16_compute_16_500",  16, 16,  8, 500, False),

    ("awq",     "INT4/FP16", "SIMD bank",  32,
     "int4fp16_compute_32_500",  32, 32, 16, 500, False),
    ("awq",     "INT4/BF16", "SIMD bank",  32,
     "int4bf16_compute_32_500",  32, 32, 16, 500, False),
    ("awq",     "INT4/FP16", "P3-LLM PCU",  32,
     "int4fp16_pcu32_500",       32, 32, 16, 500, True),
    ("awq",     "INT4/BF16", "P3-LLM PCU",  32,
     "int4bf16_pcu32_500",       32, 32, 16, 500, True),

    ("awq",     "INT4/FP16", "SIMD bank",  64,
     "int4fp16_compute_64_500",  64, 64, 32, 500, False),
    ("awq",     "INT4/BF16", "SIMD bank",  64,
     "int4bf16_compute_64_500",  64, 64, 32, 500, False),
    ("awq",     "INT4/FP16", "P3-LLM PCU",  64,
     "int4fp16_pcu_top_pcu500",  64, 64, 32, 500, True),
    ("awq",     "INT4/BF16", "P3-LLM PCU",  64,
     "int4bf16_pcu_top_pcu500",  64, 64, 32, 500, True),
    ("p3llm",   "FP4/FP8",   "P3-LLM PCU",  64,
     "p3llm_pcu_500",            64, 64, 32, 500, True),
]

BASELINE_GMACS = 8 * 250e6 / 1e9


def sequential_area(stat_path: pathlib.Path) -> float:
    if not stat_path.exists():
        return 0.0
    total = 0.0
    for cell, count in re.findall(r"^\s+(\w+)\s+(\d+)\s*$", stat_path.read_text(), re.M):
        if cell in DFF_AREA:
            total += DFF_AREA[cell] * int(count)
    return total


def power_of(top: str):
    """Vectorless total power at 0.20 input activity, applied to every row."""
    path = R / "power" / f"{top}_power.rpt"
    if not path.exists():
        return None
    match = re.search(r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)", path.read_text(), re.M)
    return float(match.group(1)) if match else None


def main() -> None:
    measured = {}
    with (R / "area.csv").open() as handle:
        for row in csv.DictReader(handle):
            measured[row["label"]] = row

    rows = []
    for paper, precision, org, ops, label, muls, adders, mac_cyc, mhz, has_acc in ROWS:
        entry = measured.get(label)
        if entry is None:
            print(f"  (missing: {label})")
            continue
        area = float(entry["area_um2"])
        seq = sequential_area(R / "reports" / label / "synth_stat.txt")
        gmacs = mac_cyc * mhz * 1e6 / 1e9
        power = power_of(entry["top"])
        rows.append({
            "paper": paper,
            "precision": precision,
            "organization": org,
            "operators": ops,
            "freq_mhz": mhz,
            "total_mul": muls,
            "total_adder": adders,
            "mac_per_cycle": mac_cyc,
            "gmac_per_s": f"{gmacs:.1f}",
            "throughput_norm": f"{gmacs / BASELINE_GMACS:.1f}",
            "compute_area_um2": f"{area:.1f}",
            "combinational_um2": f"{area - seq:.1f}",
            "sequential_um2": f"{seq:.1f}",
            "um2_per_mac": f"{area / mac_cyc:.0f}",
            "um2_per_gmacs": f"{area / gmacs:.0f}",
            "power_w": f"{power:.4f}" if power else "",
            "pj_per_mac": f"{power / gmacs * 1000:.1f}" if power else "",
            "includes_accumulator": "yes" if has_acc else "no (in GRF)",
            "cells": entry["cells"],
            "dffs": entry["dffs"],
            "wns_ns": entry["wns_ns"],
        })

    path = R / "comparison_compute.csv"
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {path}\n")

    hdr = (f"{'paper':<9}{'precision':<12}{'organization':<13}{'MHz':>5}{'mul':>5}{'add':>5}"
           f"{'MAC/cy':>7}{'GMAC/s':>8}{'norm':>6}{'COMPUTE':>10}{'comb':>10}"
           f"{'seq':>9}{'um2/MAC':>9}{'um2/GMACs':>11}{'Power W':>9}"
           f"{'pJ/MAC':>8}{'WNS':>6}")
    print(hdr); print("-" * len(hdr))
    for r in rows:
        print(f"{r['paper']:<9}{r['precision']:<12}{r['organization']:<13}"
              f"{r['freq_mhz']:>5}"
              f"{r['total_mul']:>5}{r['total_adder']:>5}{r['mac_per_cycle']:>7}"
              f"{r['gmac_per_s']:>8}{r['throughput_norm']+'x':>6}"
              f"{r['compute_area_um2']:>10}{r['combinational_um2']:>10}"
              f"{r['sequential_um2']:>9}{r['um2_per_mac']:>9}"
              f"{r['um2_per_gmacs']:>11}{r['power_w']:>9}{r['pj_per_mac']:>8}"
              f"{r['wns_ns']:>6}")


if __name__ == "__main__":
    main()
