# AWQ 16PE dequant_rne

AWQ 16PE의 ③ dequant_rne 구성이다. 산술과 제어는 8PE 구성과 같고 출력 lane만
16개다.

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| integer accumulator | signed INT32 |
| dequant engine | shared 1 lane, II=1 |
| group buffering | snapshot 2개 |
| 출력 | BF16 또는 FP16 |
| BF16 면적 | 105,060.690 µm² |

연산식은 `2_awq_p3llm_8pe_v2_dequant_rne`와 같다. 검증은
`make -C verif TEST=pcu_bf16_64_dq sim`으로 실행한다.
