# SpinQuant acc16

SpinQuant의 ② acc16 구성이다.

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT16 |
| `ACC_RSH` | 7, RNE |
| overflow | sticky report |
| 출력 | raw INT16 |
| 면적 | 25,767.420 µm² |

곱셈기와 reduction 경로는 ① base와 같다. `ACC_RSH=7`은 K=14,336의 22-bit
최악 누산값에서 상위 정밀도를 보존하기 위한 값이다. 누산기 저장량은 2,048 bit에서
1,024 bit로 줄어든다.
