# DATE 논문 — PIM 연산기 RTL 및 합성 결과

정밀도와 조직이 다른 4종의 PIM 연산기를 **동일 조건에서** 설계·검증·합성한 결과.

---

## 1. 비교군

| 논문 행 | 정밀도 (W/A) | 조직 | 누산 | top 모듈 |
|---|---|---|---|---|
| hbm-pim | FP16 | SIMD MAC 레인 | binary32 | `hbmpim_fp16_pcu_16_lane` |
| awq-hbm-pim | INT4/FP16, INT4/BF16 | SIMD MAC 레인 | binary32 | `awq_int4{fp,bf}16_pcu_{16,32,64}_lane` |
| awq-p3-llm | INT4/FP16, INT4/BF16 | P3-LLM PCU | signed 32b 고정소수점 | `int4{fp,bf}16_pcu32`, `int4{fp,bf}16_pcu_top` |
| p3llm | FP4/FP8 | P3-LLM PCU | signed 32b 고정소수점 | `p3llm_pcu` |

앞의 네 행은 모두 **누산기를 포함한 경계**에서, **32비트 누산 폭**과 **4단 파이프라인**으로 측정한다.
SIMD 행은 원래 조합회로 곱셈·덧셈 뱅크였고 누산이 GRF에 있어 측정 경계 밖이었는데,
그러면 PCU 행만 순차 면적을 부담하게 되어 두 조직을 같은 기준으로 비교할 수 없었다.
지금은 SIMD 레인마다 binary32 가산기와 32비트 누산 레지스터를 갖는다.
이 때문에 SIMD 행의 면적은 이전 판보다 크며, 그 증가분이 곧 float 조직에서
32비트 누산이 치르는 비용이다 — PCU는 같은 자리에서 캐리 전파 덧셈만 하면 된다.

HBM-PIM과 AWQ-HBM-PIM SIMD의 multiplier 및 binary32 accumulator adder는 같은
비교용 경량 산술 contract를 사용한다. 정상 finite 입력은 RNE로 계산하며
subnormal 입력은 signed zero로 처리(DAZ), subnormal 결과는 signed zero로
flush(FTZ)한다. NaN과 infinity 입력은 지원 범위 밖이다.

---

## 2. 디렉토리

```
DATE_RTL/
├── rtl/
│   ├── 1_hbmpim/          FP16 SIMD: mul/add/1-lane/16-lane top
│   ├── 2_awq_hbmpim/      INT4 x FP16/BF16 SIMD: mul/add/1-lane/16·32·64-lane top
│   ├── 3_awq_p3llm_8pe/   INT4 x float PCU, 8 PE = 32 multiplier
│   ├── 3_awq_p3llm_16pe/  INT4 x float PCU, 16 PE = 64 multiplier
│   └── 4_p3llm/           FP4 x FP8 PCU
├── synth/                 합성 · 전력 · 표 생성 스크립트
├── verif/                 golden model 및 cocotb 테스트
│   └── fp32/              binary32 누산 경로 Verilator 검증 (cocotb 불필요)
└── results/               면적 · 타이밍 · 전력 리포트, 최종 표
```


## 3. 재현 방법

```bash
cd synth
./run_all.sh            # 합성 → 전력 → 표 생성
./run_all.sh synth      # 합성만
./run_all.sh power      # 전력만
./run_all.sh table      # 표만 재생성
python3 build_comparison_22nm.py  # 공통 결과에서 22nm 비교표만 재생성
```

필요한 외부 도구 (경로는 환경변수로 덮어쓸 수 있다):

| 도구 | 기본 경로 | 환경변수 |
|---|---|---|
| OpenROAD-flow-scripts | `~/.cache/openroad-user/OpenROAD-flow-scripts` | `ORFS_ROOT` |
| OpenROAD | `~/.local/openroad-2024/usr/bin/openroad` | `OPENROAD_EXE` |
| Yosys 0.52 | `~/.local/yosys-0.52/usr/bin/yosys` | `YOSYS_EXE` |
| sv2v 0.0.13 | `~/.local/sv2v-0.0.13/sv2v-Linux/sv2v` | `SV2V_EXE` |

산출물: `build/`(중간), `results/area.csv`, `results/reports/`,
`results/power/`, `results/comparison_compute.csv`,
`results/comparison_22nm.csv`.
모든 설계의 면적·report·power는 같은 `results/` 구조에 저장
면적만 재합성하여 netlist가 기존 power report보다 새로우면 두 CSV의 해당
`Power W`와 `pJ/MAC`은 빈 칸으로 표시한다. `./run_all.sh power`를 다시 실행한
뒤 표를 재생성해야 새 RTL 기준 전력·에너지가 채워진다.

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

**연산량 회계**
- SIMD MAC 레인과 P3-LLM PE는 매 cycle 새 입력을 받을 수 있으므로
  `MAC/cy`는 물리 multiplier 수와 같다. 즉 16/32/64 multiplier 행은 각각
  16/32/64 MAC/cycle이다.
- `add`는 RTL의 `+` 토큰 수가 아니라 **architectural accumulator lane 수**다.
  SIMD는 multiplier당 하나, 8/16-PE P3-LLM PCU는 8/16개다.

**22nm 투영표**
- `results/comparison_22nm.csv`의 면적과 power는 Nangate45 합성값을 각각
  4.545와 1.625로 나눈 투영값이며, `WNS45`는 45nm 측정값 그대로다.
- `pJ/MAC`은 45nm 연산 에너지를 2.100으로 나눈 별도 투영값이다. 이 계수에는
  node speed-up 가정이 포함되므로, 표에 유지한 목표 MHz/GMAC/s와 투영 power만
  다시 나누어 얻는 값과는 일치하지 않는다.

---

## 5. 검증

cocotb 1.9.2 + Verilator 5.032. 상세는 [verif/README.md](verif/README.md).

```bash
cd verif
make                                        
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 make   
```
