"""Assemble the compute-only comparison table.

The table this feeds is about arithmetic, so every row is synthesized at a
boundary that contains no register file, no control and no buffers.

Every row includes its accumulator. The base rows all use the same 32-bit
width and the same four registered stages; the acc16 rows deliberately do not,
because narrowing that accumulator is what they exist to price. The accumulator
width is stated per row rather than assumed.

  * The HBM-PIM baseline is a SIMD row of MAC lanes. Each lane multiplies at
    16-bit float and accumulates at binary32 into a register of its own. It
    used to be a combinational multiplier and adder bank with the accumulation
    left in the GRF, which put it at a different boundary from the PCU rows and
    gave it zero sequential area; that is no longer the case.
  * The P3-LLM-organized rows are the PCU. Their accumulators sit inside the
    processing elements and cannot be separated from the arithmetic without
    changing the architecture.

The sequential share is still printed for every row, but it now measures a real
difference in what accumulation costs each organization rather than an artifact
of where the boundary was drawn. The PCU accumulates in fixed point, so its
final stage is a carry-propagate add; the baseline SIMD lanes run a full
binary32 add, with alignment, normalization and rounding, inside the
accumulator loop.
"""

from __future__ import annotations

import csv
import pathlib
import re

C = pathlib.Path(__file__).resolve().parent
R = C.parent / "results"   # area.csv / reports/ / power/ live here
B = C.parent / "build"

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

