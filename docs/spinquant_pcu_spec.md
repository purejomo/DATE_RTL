# SpinQuant PCU 명세

## 비교 구성

| 축 | 조직 | 출력 | 면적 (µm²) |
|---|---|---|---:|
| ① base | 16 PE / 500 MHz | INT32 | 32,376 |
| ② acc16 | 16 PE / 500 MHz | INT16 | 25,767 |
| ③ dequant_rne | 16 PE / 500 MHz | FP16 | 40,271 |
| ④ dequant_requant | 16 PE / 500 MHz | UINT4 | 39,997 |
| v2 ① base | 32 PE / 500 MHz | INT32 | 64,345 |
| v2 ② acc16 | 32 PE / 500 MHz | INT16 | 51,191 |
| v2 ③ dequant_rne | 32 PE / 500 MHz | FP16 | 68,391 |
| v2 ④ dequant_requant | 32 PE / 500 MHz | UINT4 | 68,389 |

## 연산

Weight는 signed INT4, activation은 unsigned INT4다.

```text
acc[e][i] += Σj W_q[i,j] × A_q[j]
```

| 항목 | 값 |
|---|---|
| weight | signed INT4, −8..7 |
| activation | unsigned INT4, 0..15 |
| product | signed 8 bit |
| 4-way partial sum | signed 10 bit |
| base accumulator | 24-bit carry chain, 32-bit output |
| entry | 4 |

Rotation은 weight에 offline merge한다. Activation quantization과 base 축의 scale 및
bias 적용은 NPU가 담당한다.

## 데이터패스

```text
weight beat → local latch → PE array → accumulator file → raw drain
```

| 구성 | PE | multiplier | weight beat | output | peak |
|---|---:|---:|---:|---:|---:|
| base | 16 | 64 | 256 bit | 512 bit | 64 MAC/cycle |
| v2 | 32 | 128 | 512 bit | 1,024 bit | 128 MAC/cycle |

한 PE는 INT4 multiplier 4개, 4:2 reduction과 accumulator adder 1개를 가진다.
Pipeline은 2 stage이며 II=1이다.

Base의 2-pump는 한 weight beat를 두 activation entry에 재사용한다. v2의
64 GMAC/s를 지속하려면 512-bit weight beat를 공급할 bank pair 또는 동등한 대역폭이
필요하다.

## 확장 축

| 축 | 변경 |
|---|---|
| ② acc16 | `ACC_RSH=7` RNE 후 INT16 누산 |
| ③ dequant_rne | `acc+bias_int`에 scale을 곱해 FP16 출력 |
| ④ dequant_requant | 2-pass min/max 후 UINT4 출력 |

③의 연산은 다음과 같다.

```text
fixed[i] = acc[i] + bias_int[i]
fp32[i]  = RNE32(fixed[i] × scale[i])
y16[i]   = RNE16(fp32[i])
```

④는 pass 1에서 output row min/max를 구하고 pass 2에서 UINT4로 변환한다.

```text
q4[i] = clamp(RNE(fp32[i] / next_scale) + next_zp, 0, 15)
```

③은 host requantization이 남고, ④는 W4A4 activation loop를 PCU에서 마친다.

## v2

| 축 | 면적 (µm²) | v2 base 대비 | 69,000 µm² 여유 |
|---|---:|---:|---:|
| ① base | 64,345.400 | — | 4,654.600 |
| ② acc16 | 51,191.434 | −20.4% | 17,808.566 |
| ③ dequant_rne | 68,391.260 | +6.3% | 608.740 |
| ④ dequant_requant | 68,389.132 | +6.3% | 610.868 |

v2는 128 MAC/cycle이며 각 RTL 디렉터리 내부에서 의존성을 해결한다. ④는 UINT4
전용으로 FP16 보조 출력 packer를 제외한다.

## 검증과 결과

```bash
make -C verif TEST=spinquant_pcu sim
make -C verif TEST=spinquant_pcu_acc16 sim
make -C verif TEST=spinquant_pcu_dq sim
make -C verif TEST=spinquant_pcu_rq sim
make -C verif TEST=spinquant_pcu_v2 sim
make -C verif TEST=spinquant_pcu_v2_acc16 sim
make -C verif TEST=spinquant_pcu_v2_dq sim
make -C verif TEST=spinquant_pcu_v2_rq sim
./synth/run_spinquant_v2.sh
```

면적 정본은 [`results/area.csv`](../results/area.csv)에 있다.
