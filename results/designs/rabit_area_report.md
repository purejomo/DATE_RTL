# RaBiT 2-bit PIM 연산기 (PCU) — 면적 · 타이밍 리포트

- 생성: `synth/run_rabit.sh`
- 조건: Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지 (P&R 미수행)
- 명세: [docs/rabit_pcu_spec.md](../../docs/rabit_pcu_spec.md)

## 1. baseline 대비

비교 대상: **HBM-PIM FP16 16-lane SIMD 연산부** (`hbmpim_fp16_pcu_16_lane`,
60,176 um2 @ 4.0 ns).

- 포함: 곱셈기, 가산기, 32-bit 누산기
- 제외: GRF/CRF, 버퍼, bank 인터페이스
- RaBiT 만 추가로 포함: 누산기 배열 64 x 32b — stripe 하나의 k sweep 동안
  32 output x 2 path 를 상주시켜야 하므로 버퍼가 아니라 산술 상태다.

| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |
|---|---|---:|---:|---:|---:|---:|---:|
| HBM-PIM FP16 SIMD 16 lane | `hbmpim_fp16_pcu_16_lane` | 4.0 ns | 60,176 | 1.000x | 56433 | 1578 | +2.01 |
| RaBiT PCU, 8 PE, MANT_W 12, shifter on (250 MHz) | `rabit_pcu` | 4.0 ns | 45,254 | 0.752x | 37126 | 2208 | +1.16 |
| RaBiT PCU, 8 PE, MANT_W 12, shifter on (500 MHz) | `rabit_pcu` | 2.0 ns | 45,254 | 0.752x | 37126 | 2208 | -0.04 |

**면적 제약 충족**: 45,254 um2 < 60,176 um2 (baseline의 75.2 %, 14,922 um2 절감).

곱셈기 0 개 대신 누산기 배열 64 x 32b 를 경계 안에 넣고도 baseline 보다
작다. DFF 는 baseline 의 1.40 배 (2208 vs 1578) 지만 조합 논리가 훨씬 가볍다.

### 타이밍

PCU 는 column command 당 2 cycle (2-pump). 따라서 PCU 주기 4.0 ns = tCCD_S
8.0 ns, 2.0 ns = tCCD_S 4.0 ns.

- **250 MHz** (4.0 ns): slack +1.16 ns (MET). worst path `wr_fp16_i[27]` -> `cvt_blk_o[125]`, arrival 2.04 ns, required 3.20 ns.
- **500 MHz** (2.0 ns): slack -0.04 ns (VIOLATED). worst path `wr_fp16_i[27]` -> `cvt_blk_o[125]`, arrival 1.64 ns, required 1.60 ns.

두 주기의 면적이 같은 것은 오타가 아니다 — ABC area mode (`ABC_AREA=1`) 는
주기를 죄어도 같은 매핑을 낸다. 두 행 모두 실제로 합성했고 (FLOW_VARIANT
date_4p0 / date_2p0) 타이밍 리포트만 다르다.

worst path 는 두 구성 모두 `wr_fp16_i -> cvt_blk_o` **조합 경로**다.
convert-on-write 유닛이 GRF write port 에 직결된 의도된 구조다 (변환 결과가
GRF 에 저장되는 값). 500 MHz 미달(-0.04 ns, 2 %) 은 I/O 예산 때문이다:

- 이 경로에는 플로우 관례대로 입출력 각각 주기의 20 % 가 I/O delay 로 잡힌다.
- 두 주기의 arrival 차이에서 역산한 순수 논리 지연은 약 **1.25 ns**, 나머지는
  I/O 예산이다. 실제 시스템에서 끝점은 GRF flop 이므로 500 MHz 에서도 논리
  자체는 들어간다.
- 더 죄려면 변환 출력을 1 단 register 하면 되지만 WR->GRF 지연이 1 cycle 늘어
  AAM barrier 타이밍에 영향을 준다. 구현하지 않고 제안으로만 남겼다
  (docs/rabit_pcu_spec.md P2).

### 전력

전력은 vectorless `set_power_activity -global 0.20` 한 가지 모델이다 (모든
net 에 균일, 전파 없음). 같은 32 GMAC/s 인 p3llm 행과의 비교:

| | Power | pJ/MAC |
|---|---:|---:|
| p3llm_pcu | 0.0351 W | 1.10 |
| rabit_pcu | 0.0116 W | 0.36 |

이 3.0 배는 대체로 면적 차이를 다시 말하는 값이다 (셀 수 37,126 對 61,847).
`-global` 은 설계별 활성도를 구분하지 않아 전 행의 nW/cell 이 519~646
(산포 1.25x) 에 몰리고, 덜 토글하는 구조에 크레딧이 붙지 않는다.

**설계 간 에너지 우열은 이 표로 주장하지 않는다** — 방어 가능한 비교에는
gate-level VCD 가 필요하다. 특히 rabit 은 면적을 아끼려고 **stage A 입력을
등록하지 않아** (word/block 유지는 bank·GRF 몫, 약 684 FF ≈ 4,000 um2 절감)
변환기와 8 PE 의 4:2 tree 가 전부 primary input 에서 시작하는 조합 경로다.
활성도를 전파시키는 추정 모델에서 특히 불리하게 잡히는 구조다. 입력 레지스터를
넣는 쪽은 docs/rabit_pcu_spec.md 제안 P5 — 면적은 baseline 아래에 남는다.

## 2. 모듈별 면적

블록별 단독 합성값. 셋의 합이 flat top 보다 큰 이유는 두 가지다.

