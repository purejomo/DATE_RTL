# AWQ INT4×float PIM 연산기 (PCU) 설계 명세 — v2

Bank-attached PIM 연산기. AutoAWQ W4G128 weight 와 16-bit float activation 의
**projection layer GEMV 전용** 데이터패스이며, P3-LLM 의 PE 조직을 그대로 쓰고
피연산자 형식만 바꾼 비교 행이다.

- RTL: [rtl/2_awq_p3llm_8pe_v2/](../rtl/2_awq_p3llm_8pe_v2/) (8 PE, v2),
  [rtl/2_awq_p3llm_16pe_v2/](../rtl/2_awq_p3llm_16pe_v2/) (16 PE, v2).
  v1 broadcast-nibble ZP 빌드는 삭제됐다 — 두 빌드 모두 PE별 독립 4-bit ZP다.
  누산 축 변형은 `*_acc16`, PU 내 dequant 변형은 `*_dequant_rne` 디렉토리
- Golden model: [verif/models/int4float_pcu_model.py](../verif/models/int4float_pcu_model.py)
- 회귀: `cd verif && make TEST=pcu_bf16_32` (전체는 `make`)
- 합성: `cd synth && ./run_all.sh synth`
- 면적·타이밍 리포트:
  [results/designs/awq_p3llm_v2_area_report.md](../results/designs/awq_p3llm_v2_area_report.md)

한 줄 요약: **v2 가 v1 과 다른 것은 zero-point 팬아웃 하나뿐이다.** 산술, 파이프
라인 4단, 누산기 폭, II=1, 소프트웨어가 정하는 block exponent 는 전부 그대로다.

---

## 1. 연산 정의

### 1.1 AutoAWQ 가 PCU 에 남기는 것

AutoAWQ 는 activation-aware per-channel scaling 을 **weight 에 흡수시킨 뒤**
group size 128 의 asymmetric INT4 로 양자화한다. PCU 관점에서 남는 것은:

| | 형식 | 어디서 만들어지나 |
|---|---|---|
| Weight `W_q` | **unsigned INT4** (0..15) + group ZP | AWQ scaling 흡수 후 per-output-channel/group asymmetric 양자화, offline. DRAM 에 그대로 저장 |
| Zero point `z` | **unsigned INT4** (0..15) | 같은 양자화가 만든 metadata. **output channel × group 단위** |
| Activation | **BF16 또는 binary16** | NPU 가 그대로 보낸다. 양자화하지 않는다 |

dequantization 은 `W̃ = s · (W_q - z)` 이므로

```
W̃ · a = s · Σ (W_q - z) · a
```

- `(W_q - z)` 는 **PCU 안**에서 계산한다 (`int4_asym_decode`).
- `s` (group scale) 와 output-group reduction, 최종 BF16 packing 은 **PCU 밖**
  functional postprocess 다. 이 경계는 v1 과 같다.

### 1.2 v1 → v2 가 바꾼 것

v1 은 `i_weight_zp` 이 4-bit 하나였고 그것을 모든 output PE 에 broadcast 했다.
AutoAWQ 는 zero point 를 **output channel 별로** 저장하므로, 한 transaction 이
서로 다른 8 개 output channel 을 계산하는 이 조직에서 broadcast 는 표준 AutoAWQ
metadata 배치를 구현하지 않는다.

| | v1 | v2 |
|---|---|---|
| `i_weight_zp` 폭 | 4 bit | `NUM_PES*4` bit (8 PE = 32 bit) |
| PE 당 zero point | 전부 동일 | 독립 |
| 그 외 | — | 전부 동일 |

`int4float_pe` 는 v1 과 v2 가 같은 소스다. PE 는 원래부터 4-bit ZP 를 포트로
받고 lane 4 개의 `int4_asym_decode` 에 나눠 주므로, 바뀐 것은 `int4float_pcu` 의
슬라이스 한 줄 (`i_weight_zp[pe*4 +: 4]`) 뿐이다.

### 1.3 역할 분담

| 단계 | 어디서 |
|---|---|
| AWQ per-channel scaling 흡수 | offline |
| asymmetric INT4 양자화, `(W_q, z, s)` 생성 | offline |
| block exponent `i_ref_exp` 선정 | NPU (software) |
| block-float 정렬, `(W_q - z)` 디코드, 32 곱, 누산 | **PCU** |
| group scale `s` 적용, output-group reduction, BF16 packing | NPU (functional postprocess) |

