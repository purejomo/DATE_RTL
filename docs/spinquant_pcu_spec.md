# SpinQuant W4A4 PIM 연산기 (PCU) 설계 명세

Bank-attached PIM 연산기. SpinQuant (W4A4) 정밀도의 **projection layer GEMV
전용** 데이터패스이며, HBM-PIM (ISCA'21, Aquabolt-XL/FIMDRAM) 스타일 16-lane
FP16 SIMD 연산부를 baseline 으로 삼는다.

- RTL: [rtl/5_spinquant/](../rtl/5_spinquant/)
- Golden model: [verif/models/spinquant_model.py](../verif/models/spinquant_model.py)
- 회귀: `cd verif && make TEST=spinquant_pcu` (전체는 `make`)
- 합성: `cd synth && ./run_spinquant.sh`
- 면적·타이밍 리포트:
  [results/designs/spinquant_area_report.md](../results/designs/spinquant_area_report.md)

한 줄 요약: **PCU 는 순수 integer dot-product engine 이다.** SpinQuant 의
수치 구조가 rotation·zero point·scale 을 전부 PCU 밖으로 밀어내므로, 경계 안에
남는 것은 signed4 × unsigned4 곱셈기 64 개와 그것을 받는 누산기뿐이다.

---

## 1. 연산 정의

### 1.1 SpinQuant 가 PCU 에 남기는 것

SpinQuant 는 학습된 rotation R1·R2 를 weight 에 흡수시키고 (offline), down_proj
입력에는 R4 online Hadamard 를 적용한 뒤 양자화한다. PCU 관점에서 중요한 것은
**그 결과가 무엇이냐**뿐이다.

| | 형식 | 어디서 만들어지나 |
|---|---|---|
| Weight `W_q` | **signed INT4** (-8..7) | R1·R2 merge 후 GPTQ per-channel symmetric 양자화, offline. DRAM 에 그대로 저장 |
| Activation `A_q` | **unsigned INT4** (0..15) | NPU 가 per-token asymmetric min-max (no clip) 로 양자화, input GRF 로 전송 |

dequantization 은 다음과 같이 전개된다. `Ã = s_a · A_q + β` 이므로

```
W · Ã = s_a · (W_q · A_q) + β · Σ W_row
```

- `β · Σ W_row` 는 output channel 별 상수다. weight 가 정해지면 결정되므로
  **offline 에 계산해 NPU bias 에 fusion** 한다.
- `s_w` (per output channel), `s_a` (per token) 는 **NPU 가 drain 이후에** 곱한다.

따라서 PCU 가 계산하는 것은 정수 내적 하나뿐이다.

```
acc[e][i] += Σ_{j<4} W_q[i][j] · A_q[j]
```

### 1.2 역할 분담

| | 담당 | 합성 |
|---|---|:--:|
| R1·R2 rotation merge, GPTQ 양자화 | offline | X |
| R4 online Hadamard (down_proj 입력) | NPU | X |
| activation per-token min-max 양자화 → `A_q` | NPU | X |
| `β · Σ W_row` bias 보정 사전계산 | offline → NPU bias | X |
| **`Σ W_q · A_q` 정수 내적 · 누산** | **PCU** | **O** |
| `s_w ⊙ s_a ⊙ acc + bias` | NPU | X |

**금지 목록.** 아래 중 하나라도 RTL 에 있으면 이 설계의 주장이 무너진다. 현재
`rtl/5_spinquant/` 전체를 통틀어 하나도 없다.

- 부동소수점 연산기, exponent alignment shifter
- format decoder (FP8/FP4/BitMoD 류)
- zero-point 감산기
- scale 곱셈기, dequantization shifter

확인은 한 줄이면 된다 — 주석을 걷어내고 나면 hit 이 `timescale` 뿐이다.

```bash
for f in rtl/5_spinquant/*.sv; do
    awk '!/^[[:space:]]*\/\//' "$f" \
    | grep -inE 'exponent|mantissa|zero_point|scale|fp16|fp8|>>>|<<<' \
    | sed "s|^|$f:|"
done
```

---

## 2. 수 표현과 폭

### 2.1 곱

`w ∈ [-8, 7]`, `a ∈ [0, 15]` 이므로 `w·a ∈ [-120, 105]` 이고 **signed 8 bit 에
정확히** 들어간다. `spinquant_mul_s4u4` 는 4×5 signed 곱의 9-bit 결과를 8-bit
로 자르며, 그 절단이 무손실임을 `SPINQUANT_ASSERTIONS` 가 확인한다.

### 2.2 부분합

4 개 곱을 더하면 `|Σ| ≤ 480` 이므로 `PSUM_W = 8 + log2(4) = 10 bit` 에 정확히
들어간다. 4:2 compressor 는 `mod 2^10` 으로 감기지만 참값이 10 bit 에 들어가므로
wrap 이 상쇄되어 CPA 출력이 정확하다 — RaBiT PE 와 같은 논증이고, 마찬가지로
assertion 이 재계산으로 대조한다.

### 2.3 누산기: 24-bit chain in 32-bit register

최악의 누산은 K 방향 전체가 최악 곱인 경우다.

| K | 최악 누산 | 필요 bit |
|---:|---:|---:|
| 4096 | -491,520 | 21 |
| 11008 | -1,320,960 | 22 |
| **14336** | **-1,720,320** | **22** |
| 69,905 | -8,388,600 | 24 (여기서 포화) |

`ACC_CHAIN_W = 24` 는 K = 14336 에 **2 bit 여유**를 남기고, K = 69,905 까지
견딘다. LLaMA 계열 projection layer 의 어떤 K 도 이 범위 안이다.

레지스터 폭은 `ACC_W = 32` 로 유지한다 (GRF 해석과 P3-LLM 비교 정합성).
상위 8 bit 는 bit 23 의 sign extension 이고, drain 은 32-bit 부호확장값을 낸다.
**단, 그 8 bit 는 D 입력이 같으므로 합성기가 병합한다.** 실측 DFF 는 대표 구성
1,960 개, `_acc32` 구성 2,472 개로 차이가 정확히 512 개 = 4 entry × 16 PE ×
8 bit 다. 즉 24-bit chain 의 절감은 carry 길이만이 아니라 중복 flop 제거까지
포함하며, 아키텍처상의 폭 (drain 이 32-bit 부호확장값을 낸다) 과 실리콘상의 폭이
갈리는 지점이다. 어느 쪽으로 읽어도 면적 제약은 충족되므로 리포트는 두 구성을
모두 싣는다 — `spinquant_pcu` 32,376 um² (baseline 의 0.538x),
`spinquant_pcu_acc32` 40,390 um² (0.671x).

### 2.4 overflow: 포화가 아니라 보고

24-bit chain 은 지원 범위 안에서 넘칠 수 없으므로 포화 회로는 죽은 실리콘이다.
대신 two's complement overflow 를 검출해 `ovf_sticky_o` 로 올린다 (P3-LLM 과
RaBiT 은 포화시킨다 — 그쪽은 alignment shift 때문에 실제로 넘칠 수 있다).
`status_clr_i` 로 내린다. 같은 cycle 에 clear 와 event 가 겹치면 event 가 이긴다.

