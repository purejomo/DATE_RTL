# rtl/ — 설계 디렉토리 안내

각 디렉토리는 **PIM 연산기 한 종류**다. 서로 독립적으로 합성·검증되며,
공통 조건(Nangate45 typical, Yosys + OpenROAD, logic synthesis only)에서
면적을 비교하는 것이 이 저장소의 목적이다.

한눈에:

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

면적은 [results/area.csv](../results/area.csv)의 값이며 이 표는 사본이다. 최신 값은 CSV를 본다.

---

## 디렉토리별

### 1_hbmpim — 기준선
삼성 HBM-PIM의 연산기. FP16 곱하기 FP16, binary32 누산, 16 lane SIMD.
다른 모든 설계가 "이것보다 작은가"로 평가되므로 **먼저 읽을 것**.
파일은 `mul → add → 1_lane → 16_lane` 순으로 쌓인다.

### 2_awq_hbmpim — AWQ, SIMD 조직
가중치만 INT4로 낮추고 조직은 1_hbmpim 그대로 유지. 활성값 포맷 두 가지
(`fp16`/`bf16`) × lane 수 세 가지(16/32/64) = 6개 top. lane 수를 늘린 것은
3_awq_p3llm과 **곱셈기 개수를 맞춰 비교**하기 위한 것이다 (32 lane ↔ 8 PE,
64 lane ↔ 16 PE).

### 3_awq_p3llm_8pe, 3_awq_p3llm_16pe — AWQ, PE 조직
2_awq_hbmpim과 **같은 연산을 P3-LLM 조직으로** 한 것. 차이는 조직뿐:
float 누산 대신 고정소수점 누산, lane 대신 PE(4 곱셈기 + 4:2 압축기 + 누산기).
지수 정렬은 PE가 아니라 공용 front-end `int4float_align`에서 한 번만 한다.

두 디렉토리의 소스는 `int4float_pcu.v`의 주석과 `NUM_PES` 값만 다르고 나머지는
동일하다. 합성 스크립트가 디렉토리 단위로 소스를 넘기기 때문에 파라미터 하나로
합치지 않고 분리해 두었다.

### 4_p3llm — P3-LLM 원본
FP4 가중치 × FP8 활성값. 16 PE, PE당 6×6 signed 곱셈기 4개. 포맷 디코더가
따로 있다 (`fp8_e4m3`, `fp8_s0e4m4`, `bitmod4`, `int4_asym`). 3_awq_p3llm는
이 디렉토리의 `compressor_4to2.sv`를 그대로 쓴다 (동일 파일).

### 4_p3llm_with_dequant — P3-LLM + 내부 dequant
4_p3llm의 **파일 사본** + dequant 파이프라인 3개 + `p3llm_pcu_dequant` top.
`p3llm_pkg/pe/pcu/compressor`는 4_p3llm과 바이트 단위로 동일하다 —
**둘 중 하나만 고쳐 두면 안 된다.**
양자화 그룹 경계마다 INT32 누산값 16개를 직렬화해 FP16 결과로 바꾼다.
수치 계약은 [4_p3llm_with_dequant/README.md](4_p3llm_with_dequant/README.md) 참고.

### 5_rabit — RaBiT base
2-bit residual binarization: 가중치가 ±1 비트라 **곱셈기가 하나도 없다.**
곱셈 대신 부호 반전 + 4:2 압축 트리. 입력은 fp16 16개를 block floating point로
변환해 받고(`cvt_fp16_blk`), 출력은 원시 누산값 A₁/A₂를 그대로 뱉는다.
스케일 `y = g₁A₁ + g₂A₂`와 입력 스케일 `h`는 **NPU가 처리한다.**

### 5_rabit_fullsacle — RaBiT full-scale variant
위의 h/g 스케일 처리를 PCU 안으로 옮긴 판. base RTL을 **수정하지도 복사하지도
않고** `5_rabit/`의 모듈을 그대로 인스턴스한다 (합성·검증 스크립트가 두
디렉토리 소스를 함께 넘긴다).

추가된 것은 세 블록뿐이다: `h_scale_unit`(write 경로), `g_buffer`,
`g_dequant_unit`(drain 경로). inner loop에는 곱셈기를 넣지 않았고, 그래서
면적이 2.07배가 되는 동안 처리량은 0.58 %만 잃는다.
자세한 내용·미결 질문(Q1~Q8)은 [5_rabit_fullsacle/README.md](5_rabit_fullsacle/README.md).

> 디렉토리명 `fullsacle`은 `fullscale`의 오타지만 스크립트·문서가 전부 이
> 이름을 참조하므로 고치지 않았다.

---

## 공통 규칙

**합성 경계** — 모든 설계는 곱셈기와 누산기를 포함해 합성한다. GRF/SRF,
데이터 버퍼, 명령 디코더, 메모리 인터페이스는 경계 밖이다. 비교가 성립하는
유일한 조건이므로 새 설계를 추가할 때도 지킬 것.

**클록** — hbm-pim과 rabit 계열은 250 MHz, 나머지는 500 MHz. 원 논문의
동작점을 따른 것이라 임의로 바꾸면 표가 깨진다.

**results/는 직접 편집하지 않는다** — 전부 스크립트 생성물이다.

## 어떻게 돌리나

```bash
cd synth
./run_all.sh          # 전 설계 합성 → 전력 → 비교표
./run_rabit.sh        # rabit base: 파라미터 스윕 + 모듈 분해
./run_rabit_fs.sh     # rabit full-scale: 면적 + 정확도 + 처리량 리포트

cd ../verif
make                  # 전체 cocotb 회귀
make TEST=rabit_pcu   # 하나만
make list             # 테스트 목록
```

| 디렉토리 | 테스트 타깃 |
|---|---|
| 1_hbmpim | `fp16_mul` |
| 2_awq_hbmpim | `int4fp16_mul`, `int4bf16_mul` |
| 3_awq_p3llm_* | `pcu_fp16_32`, `pcu_bf16_32`, `pcu_fp16_64`, `pcu_bf16_64` |
| 4_p3llm | `p3llm_decoders`, `p3llm_compressor`, `p3llm_pe`, `p3llm_pcu` |
| 4_p3llm_with_dequant | `p3llm_dequant_arith`, `p3llm_dequant` |
| 5_rabit | `rabit_cvt`, `rabit_align`, `rabit_pe`, `rabit_acc`, `rabit_pcu`(+`_m10`/`_noshift`/`_m10_noshift`) |
| 5_rabit_fullsacle | `rabit_fs`, `rabit_fs_pipe`, `rabit_fs_h16` |

전체 결과 해석은 최상위 [README.md](../README.md), 설계별 상세 분석은
[results/designs/](../results/designs/).
