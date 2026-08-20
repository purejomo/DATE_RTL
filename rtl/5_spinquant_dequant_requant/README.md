# SpinQuant dequant_requant

SpinQuant의 ④ 구성이다. dequantization과 UINT4 requantization을 PCU에서 처리한다.

```text
fixed[i] = acc[i] + bias_int[i]
fp32[i]  = RNE32(fixed[i] × scale[i])
q4[i]    = clamp(RNE(fp32[i] / next_scale) + next_zp, 0, 15)
```

| 항목 | 값 |
|---|---|
| compute | 16 PE × 4 multiplier, 500 MHz |
| accumulator | signed INT32 |
| requant | 2-pass min/max, RNE, zero-point, clamp |
| 출력 | UINT4 |
| 면적 | 39,996.824 µm² |
| 셀 / DFF | 32,769 / 2,260 |

Pass 1은 output row의 min/max를 구하고, NPU가 다음 token scale과 zero-point를
계산한다. Pass 2는 미리 계산된 reciprocal scale을 곱해 UINT4를 출력한다.
`KEEP_FP16_OUT=1`이면 FP16 출력도 유지한다.

검증:

```bash
make -C verif TEST=spinquant_rq_cvt sim
make -C verif TEST=spinquant_pcu_rq sim
```
