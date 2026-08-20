# SpinQuant v2 dequant_requant

SpinQuant 32PE의 ④ dequant_requant 구성이다.

| 항목 | 값 |
|---|---|
| compute | 32 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT32 |
| requant | 2-pass min/max, RNE, zero-point, clamp |
| weight beat | 512 bit |
| 출력 | UINT4 |
| 면적 | 68,389.132 µm² |

UINT4 전용 구성으로 FP16 보조 출력 packer는 제외한다.

검증: `make -C verif TEST=spinquant_pcu_v2_rq sim`
