# DATE 논문 — PIM 연산기 RTL 및 합성 결과

정밀도와 조직이 다른 PIM 연산기를 **동일 조건에서** 설계·검증·합성한 결과.

## 1. 비교군

| 비교군 | 정밀도 (W/A) | 조직 | 누산 | 클록 | top 모듈 |
|---|---|---|---|---:|---|
| hbm-pim | FP16/FP16 | SIMD 16 lane | binary32 | 250 MHz | `hbmpim_fp16_pcu_16_lane` |
| awq-p3-llm | INT4/BF16 | 8 PE (v2) / 16 PE (v1) | signed 32b 고정소수점 | 500 MHz | `int4bf16_pcu32`, `int4bf16_pcu_top` |
| p3llm | FP4/FP8 | 16 PE | signed 32b 고정소수점 | 500 MHz | `p3llm_pcu` |
| rabit | 2-bit residual binary / FP16 | 8 PE, 곱셈기 0개 | signed 32b 고정소수점 | 250 MHz | `rabit_pcu` |
| spinquant | INT4/INT4 (W4A4) | 16 PE | 32b 레지스터 안 24b carry chain | 500 MHz (tCCD_S) | `spinquant_pcu` |

변종으로 `p3llm_pcu_dequant` (PCU 안에서 dequantization) 와 `rabit_pcu_fs`
(h/g 스케일을 PCU 안으로) 가 있다. 디렉토리별 상세는 [rtl/README.md](rtl/README.md).

모든 비교군은 **multiplier + accumulator 를 포함한 연산 경계**로 합성한다.
GRF/SRF, 데이터 버퍼, 명령 디코더, 메모리 인터페이스는 합성 범위 밖이다.

## 2. 디렉토리

```
rtl/       설계 RTL (비교군별)
synth/     합성 · 전력 · 표 생성 스크립트
verif/     golden model 및 cocotb 회귀 (fp32/ 는 Verilator 단독)
tools/     RaBiT weight packer · 정확도 스윕
docs/      AWQ · RaBiT · SpinQuant PCU 설계 명세
results/   생성물 — 직접 편집하지 않는다 (results/README.md)
```

`results/` 는 여러 설계를 나란히 놓는 산출물(`area.csv`,
`comparison_compute.csv`, `comparison_22nm.csv`, `reports/`, `power/`)을 최상위에,
한 설계에만 해당하는 분석을 `designs/` 에 둔다.

## 3. 재현

```bash
cd synth
./run_all.sh                      # 합성 → 전력 → 표 생성
./run_all.sh synth|power|table    # 단계별
python3 build_comparison_22nm.py  # 22nm 투영 표만 재생성

./run_rabit.sh        # rabit 행만: 파라미터 스윕 + 모듈별 분해
./run_rabit_fs.sh     # rabit full-scale 행만
./run_spinquant.sh    # spinquant 행만
```

행 단위 스크립트는 다른 설계의 결과를 건드리지 않는다 (`merge_area_csv.py` 가
label 단위로 병합).

필요한 외부 도구 (경로는 환경변수로 덮어쓸 수 있다):

| 도구 | 기본 경로 | 환경변수 |
|---|---|---|
| OpenROAD-flow-scripts | `~/.cache/openroad-user/OpenROAD-flow-scripts` | `ORFS_ROOT` |
| OpenROAD | `~/.local/openroad-2024/usr/bin/openroad` | `OPENROAD_EXE` |
| Yosys 0.52 | `~/.local/yosys-0.52/usr/bin/yosys` | `YOSYS_EXE` |
| sv2v 0.0.13 | `~/.local/sv2v-0.0.13/sv2v-Linux/sv2v` | `SV2V_EXE` |

## 4. 측정 조건

**합성** — Nangate45 표준 셀 typical corner (1.10 V, 25 °C), Yosys 0.52
(ABC area mode) + OpenROAD. **논리 합성까지이고 P&R 은 수행하지 않는다**:
면적은 셀 면적의 합이며 배선 면적을 포함하지 않는다. 주파수는 각 논문의 값을
따른다 (hbm-pim 250 MHz, 나머지 500 MHz).

**전력** — vectorless `set_power_activity -global`, 활성도 0.20 / duty 0.50 을
모든 net 에 균일하게. 전파 없음. 설계마다 인터페이스가 달라 동일 자극(VCD)을
정의할 수 없어 확률적 활성도를 쓴다.

- **왜 `-global` 인가.** 논문 수치와 맞는 쪽이다. P3-LLM 논문이 보고한 HBM-PIM
  대비 에너지 비 **3.83x** 에 대해 `-global` 은 **3.44x**, 면적 비도 논문 3.69x
  對 우리 3.38x 로 함께 맞는다. 대안이던 `-input` (primary input 에만 걸고
  전파) 은 같은 축에서 18.81x 로 크게 벗어난다 — OpenSTA 의 transition density
  전파가 조합 깊이를 따라 활성도를 증폭시켜, 에너지가 아니라 파이프라인 깊이를
  재는 셈이 되기 때문이다.
- **한계.** `-global` 은 셀 수에 거의 비례하므로 실제로 덜 토글하는 설계에
  크레딧을 주지 않는다. **설계 간 에너지 우열은 비율 수준에서만 이야기한다.**
  완전한 해법은 gate-level 시뮬레이션 + 공통 워크로드다. 면적·타이밍 비교에는
  이 한계가 없다.

## 5. 검증

cocotb 1.9.2 + Verilator 5.032. 상세는 [verif/README.md](verif/README.md).

```bash
cd verif
make                                   # 전체 회귀
PCU_ITERS=300 make                     # 빠른 확인
cd fp32 && make                        # binary32 누산 경로 (Verilator 단독)
```
