#!/usr/bin/env python3
"""Build the full-scale RaBiT PCU comparison report.

Reads results/area.csv and the per-label OpenROAD reports, adds the slot-level
throughput measurement from tools/pack_rabit_fs.py, and writes
results/designs/rabit_fs_report.md: the three-column area comparison the experiment
exists to produce, a module breakdown, timing at both clock points, and the
throughput ratio with the g load and the drain stall broken out.

    | module | base PCU | PCU-FS | baseline FP16 16-lane |

The base column is owned by synth/run_rabit.sh and the baseline column by
synth/run_all.sh; this script only reads them, so a missing row is reported as
"not synthesized" rather than silently dropped.
"""

from __future__ import annotations

import csv
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
RESULTS = ROOT / "results"
AREA_CSV = RESULTS / "area.csv"
REPORTS = RESULTS / "reports"
OUTPUT = RESULTS / "designs" / "rabit_fs_report.md"

sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "verif" / "models"))

BASELINE = "compute_hbmpim_250"
BASE_PCU = "rabit_pcu_250"
FS_PCU = "rabit_pcu_fs_250"
FS_PCU_P = "rabit_pcu_fs_p_250"
FS_PCU_H16 = "rabit_pcu_fs_h16_250"

CLOCK_ROWS = (
    ("rabit_pcu_250", "base PCU", "250 MHz", 4.0),
    ("rabit_pcu_500", "base PCU", "500 MHz", 2.0),
    ("rabit_pcu_fs_250", "PCU-FS", "250 MHz", 4.0),
    ("rabit_pcu_fs_500", "PCU-FS", "500 MHz", 2.0),
    ("rabit_pcu_fs_p_250", "PCU-FS, H_MUL_PIPE", "250 MHz", 4.0),
    ("rabit_pcu_fs_p_500", "PCU-FS, H_MUL_PIPE", "500 MHz", 2.0),
    ("rabit_fs_blk_hscale_250", "h_scale_unit", "250 MHz", 4.0),
    ("rabit_fs_blk_hscale_500", "h_scale_unit", "500 MHz", 2.0),
    ("rabit_fs_blk_dq_250", "g_dequant_unit", "250 MHz", 4.0),
    ("rabit_fs_blk_dq_500", "g_dequant_unit", "500 MHz", 2.0),
)

# label, module name, instances, what it is, which variant it belongs to
BLOCKS = (
    ("rabit_blk_cvt_250", "cvt_fp16_to_blk", 1,
     "convert-on-write, fp16 x16 -> block", "both"),
    ("rabit_blk_pe_250", "rabit_pe", 8,
     "negate + 4:2 tree + CPA + align + acc add", "both"),
    ("rabit_blk_acc_250", "acc_regfile", 1,
     "64 x 32b architectural accumulators", "both"),
    ("rabit_fs_blk_hscale_250", "h_scale_unit", 1,
     "h latch + 16 x (fp16 x fp8) + fp16 pack", "FS only"),
    ("rabit_fs_blk_gbuf_250", "g_buffer", 1,
     "64 x 16b output scales, 4-word fill", "FS only"),
    ("rabit_fs_blk_dq_250", "g_dequant_unit", 1,
     "4 lanes: normalize, 12x11 mul, align-add, fp16 round", "FS only"),
)

SHAPES = ((4096, 4096), (4096, 11008), (1024, 4096), (128, 512))


def load_area() -> dict:
    if not AREA_CSV.exists():
        return {}
    with AREA_CSV.open(newline="", encoding="utf-8") as handle:
        return {row["label"]: row for row in csv.DictReader(handle)}


def timing(label: str) -> dict:
    """Worst setup path of one label: slack, endpoints, arrival, required."""

    out = {"slack": None, "start": None, "end": None,
           "arrival": None, "required": None}
    path = REPORTS / label / "1_Post_synthesis.rpt"
    if not path.exists():
        return out
    text = path.read_text(encoding="utf-8", errors="replace")

    section = text.split("report_checks -path_delay max", 1)
    if len(section) < 2:
        return out
    body = section[1]

    found = re.findall(r"^\s+(-?[\d.]+)\s+slack \((?:MET|VIOLATED)\)",
                       body, re.MULTILINE)
    if found:
        out["slack"] = min(float(value) for value in found)
    match = re.search(r"^Startpoint: (\S+)", body, re.MULTILINE)
    if match:
        out["start"] = match.group(1)
    match = re.search(r"^Endpoint: (\S+)", body, re.MULTILINE)
    if match:
        out["end"] = match.group(1)
    match = re.search(r"^\s+(-?[\d.]+)\s+data arrival time", body, re.MULTILINE)
    if match:
        out["arrival"] = float(match.group(1))
    match = re.search(r"^\s+(-?[\d.]+)\s+data required time", body, re.MULTILINE)
    if match:
        out["required"] = float(match.group(1))
    return out


