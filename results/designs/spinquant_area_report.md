# SpinQuant W4A4 PIM 연산기 (PCU) — 면적 · 타이밍 리포트

- 생성: `synth/run_spinquant.sh`
- 조건: Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지 (P&R 미수행)
- 명세: [docs/spinquant_pcu_spec.md](../../docs/spinquant_pcu_spec.md)

## 1. 면적 제약

제약: **HBM-PIM 16-lane FP16 SIMD 연산부 (60,176 um2 @ 4.0 ns) 이하.**

- 포함: 곱셈기, 가산기, 32b 누산기
- 제외: GRF/CRF, 버퍼, bank 인터페이스
- SpinQuant 만 추가로 포함: 256b read latch, 누산기 파일 4 x 16 x 32b (가격은 2절)

| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |
|---|---|---:|---:|---:|---:|---:|---:|
| HBM-PIM FP16 SIMD 16 lane | `hbmpim_fp16_pcu_16_lane` | 4.0 ns | 60,176 | 1.000x | 56433 | 1578 | +2.01 |
| SpinQuant PCU — tCCD_S (500 MHz) | `spinquant_pcu` | 2.0 ns | 32,376 | 0.538x | 25843 | 1960 | +0.88 |
| SpinQuant PCU — tCCD_L (250 MHz) | `spinquant_pcu` | 4.0 ns | 32,376 | 0.538x | 25843 | 1960 | +2.09 |

**충족**: 32,376 vs 60,176 um2 — baseline 의 53.8 %, 27,800 um2 (46.2 %) 절감.

| 설계 | 면적 (um2) | baseline 대비 | MAC/cycle | um2/MAC |
|---|---:|---:|---:|---:|
| SpinQuant W4A4 PCU, 16 PE x 4 way | 32,376 | 0.538x | 64 | 506 |
| P3-LLM PCU, FP4/FP8, 16 PE x 4 way | 71,287 | 1.185x | 64 | 1,114 |
| AWQ P3-LLM PCU, INT4/BF16, 16 PE x 4 way | 72,280 | 1.201x | 64 | 1,129 |
| RaBiT PCU, 2-bit RB/FP16, 8 PE (250 MHz) | 45,254 | 0.752x | 128 | 354 |
| HBM-PIM FP16 SIMD 16 lane | 60,176 | 1.000x | 16 | 3,761 |

조직은 **P3-LLM PCU 와 동일** (16 PE x 4 way, 64 multiplier). 조직을 고정하고
정밀도만 바꾼 행이다. 면적 차이의 내역:

- 없어진 것: FP8/FP4 디코더, exponent alignment shifter, BitMoD special-value
  경로, zero-point 감산기, scale 곱셈기. 곱셈기는 signed4 x unsigned4 하나뿐.
- 늘어난 것: 누산기 파일. P3-LLM 은 PE 당 1 개 (16 x 32b), 이 설계는 GRF
  해석대로 entry 4 개 (4 x 16 x 32b).

| 설계 | 총 면적 | 조합 (um2) | 순차 (um2) | 순차 비중 | DFF |
|---|---:|---:|---:|---:|---:|
| SpinQuant W4A4 PCU | 32,376 | 23,513 | 8,863 | 27.4 % | 1960 |
| P3-LLM PCU | 71,287 | 59,557 | 11,730 | 16.5 % | 2594 |
| HBM-PIM FP16 SIMD 16 lane | 60,176 | 53,040 | 7,136 | 11.9 % | 1578 |

순차 비중이 큰 것은 설계가 무거워서가 아니라 조합 논리가 가벼워서다 — 산술이
4-bit 정수 곱 64 개로 끝나 면적의 상당 부분이 누산기 파일 (2048 FF) 과
read latch (256 FF) 다.

## 2. 모듈별 면적과 경계 선택

블록별 단독 합성값. 단독 합성은 포트 드라이버를 자체 부담하고, flat top 에서
16 PE 가 공유하는 activation 버스 · 누산기 read mux 를 혼자 떠안는다. 따라서
**상대 비중용**이며 합이 flat top 과 일치하지 않는다.

| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |
|---|---:|---:|---:|---:|---|
| `spinquant_pe` | 16 | 1,082 | 17,313 | 10 | 4 multipliers + 4:2 compressor + CPA + 24b accumulate add |
| `spinquant_acc_regfile` | 1 | 21,171 | 21,171 | 2048 | 4 x 16 x 32b accumulators, accumulate read + drain read |
| **단독 합성 소계** | | | **38,484** | | |
| **flat top 실측** | | | **32,376** | 1960 | read latch · 파이프라인 제어 포함, 소계 대비 -6,108 |

