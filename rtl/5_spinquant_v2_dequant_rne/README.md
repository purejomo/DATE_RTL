# SpinQuant v2 dequant_rne

SpinQuant 32PE의 ③ dequant_rne 구성이다.

| 항목 | 값 |
|---|---|
| compute | 32 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT32 |
| dequant | shared 1 lane |
| weight beat | 512 bit |
| 출력 | FP16 |
| 면적 | 68,391.260 µm² |

검증: `make -C verif TEST=spinquant_pcu_v2_dq sim`
