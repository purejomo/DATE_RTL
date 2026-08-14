# 검증

cocotb + Verilator 회귀. 논문 표의 모든 산술 블록을 golden model과 대조한다.

```
verif/
├── Makefile                 단일 진입점
├── models/                  golden model (순수 파이썬 정수 연산)
│   ├── float_reference.py       IEEE-754 FP16 / BF16 정확 모델
│   ├── int4float_pcu_model.py   awq PCU 모델
│   ├── p3llm_formats.py         p3llm FP8 / FP4 디코더 모델
│   ├── p3llm_pcu_model.py       p3llm PE · PCU 모델
│   └── rabit_model.py           rabit 변환 · PE · 누산기 · PCU 모델
└── tests/
    ├── test_fp16_mul_lane.py        baseline
    ├── test_int4fp16_mul_lane.py    awq SIMD
    ├── test_int4bf16_mul_lane.py    awq SIMD
    ├── test_int4float_pcu.py        awq PCU
    ├── test_p3llm_decoders.py       p3llm
    ├── test_p3llm_pe.py             p3llm
    ├── test_p3llm_pcu.py            p3llm
    ├── test_rabit_cvt.py            rabit convert-on-write
    ├── test_rabit_pe.py             rabit PE
    ├── test_rabit_acc.py            rabit 누산기 배열
    ├── test_rabit_pcu.py            rabit end-to-end GEMV
    ├── common.py                    cocotb 헬퍼
    └── harness/                     디코더 · compressor · cvt 노출용 SV 래퍼
fp32/                        binary32 누산 경로 (cocotb 없이 Verilator만)
├── Makefile
├── tb_top.v / main.cpp          HBM-PIM · AWQ binary32 가산기
└── tb_mac.v / main_mac.cpp      내부 형식 변환 · MAC 레인 4단 파이프라인
```

## 실행

```bash
make                    # 전체 회귀 (현재 TESTS 목록 전체)
make list               # 테스트 이름 목록
make TEST=p3llm_pcu     # 하나만
make distclean          # 산출물 삭제
```

산출물은 `build/<test>/`, 결과 XML은 `build/<test>.xml`.

## 테스트 목록

논문의 4개 행을 모두 덮는다.

