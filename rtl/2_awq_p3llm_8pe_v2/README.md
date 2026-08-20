# 2_awq_p3llm_8pe_v2

Standard AutoAWQ의 output-channel/group별 asymmetric zero-point를 DATE의
8-PE, 32-multiplier PCU에 직접 전달하는 v2 RTL이다.

- `int4bf16_pcu32`: H2-S1용 W4G128/BF16 top
- `int4fp16_pcu32`: 동일 구조의 FP16 비교 top
- `i_weight_zp[pe*4 +: 4]`: PE별 독립 4-bit zero-point
- 8 PE × 4 multiplier, signed 32-bit accumulator, 4-stage pipeline, II=1
- 목표 clock 500 MHz; DRAM 측 command cadence는 tCCD_S=2

축①인 이 디렉토리에서는 scale 적용, output-group reduction, BF16 packing이 PCU
밖에 있다. 이 후처리를 PCU 안으로 옮긴 구현은
[`2_awq_p3llm_8pe_v2_dequant_rne`](../2_awq_p3llm_8pe_v2_dequant_rne)이다.

현재 Nangate45 2.0 ns 합성 결과는 36,918 µm², 32,282 cells, 1,566 DFF이며 setup
slack은 +0.66 ns다. 정본은 `results/area.csv`와
`results/reports/int4bf16_pcu32_500/1_Post_synthesis.rpt`다.
