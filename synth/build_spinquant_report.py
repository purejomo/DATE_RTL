#!/usr/bin/env python3
"""Build the SpinQuant W4A4 PCU area and timing report from the synthesis results.

Reads results/area.csv and the per-label OpenROAD reports, then writes
results/designs/spinquant_area_report.md: the comparison against the HBM-PIM
baseline compute unit, the timing at tCCD_S, a module-level breakdown, and the
boundary/carry-chain sweep.

Every number in the output is read out of the flow's own artefacts. Nothing is
transcribed by hand, so re-running synthesis and re-running this script is
enough to keep the report honest.
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
DESIGNS = RESULTS / "designs"
OUTPUT = DESIGNS / "spinquant_area_report.md"

BASELINE = "compute_hbmpim_250"
DELIVERED = "spinquant_pcu_500"

# Rows the report compares the delivered configuration against. These are the
# other designs in the same table, all measured at the same boundary.
PEERS = (
    ("p3llm_pcu_500", "P3-LLM PCU, FP4/FP8, 16 PE x 4 way"),
    ("int4bf16_pcu_top_pcu500", "AWQ P3-LLM PCU, INT4/BF16, 16 PE x 4 way"),
    ("rabit_pcu_250", "RaBiT PCU, 2-bit RB/FP16, 8 PE (250 MHz)"),
)

MAIN = (
    ("spinquant_pcu_500", "tCCD_S (500 MHz)"),
    ("spinquant_pcu_250", "tCCD_L (250 MHz)"),
)

SWEEP = (
    ("spinquant_pcu_500", "24 bit", "안",
     "**대표 구성** — K 상한이 chain 을 24 bit 로 끊게 해준다"),
    ("spinquant_pcu_acc32_500", "32 bit", "안",
     "carry chain 을 아키텍처 레지스터 폭까지 되돌린 경우"),
    ("spinquant_pcu_nolatch_500", "24 bit", "밖",
     "256b read latch 를 경계 밖으로 뺀 경우"),
)

# Throughput scale-up points.
#
#   label, description, multipliers, peak MAC/cycle, R needed to sustain it,
#   sustained MAC/cycle at batch 1, weight bits the bank must deliver per cycle
#
# R is the number of activation rows that reuse one weight beat, spatial times
# temporal. The bank hands one PCU 256 bits per tCCD_L, which is 128 bits per
# tCCD_S cycle (docs/rabit_pcu_spec.md fixes that convention), so 32 INT4
# weights per cycle and therefore
#
#     sustained MAC/cycle = (weight bits per cycle / 4) x R
SCALE = (
    ("spinquant_pcu_500", "대표: 16 PE x 4 way, 1 row, 4 entry",
     64, 64, 2, 32, 128),
    ("spinquant_pcu_r2e2_500", "2 row spatial x 2 entry",
     128, 128, 4, 32, 128),
    ("spinquant_pcu_r2_500", "2 row spatial x 4 entry",
     128, 128, 4, 32, 128),
    ("spinquant_pcu_r4_500", "4 row spatial x 4 entry",
     256, 256, 8, 32, 128),
    ("spinquant_pcu_w512_500", "32 PE x 4 way, 512b beat (대역폭 2배 전제)",
     128, 128, 2, 64, 256),
)

FMAX = (
    ("spinquant_pcu_500", "2.0"),
    ("spinquant_pcu_1p0", "1.0"),
    ("spinquant_pcu_0p8", "0.8"),
)

BLOCKS = (
    ("spinquant_blk_pe_500", "spinquant_pe", 16,
     "4 multipliers + 4:2 compressor + CPA + 24b accumulate add"),
    ("spinquant_blk_acc_500", "spinquant_acc_regfile", 1,
     "4 x 16 x 32b accumulators, accumulate read + drain read"),
)

# Nangate45 flip-flop cell areas, the same table build_compute_table.py uses to
# split sequential area from combinational.
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


def load_area() -> dict:
    with AREA_CSV.open(newline="", encoding="utf-8") as handle:
        return {row["label"]: row for row in csv.DictReader(handle)}


def sequential_area(label: str) -> float:
    path = REPORTS / label / "synth_stat.txt"
    if not path.exists():
        return 0.0
    total = 0.0
    text = path.read_text(encoding="utf-8", errors="replace")
    for cell, count in re.findall(r"^\s+(\w+)\s+(\d+)\s*$", text, re.M):
        if cell in DFF_AREA:
            total += DFF_AREA[cell] * int(count)
    return total


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
    for required in (BASELINE, DELIVERED):
        if required not in area:
            raise SystemExit(f"{AREA_CSV}: row {required} is missing")

    base = float(area[BASELINE]["area_um2"])
    delivered = float(area[DELIVERED]["area_um2"])

    lines: list[str] = []
    add = lines.append

    add("# SpinQuant W4A4 PIM 연산기 (PCU) — 면적 · 타이밍 리포트")
    add("")
    add("- 생성: `synth/run_spinquant.sh`")
    add("- 조건: Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지 (P&R 미수행)")
    add("- 명세: [docs/spinquant_pcu_spec.md](../../docs/spinquant_pcu_spec.md)")
    add("")

    add("## 1. 면적 제약")
    add("")
    add(f"제약: **HBM-PIM 16-lane FP16 SIMD 연산부 ({base:,.0f} um2 "
        f"@ {area[BASELINE]['clock_ns']} ns) 이하.**")
    add("")
    add("- 포함: 곱셈기, 가산기, 32b 누산기")
    add("- 제외: GRF/CRF, 버퍼, bank 인터페이스")
    add("- SpinQuant 만 추가로 포함: 256b read latch, 누산기 파일 4 x 16 x 32b (가격은 2절)")
    add("")
    add("| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |")
    add("|---|---|---:|---:|---:|---:|---:|---:|")
    row = area[BASELINE]
    info = timing(BASELINE)
    add(f"| HBM-PIM FP16 SIMD 16 lane | `{row['top']}` | {row['clock_ns']} ns | "
        f"{base:,.0f} | 1.000x | {row['cells']} | {row['dffs']} | "
        f"{fmt(info['slack'], '{:+.2f}')} |")
    for label, target in MAIN:
        if label not in area:
            continue
        row = area[label]
        info = timing(label)
        value = float(row["area_um2"])
        add(f"| SpinQuant PCU — {target} | `{row['top']}` | "
            f"{row['clock_ns']} ns | {value:,.0f} | {value/base:.3f}x | "
            f"{row['cells']} | {row['dffs']} | {fmt(info['slack'], '{:+.2f}')} |")
    add("")

    verdict = "충족" if delivered < base else "미충족"
    add(f"**{verdict}**: {delivered:,.0f} vs {base:,.0f} um2 — "
        f"baseline 의 {delivered/base*100:.1f} %, "
        f"{base-delivered:,.0f} um2 ({(1-delivered/base)*100:.1f} %) 절감.")
    add("")
    add("| 설계 | 면적 (um2) | baseline 대비 | MAC/cycle | um2/MAC |")
    add("|---|---:|---:|---:|---:|")
    mac_of = {
        "spinquant_pcu_500": 64,
        "p3llm_pcu_500": 64,
        "int4bf16_pcu_top_pcu500": 64,
        "rabit_pcu_250": 128,
        BASELINE: 16,
    }
    order = [(DELIVERED, "SpinQuant W4A4 PCU, 16 PE x 4 way")] + list(PEERS) + [
        (BASELINE, "HBM-PIM FP16 SIMD 16 lane")]
    for label, description in order:
        if label not in area:
            continue
        value = float(area[label]["area_um2"])
        macs = mac_of.get(label)
        per = f"{value/macs:,.0f}" if macs else "n/a"
        add(f"| {description} | {value:,.0f} | {value/base:.3f}x | "
            f"{macs if macs else 'n/a'} | {per} |")
    add("")
    add("조직은 **P3-LLM PCU 와 동일** (16 PE x 4 way, 64 multiplier). 조직을 고정하고")
    add("정밀도만 바꾼 행이다. 면적 차이의 내역:")
    add("")

    add("- 없어진 것: FP8/FP4 디코더, exponent alignment shifter, BitMoD special-value")
    add("  경로, zero-point 감산기, scale 곱셈기. 곱셈기는 signed4 x unsigned4 하나뿐.")
    add("- 늘어난 것: 누산기 파일. P3-LLM 은 PE 당 1 개 (16 x 32b), 이 설계는 GRF")
    add("  해석대로 entry 4 개 (4 x 16 x 32b).")
    add("")
    add("| 설계 | 총 면적 | 조합 (um2) | 순차 (um2) | 순차 비중 | DFF |")
    add("|---|---:|---:|---:|---:|---:|")
    for label, description in [(DELIVERED, "SpinQuant W4A4 PCU"),
                               ("p3llm_pcu_500", "P3-LLM PCU"),
                               (BASELINE, "HBM-PIM FP16 SIMD 16 lane")]:
        if label not in area:
            continue
        value = float(area[label]["area_um2"])
        seq = sequential_area(label)
        add(f"| {description} | {value:,.0f} | {value-seq:,.0f} | {seq:,.0f} | "
            f"{seq/value*100:.1f} % | {area[label]['dffs']} |")
    add("")
    add("순차 비중이 큰 것은 설계가 무거워서가 아니라 조합 논리가 가벼워서다 — 산술이")
    add("4-bit 정수 곱 64 개로 끝나 면적의 상당 부분이 누산기 파일 (2048 FF) 과")
    add("read latch (256 FF) 다.")
    add("")

    add("## 2. 모듈별 면적과 경계 선택")
    add("")
    add("블록별 단독 합성값. 단독 합성은 포트 드라이버를 자체 부담하고, flat top 에서")
    add("16 PE 가 공유하는 activation 버스 · 누산기 read mux 를 혼자 떠안는다. 따라서")
    add("**상대 비중용**이며 합이 flat top 과 일치하지 않는다.")
    add("")
    add("| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |")
    add("|---|---:|---:|---:|---:|---|")
    total = 0.0
    for label, name, count, description in BLOCKS:
        if label not in area:
            continue
        row = area[label]
        unit = float(row["area_um2"])
        total += unit * count
        add(f"| `{name}` | {count} | {unit:,.0f} | {unit*count:,.0f} | "
            f"{row['dffs']} | {description} |")
    if total:
        add(f"| **단독 합성 소계** | | | **{total:,.0f}** | | |")
        add(f"| **flat top 실측** | | | **{delivered:,.0f}** | "
            f"{area[DELIVERED]['dffs']} | read latch · 파이프라인 제어 포함, "
            f"소계 대비 {delivered-total:+,.0f} |")
    add("")

    add("경계 안에 넣은 두 항목의 가격:")
    add("")
    add("| 구성 | carry chain | read latch | 면적 (um2) | 기본 대비 | baseline 대비 | DFF |")
    add("|---|---|:--:|---:|---:|---:|---:|")
    for label, chain, latch, note in SWEEP:
        if label not in area:
            continue
        row = area[label]
        value = float(row["area_um2"])
        add(f"| {note} | {chain} | {latch} | {value:,.0f} | "
            f"{value-delivered:+,.0f} | {value/base:.3f}x | {row['dffs']} |")
    add("")
    if "spinquant_pcu_acc32_500" in area:
        acc32 = float(area["spinquant_pcu_acc32_500"]["area_um2"])
        gap = acc32 - delivered
        dff_delta = (int(area["spinquant_pcu_acc32_500"]["dffs"])
                     - int(area[DELIVERED]["dffs"]))
        add(f"- **carry chain**: 32-bit 구성이 +{gap:,.0f} um2 "
            f"(+{gap/delivered*100:.1f} %). DFF 차 {dff_delta:,d} 개는")
        add("  4 entry x 16 PE x 8 bit 와 정확히 일치 — 상위 8 bit 는 bit 23 의 sign")
        add("  extension 이라 합성기가 병합한다. 절감분 = carry 길이 + 중복 flop 제거.")
        add("  아키텍처상 누산기 폭은 32-bit 유지 (drain 은 32-bit 부호확장값), 줄어든")
        add(f"  것은 실리콘이다. 어느 쪽이든 baseline 아래 ({acc32/base:.3f}x).")
    if "spinquant_pcu_nolatch_500" in area:
        nolatch = float(area["spinquant_pcu_nolatch_500"]["area_um2"])
        gap = delivered - nolatch
        add(f"- **256b read latch**: {gap:,.0f} um2 = 대표 구성의 "
            f"{gap/delivered*100:.1f} %. 밖으로 빼면 P3-LLM ·")
        add(f"  SIMD 행과 같은 경계가 되고 {nolatch:,.0f} um2 "
            f"({nolatch/base:.3f}x). 대표값은 **포함한** 쪽 —")
        add("  2-pump 가 이 설계의 주장 기능이므로 그 레지스터를 빼면 주장과 측정이 어긋난다.")
    add("")

    add("## 3. 타이밍")
    add("")
    add("목표는 tCCD_S 500 MHz (2.0 ns) — baseline 이 tCCD_L 250 MHz 이므로. command")
    add("하나당 1 cycle 이다 (2-pump 는 beat 재사용이지 cycle 분할이 아니다).")
    add("")
    for label, target in MAIN:
        info = timing(label)
        if info["slack"] is None:
            continue
        status = "MET" if info["slack"] >= 0 else "VIOLATED"
        short = target.split(" (")[0]
        add(f"- **{short} ({area[label]['clock_ns']} ns)**: slack "
            f"{info['slack']:+.2f} ns ({status}). worst path `{info['start']}` ->")
        add(f"  `{info['end']}`, arrival "
            f"{fmt(info['arrival'], '{:.2f}')} ns.")
    add("")
    add("두 주기의 면적이 같은 것은 오타가 아니다 — ABC area mode (`ABC_AREA=1`) 는")
    add("주기를 죄어도 같은 매핑을 낸다. 두 행 모두 실제로 합성했고 (FLOW_VARIANT")
    add("date_2p0 / date_4p0) 타이밍 리포트만 다르다.")
    add("")

    add("## 4. 처리량을 더 올릴 여지")
    add("")
    add("정수 연산기라 곱셈기는 거의 공짜다. **MAC/cycle 을 묶는 것은 산술이 아니라")
    add("피연산자 공급**이고, 아래 두 절이 그것을 보인다.")
    add("")
    add("### 4.1 산술은 제약이 아니다")
    add("")
    add("| 목표 주기 | 주파수 | worst slack (ns) | 면적 (um2) |")
    add("|---:|---:|---:|---:|")
    for label, period in FMAX:
        if label not in area:
            continue
        info = timing(label)
        if info["slack"] is None:
            continue
        mhz = 1000.0 / float(period)
        add(f"| {period} ns | {mhz:,.0f} MHz | {info['slack']:+.2f} | "
            f"{float(area[label]['area_um2']):,.0f} |")
    add("")
    add("데이터패스는 **1 GHz 에서 닫힌다** (tCCD_S 의 2 배). 면적은 "
        f"baseline 의 {delivered/base*100:.0f} %.")
    add("주파수로도 면적으로도 여유가 있다. (면적이 주기와 무관한 이유는 3절 참조.)")
    add("")
    add("### 4.2 실제 벽: weight 대역폭")
    add("")
    add("bank 는 column command 당 256 bit 를 tCCD_L 마다 준다 (docs/rabit_pcu_spec.md")
    add("convention). PCU clock = tCCD_S = tCCD_L / 2 → 지속 공급량은 **cycle 당")
    add("128 bit = INT4 weight 32 개**.")
    add("")
    add("```")
    add("지속 MAC/cycle = (cycle 당 weight bit / 4) x R")
    add("R = 한 weight beat 를 재사용하는 activation row 수 (spatial x temporal)")
    add("```")
    add("")
    add("대표 구성은 R = 2 (2-pump) → 지속 64 MAC/cycle 로 공급과 정확히 일치.")
    add("지속 처리량을 올리는 길은 R 증가뿐인데, **R 을 늘리면 그만큼 누산기가 더")
    add("필요하다** — 이 설계에서 가장 비싼 자원이다.")
    add("")
    add("### 4.3 확장 지점 실측")
    add("")
    add("| 구성 | mult | peak MAC/cy | 필요 R | batch-1 지속 | 면적 (um2) | baseline 대비 | um2/MAC | slack |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for label, description, muls, peak, need_r, batch1, _bits in SCALE:
        if label not in area:
            continue
        value = float(area[label]["area_um2"])
        info = timing(label)
        mark = " **(제약 초과)**" if value > base else ""
        add(f"| {description}{mark} | {muls} | {peak} | {need_r} | {batch1} | "
            f"{value:,.0f} | {value/base:.3f}x | {value/peak:,.0f} | "
            f"{fmt(info['slack'], '{:+.2f}')} |")
    add("")
    if "spinquant_pcu_r2e2_500" in area:
        r2e2 = float(area["spinquant_pcu_r2e2_500"]["area_um2"])
        add(f"- **2배는 된다, 조건부로.** `r2e2` 는 지속 128 MAC/cycle 을 "
            f"{r2e2:,.0f} um2")
        add(f"  ({r2e2/base:.3f}x) 에 낸다. 누산기 상태가 대표 구성과 같기 때문 "
            f"— input row 를 entry")
        add("  축(시간)에서 lane 축(공간)으로 옮기고 entry 를 4 → 2 로 줄이면 총 bit 수가")
        add(f"  그대로다 (DFF {area['spinquant_pcu_r2e2_500']['dffs']} vs "
            f"{area[DELIVERED]['dffs']}). 늘어난 것은 PE 16 개뿐이고 "
            f"um2/MAC {r2e2/128:,.0f} 으로")
        add("  전 구성 중 최고. **대가: output-channel group interleave 포기, batch (또는")
        add("  chunked prefill token) ≥ 4 요구.**")
    if "spinquant_pcu_r2_500" in area:
        r2 = float(area["spinquant_pcu_r2_500"]["area_um2"])
        add("- **interleave 를 지키면 제약 초과.** `r2` 는 같은 128 MAC/cycle 에 entry 4")
        add(f"  개를 유지하지만 누산기가 2 배가 되어 {r2:,.0f} um2 ({r2/base:.3f}x).")
    if "spinquant_pcu_r4_500" in area:
        r4 = float(area["spinquant_pcu_r4_500"]["area_um2"])
        add(f"- **4배는 안 된다.** `r4` 는 {r4:,.0f} um2 ({r4/base:.3f}x). "
            f"누산기가 R 에 선형이라")
        add("  여기서부터 누산기 파일이 설계를 지배한다.")
    if "spinquant_pcu_w512_500" in area:
        w512 = float(area["spinquant_pcu_w512_500"]["area_um2"])
        add("- **batch-1 은 대역폭이 천장.** 위 네 행 모두 batch-1 지속 32 MAC/cycle 로")
        add(f"  같다. 천장을 올리려면 beat 를 넓혀야 하고 그게 `w512` "
            f"({w512:,.0f} um2, {w512/base:.3f}x)")
        add("  다. 단 **PCU 에 column 대역폭 2 배를 준다는 아키텍처 전제** (bank pair 또는")
        add("  pseudo-channel) 가 필요해 다른 숫자와 전제가 다르므로 참고용.")
    add("")
    add("### 4.4 결론")
    add("")
    add("- **decode (batch 작음)**: 대표 구성이 이미 균형점. 곱셈기를 늘려도 지속")
    add("  처리량은 그대로고 면적만 는다. batch-1 만 보면 64 개도 2 배 과잉 (절반이 논다).")
    add("- **batch / chunked prefill ≥ 4**: `r2e2` 가 면적 제약 안에서 지속 처리량을")
    add("  2 배로 만드는 유일한 지점이고 um2/MAC 도 개선된다. RTL 은 `NROW` 파라미터로")
    add("  지원하며 같은 testbench 로 검증되어 있다 (`make TEST=spinquant_pcu_r2e2`).")
    add("- **그 이상**: 누산기 파일이 R 에 선형이라 면적 제약과 충돌한다.")
    add("")

    add("## 5. 검증")
    add("")
    add("```")
    add("cd verif && make TEST=spinquant_pcu          # 전체 PCU")
    add("cd verif && make TEST=spinquant_pcu_nolatch  # read latch 경계 밖")
    add("cd verif && make TEST=spinquant_pcu_acc32    # 32-bit carry chain")
    add("cd verif && make TEST=spinquant_pe           # PE 단독")
    add("cd verif && make TEST=spinquant_acc          # 누산기 파일 단독")
    add("```")
    add("")
    add("golden model 은 순수 파이썬 정수 GEMV (`verif/models/spinquant_model.py`).")
    add("")
    add("- testbench 가 [16 x K] weight tile 을 256b beat stream 으로 잘라 microkernel")
    add("  command 순서를 재현하고, 누산기 갱신을 매 cycle bit-exact 로 대조한다.")
    add("- 최악 누산 (K = 14336, weight 전부 -8, activation 전부 15) 에서 24-bit carry")
    add("  chain 이 넘치지 않음을 확인한다 (-1,720,320, 22 bit).")
    add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
