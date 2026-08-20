# RTL 구성

HBM-PIM 기준 연산기와 네 가지 최적화 축의 RTL이다. 면적은 Nangate45 논리 합성
결과이며 외부 GRF, command memory, DRAM bank interface는 제외한다.

## 전체 면적 비교

| 디렉터리 | 설계 | 축 | 조직 / 클록 | 출력 | 면적 (µm²) | base 면적 대비 |
|---|---|---|---|---|---:|---:|
| [1_hbmpim/](1_hbmpim/) | HBM-PIM | 기준 | 16 lane / 250 MHz | FP32 | 60,176 | — |
| [2_awq_p3llm_8pe_v2/](2_awq_p3llm_8pe_v2/) | AWQ | ① base | 8 PE / 500 MHz | INT32 | 36,919 | — |
| [2_awq_p3llm_8pe_v2_acc16/](2_awq_p3llm_8pe_v2_acc16/) | AWQ | ② acc16 | 8 PE / 500 MHz | INT16 | 36,194 | −2.0% |
| [2_awq_p3llm_8pe_v2_dequant_rne/](2_awq_p3llm_8pe_v2_dequant_rne/) | AWQ | ③ dequant_rne | 8 PE / 500 MHz | BF16 | 61,702 | +67.1% |
| [2_awq_p3llm_16pe_v2/](2_awq_p3llm_16pe_v2/) | AWQ | ① base | 16 PE / 500 MHz | INT32 | 72,280 | — |
| [2_awq_p3llm_16pe_v2_acc16/](2_awq_p3llm_16pe_v2_acc16/) | AWQ | ② acc16 | 16 PE / 500 MHz | INT16 | 68,569 | −5.1% |
| [2_awq_p3llm_16pe_v2_dequant_rne/](2_awq_p3llm_16pe_v2_dequant_rne/) | AWQ | ③ dequant_rne | 16 PE / 500 MHz | BF16 | 105,061 | +45.4% |
| [3_p3llm/](3_p3llm/) | P3-LLM | ① base | 16 PE / 500 MHz | INT32 | 71,287 | — |
| [3_p3llm_acc16/](3_p3llm_acc16/) | P3-LLM | ② acc16 | 16 PE / 500 MHz | INT16 | 62,152 | −12.8% |
| [3_p3llm_dequant_rne/](3_p3llm_dequant_rne/) | P3-LLM | ③ dequant_rne | 16 PE / 500 MHz | FP8-E4M3 | 106,359 | +49.2% |
| [4_rabit/](4_rabit/) | RaBiT | ① base | 8 PE / 500 MHz | INT32 | 45,254 | — |
| [4_rabit_acc16/](4_rabit_acc16/) | RaBiT | ② acc16 | 8 PE / 500 MHz | INT16 | 32,209 | −28.8% |
| [4_rabit_dequant_rne/](4_rabit_dequant_rne/) | RaBiT | ③ dequant_rne | folded 4 PE / 500 MHz | FP16 | 56,006 | +23.8% |
| [5_spinquant/](5_spinquant/) | SpinQuant | ① base | 16 PE / 500 MHz | INT32 | 32,376 | — |
| [5_spinquant_acc16/](5_spinquant_acc16/) | SpinQuant | ② acc16 | 16 PE / 500 MHz | INT16 | 25,767 | −20.4% |
| [5_spinquant_dequant_rne/](5_spinquant_dequant_rne/) | SpinQuant | ③ dequant_rne | 16 PE / 500 MHz | FP16 | 40,271 | +24.4% |
| [5_spinquant_dequant_requant/](5_spinquant_dequant_requant/) | SpinQuant | ④ dequant_requant | 16 PE / 500 MHz | UINT4 | 39,997 | +23.5% |
| [5_spinquant_v2/](5_spinquant_v2/) | SpinQuant v2 | ① base | 32 PE / 500 MHz | INT32 | 64,345 | — |
| [5_spinquant_v2_acc16/](5_spinquant_v2_acc16/) | SpinQuant v2 | ② acc16 | 32 PE / 500 MHz | INT16 | 51,191 | −20.4% |
| [5_spinquant_v2_dequant_rne/](5_spinquant_v2_dequant_rne/) | SpinQuant v2 | ③ dequant_rne | 32 PE / 500 MHz | FP16 | 68,391 | +6.3% |
| [5_spinquant_v2_dequant_requant/](5_spinquant_v2_dequant_requant/) | SpinQuant v2 | ④ dequant_requant | 32 PE / 500 MHz | UINT4 | 68,389 | +6.3% |

## 축 설명

| 축 | 의미 |
|---|---|
| ① base | 32-bit 누산 후 raw 정수 출력 |
| ② acc16 | RNE 축소 후 16-bit 누산·출력 |
| ③ dequant_rne | PCU에서 다음 activation 형식으로 dequant 및 RNE 변환 |
| ④ dequant_requant | dequant 후 UINT4 재양자화; SpinQuant 전용 |

RaBiT ③은 입력 스케일 `s_in × x`도 내부에서 처리한다. 4 PE 2-fold compute 경로,
27-bit exact accumulator, 그룹 단위 256-bit 출력 스케일 버퍼와 1-lane dequant/RNE를
사용한다.

SpinQuant v2는 32 PE와 512-bit weight beat를 사용한다. ④는 UINT4 전용이다.

## 파일 규칙

- RTL 파일 하나에는 module 또는 package 하나만 둔다.
- 파일명과 module/package 이름을 같게 둔다.
- 각 설계 디렉터리는 필요한 공통 모듈의 로컬 사본을 가진다.
- 같은 이름의 모듈을 가진 서로 다른 설계 디렉터리는 한 번에 함께 컴파일하지 않는다.

소스 목록은 [synth/run_all.sh](../synth/run_all.sh),
[synth/run_rabit_fs.sh](../synth/run_rabit_fs.sh),
[verif/Makefile](../verif/Makefile)에 있다.
