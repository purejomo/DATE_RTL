# RaBiT 2-bit PIM 연산기 (PCU) — 면적 · 타이밍 리포트

`synth/run_rabit.sh` 가 생성한다. 측정 조건은 다른 행과 동일하다:
Nangate45 typical corner, Yosys 0.52 (ABC area mode) + OpenROAD,
논리 합성까지 (P&R 미수행).

## 1. baseline 대비

비교 대상은 HBM-PIM FP16 16-lane SIMD 연산부
(`hbmpim_fp16_pcu_16_lane`, 60,176 um2 @ 4.0 ns).
두 설계 모두 곱셈기·가산기·32-bit 누산기를 포함하고 GRF/CRF·버퍼·
bank 인터페이스는 제외한다. RaBiT 쪽은 누산기 배열 64 x 32b 가
경계 안에 있다 — stripe 하나의 k sweep 동안 32 output x 2 path 를
상주시켜야 하므로 버퍼가 아니라 산술 상태다.

| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |
|---|---|---:|---:|---:|---:|---:|---:|
| HBM-PIM FP16 SIMD 16 lane | `hbmpim_fp16_pcu_16_lane` | 4.0 ns | 60,176 | 1.000x | 56433 | 1578 | +2.01 |
| RaBiT PCU, 8 PE, MANT_W 12, shifter on (250 MHz) | `rabit_pcu` | 4.0 ns | 45,254 | 0.752x | 37126 | 2208 | +1.16 |
| RaBiT PCU, 8 PE, MANT_W 12, shifter on (500 MHz) | `rabit_pcu` | 2.0 ns | 45,254 | 0.752x | 37126 | 2208 | -0.04 |

**면적 제약 충족**: 45,254 um2 < 60,176 um2 (baseline의 75.2 %, 14,922 um2 절감).

곱셈기가 하나도 없는 대신 누산기 배열 64 x 32b 가 경계 안으로
들어왔는데도 baseline 보다 작다. DFF 는 baseline 의 1.40 배지만
(2208 vs 1578) 조합 논리가 훨씬 가볍다.

### 타이밍

PCU 는 column command 하나당 2 cycle 을 쓴다 (2-pump). 따라서 PCU 주기
4.0 ns 는 tCCD_S 8.0 ns 에 해당하고, 2.0 ns 는 tCCD_S 4.0 ns 다.

- **250 MHz** (4.0 ns): slack +1.16 ns (MET). worst path `wr_fp16_i[27]` -> `cvt_blk_o[125]`, arrival 2.04 ns, required 3.20 ns.
- **500 MHz** (2.0 ns): slack -0.04 ns (VIOLATED). worst path `wr_fp16_i[27]` -> `cvt_blk_o[125]`, arrival 1.64 ns, required 1.60 ns.

두 주기의 면적이 같은 것은 오타가 아니다. 이 플로우는 ABC 를 area
mode (`ABC_AREA=1`) 로 돌리므로 주기를 죄어도 같은 매핑을 낸다.
두 행은 실제로 각각 합성되었고 (FLOW_VARIANT date_4p0 / date_2p0)
타이밍 리포트만 다르다.

두 구성 모두 worst path 가 `wr_fp16_i -> cvt_blk_o` 인 **조합 경로**다.
convert-on-write 유닛이 GRF write port 에 직결되어 있기 때문이며,
이것은 의도된 구조다 (변환 결과가 GRF 에 저장되는 값이다).

이 경로에는 합성 플로우의 관례대로 입력·출력 각각 주기의 20 % 가
I/O delay 로 잡혀 있다. 두 주기의 arrival 차이에서 순수 논리 지연을
역산하면 약 **1.25 ns** 이고, 나머지는 I/O 예산이다. 실제 시스템에서
이 경로의 끝점은 GRF flop 이므로 500 MHz 에서도 논리 자체는 들어간다.
합성 리포트상의 500 MHz 미달(-0.04 ns, 2 %)은 그 I/O 예산 때문이다.
주기를 더 죄어야 한다면 변환 출력을 1 단 register 하는 방법이 있지만
WR->GRF 지연이 1 cycle 늘어 AAM barrier 타이밍에 영향을 주므로
구현하지 않고 제안으로만 남겼다 (docs/rabit_pcu_spec.md P2).

