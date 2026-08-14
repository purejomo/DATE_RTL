# DATE 논문 — PIM 연산기 RTL 및 합성 결과

정밀도와 조직이 다른 4종의 PIM 연산기를 **동일 조건에서** 설계·검증·합성한 결과.

---

## 1. 비교군

| 비교군 | 정밀도 (W/A) | 합성 구성 | 누산 | 목표 클록 | top 모듈 |
|---|---|---|---|---:|---|
| hbm-pim | FP16/FP16 | SIMD 16 lane  | binary32 | 250 MHz | `hbmpim_fp16_pcu_16_lane` |
| awq-hbm-pim | INT4/FP16, INT4/BF16 | SIMD 16/32/64 lane  | binary32 | 500 MHz | `awq_int4{fp,bf}16_pcu_{16,32,64}_lane` |
| awq-p3-llm | INT4/FP16, INT4/BF16 | 8/16 PE | signed 32b 고정소수점 | 500 MHz | `int4{fp,bf}16_pcu32`, `int4{fp,bf}16_pcu_top` |
| p3llm | FP4/FP8 | 16 PE | signed 32b 고정소수점 | 500 MHz | `p3llm_pcu` |

모든 비교군은 multiplier와 accumulator를 포함한 연산 경계로 합성한다.
GRF/SRF, 데이터 버퍼, 명령 디코더 및 메모리 인터페이스는 합성 범위에 포함하지 않는다.

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
│   └── fp32/              binary32 누산 경로 Verilator 검증
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

설계의 면적·report·power는 같은 `results/` 구조에 저장

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

---

## 5. 검증

cocotb 1.9.2 + Verilator 5.032. 상세는 [verif/README.md](verif/README.md).

```bash
cd verif
make                                        
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 make   
```