---

## 3. 마이크로아키텍처

### 3.1 토폴로지: 16 PE × 4-way (1 × 4 × 16 GEMV tile)

```
        256b bank beat (RD, 64 x INT4)     16b activation (4 x UINT4)
                       │                   from the input GRF select
                 ┌─────▼─────┐                        │
     w_load_i ──>│  w_hold_q │ 256 FF                 │ broadcast
                 └─────┬─────┘                        │ to all PEs
       ┌───────────────┼───────────────┐              │
       │ 16b           │ 16b           │ 16b          │
  ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐        │
  │   PE 0   │    │   PE 1   │ .. │  PE 15   │<-------┘
  ├──────────┤    ├──────────┤    ├──────────┤
  │ 4x mul   │    │          │    │          │  stage 1
  │ 4:2 +CPA │    │          │    │          │
  │ psum_q   │10b │          │    │          │  ---- register ----
  │ acc add  │    │          │    │          │  stage 2 (24b chain)
  └────┬─────┘    └────┬─────┘    └────┬─────┘
       │ 32b           │ 32b           │ 32b
       └───────────────┴───────────────┘
                       │ 512b
             ┌─────────▼──────────┐
             │   acc_regfile      │  4 entry x 16 lane x 32b
             │  rd / drain / wr   │  accumulate read + drain read
             └─────────┬──────────┘
                       │ 512b
                  drain_data_o
```

- 매 command: bank 에서 **256b = signed INT4 weight 64 개**, input 측에서
  **unsigned INT4 activation 4 개**.
- weight 64 개 = (16 output channel) × (K 방향 4 개). activation 4 개는 16 개 PE
  전체에 broadcast.