- 단독 합성은 블록마다 자기 포트를 구동할 드라이버를 온전히 갖춰야 한다.
- flat top 에서 8 PE 가 공유하는 block mantissa 버스 (214 bit) 와 누산기
  read mux 를 단독 PE 는 혼자 떠안는다.

따라서 아래 표는 **상대 비중용**이다.

| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |
|---|---:|---:|---:|---:|---|
| `cvt_fp16_to_blk` | 1 | 5,002 | 5,002 | 0 | convert-on-write, fp16x16 -> block |
| `rabit_pe` | 8 | 3,693 | 29,547 | 17 | negate + 4:2 tree + CPA + shift + acc add |
| `acc_regfile` | 1 | 20,872 | 20,872 | 2048 | 64 x 32b architectural accumulators |
| **단독 합성 소계** | | | **55,421** | | |
| **flat top 실측** | | | **45,254** | 2208 | 시퀀서 포함, 소계 대비 -10,168 |

비중은 누산기 배열 (2048 FF) > PE 8 개 > 변환기 (1 개뿐) 순이다. 면적을 더
줄이려면 `MANT_W` 가 PE 와 변환기를 동시에 줄이는 유일한 노브다 — 누산기
배열은 `ACC_W` 와 group 수가 정하므로 스펙을 바꾸지 않는 한 고정이다.

## 3. MANT_W / SHIFTER_EN 스윕

면적은 모두 250 MHz 기준이다.

| MANT_W | SHIFTER_EN | 면적 (um2) | 기본 구성 대비 | baseline 대비 | DFF |
|---:|:--:|---:|---:|---:|---:|
| 12 | on | 45,254 | +0 | 0.752x | 2208 |
| 10 | on | 42,097 | -3,157 | 0.700x | 2192 |
| 12 | off | 45,777 | +523 | 0.761x | 2200 |
| 10 | off | 44,349 | -905 | 0.737x | 2184 |

읽는 법:

- **`MANT_W` 12 -> 10**: 3,157 um2 절감 (기본 구성의 7.0 %). 면적이 더
  필요할 때 제일 먼저 돌릴 노브다.
- **`SHIFTER_EN` off**: 면적이 오히려 **523 um2 늘어난다.** PE 8 개의 barrel
  shifter 가 사라지는 대신 변환기가 global E0 정렬을 하면서 lane 마다
  saturation/clamp 경로를 켜야 하고, 그 비용이 더 크다. 면적 목적으로는
  쓸 이유가 없는 노브다.
- **둘 다**: 44,349 um2 로 기본 구성보다 905 um2 작지만 MANT_W 만 줄인
  42,097 um2 보다 크다.

### 정확도

`python3 tools/rabit_accuracy.py` 가 RTL 대조를 마친 golden model 로 실제
projection 형상에서 측정한 값이다.

- `PCU rel err`: 동일 binarized weight 를 정확히 계산한 값 대비 고정소수점
  데이터패스의 오차
- `quantization rel err`: 양자화 전 layer 대비 전체 오차

| shape | config | mean(E0-e_ent) | PCU rel err (mean) | PCU rel err (worst seed) | quantization rel err | sat |
|---|---|---:|---:|---:|---:|:--:|
| 4096x4096 | MANT_W 12, shifter on | 0.48 | 7.869e-04 | 1.151e-03 | 4.307e-01 | no |
| 4096x4096 | MANT_W 10, shifter on | 0.48 | 3.317e-03 | 4.994e-03 | 4.308e-01 | no |
| 4096x4096 | MANT_W 12, shifter off | 0.00 | 3.178e-04 | 4.533e-04 | 4.307e-01 | no |
| 4096x4096 | MANT_W 10, shifter off | 0.00 | 1.297e-03 | 1.518e-03 | 4.308e-01 | no |
| 4096x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.108e-04 | 2.969e-04 | 4.307e-01 | no |
| 11008x4096 | MANT_W 12, shifter on | 0.48 | 6.609e-04 | 9.982e-04 | 2.983e-01 | no |
| 11008x4096 | MANT_W 10, shifter on | 0.48 | 2.838e-03 | 3.458e-03 | 2.982e-01 | no |
| 11008x4096 | MANT_W 12, shifter off | 0.00 | 2.407e-04 | 3.217e-04 | 2.982e-01 | no |
| 11008x4096 | MANT_W 10, shifter off | 0.00 | 1.085e-03 | 1.402e-03 | 2.982e-01 | no |
| 11008x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.131e-04 | 3.093e-04 | 2.983e-01 | no |

cell 당 5 seeds x 16 sampled output rows, 오차는 L2-relative.

- **PCU 오차는 어느 구성이든 양자화 오차보다 최소 두 자릿수 작다.** 이
  데이터패스의 고정소수점 선택은 RaBiT 정확도에 사실상 영향이 없다.
  `MANT_W` 10 (면적 -7.0 %) 에서도 양자화 오차의 1/100 수준이다.
- **truncating 행은 worst-seed 열로 읽는다.** 산술 우 shift 가 floor 하므로
  오차가 단방향 편향이고 mean(E0-e_ent) 에 따라 커진다. 행 간 산포는 정밀도가
  아니라 이 편향이다.
- **`+ RNE` 행은 그 편향만 없앤 경우**로, 기본 제공이 아니라 제안이다
  (docs/rabit_pcu_spec.md P1).
- **이 표는 h = 1 고정이다** (`_fit_row` 참고). 학습된 per-input-channel h 는
  block exponent 를 벌려 E0 를 올리므로 truncating 행만 나빠진다 (RNE 행은
  그대로). packer 의 fitted h 를 쓰는 RTL 회귀가 MANT_W 12 에서 7.6e-4 ~
  3.8e-3 을 보이는 이유다.

