# AWQ 8PE v2

AutoAWQ W4G128 연산을 위한 8PE 구성이다.

| 항목 | 값 |
|---|---|
| compute | 8 PE × 4 multiplier, 500 MHz |
| weight | asymmetric INT4, PE별 4-bit zero-point |
| activation | BF16 또는 FP16 |
| accumulator | signed INT32 |
| pipeline | 4 stage, II=1 |
| 면적 | 36,918.672 µm² |

이 디렉터리는 ① base 축이며 raw INT32를 출력한다. 누산 축소는
`2_awq_p3llm_8pe_v2_acc16`, PCU 내부 dequant/RNE는
`2_awq_p3llm_8pe_v2_dequant_rne`에 있다.