마지막 행은 정확도 계산에는 반영하지만 **GPU kernel latency/PPA 측정은 하지
않는다** (EXTENSION). 따라서 이 설계는 GPU postprocess 가속기나 end-to-end CUDA
bit-exact 를 주장하지 않는다.

---

## 2. 수 표현과 폭

### 2.1 왜 block floating point 인가

P3-LLM 은 activation 의 raw exponent 로 PE 안에서 곱을 shift 한다. FP8-E4M3 은
exponent 가 4-bit 라 가능한 방법이다. 그런데 이 행의 activation 은 16-bit float
이므로 같은 방법을 쓰면 (곱 크기 + 최대 shift + 부호) 만큼이 필요하다:

| activation | exponent bits | 필요 폭 |
|---|---:|---:|
| FP8-E4M3 (P3-LLM) | 4 | 26 bit |
| binary16 | 5 | 15 + 30 + 1 = **46 bit** |
| bfloat16 | 8 | 12 + 254 + 1 = **267 bit** |

그래서 **block 당 한 번만** 정렬한다. `i_ref_exp` 는 block 안 최대 activation 의
unbiased exponent 이고 software 가 준다. 지수 로직은 lane 별 64 개 shifter 가
아니라 공유 `int4float_align` 4 개에 모인다.

```
aligned = (-1)^sign * ((significand << GUARD) >> (i_ref_exp - lsb_exp))
value   = aligned * 2^(i_ref_exp - GUARD)
```

- `GUARD = 8`: block 최대값보다 8 binade 아래까지 살린다. 그보다 아래는 flush
  된다 — block floating point 의 본질적 손실이고, 그래서 reference 가 global 이
  아니라 block 단위다.
- 버려지는 비트는 **RNE 로 반올림**한다. truncate 하면 편향이 단방향이라 128
  group 에 걸쳐 수십 LSB 로 누적되고, 비교 대상인 곱셈기 lane 들은 반올림하므로
  두 조직이 수치적으로 동치가 아니게 된다.
- `i_ref_exp` 를 최대값보다 낮게 주면 shift 가 0 에서 포화하고 값이 잘린다.
  `o_saturate` 가 그것을 보고한다. Inf/NaN 은 0 으로 디코드하고 `o_invalid`.

### 2.2 폭 산정

| 신호 | 폭 | 유래 |
|---|---:|---|
| `significand` | `MANT_W+1` | hidden bit 포함 |
| aligned (`ALIGNED_W`) | `MANT_W+GUARD+2` | BF16 17 bit, binary16 20 bit |
| decoded weight | signed 5 bit | `W_q - z` ∈ [-15, +15] |
| product (`PROD_W`) | `ALIGNED_W+5` | BF16 22 bit, binary16 25 bit |
| compressor in | 26 bit | P3-LLM `compressor_4to2` 그대로, 두 형식 모두 수용 |
| compressor out | 28 bit | sum · carry |
| accumulator | **signed 32 bit** | PE 안에 상주 |

`int4_asym_decode` 는 차이를 sign + 4-bit magnitude 로 쪼갠다. 곱셈기 lane 이
unsigned 11×4 array 를 쓰고 부호를 마지막에 붙이는 쪽이 signed 12×5 보다 작기
때문이다.

### 2.3 누산기: 포화

누산기는 **포화**한다 (wrap 아님). 이전 판은 33-bit 합을 32-bit 로 잘라 overflow
가 부호를 뒤집었고 실리콘에서 그것을 알 방법이 없었다. 헤드룸은 유한하다:
binary16 activation + `GUARD=8` 최악에서 68 transaction 이면 2^31 에 닿으므로,
group size 가 256 을 넘으면 실제로 도달할 수 있다.

누산기 LSB 의 가치는 `2^(i_ref_exp - GUARD)` 다. 그 스케일과 group scale `s` 는
PCU 밖에서 적용한다.

---

## 3. 마이크로아키텍처

### 3.1 토폴로지: 8 PE × 4-way (1 × 4 × 8 GEMV tile)

