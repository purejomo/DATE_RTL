# SpinQuant v2 acc16

SpinQuant 32PE의 ② acc16 구성이다.

| 항목 | 값 |
|---|---|
| compute | 32 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT16, `ACC_RSH=7`, RNE |
| weight beat | 512 bit |
| 출력 | 32 × INT16 = 512 bit |
| 면적 | 51,191.434 µm² |

검증: `make -C verif TEST=spinquant_pcu_v2_acc16 sim`
