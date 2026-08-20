# RaBiT dequant_rne

입력 scale과 출력 dequant/RNE를 PCU 내부에서 처리하는 ③ 최종 구성이다.

| 항목 | 값 |
|---|---|
| compute | physical 4 PE, 2-fold, 500 MHz |
| 입력 | RB2 weight, FP16 `x`, FP8-E4M3 `s_in` |
| block mantissa | 12 bit |
| accumulator | signed 27 bit |
| dequant | 1 lane, FP16 RNE |
| output-scale buffer | 8 output × 2 path × FP16 = 256 bit |
| 면적 | 56,005.768 µm² |
| 셀 / DFF | 47,048 / 2,882 |

```text
u_p[k] = s_in,p[k] × x[k]
A_p[j] = Σk B_p[j][k] × u_p[k]
y[j]   = FP16_RNE(s_out,1[j] × A_1[j] + s_out,2[j] × A_2[j])
```

한 weight word의 출력 8개를 `output half 2 × path 2` 순서로 4 cycle 처리한다.

```text
K chunk마다   WR_H, WR_X, RD_G0, RD_G1, RD_G2, RD_G3
K sweep 뒤    (WR_G(group), DQ(group)) × 4
```

| 적용 최적화 | 값 |
|---|---|
| PE folding | 8 logical output / 4 physical PE |
| accumulator | 32 → 27 bit, `K≤14336` 및 `E0=max(e_ent)` |
| dequant product | 24 → 23 bit |
| exponent state | 10 → 8 bit |
| dequant lane | 2 → 1 |
| scale buffer | 1,024 → 256 bit |
| drain order | output half → path |

8PE base와 같은 500 MHz에서의 word throughput은 다음과 같다.

| K | folded 4PE / 8PE base |
|---:|---:|
| 512 | 54.44% |
| 4,096 | 59.23% |
| 11,008 | 59.71% |

```bash
PATH="$PWD/.venv/bin:$PATH" make -C verif TEST=rabit_fs sim
./synth/run_rabit_fs.sh
```
