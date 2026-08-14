# 전력 측정 방식 점검 — vectorless 활성도 모델

`synth/probe_power_activity.sh` 가 생성한다. 결론부터: **현재 비교표의 전력 열은
설계 간 비교 근거로 쓸 수 없다.** 합성 범위 문제가 아니라 활성도 모델 문제다.

## 1. 범위는 문제가 없었다

먼저 의심되는 것부터 배제했다. 12개 행 전부 확인:

| 확인 항목 | 결과 |
|---|---|
| 전력에 쓴 netlist 의 cell 수 vs `area.csv` | 전 행 **일치** |
| liberty / LEF / corner | 전 행 동일 (Nangate45 typical) |
| SDC | 전 행 `constraint.sdc` 동일 |
| clock port | 전 행 `clk` 존재 (virtual clock fallback 걸린 행 없음) |
| `Clock` group 전력 | 전 행 0 W — P&R 전이라 clock tree 가 없어서, 정상이고 동일 |

즉 무엇을 합성했고 무엇을 측정했는지는 설계 간에 다르지 않다.

## 2. 문제는 활성도 전파다

`synth/power.tcl` 은 VCD 가 없으면 다음으로 떨어진다.

```tcl
set_power_activity -input -activity 0.20 -duty 0.50
```

**primary input 에만** 0.20 을 걸고 OpenSTA 가 앞으로 전파한다. 전파는 transition
density 모델이고, 독립 입력을 가정한 XOR 의 출력 density 는 입력 density 의
**합**이다. 따라서 조합 깊이를 따라 density 가 증폭되고, flip-flop 이 그것을
리셋한다. 결과적으로 이 숫자는 설계가 태우는 에너지가 아니라 **조합 깊이와
레지스터 위치**를 재게 된다.

동일 netlist·SDC·라이브러리에서 활성도 모델만 바꿔 측정한 값:

| top | cells | ns | `-input` W | `-global` W | 증폭 | nW/cell @2ns |
|---|---:|---:|---:|---:|---:|---:|
| p3llm_pcu_dequant | 86514 | 2.0 | 0.0781 | 0.0547 | 1.4x | 632.3 |
| p3llm_pcu | 61847 | 2.0 | 0.0664 | 0.0351 | 1.9x | 567.5 |
| int4bf16_pcu32 | 32448 | 2.0 | 0.0468 | 0.0179 | 2.6x | 551.7 |
| int4bf16_pcu_top | 62010 | 2.0 | 0.0914 | 0.0344 | 2.7x | 554.7 |
| int4fp16_pcu_top | 72372 | 2.0 | 0.1120 | 0.0394 | 2.8x | 544.4 |
| int4fp16_pcu32 | 38176 | 2.0 | 0.0595 | 0.0205 | 2.9x | 537.0 |
| hbmpim_fp16_pcu_16_lane | 56433 | 4.0 | 0.1580 | 0.0151 | **10.5x** | 535.1 |
| awq_int4bf16_pcu_16_lane | 44340 | 2.0 | 0.2710 | 0.0230 | **11.8x** | 518.7 |
| awq_int4bf16_pcu_64_lane | 177146 | 2.0 | 1.0900 | 0.0923 | **11.8x** | 521.0 |
| awq_int4fp16_pcu_64_lane | 186355 | 2.0 | 1.2300 | 0.0967 | **12.7x** | 518.9 |
| awq_int4fp16_pcu_16_lane | 46836 | 2.0 | 0.3290 | 0.0256 | **12.9x** | 546.6 |
| rabit_pcu | 37126 | 4.0 | 0.4260 | 0.0116 | **36.7x** | 624.9 |

- `-global` (모든 net 에 균일 0.20, 전파 없음) 기준 **nW/cell 은 518.7 ~ 632.3,
  산포 1.22x** 다. 같은 라이브러리·같은 가정이면 전력이 cell 수에 비례한다는
  당연한 결과이고, 설계 간 편향이 없다.
- `-input` 기준 **증폭 배율은 1.4x ~ 36.7x, 산포 25.7x** 다. 지금 표의 전력 열이
  실제로 순위 매기는 것이 바로 이 배율이다.

증폭 배율이 아키텍처와 정확히 붙는다:

| 조직 | 증폭 | 이유 |
|---|---:|---|
| P3-LLM PCU | 1.4 ~ 2.9x | 6x6 곱셈기와 얕은 compressor 가 stage 0 레지스터 뒤에 있다. density 가 자주 리셋된다 |
| SIMD lane | 10.5 ~ 12.9x | FP16/INT4 곱셈 + FP32 정규화가 긴 조합 체인이다. mantissa 곱은 XOR 이 많아 density 가 잘 자란다 |
| RaBiT PCU | 36.7x | 16-way 4:2 tree 가 전부 XOR/majority 인 데다 입력 레지스터가 없어 primary input 에서 바로 시작한다 |

## 3. 순위가 뒤집힌다

같은 32 GMAC/s 인 두 행을 보면:

| | `-input` (현행) | `-global` |
|---|---:|---:|
| p3llm_pcu | 0.0664 W | 0.0351 W |
| rabit_pcu | 0.4260 W | 0.0116 W |

현행 방식에서는 rabit 이 p3llm 보다 6.4배 나쁘고, 균일 활성도에서는 3.0배 좋다.
**결론이 반대로 나온다.** pJ/MAC 로 환산하면 (`-global` 기준):

| 행 | 현행 pJ/MAC | `-global` pJ/MAC |
|---|---:|---:|
| hbm-pim FP16 SIMD | 39.5 | 3.8 |
| awq INT4/FP16 SIMD 64 | 38.4 | 3.0 |
| awq INT4/FP16 P3-LLM PCU 64 | 3.5 | 1.2 |
| p3llm FP4/FP8 PCU | 2.1 | 1.1 |
| rabit 2-bit RB PCU | 13.3 | 0.36 |

SIMD 대 PCU 의 에너지 격차가 약 11배에서 약 2.5배로 줄어든다. 즉 이 문제는
rabit 행만의 문제가 아니라 **이미 표에 실린 다른 행들의 주장에도 영향을 준다.**

## 4. 어느 쪽도 "정답"은 아니다

- `-input` 은 전파를 하니 원리상 더 물리적이지만, OpenSTA 의 density 전파는
  reconvergence 와 상관관계를 무시해서 깊은 XOR 논리에서 발산한다. 보정되지 않은
  25.7x 산포가 그 증거다.
- `-global` 은 균일해서 설계를 편향시키지 않지만, 사실상 "전력 ∝ cell 수" 라
  활성도가 실제로 낮은 설계를 보상하지 못한다.
- **동일 자극(VCD) 기반이 유일하게 방어 가능한 설계 간 비교다.**
  `synth/power.tcl` 은 이미 `read_power_activities -vcd` 를 지원하고 주석도 그
  의도로 쓰여 있는데(`"Activity is annotated from a VCD produced by that design's
  own cocotb regression"`), `run_all.sh do_power` 가 VCD 인자로 빈 문자열을 넘겨서
  항상 vectorless 로 떨어지고 있다. 각 설계마다 cocotb 회귀가 이미 있으므로
  Verilator `--trace` 로 VCD 를 뽑는 경로는 열려 있다.

## 재현

```bash
cd synth && ./probe_power_activity.sh
```
