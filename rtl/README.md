# rtl/

비교군 5종의 연산 데이터패스. 같은 번호는 같은 설계의 변종이다.

| 디렉토리 | 곱셈기 조직 | 누산 | top 모듈 | 클록 | 면적 (µm²) |
|---|---|---|---|---:|---:|
| [1_hbmpim/](1_hbmpim/) | FP16 SIMD 16 lane | binary32 | `hbmpim_fp16_pcu_16_lane` | 250 MHz | 60,176 |
| [2_awq_p3llm_8pe_v2/](2_awq_p3llm_8pe_v2/) | 8 PE × 4 = 32 mult | signed 32b 고정소수점 | `int4bf16_pcu32` | 500 MHz | 36,919 |
| [2_awq_p3llm_16pe/](2_awq_p3llm_16pe/) | 16 PE × 4 = 64 mult | signed 32b 고정소수점 | `int4bf16_pcu_top` | 500 MHz | 71,745 |
| [3_p3llm/](3_p3llm/) | 16 PE × 4 = 64 mult (6×6) | signed 32b 고정소수점 | `p3llm_pcu` | 500 MHz | 71,287 |
| [3_p3llm_with_dequant/](3_p3llm_with_dequant/) | 동일 + 공유 FP 후처리 1개 | FP32 → FP16 출력 | `p3llm_pcu_dequant` | 500 MHz | 108,068 |
| [4_rabit/](4_rabit/) | **곱셈기 0개**, 8 PE | signed 32b 고정소수점 | `rabit_pcu` | 250 MHz | 45,254 |
| [4_rabit_fullscale/](4_rabit_fullscale/) | base + h 곱 16개, g 곱 4개 | 동일 + FP16 출력 | `rabit_pcu_fs` | 250 MHz | 93,522 |
| [5_spinquant/](5_spinquant/) | 16 PE × 4 = 64 mult (s4×u4) | 32b 레지스터 안 24b chain | `spinquant_pcu` | 500 MHz | 32,376 |

면적은 Nangate45 typical, 논리 합성까지의 셀 면적 합이다 (`results/area.csv`).

`2_awq_p3llm_8pe_v2` 는 zero-point 계약이 다르다. `i_weight_zp` 이 PE 당 4-bit
(8 PE = 32 bit) 로, AutoAWQ 가 실제로 저장하는 output-channel/group 별 배치다.
`2_awq_p3llm_16pe` 는 아직 v1 broadcast nibble (4 bit) 이라 두 top 의 포트 폭이
다르다. 자세한 것은 [docs/awq_p3llm_pcu_spec.md](../docs/awq_p3llm_pcu_spec.md).

## 컴파일 시 주의

- `2_awq_p3llm_8pe_v2` + `2_awq_p3llm_16pe`: 함께 컴파일 금지 (모듈 중복 정의)
- `3_p3llm` + `3_p3llm_with_dequant`: 함께 컴파일 금지 (같은 이유)
- `4_rabit` + `4_rabit_fullscale`: 반드시 함께 컴파일 (모듈 공유)

소스 목록의 정본은 [`synth/run_all.sh`](../synth/run_all.sh) 와
[`verif/Makefile`](../verif/Makefile) 이다.
