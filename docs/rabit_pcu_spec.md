# RaBiT PCU 명세

## 비교 구성

| 축 | 조직 | accumulator | 출력 | 면적 (µm²) |
|---|---|---|---|---:|
| ① base | 8 PE / 500 MHz | INT32 | raw INT32 | 45,254 |
| ② acc16 | 8 PE / 500 MHz | INT16 | raw INT16 | 32,209 |
| ③ dequant_rne | folded 4 PE / 500 MHz | INT27 | FP16 | 56,006 |

③은 입력 scale `s_in×x`와 출력 dequant/RNE를 모두 PCU 내부에서 처리한다.

## 연산과 데이터 매핑

```text
u_p[k] = s_in,p[k] × x[k]
A_p[j] = Σk B_p[j][k] × u_p[k]
y[j]   = FP16_RNE(s_out,1[j] × A_1[j] + s_out,2[j] × A_2[j])
```

RTL 이름은 `h=s_in`, `g=s_out`이다. 한 256-bit weight word의 배치는 다음과 같다.

```text
bit[j*(2*16) + p*16 + k] = B_p[j][k]
input 16 × output 8 × path 2 = 256 bit
```

| 축 | physical PE | word 처리 cycle |
|---|---:|---:|
| ①·② | 8 | path 2개 = 2 cycle |
| ③ | 4 | output half 2개 × path 2개 = 4 cycle |

## ③ 최종 구성

| 항목 | 값 |
|---|---|
| physical PE | 4, `NFOLD=2` |
| block mantissa | 12 bit |
| accumulator | signed 27 bit |
| input scale | FP8-E4M3, 16-lane `s_in×x` |
| output scale | FP16, group당 256-bit buffer |
| dequant | 1 lane, FP16 RNE |
| output pack | FP16 4개 / 64-bit beat |

적용한 폭과 storage 최적화는 다음과 같다.

| 항목 | 변경 |
|---|---|
| accumulator | 32 → 27 bit |
| dequant product | 24 → 23 bit |
| exponent state | 10 → 8 bit |
| dequant lane | 2 → 1 |
| output-scale buffer | 1,024 → 256 bit |
| drain order | output half → path |

ACC27은 `K≤14336`, `E0=max(e_ent)`에서 exact하다.

```text
|ACC|max = 16 × 4095 × (14336/16) = 58,705,920 < 2^26
```

## 명령과 처리량

```text
K chunk마다   WR_H, WR_X, RD_G0, RD_G1, RD_G2, RD_G3
K sweep 뒤    (WR_G(group), DQ(group)) × 4
```

`C=K/16`일 때 8PE base는 `6C+4` slot, folded 4PE ③은 `10C+40` slot이다.

| K | ③ / 8PE base word throughput |
|---:|---:|
| 512 | 54.44% |
| 4,096 | 59.23% |
| 11,008 | 59.71% |

## 검증과 결과

```bash
PATH="$PWD/.venv/bin:$PATH" make -C verif TEST=rabit_fs sim
python3 tools/pack_rabit_fs.py --self-test
./synth/run_rabit_fs.sh
```

회귀는 FP16 출력, raw accumulator drain, 4-cycle folded read와 16-cycle group drain을
검사한다. 면적 정본은 [`results/area.csv`](../results/area.csv), 리포트는
`results/reports/rabit_pcu_fs_500/`에 있다.
