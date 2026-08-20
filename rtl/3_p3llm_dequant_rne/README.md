# P3-LLM dequant_rne

P3-LLM의 ③ dequant_rne 구성이다. 16PE raw PCU 뒤에 shared dequant engine을 둔다.

```text
prod32[p]  = RNE32(raw[p] × vector_scale[p] × 2^mode_offset)
fp_acc[p]  = RNE32(fp_acc[p] + prod32[p])
result8[p] = RNE_E4M3(fp_acc[p] × final_scale)
```

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| raw accumulator | signed INT32 |
| dequant engine | shared 1 lane, II=1 |
| group buffering | INT32 snapshot 2개 |
| 출력 | FP8-E4M3FN |
| 면적 | 106,359.036 µm² |

| mode | 입력 | weight | exponent offset |
|---|---|---|---:|
| LINEAR | FP8-E4M3 | BitMoD FP4 | −12 |
| QK | FP8-E4M3 | asymmetric INT4 | −11 |
| PV | FP8-S0E4M4 | asymmetric INT4 | −19 |

E4M3 overflow는 최대 finite 값으로 포화하고 status를 남긴다. 검증은
`make -C verif TEST=p3llm_dequant sim`으로 실행한다.
