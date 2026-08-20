# DATE — PIM PCU RTL

HBM-PIM, AWQ, P3-LLM, RaBiT, SpinQuant PCU의 RTL·검증·합성 결과를 비교한다.

## 전체 면적 비교

Nangate45 논리 합성 결과다. 모든 값은 연산 데이터패스와 누산기를 포함한다.

| 설계 | 축 | 조직 / 클록 | 출력 | 면적 (µm²) | HBM 면적 대비 | base 면적 대비 |
|---|---|---|---|---:|---:|---:|
| HBM-PIM (FP16/FP16) | 기준 | 16 lane / 250 MHz | FP32 | 60,176 | 1.000x | — |
| AWQ (INT4/BF16) | ① base | 8 PE / 500 MHz | INT32 | 36,919 | 0.614x | — |
| AWQ (INT4/BF16) | ② acc16 | 8 PE / 500 MHz | INT16 | 36,194 | 0.601x | −2.0% |
| AWQ (INT4/BF16) | ③ dequant_rne | 8 PE / 500 MHz | BF16 | 61,702 | 1.025x | +67.1% |
| AWQ (INT4/BF16) | ① base | 16 PE / 500 MHz | INT32 | 72,280 | 1.201x | — |
| AWQ (INT4/BF16) | ② acc16 | 16 PE / 500 MHz | INT16 | 68,569 | 1.139x | −5.1% |
| AWQ (INT4/BF16) | ③ dequant_rne | 16 PE / 500 MHz | BF16 | 105,061 | 1.746x | +45.4% |
| P3-LLM (FP4/FP8) | ① base | 16 PE / 500 MHz | INT32 | 71,287 | 1.185x | — |
| P3-LLM (FP4/FP8) | ② acc16 | 16 PE / 500 MHz | INT16 | 62,152 | 1.033x | −12.8% |
| P3-LLM (FP4/FP8) | ③ dequant_rne | 16 PE / 500 MHz | FP8-E4M3 | 106,359 | 1.767x | +49.2% |
| RaBiT (RB2/FP16) | ① base | 8 PE / 500 MHz | INT32 | 45,254 | 0.752x | — |
| RaBiT (RB2/FP16) | ② acc16 | 8 PE / 500 MHz | INT16 | 32,209 | 0.535x | −28.8% |
| RaBiT (RB2/FP16) | ③ dequant_rne | folded 4 PE / 500 MHz | FP16 | 56,006 | 0.931x | +23.8% |
| SpinQuant (INT4/INT4) | ① base | 16 PE / 500 MHz | INT32 | 32,376 | 0.538x | — |
| SpinQuant (INT4/INT4) | ② acc16 | 16 PE / 500 MHz | INT16 | 25,767 | 0.428x | −20.4% |
| SpinQuant (INT4/INT4) | ③ dequant_rne | 16 PE / 500 MHz | FP16 | 40,271 | 0.669x | +24.4% |
| SpinQuant (INT4/INT4) | ④ dequant_requant | 16 PE / 500 MHz | UINT4 | 39,997 | 0.665x | +23.5% |
| SpinQuant v2 (INT4/INT4) | ① base | 32 PE / 500 MHz | INT32 | 64,345 | 1.069x | — |
| SpinQuant v2 (INT4/INT4) | ② acc16 | 32 PE / 500 MHz | INT16 | 51,191 | 0.851x | −20.4% |
| SpinQuant v2 (INT4/INT4) | ③ dequant_rne | 32 PE / 500 MHz | FP16 | 68,391 | 1.137x | +6.3% |
| SpinQuant v2 (INT4/INT4) | ④ dequant_requant | 32 PE / 500 MHz | UINT4 | 68,389 | 1.136x | +6.3% |

원시 결과는 [results/area.csv](results/area.csv), 상세 비교는
[RTL 요약](rtl/README.md)에서 확인한다.

## 축

| 축 | 의미 | 적용 대상 |
|---|---|---|
| ① base | 32-bit 누산 후 raw INT32 출력 | AWQ, P3-LLM, RaBiT, SpinQuant |
| ② acc16 | RNE 축소 후 16-bit 누산·출력 | AWQ, P3-LLM, RaBiT, SpinQuant |
| ③ dequant_rne | PCU에서 다음 activation 형식으로 변환 | AWQ→BF16, P3-LLM→FP8, RaBiT·SpinQuant→FP16 |
| ④ dequant_requant | dequant 후 UINT4 재양자화 | SpinQuant |

HBM-PIM은 비교 기준이므로 확장축이 없다.
RaBiT ③은 입력 스케일 `s_in × x`와 출력 dequant/RNE를 모두 PCU 내부에서 처리한다.
SpinQuant v2는 모든 축이 32 PE이며 512-bit weight beat가 필요하다. ④는 UINT4 전용으로
FP16 보조 출력 packer를 제외한다. v2 ①은 16 PE ①보다 면적이 98.7% 크다.

## 실행

합성:

```bash
cd synth
./run_all.sh                   # 기본 비교축
./run_all.sh synth|power|table # 단계별
./run_rabit.sh                 # RaBiT 스윕
./run_rabit_fs.sh              # 최종 RaBiT dequant_rne
./run_spinquant.sh             # SpinQuant 스윕
./run_spinquant_v2.sh          # SpinQuant 32 PE v2
```

검증:

```bash
cd verif
make                 # 전체 회귀
PCU_ITERS=300 make   # 빠른 회귀
make TEST=<이름>     # 단일 테스트
make list            # 테스트 목록
cd fp32 && make      # binary32 경로
```

필요 도구: Yosys 0.52, OpenROAD, OpenROAD-flow-scripts, sv2v.

## 문서와 결과

- RTL: [rtl/](rtl/), [RTL 요약](rtl/README.md)
- 설계 명세: [AWQ/P3-LLM](docs/awq_p3llm_pcu_spec.md), [RaBiT](docs/rabit_pcu_spec.md), [SpinQuant](docs/spinquant_pcu_spec.md)
- 검증: [verif/](verif/), [검증 안내](verif/README.md)
- 합성: [synth/](synth/)
- 결과: [results/](results/) (`area.csv`, 비교 CSV, 원시 합성·전력 리포트)

## 측정 조건

- Nangate45 typical, Yosys ABC area mode, OpenROAD
- P&R 및 배선 면적 제외
- 외부 GRF/SRF, command memory, DRAM bank interface 제외
- 데이터플로에 필요한 로컬 sequencer/state는 포함(SpinQuant read latch, RaBiT group-scale buffer 등)
- 전력은 vectorless global activity 0.20, duty 0.50 기준