### 전력 — 비교 시 주의

`results/comparison_compute.csv` 의 rabit 행은 0.426 W / 13.3 pJ/MAC
이다. 같은 32 GMAC/s 인 p3llm 행(0.066 W / 2.1 pJ/MAC)보다 훨씬 큰데,
**이 차이의 상당 부분은 설계가 아니라 측정 방식에서 온다.**

전력은 vectorless 추정이다 (입력 toggle rate 0.20 을 조합 논리로
확률 전파). 그런데 rabit 은 면적을 아끼려고 **stage A 입력을 등록하지
않았다** — word 와 block 을 2 cycle 동안 붙잡아 두는 일은 bank 와 GRF
몫이라 PCU 안에 입력 레지스터를 두지 않았다 (약 684 FF, 4,000 um2 절감).
그 결과 변환기와 8 개 PE 의 4:2 tree 가 전부 primary input 에서 바로
시작하는 조합 경로가 되어, 추정기가 그 논리 전체를 0.20 활성도로
때린다. p3llm 은 stage 0 에서 피연산자를 등록하므로 tree 가 flop 출력을
받는다. 실제로 rabit 행은 전력의 98.2 % 가 조합 논리 몫이다.

XOR/majority 로만 이루어진 compressor tree 가 활성도가 높은 것은 사실
이므로 전부가 인공물은 아니다. 다만 이 숫자를 p3llm 과 나란히 놓고
에너지 효율을 논하려면 동일 자극(VCD) 기반 측정이 필요하고, 그것은
이 repo 의 4개 설계가 인터페이스가 달라 정의할 수 없다 (README §4).
면적·타이밍 비교와 달리 **전력 열은 설계 간 직접 비교 근거로 쓰지 말 것.**

입력 레지스터를 넣는 쪽이 궁금하다면 docs/rabit_pcu_spec.md 의 제안
P5 를 참고. 면적은 baseline 아래에 그대로 남지만 이 경로가 사라진다.

## 2. 모듈별 면적

각 블록을 따로 합성한 값이다. 셋을 더한 값이 flat top 보다 큰데,
이유는 두 가지다. 첫째, 따로 합성하면 블록마다 자기 포트를 구동할
드라이버를 온전히 갖춰야 한다. 둘째, flat top 에서는 8 개 PE 가 block
mantissa 버스(214 bit)와 누산기 read mux 를 공유하지만 단독 PE 는 그
공유분을 혼자 떠안는다. 따라서 아래 표는 **상대 비중**을 보는 용도다.

| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |
|---|---:|---:|---:|---:|---|
| `cvt_fp16_to_blk` | 1 | 5,002 | 5,002 | 0 | convert-on-write, fp16x16 -> block |
| `rabit_pe` | 8 | 3,693 | 29,547 | 17 | negate + 4:2 tree + CPA + shift + acc add |
| `acc_regfile` | 1 | 20,872 | 20,872 | 2048 | 64 x 32b architectural accumulators |
| **단독 합성 소계** | | | **55,421** | | |
| **flat top 실측** | | | **45,254** | 2208 | 시퀀서 포함, 소계 대비 -10,168 |

비중으로 읽으면 누산기 배열이 단연 크고 (2048 FF), 그 다음이 PE 8 개,
변환기는 하나뿐이라 가장 작다. 면적을 더 줄여야 한다면 `MANT_W` 가
PE 와 변환기 양쪽을 동시에 줄이는 유일한 노브다 — 누산기 배열은
`ACC_W` 와 group 수가 정하므로 스펙을 바꾸지 않는 한 고정이다.

## 3. MANT_W / SHIFTER_EN 스윕

면적은 모두 250 MHz 기준이다.

| MANT_W | SHIFTER_EN | 면적 (um2) | 기본 구성 대비 | baseline 대비 | DFF |
|---:|:--:|---:|---:|---:|---:|
| 12 | on | 45,254 | +0 | 0.752x | 2208 |
| 10 | on | 42,097 | -3,157 | 0.700x | 2192 |
| 12 | off | 45,777 | +523 | 0.761x | 2200 |
| 10 | off | 44,349 | -905 | 0.737x | 2184 |

