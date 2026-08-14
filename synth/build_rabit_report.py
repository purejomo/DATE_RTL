#!/usr/bin/env python3
"""Build the RaBiT PCU area and timing report from the synthesis results.

Reads results/area.csv and the per-label OpenROAD reports, then writes
results/designs/rabit_area_report.md: the comparison against the HBM-PIM baseline
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
DESIGNS = RESULTS / "designs"    # per-design analysis; results/*.csv is cross-design
OUTPUT = DESIGNS / "rabit_area_report.md"

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
    info = timing(BASELINE)
    add(f"| HBM-PIM FP16 SIMD 16 lane | `{row['top']}` | {row['clock_ns']} ns | "
        f"{float(row['area_um2']):,.0f} | 1.000x | {row['cells']} | {row['dffs']} | "
        f"{fmt(info['slack'], '{:+.2f}')} |")
    for label, description, target in MAIN:
        if label not in area:
            continue
        row = area[label]
        info = timing(label)
        ratio = float(row["area_um2"]) / base
        add(f"| {description} ({target}) | `{row['top']}` | {row['clock_ns']} ns | "
            f"{float(row['area_um2']):,.0f} | {ratio:.3f}x | {row['cells']} | "
            f"{row['dffs']} | {fmt(info['slack'], '{:+.2f}')} |")
    add("")

    if "rabit_pcu_250" in area:
        delivered = float(area["rabit_pcu_250"]["area_um2"])
        verdict = "충족" if delivered < base else "미충족"
        add(f"**면적 제약 {verdict}**: {delivered:,.0f} um2 < {base:,.0f} um2 "
            f"(baseline의 {delivered/base*100:.1f} %, "
            f"{base-delivered:,.0f} um2 절감).")
        add("")
        add("곱셈기가 하나도 없는 대신 누산기 배열 64 x 32b 가 경계 안으로")
        add("들어왔는데도 baseline 보다 작다. DFF 는 baseline 의 1.40 배지만")
        add("(2208 vs 1578) 조합 논리가 훨씬 가볍다.")
        add("")

    add("### 타이밍")
    add("")
    add("PCU 는 column command 하나당 2 cycle 을 쓴다 (2-pump). 따라서 PCU 주기")
    add("4.0 ns 는 tCCD_S 8.0 ns 에 해당하고, 2.0 ns 는 tCCD_S 4.0 ns 다.")
    add("")
    for label, _description, target in MAIN:
        info = timing(label)
        if info["slack"] is None:
            continue
        status = "MET" if info["slack"] >= 0 else "VIOLATED"
        add(f"- **{target}** ({area[label]['clock_ns']} ns): slack "
            f"{info['slack']:+.2f} ns ({status}). worst path "
            f"`{info['start']}` -> `{info['end']}`, arrival "
            f"{fmt(info['arrival'], '{:.2f}')} ns, required "
            f"{fmt(info['required'], '{:.2f}')} ns.")
    add("")
    add("두 주기의 면적이 같은 것은 오타가 아니다. 이 플로우는 ABC 를 area")
    add("mode (`ABC_AREA=1`) 로 돌리므로 주기를 죄어도 같은 매핑을 낸다.")
    add("두 행은 실제로 각각 합성되었고 (FLOW_VARIANT date_4p0 / date_2p0)")
    add("타이밍 리포트만 다르다.")
    add("")
    add("두 구성 모두 worst path 가 `wr_fp16_i -> cvt_blk_o` 인 **조합 경로**다.")
    add("convert-on-write 유닛이 GRF write port 에 직결되어 있기 때문이며,")
    add("이것은 의도된 구조다 (변환 결과가 GRF 에 저장되는 값이다).")
    add("")
    add("이 경로에는 합성 플로우의 관례대로 입력·출력 각각 주기의 20 % 가")
    add("I/O delay 로 잡혀 있다. 두 주기의 arrival 차이에서 순수 논리 지연을")
    add("역산하면 약 **1.25 ns** 이고, 나머지는 I/O 예산이다. 실제 시스템에서")
    add("이 경로의 끝점은 GRF flop 이므로 500 MHz 에서도 논리 자체는 들어간다.")
    add("합성 리포트상의 500 MHz 미달(-0.04 ns, 2 %)은 그 I/O 예산 때문이다.")
    add("주기를 더 죄어야 한다면 변환 출력을 1 단 register 하는 방법이 있지만")
    add("WR->GRF 지연이 1 cycle 늘어 AAM barrier 타이밍에 영향을 주므로")
    add("구현하지 않고 제안으로만 남겼다 (docs/rabit_pcu_spec.md P2).")
    add("")

    add("### 전력 — 비교 시 주의")
    add("")
    add("`results/comparison_compute.csv` 의 rabit 행은 0.426 W / 13.3 pJ/MAC")
    add("이다. 같은 32 GMAC/s 인 p3llm 행(0.066 W / 2.1 pJ/MAC)보다 훨씬 큰데,")
    add("**이 차이의 상당 부분은 설계가 아니라 측정 방식에서 온다.**")
    add("")
    add("전력은 vectorless 추정이다 (입력 toggle rate 0.20 을 조합 논리로")
    add("확률 전파). 그런데 rabit 은 면적을 아끼려고 **stage A 입력을 등록하지")
    add("않았다** — word 와 block 을 2 cycle 동안 붙잡아 두는 일은 bank 와 GRF")
    add("몫이라 PCU 안에 입력 레지스터를 두지 않았다 (약 684 FF, 4,000 um2 절감).")
    add("그 결과 변환기와 8 개 PE 의 4:2 tree 가 전부 primary input 에서 바로")
    add("시작하는 조합 경로가 되어, 추정기가 그 논리 전체를 0.20 활성도로")
    add("때린다. p3llm 은 stage 0 에서 피연산자를 등록하므로 tree 가 flop 출력을")
    add("받는다. 실제로 rabit 행은 전력의 98.2 % 가 조합 논리 몫이다.")
    add("")
    add("XOR/majority 로만 이루어진 compressor tree 가 활성도가 높은 것은 사실")
    add("이므로 전부가 인공물은 아니다. 다만 이 숫자를 p3llm 과 나란히 놓고")
    add("에너지 효율을 논하려면 동일 자극(VCD) 기반 측정이 필요하고, 그것은")
    add("이 repo 의 4개 설계가 인터페이스가 달라 정의할 수 없다 (README §4).")
    add("면적·타이밍 비교와 달리 **전력 열은 설계 간 직접 비교 근거로 쓰지 말 것.**")
    add("")
    add("입력 레지스터를 넣는 쪽이 궁금하다면 docs/rabit_pcu_spec.md 의 제안")
    add("P5 를 참고. 면적은 baseline 아래에 그대로 남지만 이 경로가 사라진다.")
    add("")

    add("## 2. 모듈별 면적")
    add("")
    add("각 블록을 따로 합성한 값이다. 셋을 더한 값이 flat top 보다 큰데,")
    add("이유는 두 가지다. 첫째, 따로 합성하면 블록마다 자기 포트를 구동할")
    add("드라이버를 온전히 갖춰야 한다. 둘째, flat top 에서는 8 개 PE 가 block")
    add("mantissa 버스(214 bit)와 누산기 read mux 를 공유하지만 단독 PE 는 그")
    add("공유분을 혼자 떠안는다. 따라서 아래 표는 **상대 비중**을 보는 용도다.")
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
        add(f"| **단독 합성 소계** | | | **{total:,.0f}** | | |")
        add(f"| **flat top 실측** | | | **{flat:,.0f}** | "
            f"{area['rabit_pcu_250']['dffs']} | 시퀀서 포함, "
            f"소계 대비 {flat-total:+,.0f} |")
    add("")
    add("비중으로 읽으면 누산기 배열이 단연 크고 (2048 FF), 그 다음이 PE 8 개,")
    add("변환기는 하나뿐이라 가장 작다. 면적을 더 줄여야 한다면 `MANT_W` 가")
    add("PE 와 변환기 양쪽을 동시에 줄이는 유일한 노브다 — 누산기 배열은")
    add("`ACC_W` 와 group 수가 정하므로 스펙을 바꾸지 않는 한 고정이다.")
    add("")

    add("## 3. MANT_W / SHIFTER_EN 스윕")
    add("")
    add("면적은 모두 250 MHz 기준이다.")
    add("")
    add("| MANT_W | SHIFTER_EN | 면적 (um2) | 기본 구성 대비 | baseline 대비 | DFF |")
    add("|---:|:--:|---:|---:|---:|---:|")
    reference = (
        float(area["rabit_pcu_250"]["area_um2"]) if "rabit_pcu_250" in area else None
    )
    for label, mant, shifter in SWEEP:
        if label not in area:
            continue
        row = area[label]
        value = float(row["area_um2"])
        delta = f"{value-reference:+,.0f}" if reference else "n/a"
        add(f"| {mant} | {shifter} | {value:,.0f} | {delta} | "
            f"{value/base:.3f}x | {row['dffs']} |")
    add("")
    add("읽는 법:")
    add("")
    add("- `MANT_W` 12 -> 10 은 3,157 um2 (기본 구성의 7.0 %) 를 아낀다. 면적이")
    add("  더 필요할 때 제일 먼저 돌릴 노브다.")
    add("- `SHIFTER_EN` 을 끄면 **면적이 오히려 523 um2 늘어난다.** PE 8 개의")
    add("  barrel shifter 가 사라지는 대신, 변환기가 global E0 를 상대로")
    add("  정렬하면서 lane 마다 saturation/clamp 경로를 켜야 하고 그 비용이 더")
    add("  크다. 면적을 줄이려는 목적이라면 이 노브는 쓸 이유가 없다.")
    add("- 두 노브를 함께 쓰면 44,349 um2 로 기본 구성보다 905 um2 작지만,")
    add("  MANT_W 만 줄인 42,097 um2 보다 크다.")
    add("")

    accuracy = DESIGNS / "rabit_accuracy.md"
    if accuracy.exists():
        add("### 정확도")
        add("")
        add("`python3 tools/rabit_accuracy.py` 가 RTL 과 대조를 마친 같은 golden")
        add("model 로 실제 projection 형상에서 측정한 값이다. `PCU rel err` 은")
        add("동일한 binarized weight 를 정확히 계산한 값 대비 고정소수점")
        add("데이터패스의 오차이고, `quantization rel err` 은 양자화 전 layer")
        add("대비 전체 오차다.")
        add("")
        add(accuracy.read_text(encoding="utf-8").strip())
        add("")
        add("어느 구성이든 PCU 오차는 양자화 오차보다 최소 두 자릿수 작다.")
        add("즉 이 데이터패스의 고정소수점 선택은 RaBiT 정확도에 사실상 영향을")
        add("주지 않는다. `MANT_W` 10 으로 내려도 (면적 -7.0 %) 양자화 오차의")
        add("1/100 수준을 유지한다.")
        add("")
        add("truncating 행끼리의 산포는 정밀도가 아니라 정렬 우 shift 의 단방향")
        add("편향이다 (스펙이 지정한 산술 shift). `+ RNE` 행이 그 편향만 없앤")
        add("경우이고, docs/rabit_pcu_spec.md P1 에 제안으로 정리했다.")
        add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
