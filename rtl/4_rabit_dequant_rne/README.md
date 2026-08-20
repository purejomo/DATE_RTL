# RaBiT dequant_rne

입력 스케일 `s_in` 처리와 출력 dequant/RNE를 모두 PCU 내부에서 수행하는 최종
RaBiT 설계다. RTL에서 입력 스케일은 `h`, 출력 스케일은 `g`로 표기한다.

## 최종 구성

| 항목 | 값 |
|---|---|
| compute | 8 PE, 500 MHz 합성 제약 |
| 입력 | RB2 weight, FP16 `x`, FP8-E4M3 `s_in` |
| block mantissa | 12 bit |
| accumulator | signed 27 bit |
| output scale | FP16, 8-output group당 256 bit |
| dequant/RNE | 1 lane, FP16 출력 4개를 64-bit beat로 pack |
| 합성 면적 | 65,421.636 µm², Nangate45 |
| 셀 / DFF | 55,890 / 2,948 |

## 데이터플로

```text
x[k] ──× s_in,1[k] ── block convert ── B1 ── ACC1 ──× s_out,1[j] ──┐
                                                                  +── RNE ── FP16 y[j]
x[k] ──× s_in,2[k] ── block convert ── B2 ── ACC2 ──× s_out,2[j] ──┘
```

```text
u_p[k] = s_in,p[k] × x[k]
A_p[j] = Σk B_p[j][k] × u_p[k]
y[j]   = FP16_RNE(s_out,1[j] × A_1[j] + s_out,2[j] × A_2[j])
```

`s_in × x`는 16-lane write 경로에서 계산한다. RB2 read 경로에는 multiplier가
없다. 출력 경로는 accumulator와 `s_out`을 곱한 뒤 두 path를 더하고 한 번 RNE한다.

## 명령 순서

한 K chunk는 입력 16개와 출력 group 4개를 처리한다.

```text
K chunk마다     WR_H, WR_X, RD_G0, RD_G1, RD_G2, RD_G3
K sweep 이후    (WR_G(group), DQ(group)) × 4
```

- `WR_H`: 두 path의 FP8-E4M3 `s_in`, 16개씩
- `WR_X`: FP16 `x` 16개; 두 path를 2 cycle에 생성
- `WR_G`: 선택한 8-output group의 FP16 `s_out`, 256 bit
- `DQ`: 선택한 group을 16 accumulator-port cycle에 drain

출력 스케일은 32-output 전체를 저장하지 않는다. group을 drain하기 직전에 256 bit만
적재하므로 scale state가 1024 bit에서 256 bit로 줄었다.

## 적용한 최적화

| 최적화 | 결과 |
|---|---|
| 8 PE 유지 | base와 같은 compute mapping/dataflow 유지 |
| accumulator 32→27 bit | `K ≤ 14336`, `E0=max(e_ent)` 조건에서 overflow 없이 exact |
| dequant product 24→23 bit | 12×11 unsigned product의 실제 필요 폭 사용 |
| exponent state 10→8 bit | 가능한 exponent 범위를 포함 |
| drain 순서 `half→path` | path-0 partial을 한 output만 보관 |
| dequant 2→1 lane | multiplier, path adder, FP16 packer를 각 1개로 축소 |
| group-scale streaming | output-scale buffer 1024→256 bit |
| `H_MUL_PIPE=1` | 내부 `s_in × x` 경로에 register 추가 |

ACC27의 최악값은 `16 × 4095 × (14336/16) = 58,705,920`으로 signed 27-bit
범위 안이다. 더 큰 K를 지원하려면 accumulator 폭을 다시 늘려야 한다.

## 처리량

`C=K/16`일 때 base는 stripe당 `6C+4` slot, 최종 설계는 `6C+40` slot이다.

| K | base 대비 처리량 |
|---:|---:|
| 512 | 84.48% |
| 4,096 | 97.72% |
| 11,008 | 99.14% |

## 파일 및 실행

모든 의존 RTL은 이 디렉터리 안에 있다. 각 파일은 같은 이름의 module 하나만
포함한다.

```bash
cd /home/ghlee/DATE_RTL
PATH="$PWD/.venv/bin:$PATH" make -C verif TEST=rabit_fs sim
./synth/run_rabit_fs.sh
```

합성 결과는 `results/area.csv`의 `rabit_pcu_fs_500` 행과
`results/reports/rabit_pcu_fs_500/`에 저장된다.
