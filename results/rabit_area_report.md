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

### 타이밍

PCU 는 column command 하나당 2 cycle 을 쓴다 (2-pump). 따라서 PCU 주기
4.0 ns 는 tCCD_S 8.0 ns 에 해당하고, 2.0 ns 는 tCCD_S 4.0 ns 다.

## 2. 모듈별 면적

각 블록을 따로 합성한 값이다. flat top 은 경계를 넘는 최적화를 받으므로
합계가 top 면적과 정확히 같지는 않다.

| 모듈 | 개수 | 1개 면적 (um2) | 합계 (um2) | DFF | 설명 |
|---|---:|---:|---:|---:|---|
| `cvt_fp16_to_blk` | 1 | 5,002 | 5,002 | 0 | convert-on-write, fp16x16 -> block |
| `rabit_pe` | 8 | 3,693 | 29,547 | 17 | negate + 4:2 tree + CPA + shift + acc add |
| `acc_regfile` | 1 | 20,872 | 20,872 | 2048 | 64 x 32b architectural accumulators |
| **소계** | | | **55,421** | | |
| 시퀀서 · 배선 · 경계 최적화 차분 | | | -10,168 | | flat top 45,254 um2 와의 차 |

## 3. MANT_W / SHIFTER_EN 스윕

정확도는 `python3 tools/rabit_accuracy.py` 가 같은 golden model 로
4096x4096 · 11008x4096 에서 측정한다. 아래는 면적만이다.

| MANT_W | SHIFTER_EN | 면적 (um2) | 기본 구성 대비 | baseline 대비 | DFF |
|---:|:--:|---:|---:|---:|---:|
| 12 | on | 45,254 | +0 | 0.752x | 2208 |
| 10 | on | 42,097 | -3,157 | 0.700x | 2192 |
| 12 | off | 45,777 | +523 | 0.761x | 2200 |
| 10 | off | 44,349 | -905 | 0.737x | 2184 |

