# DATE 논문 — PIM 연산기 RTL 및 합성 결과

정밀도가 다른 4종의 PIM 연산기를 **동일 조건에서** 설계·검증·합성한 결과.

---

## 1. 비교군

| 논문 행 | 정밀도 (W/A) | 조직 | top 모듈 |
|---|---|---|---|
| hbm-pim | FP16 | SIMD 뱅크 | `hbmpim_compute_16` |
| awq-hbm-pim | INT4/FP16, INT4/BF16 | SIMD 뱅크 | `int4{fp,bf}16_compute_{16,32,64}` |
| awq-p3-llm | INT4/FP16, INT4/BF16 | P3-LLM PCU | `int4{fp,bf}16_pcu32`, `int4{fp,bf}16_pcu_top` |
| p3llm | FP4/FP8 | P3-LLM PCU | `p3llm_pcu` |

---

## 2. 디렉토리

```
DATE_RTL/
├── rtl/
│   ├── common/            여러 설계가 공유하는 모듈
│   ├── 1_hbmpim/          FP16 SIMD 연산기 (baseline)
│   ├── 2_awq_hbmpim/      INT4 x float SIMD 연산기
│   ├── 3_awq_p3llm/       INT4 x float PCU (P3-LLM 조직)
│   └── 4_p3llm/           FP4 x FP8 PCU
├── synth/                 합성 · 전력 · 표 생성 스크립트
├── verif/                 golden model 및 cocotb 테스트
└── results/               면적 · 타이밍 · 전력 리포트, 최종 표
```

## 3. 재현 방법

```bash
cd synth
./run_all.sh            # 합성 → 전력 → 표 생성
./run_all.sh synth      # 합성만
./run_all.sh power      # 전력만
./run_all.sh table      # 표만 재생성
```

필요한 외부 도구 (경로는 환경변수로 덮어쓸 수 있다):

| 도구 | 기본 경로 | 환경변수 |
|---|---|---|
| OpenROAD-flow-scripts | `~/.cache/openroad-user/OpenROAD-flow-scripts` | `ORFS_ROOT` |
| OpenROAD | `~/.local/openroad-2024/usr/bin/openroad` | `OPENROAD_EXE` |
| Yosys 0.52 | `~/.local/yosys-0.52/usr/bin/yosys` | `YOSYS_EXE` |
| sv2v 0.0.13 | `~/.local/sv2v-0.0.13/sv2v-Linux/sv2v` | `SV2V_EXE` |

산출물: `build/`(중간), `results/area.csv`, `results/power/`,
`results/comparison_compute.csv`.

---

## 4. 측정 조건

**합성**
- 라이브러리: Nangate45 표준 셀, **typical corner** (1.10 V, 25 °C)
- 도구: Yosys 0.52 (ABC area mode) + OpenROAD
- 단계: **논리 합성까지. 배치배선(P&R) 미수행** → 면적은 셀 면적의 합이며
  배선 면적을 포함하지 않는다
- 주파수: hbm-pim 250 MHz, 나머지 500 MHz (각 논문의 값)

**전력**
- 방식: **vectorless** (확률적 활성도 전파). 4개 설계의 인터페이스가 달라
  동일 자극(VCD)을 정의할 수 없기 때문
- 가정: 입력 toggle rate **0.20** / duty **0.50**, 전 행 동일

---

## 5. 검증

cocotb 1.9.2 + Verilator 5.032. 상세는 [verif/README.md](verif/README.md).

```bash
cd verif
make                                        
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 make   
```

---

## 6. 결과 요약
`results/comparison_compute.csv`