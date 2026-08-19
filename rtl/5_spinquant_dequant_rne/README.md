# 5_spinquant_dequant_rne

[`5_spinquant`](../5_spinquant)의 axis-3(dequant_rne) 변형이다.
**loop를 닫지 않는 ablation 행**이라는 점을 먼저 읽어야 한다.

| 축 | 디렉토리 | 출력 | 요소당 | host에 남는 커널 |
|---|---|---|---|---|
| ① base | `5_spinquant` | INT32 | 32b | scale 곱 + 재양자화 |
| ② acc16 | `5_spinquant_acc16` | INT16 | 16b | scale 곱 + 재양자화 |
| ③ dequant_rne | **이 디렉토리** | binary16 | 16b | **재양자화** |
| ④ dequant_requant | `5_spinquant_dequant_requant` | INT4 | 4b | 없음 |

- top: `spinquant_pcu_dq`
- raw PCU(`spinquant_pcu_top`)는 **무변경**으로 인스턴스한다. `drain_data_o`
  raw drain도 그대로 남긴다.

## 왜 loop가 안 닫히나

다른 설계군은 activation이 부동소수점이라 dequant 결과가 곧 다음 레이어의 입력
포맷이고, 그래서 axis-3에서 host 커널이 완전히 사라진다. SpinQuant는 W4**A4**라
binary16을 내보내도 다음 PCU가 원하는 것은 unsigned INT4다. 따라서 이 행은
host 양자화 커널을 남긴다. ④가 그것까지 없앤다.

이 행이 존재하는 이유는 **분해**다. ④가 `KEEP_FP16_OUT=1`로 이 행의 상위집합이
되도록 맞춰두었으므로 두 행은 구조적으로 requantizer 하나만큼 다르다. 다만
면적 차이로 requantizer 비용을 뺄 수 없다. 측정값은

    ③ spinquant_pcu_dq   40,270.804 um2   31,707 cell   2,121 flop
    ④ spinquant_pcu_rq   39,996.824 um2   32,769 cell   2,260 flop

로, ④가 cell 1,062개와 flop 139개를 더 쓰면서도 총 면적은 274 um2 더 작다. 둘 다
WNS 0.09 ns / TNS 0 으로 타이밍을 여유 있게 만족하므로 타이밍 압력 때문이 아니라,
netlist 가 커지자 ABC 가 평균적으로 더 싼 셀로 매핑했기 때문이다 (1.270 -> 1.221
um2/cell). flat 합성에서 cross-boundary 최적화가 하는 일이고, 이 저장소가
`spinquant_pcu_synth.sv` 의 blk 분해에 대해 이미 경고해 둔 것과 같은 현상이다.

따라서 **requantizer 비용은 cell/flop 증분으로 말한다: +1,062 cell, +139 flop.**
총 면적의 뺄셈은 이 규모에서 의미가 없다.

## 산술 계약

`docs/spinquant_pcu_spec.md`의 전개에서 출발한다. `A~ = s_a·A_q + β`,
`W = s_w·W_q`이므로 output channel `i`에 대해

```text
y[i] = s_w[i]·s_a·acc[i] + s_w[i]·β·ΣW_q_row[i]
     = s[i] · ( acc[i] + bias_int[i] )
```

min-max asymmetric 양자화에서 `β = -s_a·zp_a`이므로 `β/s_a = -zp_a`는 정수다:

```text
s[i]        = s_w[i] · s_a               per output channel, 16b float
bias_int[i] = -zp_a · ΣW_q_row[i]        per output channel, 정수
```

**activation zero point가 정수 영역으로 접힌다.** 이것이 이 엔진이 AWQ·P3-LLM의
것보다 싼 이유다. 부동소수점 누산기도, 두 번째 스케일 곱도 필요 없다:

```text
fixed[i] = acc[i] + bias_int[i]          32-bit 정수 덧셈 1회
fp32[i]  = RNE32(fixed[i] · s[i])        spinquant_dq_fixed32_float16_mul_pipe
y16[i]   = RNE16(fp32[i])                spinquant_dq_fp32_pack_pipe
```

반올림은 위 두 번뿐이다.

`s[i]`도 `bias_int[i]`도 **PIM↔host 전송을 만들지 않는다.** `s_w`와
`ΣW_q_row`는 레이어마다 정적이고 NPU에 상주하며, `s_a`·`zp_a`는 NPU가 activation을
양자화할 때 이미 만든 토큰 스칼라다.

## 재사용

| 파일 | 원본 | 변경 |
|---|---|---|
| `spinquant_dq_fixed32_float16_mul_pipe.sv` | `2_awq_p3llm_8pe_v2_dequant_rne/awq_dq_fixed32_float16_mul_pipe.sv` | 모듈명만 |
| `spinquant_dq_fp32_pack_pipe.sv` | 같은 디렉토리의 `awq_dq_fp32_pack_pipe.sv` | 모듈명만 |

AWQ 엔진의 세 번째 모듈(`awq_dq_fp32_add_pipe`, group 간 FP32 누산)은 **쓰지
않는다.** SpinQuant는 weight group이 없어 group 간 누산이 없고, bias는 정수
영역에서 처리되기 때문이다.

## 시퀀싱

accumulator file의 drain 포트가 compute 포트와 독립이라, AWQ·P3-LLM 엔진과 달리
**스냅샷 큐가 필요 없다** — 자리에서 읽는다. 대신 스케줄 규칙이 생긴다.

> `dq_busy_o`가 높은 동안 `dq_entry_i`를 target으로 하는 MAC 명령을 내면 안 된다.
> 다른 entry는 자유롭다 (`NENTRY = 4`가 있는 이유).

한 사이클에 한 lane씩 오름차순으로, `dq_req_i` 수락 다음 사이클부터 발행한다.
`NLANE = 16`이므로 drain 하나가 16 issue cycle이다. metadata는 같은 순서로
스트리밍한다 — `dq_issue_o`가 높은 사이클에 `dq_lane_o`가 가리키는 lane의
`dq_scale_i`/`dq_bias_i`를 제시하면 된다. 결과도 같은 순서로 `y_valid_o`에
`y_lane_o` 태그와 함께 나온다.

## spec 문서와의 충돌

`docs/spinquant_pcu_spec.md`의 **금지 목록**(부동소수점 연산기·스케일 곱셈기가
하나라도 있으면 이 설계의 주장이 무너진다)은 이 디렉토리에서 깨진다. 금지 목록은
**base 행(`5_spinquant`)에만 적용된다.** base는 무변경이므로 그 주장은 그대로
유효하다.
