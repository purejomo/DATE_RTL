#!/usr/bin/env python3
"""Build the RaBiT PCU area and timing report from the synthesis results.

Reads results/area.csv and the per-label OpenROAD reports, then writes
results/rabit_area_report.md: the comparison against the HBM-PIM baseline
compute unit, a module-level breakdown, and the MANT_W / SHIFTER_EN sweep.
"""

from __future__ import annotations

import csv
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
RESULTS = ROOT / "results"
AREA_CSV = RESULTS / "area.csv"
REPORTS = RESULTS / "reports"
OUTPUT = RESULTS / "rabit_area_report.md"

BASELINE = "compute_hbmpim_250"

MAIN = (
    ("rabit_pcu_250", "RaBiT PCU, 8 PE, MANT_W 12, shifter on", "250 MHz"),
    ("rabit_pcu_500", "RaBiT PCU, 8 PE, MANT_W 12, shifter on", "500 MHz"),
)

SWEEP = (
    ("rabit_pcu_250", "12", "on"),
    ("rabit_pcu_m10_250", "10", "on"),
    ("rabit_pcu_noshift_250", "12", "off"),
    ("rabit_pcu_m10_noshift_250", "10", "off"),
)

BLOCKS = (
    ("rabit_blk_cvt_250", "cvt_fp16_to_blk", "1", "convert-on-write, fp16x16 -> block"),
    ("rabit_blk_pe_250", "rabit_pe", "8", "negate + 4:2 tree + CPA + shift + acc add"),
    ("rabit_blk_acc_250", "acc_regfile", "1", "64 x 32b architectural accumulators"),
)


def load_area() -> dict:
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


def fmt(value, spec="{:.1f}"):
    return "n/a" if value is None else spec.format(value)


def main() -> None:
    area = load_area()
    if BASELINE not in area:
        raise SystemExit(f"{AREA_CSV}: baseline row {BASELINE} is missing")
    base = float(area[BASELINE]["area_um2"])

    lines: list[str] = []
    add = lines.append

    add("# RaBiT 2-bit PIM 연산기 (PCU) — 면적 · 타이밍 리포트")
    add("")
    add("`synth/run_rabit.sh` 가 생성한다. 측정 조건은 다른 행과 동일하다:")
    add("Nangate45 typical corner, Yosys 0.52 (ABC area mode) + OpenROAD,")
    add("논리 합성까지 (P&R 미수행).")
    add("")
    add("## 1. baseline 대비")
    add("")
    add("비교 대상은 HBM-PIM FP16 16-lane SIMD 연산부")
    add(f"(`{area[BASELINE]['top']}`, {base:,.0f} um2 @ "
        f"{area[BASELINE]['clock_ns']} ns).")
    add("두 설계 모두 곱셈기·가산기·32-bit 누산기를 포함하고 GRF/CRF·버퍼·")
    add("bank 인터페이스는 제외한다. RaBiT 쪽은 누산기 배열 64 x 32b 가")
    add("경계 안에 있다 — stripe 하나의 k sweep 동안 32 output x 2 path 를")
    add("상주시켜야 하므로 버퍼가 아니라 산술 상태다.")
    add("")
    add("| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |")
    add("|---|---|---:|---:|---:|---:|---:|---:|")
    row = area[BASELINE]
    setup, _ = slack(BASELINE)
    add(f"| HBM-PIM FP16 SIMD 16 lane | `{row['top']}` | {row['clock_ns']} ns | "
        f"{float(row['area_um2']):,.0f} | 1.000x | {row['cells']} | {row['dffs']} | "
        f"{fmt(setup, '{:+.2f}')} |")
    for label, description, target in MAIN:
        if label not in area:
            continue
        row = area[label]
        setup, _ = slack(label)
        ratio = float(row["area_um2"]) / base
        add(f"| {description} ({target}) | `{row['top']}` | {row['clock_ns']} ns | "
            f"{float(row['area_um2']):,.0f} | {ratio:.3f}x | {row['cells']} | "
            f"{row['dffs']} | {fmt(setup, '{:+.2f}')} |")
    add("")

    if "rabit_pcu_250" in area:
        delivered = float(area["rabit_pcu_250"]["area_um2"])
        verdict = "충족" if delivered < base else "미충족"
        add(f"**면적 제약 {verdict}**: {delivered:,.0f} um2 < {base:,.0f} um2 "
            f"(baseline의 {delivered/base*100:.1f} %, "
            f"{base-delivered:,.0f} um2 절감).")
        add("")

    add("### 타이밍")
    add("")
    add("PCU 는 column command 하나당 2 cycle 을 쓴다 (2-pump). 따라서 PCU 주기")
    add("4.0 ns 는 tCCD_S 8.0 ns 에 해당하고, 2.0 ns 는 tCCD_S 4.0 ns 다.")
    add("")

    add("## 2. 모듈별 면적")
    add("")
    add("각 블록을 따로 합성한 값이다. flat top 은 경계를 넘는 최적화를 받으므로")
    add("합계가 top 면적과 정확히 같지는 않다.")
    add("")
    add("| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |")
    add("|---|---:|---:|---:|---:|---|")
    total = 0.0
    for label, name, count, description in BLOCKS:
        if label not in area:
            continue
        row = area[label]
        unit = float(row["area_um2"])
        n = int(count)
        total += unit * n
        add(f"| `{name}` | {n} | {unit:,.0f} | {unit*n:,.0f} | {row['dffs']} | "
            f"{description} |")
    if total and "rabit_pcu_250" in area:
        flat = float(area["rabit_pcu_250"]["area_um2"])
        add(f"| **소계** | | | **{total:,.0f}** | | |")
        add(f"| 시퀀서 · 배선 · 경계 최적화 차분 | | | {flat-total:+,.0f} | | "
            f"flat top {flat:,.0f} um2 와의 차 |")
    add("")

    add("## 3. MANT_W / SHIFTER_EN 스윕")
    add("")
    add("정확도는 `python3 tools/rabit_accuracy.py` 가 같은 golden model 로")
    add("4096x4096 · 11008x4096 에서 측정한다. 아래는 면적만이다.")
    add("")
    add("| MANT_W | SHIFTER_EN | 면적 (um2) | 기본 구성 대비 | baseline 대비 | DFF |")
    add("|---:|:--:|---:|---:|---:|---:|")
    reference = float(area["rabit_pcu_250"]["area_um2"]) if "rabit_pcu_250" in area else None
    for label, mant, shifter in SWEEP:
        if label not in area:
            continue
        row = area[label]
        value = float(row["area_um2"])
        delta = f"{value-reference:+,.0f}" if reference else "n/a"
        add(f"| {mant} | {shifter} | {value:,.0f} | {delta} | "
            f"{value/base:.3f}x | {row['dffs']} |")
    add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
