# RaBiT PCU 설계 명세

## 범위

| 디렉터리 | 축 | 구성 | 출력 | 면적 (µm²) |
|---|---|---|---|---:|
| [rtl/4_rabit/](../rtl/4_rabit/) | ① base | 8 PE, MANT12, ACC32 | raw INT32 | 45,254 |
| [rtl/4_rabit_acc16/](../rtl/4_rabit_acc16/) | ② acc16 | 8 PE, MANT10, ACC16 | raw INT16 | 32,209 |
| [rtl/4_rabit_dequant_rne/](../rtl/4_rabit_dequant_rne/) | ③ dequant_rne | 8 PE, MANT12, ACC27, DQ1 | FP16 | 65,422 |

모든 행은 500 MHz 합성 제약을 사용한다. 각 디렉터리는 필요한 모듈의 로컬 사본을
가지며 다른 RTL 디렉터리를 소스 의존성으로 사용하지 않는다.

## 연산

두 residual path를 다음과 같이 계산한다.

```text
u_p[k] = s_in,p[k] × x[k]
A_p[j] = Σk B_p[j][k] × u_p[k],  B_p[j][k] ∈ {+1, -1}
y[j]   = s_out,1[j] × A_1[j] + s_out,2[j] × A_2[j]
```

논문은 식과 그림/커널에서 `g`, `h` 이름을 서로 바꿔 쓰는 부분이 있다. 이 RTL은
`h = s_in`과 `g = s_out`을 사용한다. 역할은 입력 채널 scale과 출력 채널 scale로
고정된다.

축①/②는 `u_p`와 최종 `y` 계산을 외부에 둔다. 축③은 두 scale 연산을 모두 PCU
내부에 두고 FP16 RNE 결과를 낸다.

## 데이터 매핑

한 256-bit weight word는 입력 16개, 출력 8개, path 2개를 담는다.

```text
bit[j*(2*16) + p*16 + k] = B_p[j][k]
NIN=16, NOUT_PER_WORD=8, NPATH=2
```

8 PE가 한 cycle에 한 path의 출력 8개를 처리한다. 두 path를 두 cycle에 실행하므로
base와 dequant_rne의 compute mapping은 같다. 출력 32개 stripe는 output group
4개를 accumulator에 유지한다.

## block 변환과 PE

FP16 입력 16개를 shared exponent와 lane mantissa로 바꾼다.

```text
block = {e_ent[5:0], mantissa[16][MANT_W+1]}
partial = Σk (B[k] ? -mantissa[k] : +mantissa[k])
shift   = e_ent - E0
ACC     = saturate(ACC + align(partial, shift))
```

RB2 weight는 부호 선택이므로 PE read 경로에 multiplier가 없다. 4:2 compressor tree와
CPA로 16개 signed term을 합한다.

## 축③ 최종 구조

```text
x ──× s_in,1 ── block ── B1/PE ── ACC1 ──× s_out,1 ──┐
                                                      +── FP16 RNE
x ──× s_in,2 ── block ── B2/PE ── ACC2 ──× s_out,2 ──┘
```

### 입력 scale 경로

- `s_in`: FP8-E4M3, path 2개 × input 16개를 한 256-bit word에 저장
- `x`: FP16 16개
- 16개의 11×4 significand multiplier와 FP16 pack/RNE를 사용
- `H_MUL_PIPE=1`로 multiply 결과와 block convert 사이를 register

`s_in × x`는 GPU로 옮기지 않은 최종 선택이다.

### accumulator

최종 폭은 signed 27 bit다. 다음 계약에서 ACC32와 수학적으로 같은 결과를 낸다.

```text
K ≤ 14336
E0 = max(e_ent)
|partial per chunk| ≤ 16 × 4095 = 65,520
|ACC|max ≤ 65,520 × (14336/16) = 58,705,920 < 2^26
```

raw debug drain은 각 27-bit 값을 32-bit로 sign extension한다.

### 출력 scale과 dequant/RNE

출력 scale은 8-output group 하나만 저장한다.

```text
WR_G bit[j*32 + p*16 +: 16] = s_out,p[j]
buffer = 8 outputs × 2 paths × 16 bit = 256 bit
```

1-lane dequantizer가 다음 세 단계를 수행한다.

```text
S0  ACC normalize + FP16 scale decode + 12×11 multiply
S1  두 path exponent align + signed add
S2  FP16 round-to-nearest-even pack
```

한 group은 `output half → path` 순서로 16 accumulator-port cycle에 drain된다.
path 0 partial은 바로 다음 path 1 cycle에 소비되므로 한 output분만 보관한다. FP16
결과 네 개는 64-bit output beat로 묶는다.

### 폭 최적화

| 항목 | 최종 폭 | 근거 |
|---|---:|---|
| accumulator | 27 | 위 K/E0 계약에서 exact |
| dequant product `QW` | 23 | unsigned 12×11 product |
| exponent state `FW` | 8 | 전체 가능한 exponent 범위 포함 |
| output-scale state | 256 | group별 JIT load |
| dequant lane | 1 | multiplier/adder/packer 각 1개 |

## 명령과 처리량

```text
K chunk마다     WR_H, WR_X, RD_G0, RD_G1, RD_G2, RD_G3
K sweep 이후    (WR_G(group), DQ(group)) × 4
```

`C=K/16`일 때 base는 stripe당 `6C+4` slot, 축③은 `6C+40` slot이다.

| K | 축③ / base 처리량 |
|---:|---:|
| 512 | 84.48% |
| 4,096 | 97.72% |
| 11,008 | 99.14% |

큰 projection에서는 K sweep가 지배적이므로 group drain overhead가 작다.

## 상태 비트

`status_sticky_o`:

- accumulator saturation
- alignment saturation
- block-convert clamp

`status_fs_o`:

- FP8 `s_in` NaN encoding
- `s_in × x` FP16 saturation
- output FP16 saturation
- scale 없는 dequant request

## 검증 및 합성

```bash
cd /home/ghlee/DATE_RTL
PATH="$PWD/.venv/bin:$PATH" make -C verif TEST=rabit_fs sim
python3 tools/pack_rabit_fs.py --self-test
./synth/run_rabit_fs.sh
```

`rabit_fs` 회귀는 다음을 확인한다.

- 내부 `s_in × x`부터 FP16 `y`까지 bit-exact end-to-end 비교
- raw accumulator drain의 base 호환성
- group당 16-cycle accumulator-port drain
- 내부 interface assertion

합성 결과는 [results/area.csv](../results/area.csv)와
`results/reports/rabit_pcu_fs_500/`에 저장한다.