읽는 법:

- `MANT_W` 12 -> 10 은 3,157 um2 (기본 구성의 7.0 %) 를 아낀다. 면적이
  더 필요할 때 제일 먼저 돌릴 노브다.
- `SHIFTER_EN` 을 끄면 **면적이 오히려 523 um2 늘어난다.** PE 8 개의
  barrel shifter 가 사라지는 대신, 변환기가 global E0 를 상대로
  정렬하면서 lane 마다 saturation/clamp 경로를 켜야 하고 그 비용이 더
  크다. 면적을 줄이려는 목적이라면 이 노브는 쓸 이유가 없다.
- 두 노브를 함께 쓰면 44,349 um2 로 기본 구성보다 905 um2 작지만,
  MANT_W 만 줄인 42,097 um2 보다 크다.

### 정확도

`python3 tools/rabit_accuracy.py` 가 RTL 과 대조를 마친 같은 golden
model 로 실제 projection 형상에서 측정한 값이다. `PCU rel err` 은
동일한 binarized weight 를 정확히 계산한 값 대비 고정소수점
데이터패스의 오차이고, `quantization rel err` 은 양자화 전 layer
대비 전체 오차다.

| shape | config | mean(E0-e_ent) | PCU rel err (mean) | PCU rel err (worst seed) | quantization rel err | sat |
|---|---|---:|---:|---:|---:|:--:|
| 4096x4096 | MANT_W 12, shifter on | 0.48 | 7.116e-04 | 1.151e-03 | 4.163e-01 | no |
| 4096x4096 | MANT_W 10, shifter on | 0.48 | 3.104e-03 | 4.994e-03 | 4.165e-01 | no |
| 4096x4096 | MANT_W 12, shifter off | 0.00 | 2.804e-04 | 4.533e-04 | 4.162e-01 | no |
| 4096x4096 | MANT_W 10, shifter off | 0.00 | 1.199e-03 | 1.518e-03 | 4.163e-01 | no |
| 4096x4096 | MANT_W 12, shifter on + RNE | 0.48 | 1.959e-04 | 2.969e-04 | 4.162e-01 | no |
| 11008x4096 | MANT_W 12, shifter on | 0.48 | 6.608e-04 | 9.982e-04 | 3.309e-01 | no |
| 11008x4096 | MANT_W 10, shifter on | 0.48 | 2.862e-03 | 3.458e-03 | 3.310e-01 | no |
| 11008x4096 | MANT_W 12, shifter off | 0.00 | 2.441e-04 | 3.217e-04 | 3.308e-01 | no |
| 11008x4096 | MANT_W 10, shifter off | 0.00 | 1.089e-03 | 1.402e-03 | 3.308e-01 | no |
| 11008x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.152e-04 | 3.093e-04 | 3.308e-01 | no |

8 seeds x 16 sampled output rows per cell; errors are L2-relative.

The worst-seed column is the one to read for the truncating rows: the arithmetic right shift floors, so its error is a one-sided bias that grows with mean(E0-e_ent). The `+ RNE` row shows what removing that bias would buy (proposal P1 in docs/rabit_pcu_spec.md); it is not the delivered default.

These rows hold h = 1 (see _fit_row), which keeps the block exponents close together. Trained per-input-channel h spreads them further and pushes E0 up, so the truncating rows get worse while the RNE row does not: the RTL regression, whose stimulus comes from the packer's fitted h, sees 7.6e-4 to 3.8e-3 at MANT_W 12 for exactly this reason.

어느 구성이든 PCU 오차는 양자화 오차보다 최소 두 자릿수 작다.
즉 이 데이터패스의 고정소수점 선택은 RaBiT 정확도에 사실상 영향을
주지 않는다. `MANT_W` 10 으로 내려도 (면적 -7.0 %) 양자화 오차의
1/100 수준을 유지한다.

truncating 행끼리의 산포는 정밀도가 아니라 정렬 우 shift 의 단방향
편향이다 (스펙이 지정한 산술 shift). `+ RNE` 행이 그 편향만 없앤
경우이고, docs/rabit_pcu_spec.md P1 에 제안으로 정리했다.