- PE `i` 는 `acc[e][i] += Σ_j w[i][j]·a[j]` 를 계산한다.

### 3.2 PE 내부

| 단 | 내용 | 폭 |
|---|---|---|
| stage 1 | `spinquant_mul_s4u4` × 4 | 4b×4b → 8b |
| stage 1 | `spinquant_compressor_4to2` 1 레벨 | 10b |
| stage 1 | CPA 1 개 → `psum_q` | 10b |
| stage 2 | `acc_cur + sext(psum)` | 24b chain |
| stage 2 | sign extension → 누산기 파일 | 32b |

곱셈기 총 64 개, 누산 가산기 lane 16 개 — P3-LLM PCU 와 **완전히 같은 개수**다.
차이는 곱셈기 한 개의 크기와, 그 주변에 아무것도 없다는 것이다.

### 3.3 누산기 파일

`spinquant_acc_regfile`, 4 entry × 16 lane × 32b. 읽기 포트 두 개:

- **accumulate read** (`rd_sel_i`) — stage 2 의 read-modify-write.
  write 는 cycle 을 끝내는 edge 에 실리고 다음 cycle 의 read 가 그것을 보므로,
  같은 entry 로 연속 MAC 을 해도 bypass 가 필요 없다.
- **drain read** (`drain_sel_i`) — 비파괴 읽기. accumulate read 와 분리되어
  있으므로 **MAC-drain 이 compute cycle 을 밀어내지 않는다.**

경계 안에 두는 이유는 RaBiT 과 같다: k sweep 은 row-buffer streak 의 첫 RD 부터
끝의 MAC-drain 까지 모든 부분합을 상주시켜야 하므로 버퍼가 아니라 산술 상태다.

### 3.4 파이프라인과 2-pump

**2 stage.** command 하나당 1 cycle, backpressure 없음, stall 없음.

```
cycle c    w_load_i 가 "다음" MAC 이 쓸 beat 를 잡고,
           mac_valid_i 가 w_hold × a_q4_i 를 곱해 reduce 한다
cycle c+1  선택된 누산기 entry 를 읽어 더하고 되쓴다
cycle c+2  mac_done_o = 1, drain_data_o 가 갱신된 entry 를 보인다
```

핵심은 **cycle c 의 load 가 cycle c 를 끝내는 edge 에만 반영된다**는 점이다.
따라서 같은 cycle 에 나간 MAC 은 여전히 이전 beat 를 본다. 여기서 두 가지가
공짜로 나온다.

1. beat 가 매번 바뀌는 스트림에서도 load 를 MAC 보다 한 slot 앞세우면 **거품
   없이 1 MAC/cycle** 이 유지된다.
2. **tCCD_S 2-pump**: 두 번째 pump 에서 `w_load_i` 를 내리고 `a_q4_i` 와
   `acc_entry_i` 만 바꾸면, 한 번 latch 된 beat 가 서로 다른 activation set 두
   개를 연속 cycle 에 먹인다. 별도 hold 카운터가 필요 없다.

**acc entry 할당 규약** (4 entry = 2 input row × 2 output-channel group):

| entry | input row | output-channel group |
|---:|---:|---:|
| 0 | 0 | 0 |
| 1 | 1 | 0 |
| 2 | 0 | 1 |
| 3 | 1 | 1 |

`W_LATCH = 0` 구성은 256b hold register 를 경계 밖으로 뺀다 (P3-LLM · SIMD 행이
weight 를 받는 방식). 이때 2-pump 는 bank/GRF 가 beat 를 두 cycle 유지하는 것으로
성립하며 기능은 동일하다 — 같은 testbench 가 두 구성 모두를 통과한다.

---

## 4. 인터페이스

```systemverilog
module spinquant_pcu_top #(
    parameter int NPE         = 16,   // output channels per beat
    parameter int NWAY        = 4,    // k-elements per output channel per beat
    parameter int NENTRY      = 4,    // accumulator entries
    parameter int ACC_W       = 32,   // architectural accumulator width
    parameter int ACC_CHAIN_W = 24,   // carry chain actually implemented
    parameter int W_LATCH     = 1,    // bank read latch inside the boundary
    parameter int Q_W         = 4
) (...);
```

