# 3_awq_p3llm_8pe_v2

Standard AutoAWQ의 output-channel/group별 asymmetric zero-point를 DATE의
8-PE, 32-multiplier PCU에 직접 전달하는 v2 RTL이다.

- `int4bf16_pcu32`: H2-S1용 W4G128/BF16 top
- `int4fp16_pcu32`: 동일 구조의 FP16 비교 top
- `i_weight_zp[pe*4 +: 4]`: PE별 독립 4-bit zero-point
- 8 PE × 4 multiplier, signed 32-bit accumulator, 4-stage pipeline, II=1
- 목표 clock 500 MHz; DRAM 측 command cadence는 tCCD_S=2

v1의 scalar ZP broadcast만 PE별 32-bit ZP vector로 바꿨다. scale 적용,
output-group reduction 및 BF16 packing은 PCU 밖의 functional postprocess다.
정확도 계산에는 해당 연산을 수행하지만 GPU kernel의 latency/PPA 측정은
EXTENSION 단계로 남긴다. 따라서 이 디렉토리 자체는 GPU postprocess
가속기나 end-to-end CUDA bit-exact를 주장하지 않는다.

## 2026-08-16 Fusion-PIMSim 재검증

- directed per-PE ZP: 8/8 accumulator exact
- Llama-3.1-8B: 32 layers × 7 projections = 224개 live Verilator
- raw INT32: 54,525,952/54,525,952 independent golden exact
- final BF16: 1,376,256/1,376,256 DATE-v2 conformant golden exact
- four-stack Ramulator: 224/224 serial raw exact, 총 1,371,416 DRAM cycles
- matched Nangate45 2.0 ns: area 38,558.828 um², WNS/TNS 0.67/0.00 ns

Captured Standard AutoAWQ final BF16과는 전체 bit-exact가 아니다. Activation
block-floating 정렬과 group reduction 순서가 다르므로 CUDA AutoAWQ exact라고
표기하지 않는다. WikiText-2 32-document/128-input-token live-feedback PPL은
BF16 `9.8301211482`, DATE-v2 `10.4910672531`(+6.723682%)이며, 224 projection ×
128 token=`28,672` Verilator invocation을 실행했다. 이는 127 scored-token bounded
품질 수치이며 full WikiText-2 전체-corpus PPL은 아니다.
