# 2_awq_p3llm_16pe_v2_dequant_rne

[`2_awq_p3llm_16pe_v2`](../2_awq_p3llm_16pe_v2)의 axis-3(dequant_rne) 변형이다.

| 축 | 디렉토리 | 출력 |
|---|---|---|
| ① base | `2_awq_p3llm_16pe_v2` | raw INT32 (`o_acc`) |
| ② acc16 | `2_awq_p3llm_16pe_v2_acc16` | raw INT16 |
| ③ dequant_rne | **이 디렉토리** | BF16 / FP16 activation (`o_result`) |

- top: `int4bf16_pcu_top_dq` (`int4fp16_pcu_top_dq`는 FP16 대조군)
- raw PCU(`int4float_pcu`)는 **무변경**. `o_acc` raw drain도 그대로 남긴다
  (`4_rabit_dequant_rne`가 raw drain을 남긴 것과 동일한 이유 — base 대비 비교)

## 산술 계약

PE `p`, weight group `g`에 대해:

```text
prod32[p]   = RNE32(acc_int32[p] * scale16[p,g] * 2^(i_ref_exp - GUARD))
fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])      # group 간 누적
out16[p]    = RNE16(fp_acc32[p])                  # i_dot_last에서 1회
```

- 정수 누산기는 **32-bit 유지**. 좁히는 것은 별개의 축(②)이므로 group 경계
  이전은 ①과 bit-identical이어야 한다.
- group 간 합은 **PCU 안 FP32 state**로 들고 있다가 마지막에 한 번만
  출력 포맷으로 반올림한다. group마다 부분합을 내보내면 이 설계가 줄이려는
  데이터 이동이 오히려 늘어난다.
- **requant 단계도, 두 번째 스케일도 없다.** AWQ activation이 이미
  BF16/FP16이라 weight group scale이 유일한 스케일이고, 출력 포맷이 곧 다음
  레이어의 입력 포맷이다. (P3-LLM의 `final_scale`에 대응하는 것이 없다.)
- **가정**: `i_ref_exp`는 weight group 안에서 일정하다. 소프트웨어가 이미
  block 단위로 고르는 값이며, 여기서는 "block이 group 경계를 걸치지 않는다"로
  좁힌 것이다. 값은 accepted `i_group_last` transfer에서 1회 샘플된다.

## 추가 포트

```text
input  i_group_last                      // group의 마지막 accepted tile
input  [NUM_PES*16-1:0] i_scale          // PE별 group scale
input  i_fp_acc_clear                    // 새 dot product 시작
input  i_dot_last                        // 최종 출력 요청
output o_result_valid
input  i_result_ready
output [NUM_PES*16-1:0] o_result
output o_busy
output [3:0] o_status_sticky   // [0] invalid [1] overflow [2] underflow [3] protocol
```

## 구현 — 새로 설계하지 않고 재사용

`3_p3llm_dequant_rne`의 세 모듈을 파라미터화해 복사했다. 기존 PE 곱셈기는
`ALIGNED_W × signed 5-bit` 고정소수점이라 BF16 scale 곱에 재사용할 수 없으므로
공유 엔진 1개 추가는 불가피하다. "로직 추가 최소화"는 새로 설계하지 않는 것으로
달성한다.

| 파일 | 원본 | 일반화 |
|---|---|---|
| `awq_dq_fixed32_float16_mul_pipe.sv` | `p3llm_dequant_fixed32_fp16_mul_pipe.sv` | 고정 mode offset → signed 12-bit `exp_offset_i`; scale 포맷 파라미터화 |
| `awq_dq_fp32_add_pipe.sv` | `p3llm_dequant_fp32_add_pipe.sv` | 산술 무변경, 모듈명만 |
| `awq_dq_fp32_pack_pipe.sv` | `p3llm_dequant_fp32_fp16_mul_pack_pipe.sv` | 두 번째 스케일 곱 제거, `EXP_W`/`MANT_W` 파라미터 |

## 처리량

공유 엔진 1개, II=1. group size 128 · PE당 4 lane이면 group 경계는 32 accepted
cycle마다 오고 batch는 16 cycle이므로 여유가 있다. 정지 불가능한 raw
파이프라인과는 **스냅샷 슬롯 2개**로 디커플링한다 (`p3llm_pcu_dequant.sv`와 동일).

## 검증

`verif`의 `awq_dequant_arith` 회귀가 세 pipe를 BF16/FP16 양쪽 파라미터로
지시 경계 + 랜덤 스윕 대조한다 (`verif/models/awq_dequant_model.py`).