| 포트 | 방향 | 폭 | 뜻 |
|---|:--:|---:|---|
| `w_load_i` | in | 1 | 이 cycle 의 `w_beat_i` 를 hold register 에 잡는다 |
| `w_beat_i` | in | 256 | bank RD 1 회분, `[(i*4+j)*4 +: 4] = W_q[ch i][k j]` |
| `mac_valid_i` | in | 1 | 이 cycle 에 MAC 을 실행한다 |
| `a_q4_i` | in | 16 | `[j*4 +: 4] = A_q[k j]`, 16 PE 에 broadcast |
| `acc_entry_i` | in | 2 | 누산 대상 entry |
| `acc_clear_i` | in | 1 | 더하지 말고 덮어쓴다 (k sweep 첫 beat) |
| `mac_done_o` | out | 1 | 2 cycle 뒤 누산 완료 |
| `drain_entry_i` | in | 2 | drain 포트가 볼 entry |
| `drain_data_o` | out | 512 | `[i*32 +: 32] = acc[drain_entry_i][ch i]` |
| `status_clr_i` | in | 1 | sticky overflow 해제 |
| `ovf_sticky_o` | out | 1 | 24-bit chain overflow 를 본 적 있다 |

합성 wrapper (`spinquant_pcu_synth.sv`):

| top | chain | read latch | 용도 |
|---|---|:--:|---|
| `spinquant_pcu` | 24b | 안 | **대표 구성** |
| `spinquant_pcu_acc32` | 32b | 안 | chain 단축의 가격 |
| `spinquant_pcu_nolatch` | 24b | 밖 | P3-LLM·SIMD 와 같은 경계 |
| `spinquant_blk_pe` | — | — | PE 1 개 단독 (면적 분해) |
| `spinquant_blk_acc` | — | — | 누산기 파일 단독 (면적 분해) |

---

## 5. DRAM bank data mapping 과 command 순서

RTL 자체는 mapping 을 모른다. 아래는 microkernel 과 testbench 가 공유하는 전제다.

### 5.1 weight 배치

Weight `[N_out × K]` 를 (16 output channel) × (4 K-elem) = 64 개 단위로 256b
beat 에 채운다.

```
beat b, 16 output channel group g:
    w_beat[(i*4 + j)*4 +: 4] = W_q[16g + i][4b + j]        i<16, j<4
```

같은 16-channel group 의 K 스트림을 **한 DRAM row 에 연속 배치**한다. 그러면
ACT 1 회 뒤 RD 연타로 row-buffer hit 만 내면서 K 를 완주할 수 있다.

### 5.2 activation 배치

Input GRF entry 1 개 = 256b = `A_q` 64 개 = beat 16 개분 (K = 256). entry 4 개
상주 시 K = 1024 분을 커버한다. GRF entry 안에서 어느 4 개를 뽑을지가
`a_q4_i` 앞의 select 이며, 그 select 는 경계 밖이다.

### 5.3 command 순서

기본 (1-pump):

```
[ACT row]
repeat K/4 times:
    [RD beat_k]                       → w_load_i = 1
    [MAC acc0, a_sel_k]               → mac_valid_i = 1, acc_clear_i = (k == 0)
[MAC-drain acc0]                      → drain_entry_i = 0, drain_data_o 읽기
[PRE]
```

RD 와 MAC 은 같은 cycle 에 겹칠 수 있다 (3.4 의 load-한-slot-앞세우기). 따라서
K/4 cycle + 파이프라인 2 cycle 이면 k sweep 이 끝난다.

2-pump (tCCD_S, batch-2 또는 GQA 두 input row):

```
[ACT row]
repeat K/4 times:
    [RD beat_k]                       → w_load_i = 1, MAC(acc0, a_row0[k]) 동시
    [MAC acc1, a_row1[k]]             → w_load_i = 0  ← 같은 beat 재사용
[MAC-drain acc0], [MAC-drain acc1]
[PRE]
```

beat 당 RD 1 회, MAC 2 회. bank 는 tCCD_L 로 읽고 연산기는 tCCD_S 로 돈다.

---

## 6. 검증

golden model 은 순수 파이썬 정수 연산이다
([verif/models/spinquant_model.py](../verif/models/spinquant_model.py)) — host
부동소수점이 한 군데도 없으므로, 일치는 시뮬레이터의 FPU 가 아니라 설계에 대한
진술이다. testbench 가 `[16 × K]` weight tile 을 5 절의 mapping 대로 beat
스트림으로 자르고, microkernel 이 낼 command 순서를 cycle 단위로 재현한다.

