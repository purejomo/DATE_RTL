# AWQ 8PE acc16

AWQ 8PE의 ② acc16 구성이다.

| 항목 | 값 |
|---|---|
| compute | 8 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT16, saturating |
| BF16 `ACC_RSH` | 12 |
| FP16 `ACC_RSH` | 15 |
| 면적 | 36,193.822 µm² |

곱셈기와 reduction 경로는 ① base와 같다. 28-bit partial sum을 RNE로 좁힌 뒤
16-bit 누산기에 더한다. 시프트 기본값은 group 128의 최악값이 포화되지 않는
경계이며 정확도 최적값은 별도 sweep 대상이다.
