# 2_awq_p3llm_8pe_v2_acc16

[`2_awq_p3llm_8pe_v2`](../2_awq_p3llm_8pe_v2)의 axis-2(acc16) 변형이다. 비교
3축 중 ②에 해당한다.

| 축 | 디렉토리 | 누산 |
|---|---|---|
| ① base | `2_awq_p3llm_8pe_v2` | 32-bit 고정소수점, raw INT32 출력 |
| ② acc16 | **이 디렉토리** | 매 사이클 partial sum을 RNE로 16-bit으로 좁혀 누산 |
| ③ dequant_rne | `2_awq_p3llm_8pe_v2_dequant_rne` | 32-bit 누산 후 PCU 안에서 dequant → BF16 출력 |

- `int4bf16_pcu32_acc16`: W4G128/BF16 top, `ACC_RSH = 12`, `o_acc` 128b
- `int4fp16_pcu32_acc16`: 동일 구조의 FP16 비교 top, `ACC_RSH = 15`
- `i_weight_zp[pe*4 +: 4]`: PE별 독립 4-bit zero-point (v2 계약, 변경 없음)
- 8 PE × 4 multiplier, 4-stage pipeline, II=1 — ①과 동일

①과의 유일한 차이는 stage 3이다. 4-lane partial sum(28b)을 `ACC_RSH`만큼
RNE로 좁힌 뒤 16-bit saturating accumulate 한다. 정렬·weight decode·곱셈기·
4:2 compressor·CPA는 ①과 bit-identical이므로, 합성 면적 차이는 누산기와 반올림
로직에만 귀속된다.

누산기 LSB의 가치가 `2^(ref_exp - GUARD + ACC_RSH)`로 바뀌지만, 이 스케일은
원래도 소프트웨어가 weight group scale과 함께 적용하던 값이라 새 포트가 필요
없다. 상태 비트도 추가하지 않았다 — ①도 조용히 saturate하므로 축 간 비교를
위해 동일하게 유지한다.

`ACC_RSH` 기본값 근거와 narrow() 정의는 `int4float_pe.v` 헤더에 있다. 기본값은
"group 128에서 saturate가 절대 나지 않는 최악 경계"이지 정확도 최적값이 아니다.
최적값 탐색은 accuracy sweep 사안이며 면적에는 거의 영향이 없다 (시프트는 배선).

Fusion-PIMSim용 `int4bf16_pcu32_per_pe_zp` 별칭 wrapper는 이 복사본에서
삭제했다. acc16은 시뮬레이터 계약이 아니다.