| 시나리오 | 무엇을 확인하나 |
|---|---|
| single beat | 단일 beat = 순수 내적. K=4 GEMV reference 와 bit-exact |
| K-loop | K = 128 / 1024 / 14336 누산, row-buffer streak 모사 |
| 2-pump | 한 beat 로 두 input row, entry 0/1. load 없는 cycle 에는 beat 버스에 난수를 실어 hold register 를 검증 |
| entry interleave | 독립된 k sweep 4 개를 entry 4 개에 교대 |
| drain / acc_clear | clear 가 entry 를 다시 시작시키는지, idle cycle 이 보존되는지, reset 이 전 entry 를 지우는지 |
| worst case | w 전부 -8, a 전부 15, K = 14336 → -1,720,320, overflow 0 |
| overflow | 지원 범위 밖까지 밀어 sticky flag 와 wrap 값을 확인, `status_clr_i` 해제 |
| random | 난수 command 대량, entry·clear·idle gap 무작위 |

세 구성 (`spinquant_pcu`, `_nolatch`, `_acc32`) 이 같은 시나리오를 모두 통과한다.
PE 단독 (`spinquant_pe`) 은 (weight, activation) 코드쌍 256 개 전수 + way 별
one-hot + 누산 경계 + 난수, 누산기 파일 단독 (`spinquant_acc`) 은 두 읽기 포트의
독립성을 확인한다.

**harness 가 실제로 잡는지**를 mutation 으로 확인했다:

| 변이 | 결과 |
|---|---|
| hold register 를 load 시 투명하게 | 8 개 중 5 개 실패 |
| write entry select 를 파이프라인하지 않음 | 8 개 중 7 개 실패 |
| carry chain 을 24 → 21 bit | worst-case·overflow 시나리오 실패 |

---

## 7. 결과 요약

Nangate45 typical, Yosys 0.52 (ABC area mode) + OpenROAD, 논리 합성까지.
상세는 [results/designs/spinquant_area_report.md](../results/designs/spinquant_area_report.md).

| | 면적 (um²) | baseline 대비 | MAC/cy | um²/MAC | setup slack |
|---|---:|---:|---:|---:|---:|
| HBM-PIM FP16 SIMD 16 lane (baseline) | 60,176 | 1.000x | 16 | 3,761 | — |
| P3-LLM PCU (FP4/FP8, 16 PE × 4) | 71,287 | 1.185x | 64 | 1,114 | — |
| **SpinQuant W4A4 PCU (16 PE × 4)** | **32,376** | **0.538x** | **64** | **506** | **+0.88 ns @ 2.0 ns** |

- **면적 제약 충족**: baseline 의 53.8 %, 27,800 um² (46.2 %) 절감.
- 같은 토폴로지의 P3-LLM PCU 대비 **0.454x**.
- tCCD_S (2.0 ns) 를 slack **+0.88 ns** (44 % 여유) 로 만족한다. worst path 는
  `a_q4_i → psum_q` 로, 곱셈기와 4:2 tree 를 지나는 stage 1 경로다.
- 경계 안 두 항목의 가격: bank read latch 1,253 um² (3.9 %), 24-bit chain 은
  32-bit 대비 8,014 um² (19.8 %) 절감.

---

## 8. 처리량을 더 올릴 여지

정수 연산기라 곱셈기는 거의 공짜다. 그래서 MAC/cycle 을 묶는 것은 산술이 아니라
**피연산자 공급**이다. 실측 두 개가 그것을 못박는다.

**산술은 제약이 아니다.** 같은 top 을 주기만 바꿔 합성하면 데이터패스는
**1.0 ns (1 GHz), tCCD_S 의 2 배**에서 닫힌다 (slack +0.08 ns; 0.8 ns 에서 -0.08
로 처음 깨진다). 면적도 baseline 의 53.8 % 만 쓴다. 주파수로도 면적으로도 여유가
있다 — `./run_spinquant.sh fmax`.

**벽은 weight 대역폭이다.** bank 는 column command 하나당 256 bit 를 tCCD_L 마다
준다 (docs/rabit_pcu_spec.md 가 고정한 convention). PCU clock 이 tCCD_S = tCCD_L/2
이므로 지속 공급량은 **cycle 당 128 bit = INT4 weight 32 개**다.

```
지속 MAC/cycle = (cycle 당 weight bit / 4) x R
R = 한 weight beat 를 재사용하는 activation row 수 (spatial x temporal)
```

대표 구성은 R = 2 (2-pump 시간 다중화) → 지속 64 MAC/cycle 로 **공급과 정확히
맞아 있다**. R 을 늘리는 것 외에 지속 처리량을 올리는 방법이 없고, R 을 늘리면
그 row 수만큼 누산기가 더 필요하다 — 이 설계에서 가장 비싼 자원이다.

