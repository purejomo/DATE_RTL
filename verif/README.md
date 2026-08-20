# 검증

cocotb + Verilator 회귀. 논문 표의 모든 산술 블록을 golden model과 대조한다.

```
verif/
├── Makefile                 단일 진입점
├── models/                  golden model (순수 파이썬 정수 연산)
│   ├── float_reference.py       IEEE-754 FP16 / BF16 정확 모델
│   ├── int4float_pcu_model.py   awq PCU 모델
│   ├── awq_dequant_model.py     awq dequant 모델
│   ├── p3llm_formats.py         p3llm FP8 / FP4 디코더 모델
│   ├── p3llm_pcu_model.py       p3llm PE · PCU 모델
│   ├── p3llm_dequant_model.py   p3llm dequant · FP8 pack 모델
│   ├── rabit_model.py           rabit 변환 · PE · 누산기 · PCU 모델
│   ├── rabit_fs_model.py        rabit dequant/full-scale 모델
│   ├── spinquant_model.py       spinquant W4A4 정수 GEMV · PCU 모델
│   └── spinquant_dequant_model.py spinquant dequant/requant 모델
└── tests/                   설계군별 cocotb 테스트와 산술 harness
fp32/                        binary32 누산 경로 (cocotb 없이 Verilator만)
├── Makefile
├── tb_top.v / main.cpp          binary32 누산 가산기
├── tb_mac.v / main_mac.cpp      내부 형식 변환 · MAC 레인 4단 파이프라인
└── tb_align.v / main_align.cpp  block-float 정렬기 전수 · PE 누산 saturation
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

다섯 설계군의 base와 현재 acc16/dequant/requant 변형을 모두 덮는다(총 40개).

| 논문 행 | 이름 | RTL top | 무엇을 확인하나 |
|---|---|---|---|
| hbm-pim | `fp16_mul` | `hbmpim_fp16_mul` | 정상 finite binary16 RNE, DAZ/FTZ 코너 + 지원 encoding + 랜덤 |
| awq-p3-llm | `pcu_bf16_32` | `int4bf16_pcu32` | PCU 8 PE (v2, PE별 ZP), bfloat16 activation |
| awq-p3-llm | `pcu_fp16_32` | `int4fp16_pcu32` | 같은 것, binary16 activation |
| awq-p3-llm | `pcu_bf16_64` | `int4bf16_pcu_top` | PCU 16 PE (v2, PE별 ZP), bfloat16 activation |
| awq-p3-llm | `pcu_bf16_32_acc16` | `int4bf16_pcu32_acc16` | 축② 누산기 16-bit, 누산 전 RNE narrow (`ACC_RSH` 12). 8 PE |
| awq-p3-llm | `pcu_fp16_32_acc16` | `int4fp16_pcu32_acc16` | 같은 것, binary16 activation (`ACC_RSH` 15) |
| awq-p3-llm | `pcu_bf16_64_acc16` | `int4bf16_pcu_top_acc16` | 같은 것, 16 PE |
| awq-p3-llm | `pcu_bf16_32_dq` | `int4bf16_pcu32_dq` | 축③ end-to-end: raw INT32 대조 + group 스냅샷·태그 FIFO·배치 시퀀서를 거친 최종 BF16 벡터, sticky status 까지 golden model 대조. 8 PE |
| awq-p3-llm | `pcu_bf16_64_dq` | `int4bf16_pcu_top_dq` | 같은 것, 16 PE |
| awq-p3-llm | `awq_dequant_arith` | `awq_dequant_arith_tb` | PU 내 dequant 3-pipe: INT32×scale→FP32, FP32 누산, FP32→BF16/FP16 RNE pack. BF16·FP16 양쪽 파라미터를 한 번에 |
| p3llm | `p3llm_decoders` | `decoder_tb` | FP8-E4M3 · S0E4M4 · BitMoD4 · INT4, **전 코드 전수** |
| p3llm | `p3llm_compressor` | `compressor_tb` | 4:2 compressor의 sum/carry |
| p3llm | `p3llm_pe` | `p3llm_pe` | PE 지시 시퀀스 |
| p3llm | `p3llm_pcu` | `p3llm_pcu` | PCU 랜덤 타일 회귀 |
| p3llm | `p3llm_pcu_acc16` | `p3llm_pcu_acc16` | 축② 누산기 16-bit, `ACC_RSH` 16 (세 op_mode 공통). 같은 랜덤 타일 회귀 |
| p3llm | `p3llm_dequant_arith` | `p3llm_dequant_arith_tb` | PU 내 dequant 3-pipe 경계값. 최종 pack 은 FP8-E4M3 이며 `fp8_e4m3_decoder` 의 역함수인지 **254개 유한 코드 전수 round-trip** |
| p3llm | `p3llm_dequant` | `p3llm_pcu_dequant` | raw PCU + 공유 dequant 엔진 end-to-end, 세 op_mode. 최종 FP8 벡터와 sticky status 를 golden model 과 대조 |
| rabit | `rabit_cvt` | `rabit_cvt_tb` | convert-on-write: RNE, subnormal, max-exp 경계. MANT_W 12/10 + SHIFTER_EN 0 동시 |
| rabit | `rabit_align` | `rabit_align_tb` | 지수 정렬 shifter, shift 전 범위 (-64..63) x 경계 psum. truncate/RNE 두 모드 |
| rabit | `rabit_pe` | `rabit_pe` | 부호 조합 전수, one-hot lane, shift·saturation 경계 |
| rabit | `rabit_acc` | `rabit_acc_regfile` | slot 격리, clear, read-modify-write 순서, reset |
| rabit | `rabit_pcu` | `rabit_pcu` | end-to-end GEMV (64 x 4096), 정확한 유리수 reference 대조 |
| rabit | `rabit_pcu_m10` | `rabit_pcu_m10` | 같은 것, MANT_W 10 |
| rabit | `rabit_pcu_noshift` | `rabit_pcu_noshift` | 같은 것, SHIFTER_EN 0 |
| rabit | `rabit_pcu_m10_noshift` | `rabit_pcu_m10_noshift` | 같은 것, 두 노브 동시 |
| rabit | `rabit_pcu_acc16` | `rabit_pcu_acc16` | 축② `ACC_W` 16 · `MANT_W` 10 · `SHIFT_RND` 1. 같은 end-to-end GEMV |
| rabit-fs | `rabit_fs` | `rabit_pcu_fs` | 8 PE/ACC27/DQ1 최종 구조. `s_in·x`, group-scale dequant, FP16 RNE 출력과 raw drain을 bit-정합 대조 |

rabit-fs의 모든 RTL 의존성은 `rtl/4_rabit_dequant_rne` 안에 있다.

| spinquant | `spinquant_pe` | `spinquant_pe` | (weight, activation) 코드쌍 전수, way별 one-hot, 24b chain 경계, 랜덤 |
| spinquant | `spinquant_acc` | `spinquant_acc_regfile` | entry 격리, accumulate/drain 두 읽기 포트 독립성, reset |
| spinquant | `spinquant_pcu` | `spinquant_pcu` | end-to-end W4A4 GEMV (K=128/1024/14336), 정수 GEMV reference 대조. 2-pump·entry interleave·최악 누산·overflow 포함 |
| spinquant | `spinquant_pcu_nolatch` | `spinquant_pcu_nolatch` | 같은 것, W_LATCH 0 (read latch 경계 밖) |
| spinquant | `spinquant_pcu_acc32` | `spinquant_pcu_acc32` | 같은 것, ACC_CHAIN_W 32 |
| spinquant | `spinquant_pcu_r2e2` | `spinquant_pcu_r2e2` | 같은 것, NROW 2 · entry 2 |
| spinquant | `spinquant_pcu_r2` | `spinquant_pcu_r2` | 같은 것, NROW 2 · entry 4 |
| spinquant | `spinquant_pcu_r4` | `spinquant_pcu_r4` | 같은 것, NROW 4 |
| spinquant | `spinquant_pcu_w512` | `spinquant_pcu_w512` | 같은 것, NPE 32 (512b beat) |
| spinquant | `spinquant_pcu_acc16` | `spinquant_pcu_acc16` | 축② INT16 누산, `ACC_RSH=7`로 MSB 보존. base와 같은 GEMV 회귀 |
| spinquant | `spinquant_rq_cvt` | `spinquant_rq_fp32_to_int4` | 축④ FP32→UINT4 RNE + zero-point + clamp, 랜덤·경계값 |
| spinquant | `spinquant_pcu_dq` | `spinquant_pcu_dq` | 축③ raw INT32 + 정수 bias + scale → binary16 drain, lane/tag/status end-to-end |
| spinquant | `spinquant_pcu_rq` | `spinquant_pcu_rq` | 축④ 2-pass min/max 뒤 UINT4 requant drain end-to-end |

## binary32 누산 경로 (`verif/fp32`)

```bash
cd verif/fp32 && make
```

| 대상 | RTL | 규모 |
|---|---|---|
| binary32 add | `hbmpim_fp32_add` | 지원 finite 코너 + DAZ/FTZ 랜덤 400만 |
| 내부 형식 변환 · MAC 파이프라인 | `hbmpim_fp16_mac_1_lane` | 300,000 사이클 |
| block-float 정렬기 · PE saturation | `int4float_align`, `int4float_pe` | bfloat16 encoding 전수 × ref_exp 스윕 |


## 규모 조절

기본값은 논문용 전량이다. 빠르게 돌리려면:

| 환경변수 | 대상 | 기본 |
|---|---|---|
| `PCU_ITERS` | awq PCU 타일 수 | `4000` |
| `P3LLM_RANDOM_TILES` | p3llm PCU 타일 수 | `10000` |
| `FP16_MUL_RANDOM_PAIRS` | baseline multiplier 랜덤 쌍 | `200000` |
| `RABIT_GEMV_DOUT` / `RABIT_GEMV_DIN` | rabit end-to-end GEMV 크기 | `64` / `4096` |
| `RABIT_SEEDS` | rabit GEMV 시드 목록 | `1,2,3` |
| `RABIT_CVT_ITERS` / `RABIT_PE_ITERS` / `RABIT_ACC_ITERS` | rabit 랜덤 반복 | `4000` / `3000` / `2000` |
| `RABIT_FS_PROBLEMS` / `RABIT_FS_SEED` | rabit full-scale 문제 수 / 시드 | `4` / `20260814` |
| `SPINQUANT_PCU_ITERS` | spinquant PCU 랜덤 MAC command 수 | `6000` |
| `SPINQUANT_PE_ITERS` | spinquant PE 랜덤 벡터 수 | `20000` |
| `SPINQUANT_DQ_ROUNDS` | spinquant 축③ drain batch 수 | `12` |
| `SPINQUANT_RQ_ROUNDS` | spinquant 축④ 2-pass drain batch 수 | `12` |
| `SPINQUANT_RQ_ITERS` | FP32→UINT4 변환기 랜덤 입력 수 | `20000` |

```bash
PCU_ITERS=300 P3LLM_RANDOM_TILES=200 make                         # 빠른 확인
RABIT_GEMV_DIN=1024 make TEST=rabit_pcu                           # rabit만 짧게
```
