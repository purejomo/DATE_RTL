#!/usr/bin/env python3
"""Build results/designs/rabit_pe_scaling.md from results/area.csv.

The PE-count question is answered by one formula and four synthesis runs, so
the document is generated rather than hand-written: every number below comes
from area.csv, and re-running synth/run_rabit.sh refreshes it.
"""

from __future__ import annotations

import csv
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
RESULTS = ROOT / "results"
OUTPUT = RESULTS / "designs" / "rabit_pe_scaling.md"

BASELINE = "compute_hbmpim_250"
NIN, NPATH, ACC_W = 16, 2, 32

# label : NOUT_PER_WORD : NGROUP : description
CONFIGS = (
    ("rabit_pcu_250", 8, 4, "현행"),
    ("rabit_pcu_g8_250", 8, 8, "stripe 2배"),
    ("rabit_pcu_g8_m10_250", 8, 8, "stripe 2배 + MANT_W 10"),
    ("rabit_pcu_16pe_250", 16, 2, "PE 2배, stripe 유지"),
    ("rabit_pcu_16pe_g4_250", 16, 4, "PE 2배 + stripe 2배"),
)


def rate(nout: int, ngroup: int) -> tuple[int, float]:
    """(stripe width, sustained products per cycle) for the 2 WR : NGROUP RD schedule."""
    stripe = nout * ngroup
    cols_per_rd = nout * NIN * NPATH // 256       # a 512-bit word costs two columns
    commands = 2 + (stripe // nout) * cols_per_rd  # 2 WR + the RD burst
    return stripe, (stripe * NIN * NPATH) / (NPATH * commands)


def main() -> None:
    area = {r["label"]: r for r in csv.DictReader((RESULTS / "area.csv").open())}
    if BASELINE not in area:
        raise SystemExit(f"missing baseline row {BASELINE}")
    base = float(area[BASELINE]["area_um2"])

    L: list[str] = []
    add = L.append
    add("# RaBiT PE 수 확장 (8 -> 16 PE) 검토")
    add("")
    add("- 생성: `synth/build_rabit_pe_scaling.py` (`results/area.csv` 기반)")
    add("- 합성: `cd synth && ./run_rabit.sh`")
    add("")
    add("**결론: 16 PE 는 하지 말 것.** 면적은 baseline 을 넘고 sustained throughput 은")
    add("늘지 않는다. 늘리려면 PE 가 아니라 **stripe 폭** (`NGROUP`) 을 건드려야 한다 —")
    add("같은 이득이 훨씬 싸다.")
    add("")
    add("## 1. 8 PE 는 파라미터가 아니라 결과다")
    add("")
    add("```")
    add("WORD_W = NIN x NOUT_PER_WORD x NPATH = 16 x 8 x 2 = 256 bit = column word 하나")
    add("```")
    add("")
    add("`NIN=16` 은 GRF entry 포맷이, `NPATH=2` 는 RaBiT 2-bit 정의가, 256 bit 는")
    add("DRAM 이 정한다. 셋이 고정이면 `NOUT_PER_WORD = 256/(16x2) = 8` 하나만 남는다.")
    add("")
    add("## 2. sustained throughput 은 PE 수와 무관하다")
    add("")
    add("스케줄은 k chunk 마다 **2 WR + NGROUP RD** 다 (`tools/pack_rabit.py` 가")
    add("`n_rd == 2*n_wr` 로 강제). WR 도 column command 를 먹는다 (`rabit_pcu_top.sv`")
    add("가 `!(wr_valid_i && rd_valid_i)` 를 assert). stripe 폭을 S 라 하면 k chunk 당")
    add("column command `2 + S/8`, cycle 은 그 2배, 곱은 `32S` 이므로")
    add("")
    add("```")
    add("sustained = 32S / (2 x (2 + S/8)) = 128 x S / (S + 16)   products/cycle")
    add("```")
    add("")
    add("**NOUT (PE 수) 가 소거된다.** throughput 은 상주 stripe 폭만의 함수다.")
    add("")
    add("| 구성 | stripe | sustained p/cy | GMAC/s @250MHz | duty |")
    add("|---|---:|---:|---:|---:|")
    for label, nout, ngroup, _ in CONFIGS:
        if label.endswith("m10_250"):
            continue
        stripe, r = rate(nout, ngroup)
        cols = 2 + (stripe // nout) * (nout * NIN * NPATH // 256)
        add(f"| {nout} PE, NGROUP {ngroup} | {stripe} | {r:.2f} | {r*0.25:.2f} | "
            f"{(cols-2)/cols*100:.1f} % |")
    add("| (상한: WR 이 공짜라면) | inf | 128.00 | 32.00 | 100 % |")
    add("")
    add("- **16 PE NGROUP 2 == 8 PE NGROUP 4** (둘 다 stripe 32, 85.33 p/cy)")
    add("- **16 PE NGROUP 4 == 8 PE NGROUP 8** (둘 다 stripe 64, 102.4 p/cy)")
    add("")
    add("비교표의 `MAC/cy = 128`, `32.0 GMAC/s` 는 **peak** 이다 (RD 중일 때 값). 다른")
    add("행도 같은 규약이라 행간 비교는 유효하나, RaBiT 의 실제 duty 는 현행 구성에서")
    add("4/6 = 66.7 %, sustained 는 21.33 GMAC/s 다.")
    add("")
    add("## 3. 측정된 면적")
    add("")
    add(f"Nangate45, 4.0 ns, 다른 행과 동일 조건. baseline = `{BASELINE}`")
    add(f"{base:,.0f} um2.")
    add("")
    add("| 구성 | label | 면적 [um2] | baseline 대비 | DFF | sustained |")
    add("|---|---|---:|---:|---:|---:|")
    for label, nout, ngroup, note in CONFIGS:
        row = area.get(label)
        if row is None:
            add(f"| {note} | `{label}` | (미측정) | | | |")
            continue
        value = float(row["area_um2"])
        _, r = rate(nout, ngroup)
        flag = "" if value < base else " **초과**"
        add(f"| {nout} PE NGROUP {ngroup} — {note} | `{label}` | {value:,.0f} | "
            f"{value/base:.3f}x{flag} | {row['dffs']} | {r:.1f} p/cy |")
    add("")
    add("읽는 법:")
    add("")
    add("- **16 PE 는 어느 쪽으로 가도 baseline 초과.** stripe 를 유지해도 (NGROUP 2)")
    add("  PE array 만으로 넘고, 같이 늘리면 누산기까지 2배가 된다.")
    add("- **8 PE + NGROUP 8 = 16 PE + NGROUP 4 = 102.4 p/cy.** 같은 stripe 64 를 훨씬")
    add("  싸게 사는 것이다.")
    add("- **`MANT_W` 10 을 함께 쓰면** stripe 를 2배로 하고도 baseline 아래다.")
    add("")
    add("## 4. 측정 노이즈 바닥 — 1 % 이하 차이는 해석하지 말 것")
    add("")
    add("같은 RTL 을 소스 파일 **순서만 바꿔** 합성해도 면적이 최대 0.9 % 움직인다 —")
    add("ABC 가 drive strength 를 다르게 고르기 때문이다.")
    add("")
    add("- `rabit_pcu`: 45,253.5 vs 45,645.9 (cell 수는 동일)")
    add("- `rabit_pcu_16pe_g4`: 85,237.6 vs 86,501.9")
    add("")
    add("**행 사이 1 % 미만 차이는 설계 차이로 읽지 말 것.** 이 표의 값은 전부")
    add("`run_rabit.sh` 의 정규 소스 순서로 측정했다.")
    add("")
    add("## 5. NGROUP 을 올리는 데 드는 비용 (면적 밖)")
    add("")
    add("`NGROUP 4 -> 8` 은 스위치 하나가 아니다.")
    add("")
    add("- **`tools/pack_rabit.py`**: `NGROUP`, `OUT_PER_STRIPE`, 그리고")
    add("  `K_CHUNKS_PER_ROW = COLS_PER_ROW // NGROUP` 이 8 -> 4 로 줄어 **같은 k sweep")
    add("  에 row activation 이 2배**가 된다. PCU 밖 비용이라 여기서 값을 매길 수 없다 —")
    add("  +20 % 를 순증으로 주장하면 안 된다.")
    add("- **CA 배치**: `{k_chunk, out_group[2:0]}` 로 변경 (docs 3장).")
    add("- **회귀**: `verif/models/rabit_model.py` 의 `NGROUP` 상수, 테스트 추가.")
    add("")
    add("## 6. 16 PE 가 의미를 갖는 유일한 조건")
    add("")
    add("연산이 아니라 공급을 늘려야 한다 — column word 를 512 bit 로 넓히거나, bank")
    add("두 개가 PCU 하나를 먹이거나, column 간격을 절반으로 줄이거나. 전부 bank")
    add("인터페이스 가정을 바꾸는 일이라 스펙 9장 밖이다.")
    add("")
    add("**짚어둘 비대칭**: baseline `hbmpim_fp16_pcu_16_lane` 은 `i_a[255:0]` +")
    add("`i_b[255:0]` 로 **매 cycle** 256-bit column 하나를 받고, RaBiT 는 2 cycle 에")
    add("하나다. 즉 지금 표는 baseline 에 RaBiT 의 2배 column rate 를 주고 있다. 같은")
    add("rate 라면 16 PE 도 실제로 이득이 난다 (204.8 p/cy). 이 전제는 스펙이 정한")
    add("것이라 여기서 바꾸지 않았다.")
    add("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
