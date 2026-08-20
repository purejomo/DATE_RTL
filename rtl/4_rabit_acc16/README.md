# RaBiT acc16

RaBiT의 ② acc16 구성이다.

| 항목 | ① base | ② acc16 |
|---|---:|---:|
| PE | 8 | 8 |
| accumulator | 32 bit | 16 bit |
| block mantissa | 12 bit | 10 bit |
| align rounding | truncate | RNE |
| 출력 | raw INT32 | raw INT16 |
| 면적 | 45,253.516 µm² | 32,208.876 µm² |

`MANT_W=10`은 `ACC_W > MANT_W+5` 조건을 만족시키기 위한 값이다. 누산기 저장량은
2,048 bit에서 1,024 bit로 줄어든다. ③ dequant_rne는 별도 4PE 2-fold 구조이며
ACC27과 FP16 출력을 사용한다.