경계 안에 넣은 두 항목의 가격:

| 구성 | carry chain | read latch | 면적 (um2) | 기본 대비 | baseline 대비 | DFF |
|---|---|:--:|---:|---:|---:|---:|
| **대표 구성** — K 상한이 chain 을 24 bit 로 끊게 해준다 | 24 bit | 안 | 32,376 | +0 | 0.538x | 1960 |
| carry chain 을 아키텍처 레지스터 폭까지 되돌린 경우 | 32 bit | 안 | 40,390 | +8,014 | 0.671x | 2472 |
| 256b read latch 를 경계 밖으로 뺀 경우 | 24 bit | 밖 | 31,123 | -1,253 | 0.517x | 1704 |

- **carry chain**: 32-bit 구성이 +8,014 um2 (+24.8 %). DFF 차 512 개는
  4 entry x 16 PE x 8 bit 와 정확히 일치 — 상위 8 bit 는 bit 23 의 sign
  extension 이라 합성기가 병합한다. 절감분 = carry 길이 + 중복 flop 제거.
  아키텍처상 누산기 폭은 32-bit 유지 (drain 은 32-bit 부호확장값), 줄어든
  것은 실리콘이다. 어느 쪽이든 baseline 아래 (0.671x).
- **256b read latch**: 1,253 um2 = 대표 구성의 3.9 %. 밖으로 빼면 P3-LLM ·
  SIMD 행과 같은 경계가 되고 31,123 um2 (0.517x). 대표값은 **포함한** 쪽 —
  2-pump 가 이 설계의 주장 기능이므로 그 레지스터를 빼면 주장과 측정이 어긋난다.

## 3. 타이밍

목표는 tCCD_S 500 MHz (2.0 ns) — baseline 이 tCCD_L 250 MHz 이므로. command
하나당 1 cycle 이다 (2-pump 는 beat 재사용이지 cycle 분할이 아니다).

- **tCCD_S (2.0 ns)**: slack +0.88 ns (MET). worst path `a_q4_i[2]` ->
  `u_pcu.g_row[0].g_pe[11].u_pe.psum_q[8]$_SDFFE_PN0P_`, arrival 1.08 ns.
- **tCCD_L (4.0 ns)**: slack +2.09 ns (MET). worst path `drain_entry_i[0]` ->
  `drain_data_o[311]`, arrival 1.11 ns.

두 주기의 면적이 같은 것은 오타가 아니다 — ABC area mode (`ABC_AREA=1`) 는
주기를 죄어도 같은 매핑을 낸다. 두 행 모두 실제로 합성했고 (FLOW_VARIANT
date_2p0 / date_4p0) 타이밍 리포트만 다르다.

## 4. 처리량을 더 올릴 여지

정수 연산기라 곱셈기는 거의 공짜다. **MAC/cycle 을 묶는 것은 산술이 아니라
피연산자 공급**이고, 아래 두 절이 그것을 보인다.

### 4.1 산술은 제약이 아니다

| 목표 주기 | 주파수 | worst slack (ns) | 면적 (um2) |
|---:|---:|---:|---:|
| 2.0 ns | 500 MHz | +0.88 | 32,376 |
| 1.0 ns | 1,000 MHz | +0.08 | 32,376 |
| 0.8 ns | 1,250 MHz | -0.08 | 32,376 |

데이터패스는 **1 GHz 에서 닫힌다** (tCCD_S 의 2 배). 면적은 baseline 의 54 %.
주파수로도 면적으로도 여유가 있다. (면적이 주기와 무관한 이유는 3절 참조.)

### 4.2 실제 벽: weight 대역폭

bank 는 column command 당 256 bit 를 tCCD_L 마다 준다 (docs/rabit_pcu_spec.md
convention). PCU clock = tCCD_S = tCCD_L / 2 → 지속 공급량은 **cycle 당
128 bit = INT4 weight 32 개**.

```
지속 MAC/cycle = (cycle 당 weight bit / 4) x R
R = 한 weight beat 를 재사용하는 activation row 수 (spatial x temporal)
```

