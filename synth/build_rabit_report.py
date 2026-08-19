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
    add("- 생성: `synth/run_rabit.sh`")
    add("- 조건: Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지 (P&R 미수행)")
    add("- 명세: [docs/rabit_pcu_spec.md](../../docs/rabit_pcu_spec.md)")
    add("")
    add("## 1. baseline 대비")
    add("")
    add(f"비교 대상: **HBM-PIM FP16 16-lane SIMD 연산부** (`{area[BASELINE]['top']}`,")
    add(f"{base:,.0f} um2 @ {area[BASELINE]['clock_ns']} ns).")
    add("")
    add("- 포함: 곱셈기, 가산기, 32-bit 누산기")
    add("- 제외: GRF/CRF, 버퍼, bank 인터페이스")
    add("- RaBiT 만 추가로 포함: 누산기 배열 64 x 32b — stripe 하나의 k sweep 동안")
    add("  32 output x 2 path 를 상주시켜야 하므로 버퍼가 아니라 산술 상태다.")
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
        add("곱셈기 0 개 대신 누산기 배열 64 x 32b 를 경계 안에 넣고도 baseline 보다")
        add("작다. DFF 는 baseline 의 1.40 배 (2208 vs 1578) 지만 조합 논리가 훨씬 가볍다.")
        add("")

    add("### 타이밍")
    add("")
    add("PCU 는 column command 당 2 cycle (2-pump). 따라서 PCU 주기 4.0 ns = tCCD_S")
    add("8.0 ns, 2.0 ns = tCCD_S 4.0 ns.")
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
    add("두 주기의 면적이 같은 것은 오타가 아니다 — ABC area mode (`ABC_AREA=1`) 는")
    add("주기를 죄어도 같은 매핑을 낸다. 두 행 모두 실제로 합성했고 (FLOW_VARIANT")
    add("date_4p0 / date_2p0) 타이밍 리포트만 다르다.")
    add("")
    add("worst path 는 두 구성 모두 `wr_fp16_i -> cvt_blk_o` **조합 경로**다.")
    add("convert-on-write 유닛이 GRF write port 에 직결된 의도된 구조다 (변환 결과가")
    add("GRF 에 저장되는 값). 500 MHz 미달(-0.04 ns, 2 %) 은 I/O 예산 때문이다:")
    add("")
    add("- 이 경로에는 플로우 관례대로 입출력 각각 주기의 20 % 가 I/O delay 로 잡힌다.")
    add("- 두 주기의 arrival 차이에서 역산한 순수 논리 지연은 약 **1.25 ns**, 나머지는")
    add("  I/O 예산이다. 실제 시스템에서 끝점은 GRF flop 이므로 500 MHz 에서도 논리")
    add("  자체는 들어간다.")
    add("- 더 죄려면 변환 출력을 1 단 register 하면 되지만 WR->GRF 지연이 1 cycle 늘어")
    add("  AAM barrier 타이밍에 영향을 준다. 구현하지 않고 제안으로만 남겼다")
    add("  (docs/rabit_pcu_spec.md P2).")
    add("")

    add("### 전력")
    add("")
    add("전력은 vectorless `set_power_activity -global 0.20` 한 가지 모델이다 (모든")
    add("net 에 균일, 전파 없음). 같은 32 GMAC/s 인 p3llm 행과의 비교:")
    add("")
    add("| | Power | pJ/MAC |")
    add("|---|---:|---:|")
    add("| p3llm_pcu | 0.0351 W | 1.10 |")
    add("| rabit_pcu | 0.0116 W | 0.36 |")
    add("")
    add("이 3.0 배는 대체로 면적 차이를 다시 말하는 값이다 (셀 수 37,126 對 61,847).")
    add("`-global` 은 설계별 활성도를 구분하지 않아 전 행의 nW/cell 이 519~646")
    add("(산포 1.25x) 에 몰리고, 덜 토글하는 구조에 크레딧이 붙지 않는다.")
    add("")
    add("**설계 간 에너지 우열은 이 표로 주장하지 않는다** — 방어 가능한 비교에는")
    add("gate-level VCD 가 필요하다. 특히 rabit 은 면적을 아끼려고 **stage A 입력을")
    add("등록하지 않아** (word/block 유지는 bank·GRF 몫, 약 684 FF ≈ 4,000 um2 절감)")
    add("변환기와 8 PE 의 4:2 tree 가 전부 primary input 에서 시작하는 조합 경로다.")
    add("활성도를 전파시키는 추정 모델에서 특히 불리하게 잡히는 구조다. 입력 레지스터를")
    add("넣는 쪽은 docs/rabit_pcu_spec.md 제안 P5 — 면적은 baseline 아래에 남는다.")
    add("")

    add("## 2. 모듈별 면적")
    add("")
    add("블록별 단독 합성값. 셋의 합이 flat top 보다 큰 이유는 두 가지다.")
    add("")
    add("- 단독 합성은 블록마다 자기 포트를 구동할 드라이버를 온전히 갖춰야 한다.")
    add("- flat top 에서 8 PE 가 공유하는 block mantissa 버스 (214 bit) 와 누산기")
    add("  read mux 를 단독 PE 는 혼자 떠안는다.")
    add("")
    add("따라서 아래 표는 **상대 비중용**이다.")
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
    add("비중은 누산기 배열 (2048 FF) > PE 8 개 > 변환기 (1 개뿐) 순이다. 면적을 더")
    add("줄이려면 `MANT_W` 가 PE 와 변환기를 동시에 줄이는 유일한 노브다 — 누산기")
    add("배열은 `ACC_W` 와 group 수가 정하므로 스펙을 바꾸지 않는 한 고정이다.")
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
    add("- **`MANT_W` 12 -> 10**: 3,157 um2 절감 (기본 구성의 7.0 %). 면적이 더")
    add("  필요할 때 제일 먼저 돌릴 노브다.")
    add("- **`SHIFTER_EN` off**: 면적이 오히려 **523 um2 늘어난다.** PE 8 개의 barrel")
    add("  shifter 가 사라지는 대신 변환기가 global E0 정렬을 하면서 lane 마다")
    add("  saturation/clamp 경로를 켜야 하고, 그 비용이 더 크다. 면적 목적으로는")
    add("  쓸 이유가 없는 노브다.")
    add("- **둘 다**: 44,349 um2 로 기본 구성보다 905 um2 작지만 MANT_W 만 줄인")
    add("  42,097 um2 보다 크다.")
    add("")

    accuracy = DESIGNS / "rabit_accuracy.md"
    if accuracy.exists():
        add("### 정확도")
        add("")
        add("`python3 tools/rabit_accuracy.py` 가 RTL 대조를 마친 golden model 로 실제")
        add("projection 형상에서 측정한 값이다.")
        add("")
        add("- `PCU rel err`: 동일 binarized weight 를 정확히 계산한 값 대비 고정소수점")
        add("  데이터패스의 오차")
        add("- `quantization rel err`: 양자화 전 layer 대비 전체 오차")
        add("")
        # Only the table is inlined. rabit_accuracy.md carries the same notes
        # in English for readers who open it on its own; repeating them here
        # would say the same thing twice in two languages.
        table = [ln for ln in accuracy.read_text(encoding="utf-8").splitlines()
                 if ln.startswith("|")]
        add("\n".join(table))
        add("")
        add("cell 당 5 seeds x 16 sampled output rows, 오차는 L2-relative.")
        add("")
        add("- **PCU 오차는 어느 구성이든 양자화 오차보다 최소 두 자릿수 작다.** 이")
        add("  데이터패스의 고정소수점 선택은 RaBiT 정확도에 사실상 영향이 없다.")
        add("  `MANT_W` 10 (면적 -7.0 %) 에서도 양자화 오차의 1/100 수준이다.")
        add("- **truncating 행은 worst-seed 열로 읽는다.** 산술 우 shift 가 floor 하므로")
        add("  오차가 단방향 편향이고 mean(E0-e_ent) 에 따라 커진다. 행 간 산포는 정밀도가")
        add("  아니라 이 편향이다.")
        add("- **`+ RNE` 행은 그 편향만 없앤 경우**로, 기본 제공이 아니라 제안이다")
        add("  (docs/rabit_pcu_spec.md P1).")
        add("- **이 표는 h = 1 고정이다** (`_fit_row` 참고). 학습된 per-input-channel h 는")
        add("  block exponent 를 벌려 E0 를 올리므로 truncating 행만 나빠진다 (RNE 행은")
        add("  그대로). packer 의 fitted h 를 쓰는 RTL 회귀가 MANT_W 12 에서 7.6e-4 ~")
        add("  3.8e-3 을 보이는 이유다.")
        add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
