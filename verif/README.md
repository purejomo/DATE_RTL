# 검증

cocotb·Verilator 회귀를 Python integer golden model과 대조한다.

## 실행

```bash
make                         # 전체 회귀
make list                    # 테스트 목록
make TEST=<name>             # 단일 회귀
make distclean               # 생성물 삭제
```

결과 XML은 `build/<name>.xml`에 저장된다.

## 설계군별 주요 테스트

| 설계 | base | acc16 | dequant/requant |
|---|---|---|---|
| HBM-PIM | `fp16_mul` | — | — |
| AWQ 8PE | `pcu_bf16_32` | `pcu_bf16_32_acc16` | `pcu_bf16_32_dq` |
| AWQ 16PE | `pcu_bf16_64` | `pcu_bf16_64_acc16` | `pcu_bf16_64_dq` |
| P3-LLM | `p3llm_pcu` | `p3llm_pcu_acc16` | `p3llm_dequant` |
| RaBiT | `rabit_pcu` | `rabit_pcu_acc16` | `rabit_fs` |
| SpinQuant | `spinquant_pcu` | `spinquant_pcu_acc16` | `spinquant_pcu_dq`, `spinquant_pcu_rq` |
| SpinQuant v2 | `spinquant_pcu_v2` | `spinquant_pcu_v2_acc16` | `spinquant_pcu_v2_dq`, `spinquant_pcu_v2_rq` |

`rabit_fs`는 4PE 2-fold, ACC27, DQ1, 내부 `s_in×x`와 FP16 RNE를 검사한다.
SpinQuant v2 테스트는 32PE와 512-bit weight beat를 검사한다.

세부 산술 블록 이름은 `make list`로 확인한다.

## Golden model

| 파일 | 대상 |
|---|---|
| `models/float_reference.py` | FP16·BF16 |
| `models/int4float_pcu_model.py` | AWQ |
| `models/p3llm_pcu_model.py` | P3-LLM |
| `models/rabit_model.py` | RaBiT base |
| `models/rabit_fs_model.py` | RaBiT dequant_rne |
| `models/spinquant_model.py` | SpinQuant base |
| `models/spinquant_dequant_model.py` | SpinQuant dequant/requant |

## 빠른 실행

```bash
PCU_ITERS=300 P3LLM_RANDOM_TILES=200 make
RABIT_GEMV_DIN=1024 make TEST=rabit_pcu
SPINQUANT_PCU_ITERS=500 make TEST=spinquant_pcu_v2
```

Binary32 전용 경로는 `make -C fp32`로 실행한다.