대표 구성은 R = 2 (2-pump) → 지속 64 MAC/cycle 로 공급과 정확히 일치.
지속 처리량을 올리는 길은 R 증가뿐인데, **R 을 늘리면 그만큼 누산기가 더
필요하다** — 이 설계에서 가장 비싼 자원이다.

### 4.3 확장 지점 실측

| 구성 | mult | peak MAC/cy | 필요 R | batch-1 지속 | 면적 (um2) | baseline 대비 | um2/MAC | slack |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 대표: 16 PE x 4 way, 1 row, 4 entry | 64 | 64 | 2 | 32 | 32,376 | 0.538x | 506 | +0.88 |
| 2 row spatial x 2 entry | 128 | 128 | 4 | 32 | 46,813 | 0.778x | 366 | +0.86 |
| 2 row spatial x 4 entry **(제약 초과)** | 128 | 128 | 4 | 32 | 61,828 | 1.027x | 483 | +0.87 |
| 4 row spatial x 4 entry **(제약 초과)** | 256 | 256 | 8 | 32 | 124,290 | 2.065x | 486 | +0.86 |
| 32 PE x 4 way, 512b beat (대역폭 2배 전제) **(제약 초과)** | 128 | 128 | 2 | 64 | 64,345 | 1.069x | 503 | +0.87 |

- **2배는 된다, 조건부로.** `r2e2` 는 지속 128 MAC/cycle 을 46,813 um2
  (0.778x) 에 낸다. 누산기 상태가 대표 구성과 같기 때문 — input row 를 entry
  축(시간)에서 lane 축(공간)으로 옮기고 entry 를 4 → 2 로 줄이면 총 bit 수가
  그대로다 (DFF 2118 vs 1960). 늘어난 것은 PE 16 개뿐이고 um2/MAC 366 으로
  전 구성 중 최고. **대가: output-channel group interleave 포기, batch (또는
  chunked prefill token) ≥ 4 요구.**
- **interleave 를 지키면 제약 초과.** `r2` 는 같은 128 MAC/cycle 에 entry 4
  개를 유지하지만 누산기가 2 배가 되어 61,828 um2 (1.027x).
- **4배는 안 된다.** `r4` 는 124,290 um2 (2.065x). 누산기가 R 에 선형이라
  여기서부터 누산기 파일이 설계를 지배한다.
- **batch-1 은 대역폭이 천장.** 위 네 행 모두 batch-1 지속 32 MAC/cycle 로
  같다. 천장을 올리려면 beat 를 넓혀야 하고 그게 `w512` (64,345 um2, 1.069x)
  다. 단 **PCU 에 column 대역폭 2 배를 준다는 아키텍처 전제** (bank pair 또는
  pseudo-channel) 가 필요해 다른 숫자와 전제가 다르므로 참고용.

### 4.4 결론

- **decode (batch 작음)**: 대표 구성이 이미 균형점. 곱셈기를 늘려도 지속
  처리량은 그대로고 면적만 는다. batch-1 만 보면 64 개도 2 배 과잉 (절반이 논다).
- **batch / chunked prefill ≥ 4**: `r2e2` 가 면적 제약 안에서 지속 처리량을
  2 배로 만드는 유일한 지점이고 um2/MAC 도 개선된다. RTL 은 `NROW` 파라미터로
  지원하며 같은 testbench 로 검증되어 있다 (`make TEST=spinquant_pcu_r2e2`).
- **그 이상**: 누산기 파일이 R 에 선형이라 면적 제약과 충돌한다.

## 5. 검증

```
cd verif && make TEST=spinquant_pcu          # 전체 PCU
cd verif && make TEST=spinquant_pcu_nolatch  # read latch 경계 밖
cd verif && make TEST=spinquant_pcu_acc32    # 32-bit carry chain
cd verif && make TEST=spinquant_pe           # PE 단독
cd verif && make TEST=spinquant_acc          # 누산기 파일 단독
```

golden model 은 순수 파이썬 정수 GEMV (`verif/models/spinquant_model.py`).

- testbench 가 [16 x K] weight tile 을 256b beat stream 으로 잘라 microkernel
  command 순서를 재현하고, 누산기 갱신을 매 cycle bit-exact 로 대조한다.
- 최악 누산 (K = 14336, weight 전부 -8, activation 전부 15) 에서 24-bit carry
  chain 이 넘치지 않음을 확인한다 (-1,720,320, 22 bit).

