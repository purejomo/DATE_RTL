# AWQ 8PE dequant_rne

AWQ 8PE의 ③ dequant_rne 구성이다. INT32 누산은 유지하고 BF16 또는 FP16 결과를
PCU에서 만든다.

```text
prod32[p]   = RNE32(acc[p] × scale[p,g] × 2^(ref_exp-GUARD))
fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])
out16[p]    = RNE16(fp_acc32[p])
```

| 항목 | 값 |
|---|---|
| compute | 8 PE × 4 multiplier, 500 MHz |
| integer accumulator | signed INT32 |
| dequant engine | shared 1 lane, II=1 |
| group buffering | snapshot 2개 |
| 출력 | BF16 또는 FP16 |
| BF16 면적 | 61,701.892 µm² |

`i_group_last`에서 group scale을 받고, `i_dot_last`에서 최종 RNE 출력을 요청한다.
검증은 `make -C verif TEST=pcu_bf16_32_dq sim`으로 실행한다.
