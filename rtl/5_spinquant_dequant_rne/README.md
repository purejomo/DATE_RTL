# SpinQuant dequant_rne

SpinQuant의 ③ dequant_rne 구성이다. FP16을 출력하므로 다음 INT4 layer를 위한
requantization은 host에 남는다.

```text
fixed[i] = acc[i] + bias_int[i]
fp32[i]  = RNE32(fixed[i] × scale[i])
y16[i]   = RNE16(fp32[i])
```

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT32 |
| dequant | shared 1 lane |
| 출력 | FP16 |
| 면적 | 40,270.804 µm² |
| 셀 / DFF | 31,707 / 2,121 |

`bias_int=-zp_a×ΣW_q`로 activation zero-point를 정수 영역에 접는다. drain 중에는
대상 accumulator entry에 MAC을 발행하지 않는다. 다른 entry는 계속 사용할 수 있다.

검증: `make -C verif TEST=spinquant_pcu_dq sim`
