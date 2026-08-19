# AWQ INT4×BF16 PIM 연산기 (PCU) v2 — 면적 · 타이밍 리포트

- 생성: `synth/build_awq_report.py` (label `int4bf16_pcu32_500`)
- 합성: `cd synth && ./run_all.sh synth`
- 명세: [docs/awq_p3llm_pcu_spec.md](../../docs/awq_p3llm_pcu_spec.md)

v2 가 v1 과 다른 것은 zero-point 팬아웃 하나뿐이다: `i_weight_zp` 이 broadcast
nibble 4 bit 에서 PE 당 4 bit (8 PE = 32 bit) 로 넓어졌다. 산술, 파이프라인 4단,
누산기 폭, II=1 은 그대로다.

## 1. baseline 대비

비교 대상: **HBM-PIM FP16 16-lane SIMD 연산부** (`hbmpim_fp16_pcu_16_lane`,
60,176 um2 @ 4.0 ns).

- 포함: 곱셈기, 가산기, 32-bit 누산기
- 제외: GRF/CRF, 버퍼, bank 인터페이스
- group scale `s` 적용, output-group reduction, BF16 packing 은 PCU 밖
  functional postprocess 라 어느 숫자에도 들어 있지 않다.

| 설계 | top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack (ns) |
|---|---|---:|---:|---:|---:|---:|---:|
| HBM-PIM FP16 SIMD 16 lane | `hbmpim_fp16_pcu_16_lane` | 4.0 ns | 60,176 | 1.000x | 56433 | 1578 | +2.01 |
| **AWQ PCU v2, 8 PE x 4 way** | `int4bf16_pcu32` | 2.0 ns | 36,919 | 0.614x | 32282 | 1566 | +0.66 |
| AWQ PCU v1, 16 PE x 4 way | `int4bf16_pcu_top` | 2.0 ns | 71,745 | 1.192x | 62010 | 3054 | +0.65 |

**면적 제약 충족**: 36,919 um2 < 60,176 um2 — baseline 의 61.4 %, 23,257 um2 절감.

8 PE 판은 곱셈기 32 개로 baseline SIMD 의 32-multiplier 구성과 곱셈기 수를 맞춘
행이다. 16 PE 판과의 면적비가 1:1.94 로 정확히 2 배가 아닌 것은 공유 정렬기
(`int4float_align` 4 개) 가 `NUM_PES` 를 따라 줄지 않기 때문이다 — MAC 당 정렬
비용은 8 PE 쪽이 2 배다.

| 설계 | 면적 (um2) | baseline 대비 | MAC/cycle | um2/MAC |
|---|---:|---:|---:|---:|
| AWQ PCU v2, 8 PE x 4 way | 36,919 | 0.614x | 32 | 1,154 |
| AWQ PCU v1, 16 PE x 4 way | 71,745 | 1.192x | 64 | 1,121 |
| P3-LLM PCU, FP4/FP8, 16 PE x 4 way | 71,287 | 1.185x | 64 | 1,114 |
| SpinQuant W4A4 PCU, 16 PE x 4 way | 32,376 | 0.538x | 64 | 506 |
| HBM-PIM FP16 SIMD 16 lane | 60,176 | 1.000x | 16 | 3,761 |

조직은 **P3-LLM PCU 그대로**이고 피연산자 형식만 다르다. 16 PE 판이 P3-LLM 행과
um2/MAC 1,121 對 1,114 로 사실상 같은 것이 그 증거다 — INT4×BF16 로 바꿔서 아낀
것과 block-float 정렬기로 새로 쓴 것이 거의 상쇄된다.

### 조합 / 순차 분해

| 설계 | 총 면적 | 조합 (um2) | 순차 (um2) | 순차 비중 | DFF |
|---|---:|---:|---:|---:|---:|
| AWQ PCU v2, 8 PE | 36,919 | 29,837 | 7,081 | 19.2 % | 1566 |
| AWQ PCU v1, 8 PE | 37,261 | 30,180 | 7,082 | 19.0 % | 1566 |
| P3-LLM PCU, 16 PE | 71,287 | 59,557 | 11,730 | 16.5 % | 2594 |
| HBM-PIM FP16 SIMD 16 lane | 60,176 | 53,040 | 7,136 | 11.9 % | 1578 |

## 2. v1 → v2 의 대가: -342.6 um2 (-0.92 %)

zero-point 를 PE 별로 주는데 면적이 **줄었다.** 오타가 아니고 노이즈도 아니다.

| 구성 | 면적 (um2) | cells | DFF | 조합 (um2) | 순차 (um2) | slack |
|---|---:|---:|---:|---:|---:|---:|
| v1 (broadcast nibble) | 37,261.280 | 32,448 | 1566 | 30,179.8 | 7,081.5 | +0.66 |
| **v2 (PE 당 nibble)** | **36,918.672** | **32,282** | **1566** | **29,837.2** | **7,081.5** | **+0.66** |
| 차이 | **-342.608** | -166 | 0 | -342.6 | **0** | 0 |

읽는 법:

- **차이는 전부 조합 논리다.** 순차 면적과 DFF 수가 bit 단위로 같다. ZP 팬아웃은
  상태를 하나도 추가하지 않는다는 것이 합성 결과로 확인된다 — v1 과 v2 는 같은
  `int4float_pe` 소스를 쓰고, PE 는 원래부터 4-bit ZP 를 포트로 받는다.