RTL 은 `NROW` (한 beat 를 공간적으로 공유하는 activation row 수) 파라미터로 이
축을 지원한다. 기본값 1 이라 대표 구성은 그대로다 (netlist 동일: 32,375.924 um²,
25,843 cell, 1,960 DFF).

| 구성 | mult | peak MAC/cy | 필요 R | batch-1 지속 | 면적 (um²) | baseline 대비 | um²/MAC |
|---|---:|---:|---:|---:|---:|---:|---:|
| **대표** (16 PE × 4, 1 row, 4 entry) | 64 | 64 | 2 | 32 | 32,376 | 0.538x | 506 |
| **`r2e2`** (2 row spatial × 2 entry) | 128 | **128** | 4 | 32 | **46,813** | **0.778x** | **366** |
| `r2` (2 row spatial × 4 entry) | 128 | 128 | 4 | 32 | 61,828 | 1.027x | 483 |
| `r4` (4 row spatial × 4 entry) | 256 | 256 | 8 | 32 | 124,290 | 2.065x | 486 |
| `w512` (32 PE × 4, 512b beat) | 128 | 128 | 2 | 64 | 64,345 | 1.069x | 503 |

전 구성이 tCCD_S 를 slack +0.86 ns 이상으로 만족한다 — 확장이 공간적이라 임계
경로가 그대로이기 때문이다.

**결론.**

1. **decode (batch 작음) 를 겨냥한다면 대표 구성이 이미 균형점이다.** 곱셈기를
   늘려도 지속 처리량은 그대로고 면적만 는다. batch-1 만 보면 현재 64 개도 2 배
   과잉이라 절반이 논다.
2. **batch (또는 chunked prefill token) ≥ 4 를 주장할 수 있다면 `r2e2` 가 유일한
   무료 점심이다.** 지속 128 MAC/cycle 을 면적 제약 안(0.778x)에서 내고 um²/MAC
   도 506 → 366 으로 개선된다. input row 를 entry 축(시간)에서 lane 축(공간)으로
   옮기고 entry 를 4 → 2 로 줄이면 누산기 총 bit 수가 그대로이기 때문이다
   (DFF 2,118 vs 1,960). 대가는 output-channel group interleave 포기.
3. **그 이상은 안 된다.** 누산기 파일이 R 에 선형이라 `r2`(interleave 유지)부터
   이미 baseline 을 넘고 `r4` 는 2 배를 넘는다.
4. **batch-1 천장을 올리는 유일한 축은 beat 폭이다** (`w512`). 다만 PCU 에 column
   대역폭을 2 배로 준다는 **아키텍처 전제**가 따로 필요하고 (bank pair /
   pseudo-channel), 그러면 이 표의 다른 행과 같은 전제 위에 있지 않게 된다.

상세 실측은
[results/designs/spinquant_area_report.md](../results/designs/spinquant_area_report.md)
4 절. 검증은 다섯 구성 모두 같은 testbench 로 돈다
(`make TEST=spinquant_pcu_r2e2` 등).

---

## 9. 남은 것 (제안)

- **P1. drain 출력 등록.** 현재 `drain_data_o` 는 누산기 flop 에서 조합으로
  나온다 (P3-LLM `acc_out` 과 같은 방식이라 비교 정합성이 있다). 실 시스템에서
  bank/GRF 로 되쓰는 경로가 길면 1 단 register 를 넣을 수 있고, 512 FF ≈
  2,300 um² 를 쓴다. 지금은 여유가 충분하므로 필요 근거가 생길 때 넣는다.
- **P2. NENTRY 축소.** 누산기 파일은 단독 합성 21,171 um² 로 flat top 의 65 %
  에 해당한다 (flat 안에서는 공유 mux 와 flop 병합으로 그보다 싸다). GRF 해석을
  2 entry 로 바꾸면 2-pump 는 유지한 채 크게 줄지만, 그것은 아키텍처 전제를
  바꾸는 일이므로 스펙 변경 없이는 손대지 않는다.
- **P3. 전력.** 다른 행과 같은 한계가 있다 — vectorless `-global 0.20` 은
  활성도를 설계마다 구분하지 않아 셀 수에 거의 비례한다 (README 4 절). 다만
  이 설계는 곱셈기를 가진 전 행 중 pJ/MAC 이 가장 낮다 (0.52).
