# DATE 논문 — PIM 연산기 RTL 및 합성 결과

정밀도와 조직이 다른 PIM 연산기를 **동일 조건에서** 설계·검증·합성한 결과.

## 1. 비교군

| 비교군 | 정밀도 (W/A) | 조직 | 누산 | 클록 | top 모듈 |
|---|---|---|---|---:|---|
| hbm-pim | FP16/FP16 | SIMD 16 lane | binary32 | 250 MHz | `hbmpim_fp16_pcu_16_lane` |
| awq-p3-llm | INT4/BF16 | 8 PE / 16 PE (둘 다 v2) | signed 32b 고정소수점 | 500 MHz | `int4bf16_pcu32`, `int4bf16_pcu_top` |
| p3llm | FP4/FP8 | 16 PE | signed 32b 고정소수점 | 500 MHz | `p3llm_pcu` |
| rabit | 2-bit residual binary / FP16 | 8 PE, 곱셈기 0개 | signed 32b 고정소수점 | 250 MHz | `rabit_pcu` |
| spinquant | INT4/INT4 (W4A4) | 16 PE | 32b 레지스터 안 24b carry chain | 500 MHz (tCCD_S) | `spinquant_pcu` |

모든 비교군은 **multiplier + accumulator 를 포함한 연산 경계**로 합성한다.
GRF/SRF, 데이터 버퍼, 명령 디코더, 메모리 인터페이스는 합성 범위 밖이다.

### 1.1 비교 축 3개

각 설계군을 **누산 폭**과 **후처리 위치**의 두 방향으로 확장해 같은 조건에서
합성한다. 동기는 하나다: 지금 모든 PIM 연산기가 dequant/quant 를 GPU 에 맡기고
raw INT32 를 내보내는데, 그 데이터 이동 시간이 연산 시간 절감을 상쇄한다.
**dequant 를 PU 안에서 끝내면 면적·전력을 얼마나 쓰는가** 를 수치로 낸다.

| 축 | 뜻 | 디렉토리 접미사 |
|---|---|---|
| ① base | 32-bit 고정소수점 누산, raw 정수 출력 | — |
| ② acc16 | 매 사이클 partial sum 을 RNE 로 16-bit 으로 좁혀 누산 | `_acc16` |
| ③ dequant_rne | 32-bit 누산 후 PU 안에서 dequant → 그 설계군의 activation 정밀도로 출력 | `_dequant_rne` |

③ 의 출력은 "16-bit 통일" 이 아니라 **다음 레이어가 그대로 먹는 포맷** 이다:
AWQ 는 BF16, P3-LLM 은 **FP8-E4M3**, RaBiT 는 binary16.

면적 (µm², Nangate45, 논리 합성):

| 설계군 | ① base | ② acc16 | Δ | ③ dequant_rne | Δ |
|---|---:|---:|---:|---:|---:|
| awq 8 PE | 36,919 | 36,194 | −2.0 % | 61,702 | +67.1 % |
| awq 16 PE | 72,280 | 68,569 | −5.1 % | 105,061 | +45.4 % |
| p3llm | 71,287 | 62,152 | −12.8 % | 106,359 | +49.2 % |
| rabit | 45,254 | 32,209 | −28.8 % | 93,522 | +106.7 % |
| hbm-pim, spinquant | 각 60,176 / 32,376 | — | | — | |

읽을 때 주의할 것 세 가지.

- **RaBiT ③ 은 과다 계상이다.** 다른 설계군의 ③ 에 없는 write 경로 h 스케일
  유닛까지 포함한다. 그 블록은 `rabit_fs_blk_hscale_250` (20,651 µm²) 으로 따로
  합성돼 있으니 빼면 된다.
- **RaBiT ② 는 k 깊이를 제한한다.** 16-bit 누산기가 `din = 4096` sweep 을
  표현하지 못하고 saturate 한다 ([docs/rabit_pcu_spec.md](docs/rabit_pcu_spec.md)
  §7.1). 면적 절감은 실측이지만 그 대가가 있다.
- **SpinQuant 는 ②③ 이 비어 있다.** 특히 ③ 은 이 확장의 원래 동기가 실제로
  적용되는 유일한 설계다 (W4A4 라 dequant 뿐 아니라 requant 도 PU 안에서 끝낼 수
  있다). 나머지 셋은 activation 이 부동소수점이라 requant 단계가 없다.
  hbm-pim ② 도 baseline 보존을 위해 비워 뒀다.

디렉토리별 상세는 [rtl/README.md](rtl/README.md).

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
./run_rabit_fs.sh     # rabit 축③ (full-scale) 행만
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
make                                   # 전체 회귀 (38 테스트)
PCU_ITERS=300 make                     # 빠른 확인
make TEST=<이름>                        # 하나만; make list 로 목록
cd fp32 && make                        # binary32 누산 경로 (Verilator 단독)
```

golden model 은 전부 순수 파이썬 정수 연산이라 host FPU 를 쓰지 않는다. 일치는
시뮬레이터가 아니라 설계에 대한 진술이다. 새 축을 덮는 것:

- 축② — `pcu_bf16_32_acc16`, `pcu_fp16_32_acc16`, `pcu_bf16_64_acc16`,
  `p3llm_pcu_acc16`, `rabit_pcu_acc16`. 기존 model 에 `acc_bits`/`acc_rsh` 를
  추가해 축①과 같은 testbench 가 덮는다.
- 축③ — `awq_dequant_arith` (공유 FP pipe 3 개, BF16·FP16 동시),
  `pcu_bf16_32_dq` / `pcu_bf16_64_dq` (wrapper end-to-end),
  `p3llm_dequant_arith` / `p3llm_dequant`, `rabit_fs*`.
  P3-LLM 의 FP8-E4M3 pack 은 `fp8_e4m3_decoder.sv` 의 정확한 역함수여야 하므로
  **유한 코드 254 개 전수 round-trip** 으로 확인한다.
