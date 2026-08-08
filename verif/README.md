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
    ├── test_fp16_add_lane.py        baseline
    ├── test_int4fp16_mul_lane.py    awq SIMD
    ├── test_int4bf16_mul_lane.py    awq SIMD
    ├── test_bf16_add_lane.py        awq SIMD
    ├── test_int4float_pcu.py        awq PCU
    ├── test_p3llm_decoders.py       p3llm
    ├── test_p3llm_pe.py             p3llm
    ├── test_p3llm_pcu.py            p3llm
    ├── common.py                    cocotb 헬퍼
    └── harness/                     디코더 · compressor 노출용 SV 래퍼
```

## 실행

```bash
make                    # 전체 회귀 (13개)
make list               # 테스트 이름 목록
make TEST=p3llm_pcu     # 하나만
make distclean          # 산출물 삭제
```

산출물은 `build/<test>/`, 결과 XML은 `build/<test>.xml`.

## 테스트 목록

논문의 4개 행을 모두 덮는다.

| 논문 행 | 이름 | RTL top | 무엇을 확인하나 |
|---|---|---|---|
| hbm-pim | `fp16_mul` | `hbmpim_fp16_mul_lane` | binary16 곱. 코너 전수 + 코너×전체 786,432 + 랜덤 |
| hbm-pim | `fp16_add` | `hbmpim_fp16_add_lane` | binary16 덧셈. 위와 동일 규모 |
| awq-hbm-pim | `int4bf16_mul` | `int4bf16_mul_lane` | INT4 × bfloat16 곱, **전수 2,031,616** |
| awq-hbm-pim | `int4fp16_mul` | `int4fp16_mul_lane` | INT4 × binary16 곱, 코너 전수 + 랜덤 |
| awq-hbm-pim | `bf16_add` | `bf16_add_lane` | bfloat16 덧셈, 코너 전수 + 랜덤 |
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


## 규모 조절

기본값은 논문용 전량이다. 빠르게 돌리려면:

| 환경변수 | 대상 | 기본 |
|---|---|---|
| `INT4BF16_EXHAUSTIVE=0` | `int4bf16_mul`을 샘플링으로 | `1` (전수) |
| `INT4FP16_RANDOM_ACTS` | `int4fp16_mul` 랜덤 activation 수 | `2000` |
| `PCU_ITERS` | awq PCU 타일 수 | `4000` |
| `P3LLM_RANDOM_TILES` | p3llm PCU 타일 수 | `10000` |
| `FP16_MUL_RANDOM_PAIRS` / `FP16_ADD_RANDOM_PAIRS` | baseline lane 랜덤 쌍 | `200000` |

```bash
INT4BF16_EXHAUSTIVE=0 PCU_ITERS=300 P3LLM_RANDOM_TILES=200 make   # 빠른 확인
```
