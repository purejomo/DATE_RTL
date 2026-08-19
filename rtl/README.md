# rtl/

비교군 5종의 연산 데이터패스. 같은 번호는 같은 설계의 변종이다.

각 설계군은 최대 **세 개의 축**으로 측정한다. 축이 다르면 디렉토리도 top 모듈
이름도 다르다 — `synth/run_block_synth.sh` 가 `generated/${TOP}.v` 에,
`synth/run_all.sh` 가 `${top}_power.rpt` 에 쓰므로 이름이 겹치면 두 행이 서로를
덮어쓴다.

| 축 | 뜻 |
|---|---|
| ① base | 32-bit 고정소수점 누산, raw 정수 출력 |
| ② `*_acc16` | 매 사이클 partial sum 을 RNE 로 16-bit 으로 좁혀 누산 |
| ③ `*_dequant_rne` | 32-bit 누산 후 PU 안에서 dequant → 그 설계군의 activation 정밀도로 출력 |

③의 출력 폭은 "다음 레이어가 그대로 먹는 포맷" 이다: AWQ 는 BF16/binary16,
P3-LLM 은 **FP8-E4M3**, RaBiT 는 binary16.

## 축① — base

| 디렉토리 | 곱셈기 조직 | 누산 | top 모듈 | 클록 | 면적 (µm²) |
|---|---|---|---|---:|---:|
| [1_hbmpim/](1_hbmpim/) | FP16 SIMD 16 lane | binary32 | `hbmpim_fp16_pcu_16_lane` | 250 MHz | 60,176 |
| [2_awq_p3llm_8pe_v2/](2_awq_p3llm_8pe_v2/) | 8 PE × 4 = 32 mult | signed 32b 고정소수점 | `int4bf16_pcu32` | 500 MHz | 36,919 |
| [2_awq_p3llm_16pe_v2/](2_awq_p3llm_16pe_v2/) | 16 PE × 4 = 64 mult | signed 32b 고정소수점 | `int4bf16_pcu_top` | 500 MHz | 72,280 |
| [3_p3llm/](3_p3llm/) | 16 PE × 4 = 64 mult (6×6) | signed 32b 고정소수점 | `p3llm_pcu` | 500 MHz | 71,287 |
| [4_rabit/](4_rabit/) | **곱셈기 0개**, 8 PE | signed 32b 고정소수점 | `rabit_pcu` | 250 MHz | 45,254 |
| [5_spinquant/](5_spinquant/) | 16 PE × 4 = 64 mult (s4×u4) | 32b 레지스터 안 24b chain | `spinquant_pcu` | 500 MHz | 32,376 |

## 축② — acc16

| 디렉토리 | 바뀐 것 | top 모듈 | 클록 | 면적 (µm²) | ① 대비 |
|---|---|---|---:|---:|---:|
| [2_awq_p3llm_8pe_v2_acc16/](2_awq_p3llm_8pe_v2_acc16/) | stage 3 만 (`ACC_RSH` 12) | `int4bf16_pcu32_acc16` | 500 MHz | 36,194 | −2.0 % |
| [2_awq_p3llm_16pe_v2_acc16/](2_awq_p3llm_16pe_v2_acc16/) | 동일, 16 PE | `int4bf16_pcu_top_acc16` | 500 MHz | 68,569 | −5.1 % |
| [3_p3llm_acc16/](3_p3llm_acc16/) | stage 3 만 (`ACC_RSH` 16) | `p3llm_pcu_acc16` | 500 MHz | 62,152 | −12.8 % |
| [4_rabit_acc16/](4_rabit_acc16/) | 합성 wrapper 만 (`ACC_W` 16 · `MANT_W` 10 · `SHIFT_RND` 1) | `rabit_pcu_acc16` | 250 MHz | 32,209 | −28.8 % |

