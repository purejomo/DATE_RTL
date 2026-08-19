# rtl/

비교군 5종의 연산 데이터패스. 같은 번호는 같은 설계의 변종이다.

각 설계군은 최대 **네 개의 축**으로 측정한다. 축이 다르면 디렉토리도 top 모듈
이름도 다르다 — `synth/run_block_synth.sh` 가 `generated/${TOP}.v` 에,
`synth/run_all.sh` 가 `${top}_power.rpt` 에 쓰므로 이름이 겹치면 두 행이 서로를
덮어쓴다.

| 축 | 뜻 |
|---|---|
| ① base | 32-bit 고정소수점 누산, raw 정수 출력 |
| ② `*_acc16` | 매 사이클 partial sum 을 RNE 로 16-bit 으로 좁혀 누산 |
| ③ `*_dequant_rne` | 32-bit 누산 후 PU 안에서 dequant → 그 설계군의 activation 정밀도로 출력 |
| ④ `*_dequant_requant` | ③ + activation 재양자화 (**SpinQuant 전용**) |

③의 출력 폭은 "다음 레이어가 그대로 먹는 포맷" 이다: AWQ 는 BF16/binary16,
P3-LLM 은 **FP8-E4M3**, RaBiT 는 binary16.

**④가 SpinQuant 에만 있는 이유.** 앞의 셋은 activation 이 부동소수점이라 ③의 출력이
곧 다음 레이어의 입력이고 host 커널이 사라진다. SpinQuant 만 W4**A4** 라 binary16 을
내보내도 다음 PCU 가 원하는 것은 unsigned INT4 다. 그래서 SpinQuant 의 ③은 loop 를
절반만 닫는 ablation 행이고, 원래 동기를 만족하는 것은 ④뿐이다. 요소당 32b → 4b 로
**8× 절감**이며, 다른 설계군의 ③이 2× 인 것과 대비된다.

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
| [5_spinquant_acc16/](5_spinquant_acc16/) | stage 2 만 (`ACC_RSH` 7, MSB 보존) | `spinquant_pcu_acc16` | 500 MHz | 25,767 | −20.4 % |

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
| [5_spinquant_dequant_rne/](5_spinquant_dequant_rne/) | 공유 엔진 1개 (곱 + pack) | binary16 | `spinquant_pcu_dq` | 500 MHz | 40,271 | +24.4 % |

raw 정수 drain 은 네 설계 모두 남겨 뒀다 — ① 대비 비교를 위해서다.

**SpinQuant 축③ 주의.** 이 행은 **loop 를 닫지 않는다.** W4A4 라 binary16 출력을
다음 레이어가 읽으려면 host 양자화 커널이 여전히 돌아야 한다. 축④ 행에 대한
ablation 으로만 읽어야 한다. 엔진이 다른 ③ 보다 싼 이유는 activation zero point 가
정수 영역으로 접혀 (`bias_int[i] = -zp_a·ΣW_q_row[i]`) FP32 누산 adder 도 두 번째
스케일 곱도 필요 없기 때문이다 — 곱 하나와 pack 하나가 전부다.

**RaBiT 축③ 주의.** 다른 설계군의 ③ 에 없는 **write 경로 h 스케일 유닛** 까지
포함하므로 이 열에서 RaBiT 행만 과다 계상된다. 해당 블록은
`rabit_fs_blk_hscale_250` (20,651 µm²) 으로 따로 합성돼 있으니 추정하지 말고 빼면
된다.

## 축④ — dequant_requant (SpinQuant 전용)

| 디렉토리 | 추가된 것 | 출력 | top 모듈 | 클록 | 면적 (µm²) | ① 대비 |
|---|---|---|---|---:|---:|---:|
| [5_spinquant_dequant_requant/](5_spinquant_dequant_requant/) | ③ + min/max + INT4 변환기 | **INT4** | `spinquant_pcu_rq` | 500 MHz | 39,997 | +23.5 % |

요소당 32b → **4b**. host 커널이 완전히 사라지는 이 저장소의 유일한 행이다.
`s_a'` 가 출력 row 전체의 min/max 를 요구하므로 **2-pass** 로 푼다 — pass 1 은 PCU
lane 들의 min/max 스칼라 2개만 내보내고, NPU 가 bank 를 가로질러 리덕션을 끝낸 뒤
`t[i] = s[i]/s_a'` 를 돌려준다. 나눗셈은 하드웨어에 없다.

**③ 에서 빼서 requantizer 비용을 구하면 안 된다.** `KEEP_FP16_OUT=1` 이라 ④는 ③의
엄격한 상위집합이지만, 측정값은 cell 1,062개·flop 139개가 늘고도 총 면적이 274 µm²
더 **작다**. 둘 다 WNS 0.09 ns / TNS 0 으로 타이밍은 여유 있게 만족하므로 타이밍
압력이 아니라, netlist 가 커지자 ABC 가 평균적으로 더 싼 셀로 매핑한 결과다
(1.270 → 1.221 µm²/cell). flat 합성의 cross-boundary 최적화가 하는 일이고,
`5_spinquant/spinquant_pcu_synth.sv` 가 blk 분해에 대해 이미 경고해 둔 것과 같다.
**requantizer 비용은 cell/flop 증분(+1,062 cell, +139 flop)으로 말한다.**

면적은 Nangate45 typical, 논리 합성까지의 셀 면적 합이다 (`results/area.csv`).

## zero-point 계약

AWQ 두 판 모두 **v2** 다. `i_weight_zp` 이 PE 당 독립 4-bit (8 PE = 32 bit,
16 PE = 64 bit) 로, AutoAWQ 가 실제로 저장하는 output-channel/group 별 배치다.
v1 broadcast nibble 빌드는 트리에서 삭제했다. 자세한 것은
[docs/awq_p3llm_pcu_spec.md](../docs/awq_p3llm_pcu_spec.md).

## 컴파일 시 주의

- `5_spinquant{,_acc16,_dequant_rne,_dequant_requant}` 네 디렉토리: **어느 둘도
  함께 컴파일 금지.** 각자 `spinquant_pe` / `spinquant_pcu_top` /
  `spinquant_acc_regfile` 사본을 들고 있다
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
