# rtl/ — 설계 디렉토리 안내

| 디렉토리 | 무엇 | 곱셈기 조직 | 누산 | top 모듈 | 클록 | 면적 (um²) |
|---|---|---|---|---|---:|---:|
| [1_hbmpim/](1_hbmpim/) | HBM-PIM 원본 (**비교 기준선**) | FP16 SIMD 16 lane | binary32 | `hbmpim_fp16_pcu_16_lane` | 250 MHz | 60,176 |
| [2_awq_hbmpim/](2_awq_hbmpim/) | AWQ INT4 가중치를 HBM-PIM 조직에 | INT4×FP16/BF16 SIMD 16·32·64 lane | binary32 | `awq_int4{fp,bf}16_pcu_{16,32,64}_lane` | 500 MHz | 47,288 ~ 198,833 |
| [3_awq_p3llm_8pe/](3_awq_p3llm_8pe/) | 같은 AWQ 연산을 P3-LLM 조직에 | 8 PE × 4 = 32 mult | signed 32b 고정소수점 | `int4{fp,bf}16_pcu32` | 500 MHz | 43,112 / 37,261 |
| [3_awq_p3llm_16pe/](3_awq_p3llm_16pe/) | 위의 16 PE 판 | 16 PE × 4 = 64 mult | signed 32b 고정소수점 | `int4{fp,bf}16_pcu_top` | 500 MHz | 82,536 / 71,745 |
| [4_p3llm/](4_p3llm/) | P3-LLM 원본 | 16 PE × 4 = 64 mult (6×6) | signed 32b 고정소수점 | `p3llm_pcu` | 500 MHz | 71,287 |
| [4_p3llm_with_dequant/](4_p3llm_with_dequant/) | 위 + PCU 내부 dequantization | 동일 + 공유 FP 후처리 1개 | FP32 | `p3llm_pcu_dequant` | 500 MHz | 108,068 |
| [5_rabit/](5_rabit/) | RaBiT 2-bit residual binary (**base**) | **곱셈기 0개**, 8 PE | signed 32b 고정소수점 | `rabit_pcu` | 250 MHz | 45,254 |
| [5_rabit_fullsacle/](5_rabit_fullsacle/) | 위 + h/g 스케일을 PCU 안으로 | base + h 곱 16개, g 곱 4개 | 동일 + FP16 출력 | `rabit_pcu_fs` | 250 MHz | 93,522 |