정렬 · decode · 곱셈기 · compressor · CPA 는 ①과 bit-identical 이므로 면적 차이가
누산기에만 귀속된다. `ACC_RSH` 기본값은 "quantization group 전체에서 saturate 가
절대 안 나는 최악 경계" 이지 정확도 최적값이 아니다 — 시프트량은 배선이라 면적에
거의 영향이 없고, 최적값 탐색은 accuracy sweep 사안이다.

**RaBiT 축② 주의.** `MANT_W` 를 12→10 으로 낮추는 것은 선택이 아니라 강제다
(`rabit_align_shift` 가 `ACC_W > PSUM_W = MANT_W + 5` 를 요구한다). 또 16-bit
누산기는 `din = 4096` 깊이의 k sweep 을 표현하지 못하고 saturate 한다 —
`docs/rabit_pcu_spec.md` §7.1 에 실측이 있다.

## 축③ — dequant_rne

| 디렉토리 | 추가된 것 | 출력 | top 모듈 | 클록 | 면적 (µm²) | ① 대비 |
|---|---|---|---|---:|---:|---:|
| [2_awq_p3llm_8pe_v2_dequant_rne/](2_awq_p3llm_8pe_v2_dequant_rne/) | 공유 FP 엔진 1개 | BF16 | `int4bf16_pcu32_dq` | 500 MHz | 61,702 | +67.1 % |
| [2_awq_p3llm_16pe_v2_dequant_rne/](2_awq_p3llm_16pe_v2_dequant_rne/) | 동일, 16 PE | BF16 | `int4bf16_pcu_top_dq` | 500 MHz | 105,061 | +45.4 % |
| [3_p3llm_dequant_rne/](3_p3llm_dequant_rne/) | 공유 FP 엔진 1개 | **FP8-E4M3** | `p3llm_pcu_dequant` | 500 MHz | 106,359 | +49.2 % |
| [4_rabit_dequant_rne/](4_rabit_dequant_rne/) | h 곱 16개, g 곱, drain dequant | binary16 | `rabit_pcu_fs` | 250 MHz | 93,522 | +106.7 % |

raw 정수 drain 은 세 설계 모두 남겨 뒀다 — ① 대비 비교를 위해서다.

**RaBiT 축③ 주의.** 다른 설계군의 ③ 에 없는 **write 경로 h 스케일 유닛** 까지
포함하므로 이 열에서 RaBiT 행만 과다 계상된다. 해당 블록은
`rabit_fs_blk_hscale_250` (20,651 µm²) 으로 따로 합성돼 있으니 추정하지 말고 빼면
된다.

면적은 Nangate45 typical, 논리 합성까지의 셀 면적 합이다 (`results/area.csv`).

## zero-point 계약

AWQ 두 판 모두 **v2** 다. `i_weight_zp` 이 PE 당 독립 4-bit (8 PE = 32 bit,
16 PE = 64 bit) 로, AutoAWQ 가 실제로 저장하는 output-channel/group 별 배치다.
v1 broadcast nibble 빌드는 트리에서 삭제했다. 자세한 것은
[docs/awq_p3llm_pcu_spec.md](../docs/awq_p3llm_pcu_spec.md).

## 컴파일 시 주의

- `2_awq_p3llm_{8pe,16pe}_v2{,_acc16,_dequant_rne}` 여섯 디렉토리: **어느 둘도
  함께 컴파일 금지.** 각자 `int4float_pcu` / `int4float_pe` / `int4float_align`
  사본을 들고 있다
- `3_p3llm`, `3_p3llm_acc16`, `3_p3llm_dequant_rne`: 같은 이유로 함께 컴파일
  금지 (`p3llm_pkg` 를 포함해 전부 중복)
- `4_rabit`, `4_rabit_acc16`: 같은 이유로 함께 컴파일 금지
- `4_rabit` + `4_rabit_dequant_rne`: **반드시 함께** 컴파일 (축③ 은 축①의 모듈을
  복사하지 않고 인스턴스한다)

소스 목록의 정본은 [`synth/run_all.sh`](../synth/run_all.sh) 와
[`verif/Makefile`](../verif/Makefile) 이다.