한 transaction 이 계산하는 것:

```
4 shared activations (BF16 or binary16)
       |
       +--> int4float_align x 4          (공유 block-float 정렬)
       |
       +--> 8 x int4float_pe             (PE 당 4 곱 = 32 multiplier)
              4:2 compressor -> CPA -> signed 32b accumulator
```

P3-LLM Fig. 6(a) 와 같은 조직이고 피연산자 형식만 다르다.

**8 PE 는 bank read width 와 맞지 않는다.** 8 PE 는 transaction 당 weight 128
bit 를 먹는데 이는 256-bit bank access 의 절반이다. 이 구성이 존재하는 이유는
32-multiplier SIMD 구성과 **곱셈기 수·MAC 처리량을 맞추기 위해서**다. 공유
정렬기 4 개는 `NUM_PES` 를 따라 줄지 않으므로, MAC 당 정렬 비용은 16-PE 판의 2
배다.

### 3.2 PE 내부 — 4단 파이프라인

| stage | 하는 일 |
|---:|---|
| 0 | 정렬된 activation 캡처, weight 디코드 (`W_q - z`) |
| 1 | signed 곱 4 개 |
| 2 | 4:2 carry-save 압축 |
| 3 | CPA + 포화 누산 |

`compressor_4to2` 는 P3-LLM 의 모듈 그대로다. P3-LLM PE 와 달리 **lane 별
shifter 가 없다** — 정렬이 이미 공유 front end 에서 끝났으므로 PE 는 P3-LLM 것
보다 오히려 단순하다.

II = 1. `i_ready` 는 `rst_n` 이고, tCCD pacing 은 이 PCU 를 감싸는 wrapper 몫이다.
모든 PE 는 lockstep 이므로 `o_valid = &pe_valid` 다.

---

## 4. 인터페이스

```verilog
module int4float_pcu #(
    parameter integer EXP_W   = 5,   // 5 = binary16, 8 = bfloat16
    parameter integer MANT_W  = 10,
    parameter integer GUARD   = 8,
    parameter integer NUM_PES = 8
) (
    input  wire clk, rst_n,
    input  wire i_valid, output wire i_ready,
    input  wire i_acc_clear, i_acc_enable,
    input  wire [63:0] i_act,                   // 4 x 16-bit float
    input  wire signed [9:0] i_ref_exp,
    input  wire [NUM_PES*16-1:0] i_weight_q,    // PE 당 nibble 4 개
    input  wire [NUM_PES*4-1:0]  i_weight_zp,   // PE 당 4-bit ZP  <-- v2
    output wire o_valid,
    output wire [NUM_PES*32-1:0] o_acc,
    output wire o_saturate, o_invalid
);
```

| top | 형식 | `EXP_W`/`MANT_W` | `i_weight_zp` | 용도 |
|---|---|---|---|---|
| `int4bf16_pcu32` | BF16 | 8 / 7 | 32 bit | **H2-S1 본 행** |
| `int4fp16_pcu32` | binary16 | 5 / 10 | 32 bit | 형식만 바꾼 비교 |
| `int4bf16_pcu_top` | BF16 | 8 / 7 | 4 bit (v1) | 16 PE 행 |

`int4bf16_pcu32_per_pe_zp` / `int4fp16_pcu32_per_pe_zp` 는 Fusion-PIMSim 이 쓰는
**순수 alias** 다. 상태도 산술도 추가하지 않는다.

### 4.1 8 PE 와 16 PE 의 포트 폭이 다르다

`int4bf16_pcu_top` (16 PE) 은 아직 v1 broadcast nibble 이다. 두 디렉토리는 각자
`int4float_pcu/pe/align` 사본을 들고 있으므로 **함께 컴파일하면 모듈이 중복
정의된다** — 합성도 회귀도 한 번에 한쪽만 쓴다.

---

## 5. 검증

```bash
cd verif && make TEST=pcu_bf16_32   # 8 PE, BF16, per-PE ZP
cd verif && make TEST=pcu_fp16_32   # 8 PE, binary16, per-PE ZP
cd verif && make TEST=pcu_bf16_64   # 16 PE, BF16, broadcast ZP (v1)
```

