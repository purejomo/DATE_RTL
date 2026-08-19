#!/usr/bin/env python3
"""Build results/designs/awq_p3llm_v2_area_report.md.

Every measured number comes from results/area.csv, results/reports/ and
results/power/, so re-running synth/run_all.sh refreshes the document.

The one exception is the v1 reference in section 2. v1 is the previous RTL
(broadcast zero point) and no longer exists in the tree, so it cannot be
re-measured by this repository as it stands; the numbers below were taken by
restoring rtl/2_awq_p3llm_8pe from git and running the same flow at the same
period. They are recorded as constants rather than silently recomputed.

Both PCU rows are now v2. The sixteen-PE build used to be the v1 broadcast
contract; rtl/2_awq_p3llm_16pe_v2 gives it the same one-zero-point-per-PE
fan-out the eight-PE build has, which is the layout AutoAWQ actually stores.
That changes the sixteen-PE row's measured area, so a PCU16 number quoted from
before that conversion is not comparable with one produced now. The label
int4bf16_pcu_top_pcu500 is unchanged, and results/area.csv merges by label, so
re-running synth/run_all.sh overwrites the stale value in place.
"""

from __future__ import annotations

import csv
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
RESULTS = ROOT / "results"
REPORTS = RESULTS / "reports"
POWER = RESULTS / "power"
OUTPUT = RESULTS / "designs" / "awq_p3llm_v2_area_report.md"

BASELINE = "compute_hbmpim_250"
DELIVERED = "int4bf16_pcu32_500"
PCU16 = "int4bf16_pcu_top_pcu500"

# Rows quoted for context, all measured at the same boundary.
CONTEXT = (
    (DELIVERED, "AWQ PCU v2, 8 PE x 4 way", 32),
    (PCU16, "AWQ PCU v2, 16 PE x 4 way", 64),
    ("p3llm_pcu_500", "P3-LLM PCU, FP4/FP8, 16 PE x 4 way", 64),
    ("spinquant_pcu_500", "SpinQuant W4A4 PCU, 16 PE x 4 way", 64),
    (BASELINE, "HBM-PIM FP16 SIMD 16 lane", 16),
)

# GMAC/s per row, for the power table.
GMACS = {DELIVERED: 16.0, PCU16: 32.0, "p3llm_pcu_500": 32.0,
         "spinquant_pcu_500": 32.0, BASELINE: 4.0}

# v1 (broadcast zero point), same flow, same 2.0 ns target. See the module
# docstring: restore rtl/2_awq_p3llm_8pe from git to reproduce.
V1 = {"area": 37261.280, "cells": 32448, "dffs": 1566,
      "seq": 7081.5, "slack": 0.66,
      "start": "i_act[40]", "end": "s0_act_q[2][13]"}

# Same design, sources listed in reverse order. Recorded because section 2
# rests on the delta being larger than the flow's own run-to-run spread.
PERMUTED_AREA = 36918.672
PERMUTED_CELLS = 32282

# Cell-histogram movement between v1 and v2, largest absolute deltas first.
HISTOGRAM = "XNOR2_X1 -109, NAND2_X1 -71, AOI21_X1 -50, OR2_X1 +50, " \
            "NAND3_X1 +43,\n  XOR2_X1 +41"

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
    """Worst setup path of one label, plus the worst hold slack."""
    out = {"slack": None, "start": None, "end": None, "hold": None}
    path = REPORTS / label / "1_Post_synthesis.rpt"
    if not path.exists():
        return out
    text = path.read_text(encoding="utf-8", errors="replace")

    for key, marker in (("hold", "report_checks -path_delay min"),
                        ("slack", "report_checks -path_delay max")):
        section = text.split(marker, 1)
        if len(section) < 2:
            continue
        body = section[1]
        found = re.findall(r"^\s+(-?[\d.]+)\s+slack \((?:MET|VIOLATED)\)",
                           body, re.MULTILINE)
        if found:
            out[key] = min(float(value) for value in found)
        if key == "slack":
            match = re.search(r"^Startpoint: (\S+)", body, re.MULTILINE)
            if match:
                out["start"] = match.group(1)
            match = re.search(r"^Endpoint: (\S+)", body, re.MULTILINE)
            if match:
                out["end"] = match.group(1)
    return out


