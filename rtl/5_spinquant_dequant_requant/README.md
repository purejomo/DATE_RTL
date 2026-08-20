# 5_spinquant_dequant_requant

[`5_spinquant`](../5_spinquant)의 axis-4 변형이다. **이 저장소에서 loop를
완전히 닫는 유일한 SpinQuant 행이고, "activation quant까지 PU에서"라는 원래
동기가 실제로 적용되는 유일한 설계다.**

| 축 | 디렉토리 | 출력 | 요소당 | host에 남는 커널 |
|---|---|---|---|---|
| ① base | `5_spinquant` | INT32 | 32b | scale 곱 + 재양자화 |
| ② acc16 | `5_spinquant_acc16` | INT16 | 16b | scale 곱 + 재양자화 |
| ③ dequant_rne | `5_spinquant_dequant_rne` | binary16 | 16b | 재양자화 |
| ④ dequant_requant | **이 디렉토리** | **INT4** | **4b** | **없음** |

- top: `spinquant_pcu_rq`
- 요소당 32b → 4b, **8× 절감**. 다른 설계군의 axis-3이 2×인 것과 대비된다.
  출력이 4-bit이라 SpinQuant가 이 축에서 가장 크게 이득을 본다.
- **①에서 출발한다 (②가 아니다).** 재양자화에는 full-precision 누산기가 필요하다.

## 산술 계약

dequant 절반은 [`5_spinquant_dequant_rne`](../5_spinquant_dequant_rne)와 동일하다:

```text
fixed[i] = acc[i] + bias_int[i]        bias_int[i] = -zp_a·ΣW_q_row[i]  (정수)
fp32[i]  = RNE32(fixed[i] · s[i])      s[i] = s_w[i]·s_a
```

requant 절반은

```text
A_q'[i]  = clamp( RNE(fp32[i] / s_a') + zp_a', 0, 15 )
```

**나눗셈은 하드웨어에 없다.** pass 2에서 드라이버가 `s[i]` 대신
`t[i] = s[i]/s_a'`를 보내므로 곱셈 파이프가 `fp32[i]/s_a'`를 바로 만들고,
requantizer는 반올림·offset·clamp만 한다. 두 번째 곱셈기가 없다.

`zp_a'`는 정수이므로 반올림 뒤에 더하는 것과 앞에 더하는 것이 같다. 그래서
`spinquant_rq_fp32_to_int4`가 rounder 하류에 앉을 수 있다.

## 왜 2-pass인가

`s_a'`는 per-token asymmetric min-max에서 나오므로 **출력 row 전체**의 극값이
필요하다. PCU는 `NLANE = 16`개만 본다. 폭 문제가 아니라 데이터플로 문제이고,
로컬 하드웨어를 아무리 넣어도 풀리지 않는다.

```text
pass 1   s[i]로 dequant를 돌리고, PCU가 자기 lane들의 min/max만 뽑아 스칼라 2개를
         넘긴다 (spinquant_rq_minmax). NPU가 bank를 가로질러 리덕션을 끝내고
         s_a'·zp_a'를 계산한 뒤 t[i]와 bias_int[i]를 만든다 — 전부 NPU가 이미
         가진 데이터(s_w, ΣW_q_row, 토큰 스칼라)에서 나오므로 wide data는
         움직이지 않는다.
pass 2   t[i]로 다시 돌리고 requantizer가 INT4를 내보낸다.
```

accumulator file은 어차피 k sweep 내내 상주하므로 한 pass 더 잡아두는 것은
저장 비용이 0이다. 비용은 drain당 `NLANE` 대신 `2 × NLANE` issue cycle이다.

대안이던 **static per-layer activation scale**(1-pass)은 구현하지 않았다.
SpinQuant의 per-token dynamic 양자화를 버리는 것이라 이 하드웨어가 아니라 다른
알고리즘의 ablation이 된다.

**R4 online Hadamard**(down_proj 입력)는 NPU에 남긴다. 7개 projection 중 1개에만
걸리고, PCU 안에서 벡터를 회전시키는 것은 이 행이 묻는 것과 다른 설계 질문이다.

## 신규 모듈 2개

| 파일 | 하는 일 |
|---|---|
| `spinquant_rq_minmax.sv` | binary32 스트림의 running min/max. total-order key `key = fp32[31] ? ~fp32 : (fp32 \| 0x8000_0000)`로 unsigned 비교 1회 — 부동소수점 비교기가 없다 |
| `spinquant_rq_fp32_to_int4.sv` | binary32 → unsigned INT4, RNE + zero point + clamp |

변환기가 작은 이유: 결과가 `[0,15]`로 clamp되고 `zp_a' ≤ 15`이므로 크기 32 이상은
무조건 clamp된다. `sig·2^(exp-150)`으로 쓰면 `exp ≥ 132`는 saturate,
`exp ≤ 125`는 0, 나머지 **6개 exponent만이 실제 경로**다. 그래서 24-bit barrel
shifter 대신 6-way case이고 몫은 5비트 + 반올림 캐리를 넘지 않는다.

검증: 랜덤 60,000 입력에 대해 Python `Decimal.ROUND_HALF_EVEN` 기준과 전수 대조,
불일치 0 (`verif`의 `spinquant_rq_cvt` 회귀).

## KEEP_FP16_OUT

axis-3의 binary16 pack을 기본값으로 유지한다. 이유 둘:

1. **실제 요구다.** projection 출력의 소비자가 항상 INT4 레이어는 아니다 —
   lm_head와 residual 경로는 float를 원한다.
2. 이 디렉토리가 `5_spinquant_dequant_rne`의 **엄격한 상위집합**이 되어, 두 행이
   구조적으로 requantizer 하나만큼 다르다.

면적 차이로 requantizer 비용을 뺄 수 없다. 측정값은

    ③ spinquant_pcu_dq   40,270.804 um2   31,707 cell   2,121 flop
    ④ spinquant_pcu_rq   39,996.824 um2   32,769 cell   2,260 flop

로, ④가 cell 1,062개와 flop 139개를 더 쓰면서도 총 면적은 274 um2 더 작다. ③/④
모두 TNS 0이고 WNS는 각각 +0.17/+0.15 ns로 타이밍을 만족하므로 타이밍 압력
때문이 아니라, netlist가 커지자 ABC가 평균적으로 더 싼 셀로 매핑했기 때문이다 (1.270 -> 1.221
um2/cell). flat 합성에서 cross-boundary 최적화가 하는 일이고, 이 저장소가
`spinquant_pcu.sv`와 block wrapper의 flat 합성 차이에 대해 이미 경고해 둔 것과 같은 현상이다.

따라서 **requantizer 비용은 cell/flop 증분으로 말한다: +1,062 cell, +139 flop.**
총 면적의 뺄셈은 이 규모에서 의미가 없다.

`KEEP_FP16_OUT = 0`이면 INT4 전용 최소 빌드가 된다. `synth/run_all.sh`의 행은
상위집합 쪽을 쓴다.

## spec 문서와의 충돌

`docs/spinquant_pcu_spec.md`의 **금지 목록**은 이 디렉토리에서 깨진다.
금지 목록은 **base 행(`5_spinquant`)에만 적용된다.**
