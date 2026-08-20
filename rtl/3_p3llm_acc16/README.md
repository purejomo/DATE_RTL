# P3-LLM acc16

P3-LLM의 ② acc16 구성이다.

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT16, saturating |
| `ACC_RSH` | 16 |
| 출력 | raw INT16 |
| 면적 | 62,151.964 µm² |

decoder, multiplier, shifter와 reduction 경로는 ① base와 같다. `ACC_RSH=16`은
세 op mode의 group-128 최악값이 signed INT16에 들어가는 최소 공통 시프트다.
