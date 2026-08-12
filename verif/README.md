# 검증

cocotb + Verilator 회귀. 논문 표의 모든 산술 블록을 golden model과 대조한다.

```
verif/
├── Makefile                 단일 진입점
├── models/                  golden model (순수 파이썬 정수 연산)
│   ├── float_reference.py       IEEE-754 FP16 / BF16 정확 모델
│   ├── int4float_pcu_model.py   awq PCU 모델
│   ├── p3llm_formats.py         p3llm FP8 / FP4 디코더 모델
│   └── p3llm_pcu_model.py       p3llm PE · PCU 모델
└── tests/
    ├── test_fp16_mul_lane.py        baseline
    ├── test_int4fp16_mul_lane.py    awq SIMD
    ├── test_int4bf16_mul_lane.py    awq SIMD
    ├── test_int4float_pcu.py        awq PCU
    ├── test_p3llm_decoders.py       p3llm
    ├── test_p3llm_pe.py             p3llm
    ├── test_p3llm_pcu.py            p3llm
    ├── common.py                    cocotb 헬퍼
    └── harness/                     디코더 · compressor 노출용 SV 래퍼
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

`p3llm_pe`와 `p3llm_pcu`는 설계 자체의 SystemVerilog assertion을
(`P3LLM_ASSERTIONS`) 켜고 돌린다. 출력이 우연히 맞아도 파이프라인 내부에서
가정이 깨지면 실패한다.

## binary32 누산 경로 (`verif/fp32`)

SIMD 행에 붙인 누산기는 cocotb가 아니라 Verilator + C++ 로 검증한다. HBM과
AWQ 모두 finite 입력에 대해 subnormal 입력을 signed zero로 바꾸고(DAZ), 호스트
RNE 결과가 subnormal이면 signed zero로 flush(FTZ)한 oracle과 비교한다. 의존성은
Verilator와 C++ 컴파일러뿐이라 cocotb 없이 돌아간다.

```bash
cd verif/fp32 && make
```

| 대상 | RTL | 규모 |
|---|---|---|
| HBM-PIM binary32 add | `hbmpim_fp32_add` | 지원 finite 코너 + DAZ/FTZ 랜덤 |
| AWQ binary32 add | `awq_fp32_add` | 지원 finite 코너 + DAZ/FTZ 랜덤 |
| 내부 형식 변환 · MAC 파이프라인 | `hbmpim_fp16_mac_1_lane`, `awq_int4bf16_mac_1_lane`, `awq_int4fp16_mac_1_lane` | 300,000 사이클 |

독립 `float16_to_fp32` 모듈은 더 이상 없다. binary16/bfloat16→binary32 변환은 각
MAC lane 내부에 있으며, 마지막 항목에서 곱셈기 결과 tap을 호스트 변환 모델로
넓힌 값과 비교한다. 이 검사는 4단 스테이지 정렬과 `acc_clear`/`acc_enable` 의미도
bubble이 섞인 랜덤 스트림으로 함께 확인한다.


## 규모 조절

기본값은 논문용 전량이다. 빠르게 돌리려면:

| 환경변수 | 대상 | 기본 |
|---|---|---|
| `INT4BF16_EXHAUSTIVE=0` | `int4bf16_mul`을 샘플링으로 | `1` (전수) |
| `INT4FP16_RANDOM_ACTS` | `int4fp16_mul` 랜덤 activation 수 | `2000` |
| `PCU_ITERS` | awq PCU 타일 수 | `4000` |
| `P3LLM_RANDOM_TILES` | p3llm PCU 타일 수 | `10000` |
| `FP16_MUL_RANDOM_PAIRS` | baseline multiplier 랜덤 쌍 | `200000` |

```bash
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 P3LLM_RANDOM_TILES=200 make   # 빠른 확인
```
