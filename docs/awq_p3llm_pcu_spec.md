# AWQ·P3-LLM PCU 명세

## 비교 구성

| 설계 | 축 | 조직 | 출력 | 면적 (µm²) |
|---|---|---|---|---:|
| AWQ | ① base | 8 PE / 500 MHz | INT32 | 36,919 |
| AWQ | ② acc16 | 8 PE / 500 MHz | INT16 | 36,194 |
| AWQ | ③ dequant_rne | 8 PE / 500 MHz | BF16 | 61,702 |
| AWQ | ① base | 16 PE / 500 MHz | INT32 | 72,280 |
| AWQ | ② acc16 | 16 PE / 500 MHz | INT16 | 68,569 |
| AWQ | ③ dequant_rne | 16 PE / 500 MHz | BF16 | 105,061 |
| P3-LLM | ① base | 16 PE / 500 MHz | INT32 | 71,287 |
| P3-LLM | ② acc16 | 16 PE / 500 MHz | INT16 | 62,152 |
| P3-LLM | ③ dequant_rne | 16 PE / 500 MHz | FP8-E4M3 | 106,359 |

| 축 | 정의 |
|---|---|
| ① base | INT32 누산 후 raw 출력 |
| ② acc16 | partial sum을 RNE 축소 후 INT16 누산 |
| ③ dequant_rne | INT32 누산 후 PCU 내부에서 출력 형식으로 변환 |

## AWQ

AWQ는 asymmetric INT4 weight와 BF16/FP16 activation을 사용한다.

```text
w[p,l]   = q[p,l] - zp[p]
partial  = Σl w[p,l] × activation[l]
acc[p]   = acc[p] + align(partial, ref_exp)
```

| 항목 | 값 |
|---|---|
| PE당 multiplier | 4 |
| zero-point | PE별 독립 4 bit |
| pipeline | 4 stage, II=1 |
| base accumulator | signed INT32, saturating |
| acc16 | signed INT16, BF16 `ACC_RSH=12`, FP16 `ACC_RSH=15` |

③은 group scale을 적용하고 FP32로 group 간 누산한 뒤 마지막에 한 번 RNE한다.

```text
prod32[p]   = RNE32(acc[p] × scale[p,g] × 2^(ref_exp-GUARD))
fp_acc32[p] = RNE32(fp_acc32[p] + prod32[p])
out16[p]    = RNE16(fp_acc32[p])
```

Shared dequant engine은 1 lane, II=1이며 INT32 snapshot 2개로 raw pipeline과
분리한다.

## P3-LLM

P3-LLM은 mode에 따라 activation과 4-bit weight decoder를 선택한다.

| mode | activation | weight | exponent offset |
|---|---|---|---:|
| LINEAR | FP8-E4M3 | BitMoD FP4 | −12 |
| QK | FP8-E4M3 | asymmetric INT4 | −11 |
| PV | FP8-S0E4M4 | asymmetric INT4 | −19 |

각 PE는 decoder 4개, multiplier 4개, 4:2 reduction과 accumulator 1개를 가진다.
②는 `ACC_RSH=16`을 적용한 INT16 누산기다.

③은 다음 식을 계산하고 FP8-E4M3FN으로 출력한다.

```text
prod32[p]  = RNE32(raw[p] × vector_scale[p] × 2^mode_offset)
fp_acc[p]  = RNE32(fp_acc[p] + prod32[p])
result8[p] = RNE_E4M3(fp_acc[p] × final_scale)
```

E4M3 overflow는 최대 finite 값으로 포화하고 status를 남긴다.

## 검증과 결과

```bash
make -C verif TEST=pcu_bf16_32 sim
make -C verif TEST=pcu_bf16_32_acc16 sim
make -C verif TEST=pcu_bf16_32_dq sim
make -C verif TEST=p3llm_pcu sim
make -C verif TEST=p3llm_pcu_acc16 sim
make -C verif TEST=p3llm_dequant sim
```

RTL은 각 축 디렉터리 안에서만 의존성을 해결한다. 면적 정본은
[`results/area.csv`](../results/area.csv)에 있다.
