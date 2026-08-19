# 2_awq_p3llm_16pe_v2_acc16

[`2_awq_p3llm_16pe_v2`](../2_awq_p3llm_16pe_v2)의 axis-2(acc16) 변형이다.
산술 계약은 [`2_awq_p3llm_8pe_v2_acc16`](../2_awq_p3llm_8pe_v2_acc16)과
완전히 동일하고, `NUM_PES`만 16이다.

- `int4bf16_pcu_top_acc16`: W4G128/BF16 top, `ACC_RSH = 12`, `o_acc` 256b
- `i_weight_zp`: 16 × 4 = 64b, PE별 독립 zero-point (v2 계약)
- 16 PE × 4 multiplier = 64 multiplier, 4-stage pipeline, II=1

`int4float_pe.v` / `int4float_pcu.v`는 8-PE acc16 사본과 `NUM_PES` 기본값을
제외하면 동일하다. 두 디렉토리를 한 소스셋에 함께 넣으면 세 모듈이 중복
정의되므로 반드시 따로 컴파일한다.