| 논문 행 | 이름 | RTL top | 무엇을 확인하나 |
|---|---|---|---|
| hbm-pim | `fp16_mul` | `hbmpim_fp16_mul` | 정상 finite binary16 RNE, DAZ/FTZ 코너 + 지원 encoding + 랜덤 |
| awq-hbm-pim | `int4bf16_mul` | `awq_int4bf16_mul` | 정상 finite INT4 × bfloat16 RNE, DAZ/FTZ 지원 encoding 전수 |
| awq-hbm-pim | `int4fp16_mul` | `awq_int4fp16_mul` | 정상 finite INT4 × binary16 RNE, DAZ/FTZ 코너 + 랜덤 |
| awq-p3-llm | `pcu_fp16_32` | `int4fp16_pcu32` | PCU 8 PE, binary16 activation |
| awq-p3-llm | `pcu_bf16_32` | `int4bf16_pcu32` | PCU 8 PE, bfloat16 activation |
| awq-p3-llm | `pcu_fp16_64` | `int4fp16_pcu_top` | PCU 16 PE, binary16 activation |
| awq-p3-llm | `pcu_bf16_64` | `int4bf16_pcu_top` | PCU 16 PE, bfloat16 activation |
| p3llm | `p3llm_decoders` | `decoder_tb` | FP8-E4M3 · S0E4M4 · BitMoD4 · INT4, **전 코드 전수** |
| p3llm | `p3llm_compressor` | `compressor_tb` | 4:2 compressor의 sum/carry |
| p3llm | `p3llm_pe` | `p3llm_pe` | PE 지시 시퀀스 |
| p3llm | `p3llm_pcu` | `p3llm_pcu` | PCU 랜덤 타일 회귀 |
| rabit | `rabit_cvt` | `rabit_cvt_tb` | convert-on-write: RNE, subnormal, max-exp 경계. MANT_W 12/10 + SHIFTER_EN 0 동시 |
| rabit | `rabit_align` | `rabit_align_tb` | 지수 정렬 shifter, shift 전 범위 (-64..63) x 경계 psum. truncate/RNE 두 모드 |
| rabit | `rabit_pe` | `rabit_pe` | 부호 조합 전수, one-hot lane, shift·saturation 경계 |
| rabit | `rabit_acc` | `rabit_acc_regfile` | slot 격리, clear, read-modify-write 순서, reset |
| rabit | `rabit_pcu` | `rabit_pcu` | end-to-end GEMV (64 x 4096), 정확한 유리수 reference 대조 |
| rabit | `rabit_pcu_m10` | `rabit_pcu_m10` | 같은 것, MANT_W 10 |
| rabit | `rabit_pcu_noshift` | `rabit_pcu_noshift` | 같은 것, SHIFTER_EN 0 |
| rabit | `rabit_pcu_m10_noshift` | `rabit_pcu_m10_noshift` | 같은 것, 두 노브 동시 |
| rabit-fs | `rabit_fs` | `rabit_pcu_fs` | full-scale variant: h·x를 PCU에서 곱하고 g 역양자화까지 수행, 최종 binary16 y를 bit-정합 대조 |
| rabit-fs | `rabit_fs_pipe` | `rabit_pcu_fs_p` | 같은 것, `H_MUL_PIPE = 1` (곱셈기와 convert 사이에 레지스터, tCCD_S 충족) |
| rabit-fs | `rabit_fs_h16` | `rabit_pcu_fs_h16` | 같은 것, `H_FMT = FP16_3WR` (chunk당 WR 3개) |

## binary32 누산 경로 (`verif/fp32`)
.

```bash
cd verif/fp32 && make
```

| 대상 | RTL | 규모 |
|---|---|---|
| HBM-PIM binary32 add | `hbmpim_fp32_add` | 지원 finite 코너 + DAZ/FTZ 랜덤 |
| AWQ binary32 add | `awq_fp32_add` | 지원 finite 코너 + DAZ/FTZ 랜덤 |
| 내부 형식 변환 · MAC 파이프라인 | `hbmpim_fp16_mac_1_lane`, `awq_int4bf16_mac_1_lane`, `awq_int4fp16_mac_1_lane` | 300,000 사이클 |


## 규모 조절

기본값은 논문용 전량이다. 빠르게 돌리려면:

| 환경변수 | 대상 | 기본 |
|---|---|---|
| `INT4BF16_EXHAUSTIVE=0` | `int4bf16_mul`을 샘플링으로 | `1` (전수) |
| `INT4FP16_RANDOM_ACTS` | `int4fp16_mul` 랜덤 activation 수 | `2000` |
| `PCU_ITERS` | awq PCU 타일 수 | `4000` |
| `P3LLM_RANDOM_TILES` | p3llm PCU 타일 수 | `10000` |
| `FP16_MUL_RANDOM_PAIRS` | baseline multiplier 랜덤 쌍 | `200000` |
| `RABIT_GEMV_DOUT` / `RABIT_GEMV_DIN` | rabit end-to-end GEMV 크기 | `64` / `4096` |
| `RABIT_SEEDS` | rabit GEMV 시드 목록 | `1,2,3` |
| `RABIT_CVT_ITERS` / `RABIT_PE_ITERS` / `RABIT_ACC_ITERS` | rabit 랜덤 반복 | `4000` / `3000` / `2000` |
| `RABIT_FS_PROBLEMS` / `RABIT_FS_SEED` | rabit full-scale 문제 수 / 시드 | `4` / `20260814` |

```bash
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 P3LLM_RANDOM_TILES=200 make   # 빠른 확인
RABIT_GEMV_DIN=1024 make TEST=rabit_pcu                           # rabit만 짧게
```
