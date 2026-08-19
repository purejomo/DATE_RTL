# 3_p3llm_acc16

[`3_p3llm`](../3_p3llm)의 axis-2(acc16) 변형이다. 비교 3축 중 ②에 해당한다.

| 축 | 디렉토리 | 누산 |
|---|---|---|
| ① base | `3_p3llm` | 32-bit 고정소수점, raw INT32 출력 |
| ② acc16 | **이 디렉토리** | 매 사이클 partial sum을 RNE로 16-bit으로 좁혀 누산 |
| ③ dequant_rne | `3_p3llm_dequant_rne` | 32-bit 누산 후 PCU 안에서 dequant → FP8-E4M3 출력 |

- top: `p3llm_pcu_acc16` (`p3llm_pcu_acc16.sv`), `acc_out` 512b → 256b
- `ACC_W = 16`, `ACC_RSH = 16`
- decoder / 6×6 곱셈기 4개 / 지수 shifter / 4:2 compressor / CPA는 ①과
  bit-identical. 바뀐 것은 stage 3의 narrow + 누산기 폭뿐이다.

## ACC_RSH를 단일값으로 둔 이유와 기본값 근거

op_mode마다 binary point가 다르지만(`OP_LINEAR` 2^-12 / `OP_QK` 2^-11 /
`OP_PV` 2^-19), `ACC_RSH`는 **raw 정수에 걸리는 시프트**라 mode별 binary point가
아니라 raw 정수의 최악값이 기준이다. 세 mode의 최악값은 거의 같다:

| mode | 최악 lane product | 128-element group (4 lane × 32 tile) |
|---|---|---|
| `OP_LINEAR` | 480 << 15 | 2,013,265,920 |
| `OP_QK` | 450 << 15 | 1,887,436,800 |
| `OP_PV` | 465 << 15 | 1,950,351,360 |

`2,013,265,920 >> 16 = 30,720`은 signed 16-bit에 들어가고 `>> 15`는 들어가지
않는다. 따라서 `ACC_RSH = 16`이 세 mode 모두에서 group 전체가 절대 saturate하지
않는 최소 시프트다. 달리 말하면 acc16은 ①의 32-bit 누산기 상위 16-bit를
그대로 유지한다.

mode별 시프트로 두면 누산 경로에 mux가 하나 생기는데, 그것이야말로 이 축이
가격을 매기려는 로직이므로 단일값으로 고정했다. 시프트량 자체는 배선이라
면적에 거의 영향이 없다.

이 값은 **최악 경계**이지 정확도 최적값이 아니다. 실제 activation은 이보다
훨씬 작아서 더 작은 시프트가 하위 정밀도를 더 남긴다. 최적값 탐색은 accuracy
sweep 사안이다.