# The multiplier count is the number of independent scalar products accepted
# per cycle.  A pipelined SIMD lane accepts one product every cycle, and each
# P3-LLM PE accepts four, so MAC/cycle is equal to the multiplier count for
# these rows.  The old table divided that count by two (treating the multiply
# and add as two halves of one MAC) even though the multiplier count had
# already counted complete lanes; that understated throughput by two.
#
# ``adders`` means architectural accumulator lanes, not RTL ``+`` tokens or
# compressor stages.  The SIMD baseline has one accumulator per multiplier.  A
# P3-LLM PE shares one accumulator across its four multipliers, so the 8-PE and 16-PE
# configurations have 8 and 16 accumulator lanes respectively.
#
# The last field is whether the measured boundary contains the accumulator. It
# is now true for every row; the SIMD baseline carries a binary32 accumulator
# per lane and the PCU rows a signed 32-bit fixed-point accumulator per
# processing element. Before the baseline gained one the column read
# "no (in GRF)" and the two halves of the table were not comparable.
ROWS = [
    ("hbm-pim", "FP16",      "SIMD bank",  16,
     "compute_hbmpim_250",       16, 16, 16, 250, True),

    # AWQ INT4 weights in the P3-LLM organization, at both PE counts. The
    # 32-multiplier row is the half-width diagnostic; the 64-multiplier row is
    # operator-count matched to the p3llm and spinquant rows below it, so those
    # three differ only in precision.
    ("awq",     "INT4/BF16", "P3-LLM PCU",  32,
     "int4bf16_pcu32_500",       32,  8, 32, 500, True),
    ("awq",     "INT4/BF16", "P3-LLM PCU",  64,
     "int4bf16_pcu_top_pcu500",  64, 16, 64, 500, True),
    ("p3llm",   "FP4/FP8",   "P3-LLM PCU",  64,
     "p3llm_pcu_500",            64, 16, 64, 500, True),
    # Same 64-MAC raw PCU plus one time-multiplexed dequant pipeline.  The
    # shared scale multipliers are metadata/post-processing hardware and do not
    # increase the accepted low-precision GEMV MAC count.
    ("p3llm",   "FP4/FP8->FP8", "P3-LLM PCU+DQ", 64,
     "p3llm_pcu_dequant_500",    64, 16, 64, 500, True),

    # RaBiT is the one row where the multiplier count and MAC/cycle diverge, so
    # read the two columns separately:
    #
    #   mul = 0      There is no multiplier in the design and there must not be.
    #                A weight is one bit, so the product is the activation
    #                mantissa with a conditional sign flip; g and h scaling
    #                stays with the host.
    #   MAC/cy = 128 8 PEs x 16 inputs signed products are accepted every cycle,
    #                and both pump cycles are productive (path 1 then path 2),
    #                so the rate is sustained rather than peak.
    #
    #   add = 8      Accumulation adder lanes, one per PE, matching how the
    #                other rows count. RaBiT time-multiplexes those 8 lanes over
    #                64 architectural accumulators (4 output groups x 2 paths),
    #                which is why its DFF count is high for its area -- see
    #                results/designs/rabit.md.
    #
    # um2/MAC therefore compares a 2-bit residual-binary product against FP16
    # and INT4 products. That is the same cross-precision comparison the rest of
    # the table already makes; the precision column is what qualifies it.
    #
    # Only the 250 MHz row is listed. The 500 MHz build misses setup by 0.04 ns
    # on the convert path, so it is a sweep point in results/designs/rabit.md
    # rather than a table row.
    ("rabit",   "2-bit RB/FP16", "RaBiT PCU",  128,
     "rabit_pcu_250",             0,  8, 128, 250, True),

    # SpinQuant W4A4. The organization column reads "P3-LLM PCU" because that is
    # what it is: 16 PEs of four multipliers with one accumulator lane per PE,
    # the same topology as the awq and p3llm rows above. Keeping the label the
    # same is the point of the row -- organization held fixed, precision varied,
    # which is the comparison the table exists to make. Here both operands are
    # 4-bit integers and nothing
    # else is left: no format decoder, no exponent alignment, no zero-point
    # subtract, no scale multiply. The rotations are merged into the weights
    # offline, the activation zero point is folded into the NPU bias, and both
    # dequantization scales are applied by the NPU after the drain.
    #
    #   mul    = 64  signed4 x unsigned4, one per PE lane
    #   add    = 16  accumulator lanes, one per PE, matching the other rows
    #   MAC/cy = 64  one MAC command per cycle at tCCD_S, sustained
    #
    # The measured boundary carries more state than the P3-LLM rows do: four
    # accumulator entries per PE instead of one (the GRF reading this design
    # targets) plus the 256-bit bank read latch that makes the 2-pump schedule
    # work. results/designs/spinquant_area_report.md prices both.
    ("spinquant", "INT4/INT4", "P3-LLM PCU", 64,
     "spinquant_pcu_500",        64, 16, 64, 500, True),

    # ---- axis 2: narrowed accumulator ---------------------------------
    #
    # Same organization, same multiplier count, same MAC/cycle as the base row
    # of each family: the multipliers, the alignment/decoders and the
    # compressor tree are bit-identical, and only the accumulator moves from 32
    # bits to 16 with an RNE narrow ahead of it. ``adders`` is unchanged
    # because it counts architectural accumulator *lanes*, not their width; the
    # width shows up in the accumulator column and in the sequential area.
    #
    # RaBiT's acc16 point also drops MANT_W from 12 to 10. That is forced, not
    # chosen: rabit_align_shift requires ACC_W > PSUM_W = MANT_W + 5, so a
    # 16-bit accumulator cannot carry a 12-bit mantissa. The precision column
    # says so.
    ("awq",     "INT4/BF16", "P3-LLM PCU",  32,
     "int4bf16_pcu32_acc16_500",   32,  8, 32, 500, True),
    ("awq",     "INT4/BF16", "P3-LLM PCU",  64,
     "int4bf16_pcu_top_acc16_500", 64, 16, 64, 500, True),
    ("p3llm",   "FP4/FP8",   "P3-LLM PCU",  64,
     "p3llm_pcu_acc16_500",        64, 16, 64, 500, True),
    ("rabit",   "2-bit RB/FP16 m10", "RaBiT PCU", 128,
     "rabit_pcu_acc16_250",         0,  8, 128, 250, True),

    # ---- axis 3: dequantization inside the PU -------------------------
    #
    # The raw PCU is untouched and still drains its INT32 accumulators; what is
    # added is one shared, time-multiplexed engine (a fixed32 x bfloat16
    # multiplier, a binary32 accumulator adder, and a final RNE pack to
    # bfloat16). Like the p3llm_pcu_dequant_500 row above, those shared
    # multipliers are post-processing hardware and do not increase the accepted
    # low-precision GEMV MAC count, so ``muls`` and ``mac_cyc`` stay at the base
    # row's values and um2/MAC stays comparable.
    ("awq",     "INT4/BF16->BF16", "P3-LLM PCU+DQ",  32,
     "int4bf16_pcu32_dq_500",      32,  8, 32, 500, True),
    ("awq",     "INT4/BF16->BF16", "P3-LLM PCU+DQ",  64,
     "int4bf16_pcu_top_dq_500",    64, 16, 64, 500, True),
]


