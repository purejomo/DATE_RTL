# AWQ 16PE acc16

AWQ 16PE의 ② acc16 구성이다.

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| zero-point | PE별 4 bit, 총 64 bit |
| accumulator | signed INT16, `ACC_RSH=12` |
| 면적 | 68,569.480 µm² |

각 RTL 파일은 이 디렉터리 안에 있으며 다른 AWQ 디렉터리와 함께 컴파일하지 않는다.