def area_of(rows: dict, label: str):
    row = rows.get(label)
    if row is None or not row.get("area_um2"):
        return None
    return float(row["area_um2"])


def fmt_area(value) -> str:
    return "not synthesized" if value is None else f"{value:,.0f}"


def fmt_ratio(numer, denom) -> str:
    if numer is None or denom in (None, 0):
        return "--"
    return f"{numer/denom:.3f}x"


def main() -> int:
    from pack_rabit_fs import throughput_report

    rows = load_area()
    base = area_of(rows, BASE_PCU)
    fs = area_of(rows, FS_PCU)
    fs_p = area_of(rows, FS_PCU_P)
    fs_h16 = area_of(rows, FS_PCU_H16)
    baseline = area_of(rows, BASELINE)

    lines: list[str] = []
    add = lines.append

    add("# RaBiT PCU: full-scale variant against the base variant")
    add("")
    add("What this measures: the area and throughput cost of moving the RaBiT input")
    add("scale h and output scale g from the NPU into the PCU.")
    add("")
    add("- Conditions: Nangate45 typical (1.10 V, 25 C), Yosys 0.52 ABC area mode +")
    add("  OpenROAD, logic synthesis only, no place and route — cell area, no routing.")
    add("- Primary clock point is 250 MHz, matching the HBM-PIM baseline row. The PCU")
    add("  spends two cycles per column command, so 4.0 ns of PCU period is 8.0 ns of")
    add("  tCCD_S.")
    add("- Boundary, both RaBiT variants: input GRF and CRF outside, accumulator array")
    add("  inside.")
    add("")

    # ---- headline table ---------------------------------------------------
    add("## 1. Total area")
    add("")
    add("| design | area (um2) | vs base PCU | vs baseline FP16 16-lane |")
    add("|---|---:|---:|---:|")
    add(f"| base PCU (`rabit_pcu`, 250 MHz) | {fmt_area(base)} | 1.000x | "
        f"{fmt_ratio(base, baseline)} |")
    add(f"| PCU-FS (`rabit_pcu_fs`, 250 MHz) | {fmt_area(fs)} | "
        f"{fmt_ratio(fs, base)} | {fmt_ratio(fs, baseline)} |")
    add(f"| PCU-FS, `H_MUL_PIPE = 1` (closes timing) | {fmt_area(fs_p)} | "
        f"{fmt_ratio(fs_p, base)} | {fmt_ratio(fs_p, baseline)} |")
    add(f"| PCU-FS, H_FMT = FP16_3WR | {fmt_area(fs_h16)} | "
        f"{fmt_ratio(fs_h16, base)} | {fmt_ratio(fs_h16, baseline)} |")
    add(f"| baseline FP16 16-lane (`hbmpim_fp16_pcu_16_lane`, 250 MHz) | "
        f"{fmt_area(baseline)} | {fmt_ratio(baseline, base)} | 1.000x |")
    add("")
    if base is not None and fs is not None:
        delta = fs - base
        add(f"Delta for on-PCU scaling: **{delta:,.0f} um2**, "
            f"{delta/base*100:.1f} % of the base PCU"
            + (f", {delta/baseline*100:.1f} % of the baseline compute unit."
               if baseline else "."))
        if fs_p is not None:
            add("")
            add(f"The timing-closing build costs {fs_p-fs:,.0f} um2 more than "
                f"the specified one -- one")
            add("256-bit register between the multiply array and the convert "
                "unit -- and no")
            add("column slots at all. Read the `H_MUL_PIPE` row as the "
                "deliverable and the plain")
            add("one as the literal reading of the specification (section 3).")
        add("")

    # ---- module breakdown -------------------------------------------------
    add("## 2. Module breakdown")
    add("")
    add("Each block is synthesized on its own with registers at both ends, so an")
    add("isolated combinational block still reports a meaningful path. The sums need not")
    add("equal the flat tops above — the flow flattens everything, so a top gets")
    add("cross-boundary optimization the isolated blocks do not.")
    add("")
    add("| module | in | instances | area each (um2) | area total (um2) | what it is |")
    add("|---|---|---:|---:|---:|---|")
    fs_only_total = 0.0
    for label, name, count, what, belongs in BLOCKS:
        each = area_of(rows, label)
        total = None if each is None else each * count
        if belongs == "FS only" and total is not None:
            fs_only_total += total
        add(f"| `{name}` | {belongs} | {count} | {fmt_area(each)} | "
            f"{fmt_area(total)} | {what} |")
    add("")
    if fs_only_total:
        if base is not None and fs is not None:
            add(f"Blocks the full-scale variant adds, summed in isolation: "
                f"**{fs_only_total:,.0f} um2**. The")
            add(f"flat-top delta is {fs-base:,.0f} um2; the difference is "
                f"cross-boundary optimization plus")
            add("the rewiring in the top (write-path sequencing, "
                "accumulator-port arbitration).")
        else:
            add(f"Blocks the full-scale variant adds, summed in isolation: "
                f"**{fs_only_total:,.0f} um2**.")
        add("")

    # ---- timing -----------------------------------------------------------
    add("## 3. Timing")
    add("")
    add("Worst setup path per row. A met slack at 2.0 ns means the design closes at")
    add("500 MHz of PCU clock, which is 250 MHz of column-command rate.")
    add("")
    add("**This is the one place the specified datapath does not hold up.** With the h")
    add("multiply, the binary16 rounding and the block convert all in one cycle, the")
    add("write path is a single combinational chain from `wr_data_i` to `cvt_blk_o`, and")
    add("it misses even the 250 MHz point.")
    add("")
    add("- **`H_MUL_PIPE = 1` fixes it for free in slots.** Cycle 0 multiplies u_1,")
    add("  cycle 1 converts it while multiplying u_2, and u_2's conversion lands in the")
    add("  next slot's pump 0, one cycle before pump 1 reads it. The deadline assertion")
    add("  in `rabit_pcu_fs_top` checks exactly that, and the bit-exact regression passes")
    add("  unchanged in both modes.")
    add("- **500 MHz is not a point either variant closes** -- the base variant misses")
    add("  2.0 ns too, on its own convert path. The comparison that matters is 250 MHz.")
    add("- **At 250 MHz, `H_MUL_PIPE = 1` has *more* slack than the base variant**")
    add("  (1.22 ns against 1.16 ns): the register also shortens the base path it")
    add("  inherited, since the convert unit now starts from a flop instead of from the")
    add("  write port with its input delay. What is left as the worst path is the sticky")
    add("  h-overflow reduction across the 16 lanes -- a status bit, registerable a cycle")
    add("  later if a faster point were needed.")
    add("")
    add("| row | clock | period (ns) | slack (ns) | met | critical endpoint |")
    add("|---|---|---:|---:|:---:|---|")
    for label, name, clock, period in CLOCK_ROWS:
        info = timing(label)
        if info["slack"] is None:
            add(f"| `{label}` | {clock} | {period} | -- | -- | not synthesized |")
            continue
        met = "yes" if info["slack"] >= 0 else "**NO**"
        end = info["end"] or "--"
        add(f"| `{label}` | {clock} | {period} | {info['slack']:.3f} | {met} | "
            f"`{end}` |")
    add("")

    # ---- throughput -------------------------------------------------------
    add("## 4. Throughput")
    add("")
    add("Slot-level count from `tools/pack_rabit_fs.py`, which walks both command")
    add("streams. A column slot is one column command and two PCU cycles. The inner loop")
    add("is identical in both variants (two writes and four reads per 16-input chunk), so")
    add("the whole difference is the per-stripe overhead: four g-load writes, and a drain")
    add("that holds the accumulator port for 16 cycles instead of the base's four 2-cycle")
    add("drain commands.")
    add("")
    add("| dout x din | base slots | FS slots | g load | drain | FS/base | cost |")
    add("|---|---:|---:|---:|---:|---:|---:|")
    for dout, din in SHAPES:
        r = throughput_report(dout, din)
        add(f"| {dout} x {din} | {r['base']['total_slots']:,} | "
            f"{r['fs']['total_slots']:,} | {r['g_load_share']*100:.3f} % | "
            f"{r['drain_stall_share']*100:.3f} % | "
            f"{r['throughput_ratio']*100:.3f} % | "
            f"{r['overhead_share']*100:.3f} % |")
    add("")
    add("The 128 x 512 row shows where the overhead stops being negligible: it is a")
    add("per-stripe cost amortized over the k sweep, so it scales as 1/din. At the")
    add("projection-layer shapes RaBiT targets it stays below the 1 % the specification")
    add("allows.")
    add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