def sequential_area(stat_path: pathlib.Path) -> float:
    if not stat_path.exists():
        return 0.0
    total = 0.0
    for cell, count in re.findall(r"^\s+(\w+)\s+(\d+)\s*$", stat_path.read_text(), re.M):
        if cell in DFF_AREA:
            total += DFF_AREA[cell] * int(count)
    return total


def power_of(top: str, label: str):
    """Return power only when its report is at least as new as the netlist.

    Vectorless power under `set_power_activity -global 0.20`: the same activity
    on every net, no propagation. It gives no credit to a design that toggles
    less, so the column carries an energy comparison only at the ratio level.
    """
    path = R / "power" / f"{top}_power.rpt"
    if not path.exists():
        return None
    netlist = B / "results" / label / "1_synth.v"
    if netlist.exists() and path.stat().st_mtime < netlist.stat().st_mtime:
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
        power = power_of(entry["top"], label)
        rows.append({
            "paper": paper,
            "precision": precision,
            "organization": org,
            "operators": ops,
            "freq_mhz": mhz,
            "total_mul": muls,
            "total_add": adders,
            "mac_per_cycle": mac_cyc,
            "gmac_per_s": f"{gmacs:.1f}",
            "compute_area_um2": f"{area:.1f}",
            "combinational_um2": f"{area - seq:.1f}",
            "sequential_um2": f"{seq:.1f}",
            "um2_per_mac": f"{area / mac_cyc:.0f}",
            "um2_per_gmacs": f"{area / gmacs:.0f}",
            "power_w": f"{power:.4f}" if power else "",
            "pj_per_mac": f"{power / gmacs * 1000:.2f}" if power else "",
            "includes_accumulator": "yes" if has_acc else "no (in GRF)",
            "cells": entry["cells"],
            "dffs": entry["dffs"],
        })

    path = R / "comparison_compute.csv"
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=list(rows[0]), lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {path}\n")

    hdr = (f"{'paper':<9}{'precision':<12}{'organization':<13}{'MHz':>5}"
           f"{'mul':>5}{'add':>5}{'MAC/cy':>7}{'GMAC/s':>8}{'COMPUTE':>10}{'comb':>10}"
           f"{'seq':>9}{'um2/MAC':>9}{'um2/GMACs':>11}"
           f"{'W':>9}{'pJ/MAC':>9}")
    print(hdr); print("-" * len(hdr))
    for r in rows:
        print(f"{r['paper']:<9}{r['precision']:<12}{r['organization']:<13}"
              f"{r['freq_mhz']:>5}"
              f"{r['total_mul']:>5}{r['total_add']:>5}{r['mac_per_cycle']:>7}"
              f"{r['gmac_per_s']:>8}"
              f"{r['compute_area_um2']:>10}{r['combinational_um2']:>10}"
              f"{r['sequential_um2']:>9}{r['um2_per_mac']:>9}"
              f"{r['um2_per_gmacs']:>11}"
              f"{r['power_w']:>9}{r['pj_per_mac']:>9}")
    print()
    print("W / pJ/MAC : vectorless, set_power_activity -global 0.20, uniform")
    print("on every net. Energy is compared at the ratio level only -- a")
    print("stronger claim needs a gate-level VCD, which this flow lacks.")


if __name__ == "__main__":
    main()