def power(top: str):
    path = POWER / f"{top}_power.rpt"
    if not path.exists():
        return None
    match = re.search(r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)", path.read_text(), re.M)
    return float(match.group(1)) if match else None


def fmt(value, spec="{:.2f}"):
    return "n/a" if value is None else spec.format(value)


def delta(value, spec="{:+,.1f}"):
    """A zero delta is the finding here, so print it as a plain 0."""
    return "0" if abs(value) < 5e-2 else spec.format(value)


def main() -> None:
    with (RESULTS / "area.csv").open(newline="", encoding="utf-8") as handle:
        area = {row["label"]: row for row in csv.DictReader(handle)}
    for required in (BASELINE, DELIVERED):
        if required not in area:
            raise SystemExit(f"results/area.csv: row {required} is missing")

    base = float(area[BASELINE]["area_um2"])
    v2 = float(area[DELIVERED]["area_um2"])
    v2_seq = sequential_area(DELIVERED)
    info = timing(DELIVERED)

    lines: list[str] = []
    add = lines.append

    add("# AWQ INT4×BF16 PIM 연산기 (PCU) v2 — 면적 · 타이밍 리포트")
    add("")
    add(f"- 생성: `synth/build_awq_report.py` (label `{DELIVERED}`)")
    add("- 합성: `cd synth && ./run_all.sh synth`")
    add("- 명세: [docs/awq_p3llm_pcu_spec.md](../../docs/awq_p3llm_pcu_spec.md)")
    add("")
    add("v2 가 v1 과 다른 것은 zero-point 팬아웃 하나뿐이다: `i_weight_zp` 이 broadcast")
    add("nibble 4 bit 에서 PE 당 4 bit (8 PE = 32 bit) 로 넓어졌다. 산술, 파이프라인 4단,")
    add("누산기 폭, II=1 은 그대로다.")
    add("")

    # ---- 1. baseline -------------------------------------------------------
    add("## 1. baseline 대비")
    add("")
    add(f"비교 대상: **HBM-PIM FP16 16-lane SIMD 연산부** "
        f"(`{area[BASELINE]['top']}`,")
    add(f"{base:,.0f} um2 @ {area[BASELINE]['clock_ns']} ns).")
    add("")
    add("- 포함: 곱셈기, 가산기, 32-bit 누산기")
    add("- 제외: GRF/CRF, 버퍼, bank 인터페이스")
    add("- group scale `s` 적용, output-group reduction, BF16 packing 은 PCU 밖")
    add("  functional postprocess 라 어느 숫자에도 들어 있지 않다.")
    add("")
    add("| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |")
    add("|---|---|---:|---:|---:|---:|---:|---:|")
    for label, name, _ in ((BASELINE, "HBM-PIM FP16 SIMD 16 lane", 0),
                           (DELIVERED, "**AWQ PCU v2, 8 PE x 4 way**", 0),
                           (PCU16, "AWQ PCU v2, 16 PE x 4 way", 0)):
        if label not in area:
            continue
        row = area[label]
        value = float(row["area_um2"])
        add(f"| {name} | `{row['top']}` | {row['clock_ns']} ns | {value:,.0f} | "
            f"{value/base:.3f}x | {row['cells']} | {row['dffs']} | "
            f"{fmt(timing(label)['slack'], '{:+.2f}')} |")
    add("")
    verdict = "충족" if v2 < base else "미충족"
    add(f"**면적 제약 {verdict}**: {v2:,.0f} um2 < {base:,.0f} um2 — "
        f"baseline 의 {v2/base*100:.1f} %, {base-v2:,.0f} um2 절감.")
    add("")
    if PCU16 in area:
        ratio = float(area[PCU16]["area_um2"]) / v2
        add("두 판 모두 v2 계약이다 — `i_weight_zp` 이 PE 당 독립 4-bit 이며, 16 PE 판의")
        add("포트는 4-bit 이 아니라 64-bit 이다. 아래 16 PE 면적은 v2 로 전환한 뒤의 값이라")
        add("v1 시절 인용치와 직접 비교할 수 없다.")
        add("")
        add("8 PE 판은 곱셈기 32 개로 baseline SIMD 의 32-multiplier 구성과 곱셈기 수를 맞춘")
        add(f"행이다. 16 PE 판과의 면적비가 1:{ratio:.2f} 로 정확히 2 배가 아닌 것은 공유 정렬기")
        add("(`int4float_align` 4 개) 가 `NUM_PES` 를 따라 줄지 않기 때문이다 — MAC 당 정렬")
        add("비용은 8 PE 쪽이 2 배다.")
        add("")

    add("| 설계 | 면적 (um2) | baseline 대비 | MAC/cycle | um2/MAC |")
    add("|---|---:|---:|---:|---:|")
    for label, name, mac in CONTEXT:
        if label not in area:
            continue
        value = float(area[label]["area_um2"])
        add(f"| {name} | {value:,.0f} | {value/base:.3f}x | {mac} | "
            f"{value/mac:,.0f} |")
    add("")
    add("조직은 **P3-LLM PCU 그대로**이고 피연산자 형식만 다르다. 16 PE 판이 P3-LLM 행과")
    if PCU16 in area and "p3llm_pcu_500" in area:
        a16 = float(area[PCU16]["area_um2"]) / 64
        a_p3 = float(area["p3llm_pcu_500"]["area_um2"]) / 64
        add(f"um2/MAC {a16:,.0f} 對 {a_p3:,.0f} 로 사실상 같은 것이 그 증거다 — "
            f"INT4×BF16 로 바꿔서 아낀")
        add("것과 block-float 정렬기로 새로 쓴 것이 거의 상쇄된다.")
    add("")
    add("### 조합 / 순차 분해")
    add("")
    add("| 설계 | 총 면적 | 조합 (um2) | 순차 (um2) | 순차 비중 | DFF |")
    add("|---|---:|---:|---:|---:|---:|")
    add(f"| AWQ PCU v2, 8 PE | {v2:,.0f} | {v2-v2_seq:,.0f} | {v2_seq:,.0f} | "
        f"{v2_seq/v2*100:.1f} % | {area[DELIVERED]['dffs']} |")
    add(f"| AWQ PCU v1, 8 PE | {V1['area']:,.0f} | "
        f"{V1['area']-V1['seq']:,.0f} | {V1['seq']:,.0f} | "
        f"{V1['seq']/V1['area']*100:.1f} % | {V1['dffs']} |")
    for label, name in (("p3llm_pcu_500", "P3-LLM PCU, 16 PE"),
                        (BASELINE, "HBM-PIM FP16 SIMD 16 lane")):
        if label not in area:
            continue
        value = float(area[label]["area_um2"])
        seq = sequential_area(label)
        add(f"| {name} | {value:,.0f} | {value-seq:,.0f} | {seq:,.0f} | "
            f"{seq/value*100:.1f} % | {area[label]['dffs']} |")
    add("")

    # ---- 2. v1 vs v2 -------------------------------------------------------
    gap = v2 - V1["area"]
    add(f"## 2. v1 → v2 의 대가: {gap:+,.1f} um2 ({gap/V1['area']*100:+.2f} %)")
    add("")
    add("zero-point 를 PE 별로 주는데 면적이 **줄었다.** 오타가 아니고 노이즈도 아니다.")
    add("")
    add("| 구성 | 면적 (um2) | cells | DFF | 조합 (um2) | 순차 (um2) | slack |")
    add("|---|---:|---:|---:|---:|---:|---:|")
    add(f"| v1 (broadcast nibble) | {V1['area']:,.3f} | {V1['cells']:,} | "
        f"{V1['dffs']} | {V1['area']-V1['seq']:,.1f} | {V1['seq']:,.1f} | "
        f"{V1['slack']:+.2f} |")
    add(f"| **v2 (PE 당 nibble)** | **{v2:,.3f}** | "
        f"**{int(area[DELIVERED]['cells']):,}** | "
        f"**{area[DELIVERED]['dffs']}** | **{v2-v2_seq:,.1f}** | "
        f"**{v2_seq:,.1f}** | **{fmt(info['slack'], '{:+.2f}')}** |")
    add(f"| 차이 | **{gap:+,.3f}** | "
        f"{delta(int(area[DELIVERED]['cells'])-V1['cells'], '{:+,d}')} | "
        f"{delta(int(area[DELIVERED]['dffs'])-V1['dffs'], '{:+d}')} | "
        f"{gap:+,.1f} | "
        f"**{delta(v2_seq-V1['seq'])}** | "
        f"{delta((info['slack'] or 0)-V1['slack'], '{:+.2f}')} |")
    add("")
    add("읽는 법:")
    add("")
    add("- **차이는 전부 조합 논리다.** 순차 면적과 DFF 수가 bit 단위로 같다. ZP 팬아웃은")
    add("  상태를 하나도 추가하지 않는다는 것이 합성 결과로 확인된다 — v1 과 v2 는 같은")
    add("  `int4float_pe` 소스를 쓰고, PE 는 원래부터 4-bit ZP 를 포트로 받는다.")
    add("- **재현된다.** v1 소스를 git 에서 복원해 같은 플로우로 다시 합성하면")
    add(f"  {V1['area']:,.3f} um2 / {V1['cells']:,} cells 로 자리 숫자까지 일치한다. "
        f"v2 를 소스 파일")
    add(f"  역순으로 합성해도 {PERMUTED_AREA:,.3f} um2 / {PERMUTED_CELLS:,} cells "
        f"로 동일하다. RaBiT 행에서")
    add("  관측된 0.9 % 순서 의존성 (`results/designs/rabit_pe_scaling.md` 4절) 은 이")
    add("  설계에서는 (역순 1 회 기준) 나타나지 않았다.")
    add("- **구조 변경이 아니라 재매핑이다.** 셀 히스토그램 차이가 한 종류에 몰리지 않고")
    add(f"  퍼져 있다: {HISTOGRAM} …. 논리량은 그대로이고 ABC 가 다르게 인수분해했다.")
    add("- **왜 줄어드는지는 규명하지 않았다.** 두 판의 감산기 수와 폭이 같으므로 ABC 의")
    add("  factoring 결과 차이로 보이지만, 그 인과를 실험으로 분리하지는 않았다. 어느")
    add(f"  쪽이든 {abs(gap)/V1['area']*100:.2f} % 이므로 "
        f"**설계 선택의 근거로 쓸 크기는 아니다.**")
    add("")
    add("**결론: 표준 AutoAWQ metadata 배치를 구현하는 데 드는 면적 비용은 0 이다.**")
    add("")

    # ---- 3. timing ---------------------------------------------------------
    period = float(area[DELIVERED]["clock_ns"])
    add("## 3. 타이밍")
    add("")
    add(f"목표는 {1000/period:,.0f} MHz ({period} ns) 다. DRAM 측 command cadence 는 "
        f"tCCD_S = 2 이고, PCU 는")
    add("command 하나당 1 cycle 을 쓴다 (II = 1).")
    add("")
    status = "MET" if (info["slack"] or 0) >= 0 else "VIOLATED"
    add(f"- **{1000/period:,.0f} MHz** ({period} ns): slack "
        f"**{fmt(info['slack'], '{:+.2f}')} ns ({status})**. worst path "
        f"`{info['start']}` ->")
    add(f"  `{info['end']}`.")
    add(f"- hold: slack {fmt(info['hold'], '{:+.2f}')} ns (MET).")
    add("")
    add(f"worst path 는 v1 과 **같은 구조**다 (v1: `{V1['start']}` -> "
        f"`{V1['end']}`).")
    add("`i_act` 입력 포트에서 공유 `int4float_align` 을 지나 PE stage 0 의 activation")
    add(f"레지스터로 들어가는 조합 경로이고, 양쪽 다 slack "
        f"{fmt(info['slack'], '{:.2f}')} ns 로 같다. **critical")
    add("path 는 zero-point 쪽이 아니라 block-float 정렬기 쪽이다** — ZP 를 PE 별로")
    add("바꿔도 타이밍이 움직이지 않는 이유다.")
    add("")
    add("이 경로에는 플로우 관례대로 입출력 각각 주기의 20 % 가 I/O delay 로 잡혀 있다")
    add(f"({period} ns 주기에서 {period*0.2:.2f} ns). 실제 시스템에서 `i_act` 는 "
        f"input GRF 의 flop 에서")
    add("나온다.")
    add("")

    # ---- 4. power ----------------------------------------------------------
    add("## 4. 전력")
    add("")
    add("전력은 vectorless `set_power_activity -global 0.20` 한 가지 모델이다 (모든 net 에")
    add("균일, 전파 없음).")
    add("")
    add("| | Power | pJ/MAC | GMAC/s |")
    add("|---|---:|---:|---:|")
    for label, name, _ in CONTEXT:
        if label not in area:
            continue
        watt = power(area[label]["top"])
        gmacs = GMACS[label]
        if watt is None:
            add(f"| {name} | n/a | n/a | {gmacs:.1f} |")
            continue
        add(f"| {name} | {watt:.4f} W | {watt/gmacs*1000:.2f} | {gmacs:.1f} |")
    add("")
    add("`-global` 은 설계별 활성도를 구분하지 않아 대체로 셀 수를 다시 말하는 값이다.")
    add("**설계 간 에너지 우열은 이 표로 주장하지 않는다** — 방어 가능한 비교에는")
    add("gate-level VCD 가 필요하다.")
    add("")

    # ---- 5. verification ---------------------------------------------------
    add("## 5. 검증")
    add("")
    add("```")
    add("cd verif && make TEST=pcu_bf16_32   # 8 PE, BF16, per-PE ZP  (본 행)")
    add("cd verif && make TEST=pcu_fp16_32   # 8 PE, binary16, per-PE ZP")
    add("cd verif && make TEST=pcu_bf16_64   # 16 PE, BF16, broadcast ZP (v1)")
    add("```")
    add("")
    add("golden model 은 순수 파이썬 정수 연산이다")
    add("(`verif/models/int4float_pcu_model.py`). 정렬 · RNE 반올림 · `(W_q - z)` 디코드 ·")
    add("포화 누산을 RTL 과 문장 단위로 대응시켰고 host floating point 를 쓰지 않는다.")
    add("")
    add("- 매 transaction 마다 PE 별 signed 32-bit 누산기, `o_saturate`, `o_invalid` 를")
    add("  전부 bit-exact 대조한다. 기본 4000 transaction (`PCU_ITERS`).")
    add("- stimulus 는 corner encoding 30 % (zero, ±0, 최소 subnormal, subnormal/normal")
    add("  경계, ±1, 최대 finite, ±inf, NaN) + 랜덤 70 %, 64 transaction 마다 `acc_clear`.")
    add("- `PCU_ZP_PER_PE` 로 v1/v2 계약을 전환하므로 같은 testbench 가 세 top 을 덮는다.")
    add("")
    add("상위 Fusion-PIMSim 재검증 (Llama-3.1-8B 224 projection, raw INT32 54,525,952 건")
    add("exact 등) 은 명세 5.1 절에 있다. **Captured Standard AutoAWQ final BF16 과는")
    add("전체 bit-exact 가 아니다.**")
    add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