golden model 은 순수 파이썬 정수 연산이다
([verif/models/int4float_pcu_model.py](../verif/models/int4float_pcu_model.py)).
정렬 · 반올림 · 디코드 · 포화를 RTL 과 문장 단위로 대응시켰고 host floating
point 를 전혀 쓰지 않으므로, 일치는 시뮬레이터 FPU 가 아니라 설계에 대한 진술이다.

- `transaction` 의 zero point 는 nibble 하나 (v1 broadcast) 또는 PE 당 하나
  (v2) 를 모두 받는다. testbench 는 `PCU_ZP_PER_PE` 로 어느 쪽인지 알고 stimulus
  와 model 을 함께 맞춘다.
- stimulus 는 corner encoding (zero, ±0, 최소 subnormal, subnormal/normal 경계,
  ±1, 최대 finite, ±inf, NaN) 30 % + 랜덤 70 % 이고, 64 transaction 마다
  `acc_clear` 를 넣어 clear/accumulate 경로를 함께 돈다.
- 매 transaction 마다 PE 별 32-bit 누산기, `o_saturate`, `o_invalid` 를 전부
  bit-exact 대조한다.

`PCU_ITERS` 로 규모를 조절한다 (기본 4000).

### 5.1 2026-08-16 Fusion-PIMSim 재검증

RTL 소유 범위 밖이지만 이 v2 계약을 쓰는 상위 검증이다.

- directed per-PE ZP: 8/8 accumulator exact
- Llama-3.1-8B: 32 layer × 7 projection = 224 live Verilator
- raw INT32: 54,525,952 / 54,525,952 golden exact
- final BF16: 1,376,256 / 1,376,256 DATE-v2 conformant golden exact
- four-stack Ramulator: 224/224 serial raw exact, 1,371,416 DRAM cycle

**Captured Standard AutoAWQ final BF16 과는 전체 bit-exact 가 아니다.**
activation block-floating 정렬과 group reduction 순서가 다르므로 "CUDA AutoAWQ
exact" 로 표기하지 않는다. WikiText-2 32-document / 128-input-token
live-feedback PPL 은 BF16 `9.8301211482`, DATE-v2 `10.4910672531` (+6.723682 %)
이며 224 projection × 128 token = 28,672 Verilator invocation 을 돌렸다. 이는
127 scored-token bounded 품질 수치이지 full WikiText-2 전체-corpus PPL 이 아니다.

---

## 6. 결과 요약

Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지.

| top | 목표 주기 | 면적 (um2) | baseline 대비 | cells | DFF | setup slack |
|---|---:|---:|---:|---:|---:|---:|
| `int4bf16_pcu32` (8 PE, v2) | 2.0 ns | 36,919 | 0.614x | 32,282 | 1566 | +0.66 ns |
| `int4bf16_pcu_top` (16 PE, v1) | 2.0 ns | 71,745 | 1.192x | 62,010 | 3054 | +0.65 ns |
| baseline `hbmpim_fp16_pcu_16_lane` | 4.0 ns | 60,176 | 1.000x | 56,433 | 1578 | +2.01 ns |

v1 대비 **-342.6 um2 (-0.92 %)**. zero point 를 PE 별로 주면서 면적이 오히려
줄었고, 순차 면적과 DFF 수는 bit 단위로 같다 — 즉 **표준 AutoAWQ metadata 배치를
구현하는 데 드는 면적 비용은 0 이다.** 자세한 것은
[results/designs/awq_p3llm_v2_area_report.md](../results/designs/awq_p3llm_v2_area_report.md).

---

## 7. 남은 것

- **16 PE 판이 아직 v1 이다.** 같은 이유로 broadcast ZP 는 AutoAWQ metadata 를
  구현하지 않는다. 옮기려면 `int4float_pcu.v` 의 슬라이스 한 줄과 top 포트 폭만
  바꾸면 되고 (`i_weight_zp[pe*4 +: 4]`, 64 bit), 회귀는 `PCU_ZP_PER_PE=1` 로
  같은 testbench 가 덮는다. 다만 그러면 비교표의 16-PE 행을 다시 합성해야 한다.
- **GPU postprocess 는 EXTENSION 이다.** group scale 적용과 output-group
  reduction 의 latency/PPA 는 이 리포트의 어느 숫자에도 들어 있지 않다.
