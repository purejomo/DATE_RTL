# 5_spinquant_acc16

[`5_spinquant`](../5_spinquant)의 axis-2(acc16) 변형이다.

| 축 | 디렉토리 | 누산기 | 출력 |
|---|---|---|---|
| ① base | `5_spinquant` | INT32 (24b carry chain) | raw INT32 |
| ② acc16 | **이 디렉토리** | INT16 | raw INT16 |
| ③ dequant_rne | `5_spinquant_dequant_rne` | INT32 | binary16 |
| ④ dequant_requant | `5_spinquant_dequant_requant` | INT32 | **INT4** |

- top: `spinquant_pcu_acc16`
- 곱셈기·압축기·시퀀싱은 base와 bit-identical. 바뀌는 것은 누산기뿐이다.

## MSB를 남긴다

다른 acc16 행과 달리 여기서는 **LSB를 버리고 MSB를 남기는 것이 선택이 아니라
강제**다. 근거 수치는 `spinquant_pe.sv:18-29`에 원래부터 적혀 있다.

- 곱은 8b로 정확, `NWAY=4`개 합이 최대 480 → `PSUM_W = 10b`
- projection layer 최악 `K = 14336`에서 `-1,720,320` → **live value 22b**

같은 LSB를 유지한 채 16b로 좁히면 `32767/480 ≈ 68` MAC command,
`K = 273`에서 끊긴다 — 필요한 14336의 1/50이다. 그래서 누산기를 위로 올린다:

```text
ACC_RSH = 22 - 15 = 7
accumulator LSB = 2^7 (raw product 단위)
```

`ACC_W = 16`, `ACC_CHAIN_W = 16`. base는 32b 레지스터 안에서 상위 8b가 순수
sign extension이라 carry chain을 24b로 줄일 수 있었지만, 16b에서는 남는
sign extension이 없으므로 체인이 곧 레지스터 전체다.

## 정확도

매 add가 버리는 것은 최대 half-LSB = raw 단위로 64이고, RNE라 zero-mean이다.
`K = 14336`(accepted MAC 3584회)에서 random walk로 누적하면 대략
`sqrt(3584) × 0.29 × 128 ≈ 2200`, full-scale 1,720,320 대비 **약 0.13%**다.
이는 해석적 추정이며 실측은 이 디렉토리 범위 밖이다.

## overflow 정책이 다른 acc16 행과 반대다

다른 acc16 행은 saturate하지만 여기는 **detect-and-report**(`ovf_sticky_o`)다.
base가 그렇게 하기 때문이다 — 이 행의 목적이 `5_spinquant`와의 like-for-like
비교이므로 base 정책을 따르는 쪽이 옳다. `spinquant_pe.sv` 헤더에도 이 비대칭을
적어두었다.

## 면적이 돌아오는 곳

`spinquant_acc_regfile`이 `NENTRY × NLANE × ACC_W = 4 × 16 × 16 = 1024b`로,
base의 2048b에서 절반이 된다. `drain_data_o`도 512b → 256b.