- **재현된다.** v1 소스를 git 에서 복원해 같은 플로우로 다시 합성하면
  37,261.280 um2 / 32,448 cells 로 자리 숫자까지 일치한다. v2 를 소스 파일
  역순으로 합성해도 36,918.672 um2 / 32,282 cells 로 동일하다. RaBiT 행에서
  관측된 0.9 % 순서 의존성 (`results/designs/rabit_pe_scaling.md` 4절) 은 이
  설계에서는 (역순 1 회 기준) 나타나지 않았다.
- **구조 변경이 아니라 재매핑이다.** 셀 히스토그램 차이가 한 종류에 몰리지 않고
  퍼져 있다: XNOR2_X1 -109, NAND2_X1 -71, AOI21_X1 -50, OR2_X1 +50, NAND3_X1 +43,
  XOR2_X1 +41 …. 논리량은 그대로이고 ABC 가 다르게 인수분해했다.
- **왜 줄어드는지는 규명하지 않았다.** 두 판의 감산기 수와 폭이 같으므로 ABC 의
  factoring 결과 차이로 보이지만, 그 인과를 실험으로 분리하지는 않았다. 어느
  쪽이든 0.92 % 이므로 **설계 선택의 근거로 쓸 크기는 아니다.**

**결론: 표준 AutoAWQ metadata 배치를 구현하는 데 드는 면적 비용은 0 이다.**

## 3. 타이밍

목표는 500 MHz (2.0 ns) 다. DRAM 측 command cadence 는 tCCD_S = 2 이고, PCU 는
command 하나당 1 cycle 을 쓴다 (II = 1).

- **500 MHz** (2.0 ns): slack **+0.66 ns (MET)**. worst path `i_act[26]` ->
  `u_pcu.g_pe[0].u_pe.s0_act_q[1][5]$_SDFF_PN0_`.
- hold: slack +0.08 ns (MET).

worst path 는 v1 과 **같은 구조**다 (v1: `i_act[40]` -> `s0_act_q[2][13]`).
`i_act` 입력 포트에서 공유 `int4float_align` 을 지나 PE stage 0 의 activation
레지스터로 들어가는 조합 경로이고, 양쪽 다 slack 0.66 ns 로 같다. **critical
path 는 zero-point 쪽이 아니라 block-float 정렬기 쪽이다** — ZP 를 PE 별로
바꿔도 타이밍이 움직이지 않는 이유다.

이 경로에는 플로우 관례대로 입출력 각각 주기의 20 % 가 I/O delay 로 잡혀 있다
(2.0 ns 주기에서 0.40 ns). 실제 시스템에서 `i_act` 는 input GRF 의 flop 에서
나온다.

## 4. 전력

전력은 vectorless `set_power_activity -global 0.20` 한 가지 모델이다 (모든 net 에
균일, 전파 없음).

| | Power | pJ/MAC | GMAC/s |
|---|---:|---:|---:|
| AWQ PCU v2, 8 PE x 4 way | 0.0177 W | 1.11 | 16.0 |
| AWQ PCU v1, 16 PE x 4 way | 0.0344 W | 1.07 | 32.0 |
| P3-LLM PCU, FP4/FP8, 16 PE x 4 way | 0.0351 W | 1.10 | 32.0 |
| SpinQuant W4A4 PCU, 16 PE x 4 way | 0.0167 W | 0.52 | 32.0 |
| HBM-PIM FP16 SIMD 16 lane | 0.0151 W | 3.78 | 4.0 |

`-global` 은 설계별 활성도를 구분하지 않아 대체로 셀 수를 다시 말하는 값이다.
**설계 간 에너지 우열은 이 표로 주장하지 않는다** — 방어 가능한 비교에는
gate-level VCD 가 필요하다.

## 5. 검증

```
cd verif && make TEST=pcu_bf16_32   # 8 PE, BF16, per-PE ZP  (본 행)
cd verif && make TEST=pcu_fp16_32   # 8 PE, binary16, per-PE ZP
cd verif && make TEST=pcu_bf16_64   # 16 PE, BF16, broadcast ZP (v1)
```

golden model 은 순수 파이썬 정수 연산이다
(`verif/models/int4float_pcu_model.py`). 정렬 · RNE 반올림 · `(W_q - z)` 디코드 ·
포화 누산을 RTL 과 문장 단위로 대응시켰고 host floating point 를 쓰지 않는다.

- 매 transaction 마다 PE 별 signed 32-bit 누산기, `o_saturate`, `o_invalid` 를
  전부 bit-exact 대조한다. 기본 4000 transaction (`PCU_ITERS`).
- stimulus 는 corner encoding 30 % (zero, ±0, 최소 subnormal, subnormal/normal
  경계, ±1, 최대 finite, ±inf, NaN) + 랜덤 70 %, 64 transaction 마다 `acc_clear`.
- `PCU_ZP_PER_PE` 로 v1/v2 계약을 전환하므로 같은 testbench 가 세 top 을 덮는다.

상위 Fusion-PIMSim 재검증 (Llama-3.1-8B 224 projection, raw INT32 54,525,952 건
exact 등) 은 명세 5.1 절에 있다. **Captured Standard AutoAWQ final BF16 과는
전체 bit-exact 가 아니다.**

