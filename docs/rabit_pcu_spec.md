# RaBiT 2-bit PIM 연산기 (PCU) 설계 명세

Bank-attached PIM 연산기. RaBiT 2-bit residual binarization 정밀도의
**projection layer GEMV 전용** 데이터패스이며, HBM-PIM (ISCA'21) 스타일
16-lane FP16 SIMD 연산부를 baseline 으로 삼는다.

- RTL: [rtl/4_rabit/](../rtl/4_rabit/)
- Packer: [tools/pack_rabit.py](../tools/pack_rabit.py)
- Golden model: [verif/models/rabit_model.py](../verif/models/rabit_model.py)
- 회귀: `cd verif && make TEST=rabit_pcu` (전체는 `make`)
- 합성: `cd synth && ./run_rabit.sh`
- 면적·타이밍 리포트: [results/designs/rabit_area_report.md](../results/designs/rabit_area_report.md)

---

## 1. 연산 정의

RaBiT 논문(식 3, 4)의 dual-scale binarization:

```
W_hat = sum_p g_p (x) B_p (x) h_p ,   B_p in {+1,-1}^(dout x din),  p = 1,2
y     = sum_p g_p (*) ( B_p (h_p (*) x) )
```

PCU 가 계산하는 것은 path 별 raw 부분합뿐이다.

```
A_p[j] = sum_k B_p[j][k] * u_p[k]
u_p[k] = h_p[k] * x[k]                (NPU 가 사전계산해서 fp16 으로 WR)
y[j]   = g_1[j]*A_1[j] + g_2[j]*A_2[j]  (NPU 가 dequant)
```

g 곱과 path 합산이 NPU 몫이므로 **PCU 안에 곱셈기는 0 개**다. weight 는 1 bit
이라 곱은 mantissa 의 부호 반전으로 끝난다.

### 역할 분담

| | 담당 | 합성 |
|---|---|:--:|
| `u = h (*) x` 사전계산, fp16 WR | NPU | X |
| fp16 -> 고정소수점 변환 | PCU `cvt_fp16_to_blk` | **O** |
| `sum_k B*u` 누산 | PCU `pe_array` + `acc_regfile` | **O** |
| `y = 2^E0 * (g1*A1 + g2*A2)` | NPU | X |

---

## 2. 수 표현

### 2.1 입력: binary16

```
code (s, exp, frac) = (-1)^s * sig * 2^(e_eff - 25)
sig   = {exp != 0, frac}        (11 bit)
e_eff = 1 if exp == 0 else exp
```

normal / subnormal / zero 모두 **정확**하다. 고정소수점 변환기는 flush 할 이유가
없으므로 DAZ/FTZ 를 쓰지 않는다 (baseline FP16 SIMD 와 다른 점).

### 2.2 GRF entry: block floating point

entry 16 개 원소를 한꺼번에 변환한다.

```
e_ent   = max_k e_eff[k]                                    (SHIFTER_EN = 1)
mant[k] = RNE( (sig[k] << LSH) >> (e_ent - e_eff[k] + RSH0) )
LSH     = max(0, MANT_W - 11),  RSH0 = max(0, 11 - MANT_W)
u[k]    = (-1)^sign[k] * mant[k] * 2^(e_ent - 14 - MANT_W)
```

저장 포맷 (`BLK_W` = 214 bit, input GRF entry 폭 256 bit 이내):

```
 213      208 207                                                    0
+-----------+------------------------------------------------------+
|  e_ent 6b |  {sign 1b, mant 12b} x 16   (lane 0 이 최하위)        |
+-----------+------------------------------------------------------+
```

MANT_W = 12 검산: 1.0 은 `sig = 1024`, `LSH = 1`, 정렬 shift 0 이므로
`mant = 2048`, 값은 `2048 * 2^(15-26) = 2^0` 이다.

`MANT_W < 11` 이면 반올림 자리올림이 `MANT_W` 폭을 1 코드 넘길 수 있다. 그 lane
은 `2^MANT_W - 1` 로 clamp 한다 (최대 1 ulp 손실).

### 2.3 누산기 스케일

```
psum        = sum_k (+/-1) * mant[k]          , PSUM_W = MANT_W + 1 + 4 = 17 bit
aligned     = psum <<  (e_ent - E0)   if e_ent >= E0     (saturating)
            = psum >>> (E0 - e_ent)   otherwise          (arithmetic, floor)
acc        += aligned                          , ACC_W = 32 bit (saturating)
A_p[j]      = acc * 2^(E0 - 14 - MANT_W)
```

`cfg_e0_i` (6 bit) 는 binary16 biased exponent 와 같은 도메인이다. **호스트는
E0 를 k sweep 전체의 max e_ent 로 잡아야 한다** — 그러면 정렬이 항상 우측
shift 가 되고 좌측 saturation 경로(`status_sticky_o[1]`)가 놀게 된다.
`tools/pack_rabit.py:choose_e0()` 가 그 값을 계산한다.

> 스펙 §1 의 `y = 2^E0 * (g1*A1 + g2*A2)` 는 위 식에서 유효 지수가
> `E0 - 14 - MANT_W` 라는 뜻이다. `cfg_e0_i` 자체는 fp16 exponent 도메인 값이고
> 상수 `-14-MANT_W` 는 NPU 가 흡수한다. → 열린 질문 **Q1**.

### 2.4 폭 산정

| 신호 | 폭 | 근거 |
|---|---:|---|
| `mant` | 12 | `MANT_W` |
| `term` (부호 적용) | 13 | `MANT_W + 1` |
| `psum` | 17 | `16 * 4094 = 65504 < 2^16`, 부호 포함 17 bit 로 정확 |
| 4:2 tree | 17 | modulo `2^17`. 참값이 17 bit 에 들어가므로 wrap 이 상쇄된다 |
| 좌 shift 최대 | 15 | `ACC_W - PSUM_W`. 이 범위 안이면 overflow 가 **불가능**하므로 데이터 overflow 검출기 없이 shift 량만 clamp 하면 된다 |
| 우 shift 최대 | 17 | `>>> 17` 이 이미 극한값(양수 0, 음수 -1) |
| `acc` | 32 | 스펙 |

---

## 3. Weight word 포맷과 DRAM 매핑

### 3.1 Column word (256 bit)

한 word = **16 input x 8 output x 2 path**.

```
bit[j*32 + p*16 + k] = B_(p+1)[out j][in k]     j=0..7, p=0..1, k=0..15
값 매핑: 0 -> +1, 1 -> -1
```

RaBiT GPU 커널의 packing 과 동일하다 (논문 부록 E.1: *"each group of 32
columns is mapped to a uint32_t, with +1 -> 0 and -1 -> 1"*). 덕분에 PE j 는
`word[j*32 + p*16 +: 16]` 라는 **연속 slice** 를 그대로 받으며 shuffle 이 없다.

```
 255                                                                   0
+--------+--------+--------+--------+ ... +--------+--------+
| j=7 p1 | j=7 p0 | j=6 p1 | j=6 p0 |     | j=0 p1 | j=0 p0 |
+--------+--------+--------+--------+ ... +--------+--------+
   16b      16b      16b      16b            16b      16b
   ^-- k=15..0
```

### 3.2 Column 주소

```
CA = { k_chunk_in_row, out_group[1:0] }
```

- 한 row 안에서 같은 `k_chunk` 의 `out_group` 0..3 (= 32 output) 이 연속 column
- 그 다음 column 부터 다음 `k_chunk`
- row 가 끝나면 같은 32-output stripe 의 다음 k 구간으로 이어진다 (누산기 상주)
- stripe (32 output) 의 전체 k sweep 이 끝나야 다음 stripe 로 이동

`COLS_PER_ROW = 32` 기준으로 row 하나가 `32/4 = 8` k_chunk = 128 input 을 덮는다.
din = 4096 이면 stripe 당 32 row, dout = 4096 이면 128 stripe.

```
row r      : [k0,og0][k0,og1][k0,og2][k0,og3][k1,og0] ... [k7,og3]
row r+1    : [k8,og0] ...                                          (같은 stripe)
...
row r+31   : [k248,og0] ...                            (stripe 의 k sweep 끝)
row r+32   : 다음 stripe 의 k0
```

bank 간에는 **dout 축 partition** (bank 마다 다른 stripe). RTL 에는 영향이 없고
`tools/pack_rabit.py:address_of()` 의 주소 생성에만 나타난다.

---

## 4. Dataflow 와 타이밍

### 4.1 2-pump

PCU clock 은 tCCD_S 기준이고 column command 하나당 **2 cycle** 을 쓴다.

```
cycle 0 (pump 0): word 의 path-1 bit 8x16  -> 8 PE -> acc[og][*][path0] RMW
cycle 1 (pump 1): word 의 path-2 bit 8x16  -> 8 PE -> acc[og][*][path1] RMW
```

pump p 는 path-p bit plane 을 path-p **입력 entry** 와 짝짓는다. 즉
`A_1` 은 `(B_1, u_1)`, `A_2` 는 `(B_2, u_2)` 로만 만들어진다.

### 4.2 데이터패스

```
   WR (fp16 x16, 256b)
        |
        v
 +----------------+   blk {e_ent, sign/mant x16}    +-------------+
 | cvt_fp16_to_blk| ------------------------------> | input GRF   |
 +----------------+                                 | 4 entry     |  <- 합성 밖
   [합성 포함]                                       +------+------+
                                                            | grf_blk_i
   RD word 256b                                             | (u1, u2)
        |                                                   |
        |     +--------- path_sel (pump) --------+          |
        v     v                                  v          v
   +--------------------+                  +---------------------+
   | word slice per PE  |                  | block select (2:1)  |
   |  [j*32 + p*16 +:16]|                  |  -> mant bus, e_ent |
   +---------+----------+                  +-----+---------+-----+
             | b_bits x8                          | blk_mant | e_ent
             v                                    v          v
   +-------------------------------------------------+   shift_c = e_ent - E0
   | pe_array : rabit_pe x 8                         |        |
   |   sign XOR -> 4:2 tree(16) -> CPA -> [psum_q]   | <------+ (shift_q)
   |   -> align shift -> 32b saturating add          |
   +----------------+--------------------------+-----+
        acc_cur_i   ^                          | acc_next_o
                    |                          v
              +-----+--------------------------------+
              | acc_regfile  8 slot x 8 PE x 32b     |  [합성 포함]
              |   slot = {out_group, path}           |
              +-------------------+------------------+
                                  | drain_data_o 256b
                                  v
                            DRAM bank writeback        <- 합성 밖
```

### 4.3 파이프라인과 2-pump 타이밍

```
stage A (1 cycle) : bit/entry 선택 -> sign XOR + carry 보정 -> 4:2 tree -> CPA -> psum_q
stage B (1 cycle) : barrel shift (e_ent - E0) -> acc read -> 32b saturating add -> acc write
```

RD 두 개를 연속으로 넣었을 때 (word W, word X):

```
cycle       0     1     2     3     4
rd_valid    W     W     X     X     .
rd_ready    0     1     0     1     0        <- 마지막 pump 에서만 1
stage A     W.p0  W.p1  X.p0  X.p1  .
stage B     .     W.p0  W.p1  X.p0  X.p1
acc write   .     W.p0  W.p1  X.p0  X.p1     <- slot {og_W,0} {og_W,1} ...
rd_done     .     .     W     .     X
```

지연 2 cycle, throughput 1 word / 2 cycle. 같은 slot 에 연속으로 써도 stage B
안에서 read-modify-write 가 끝나므로 hazard 가 없다. word W 의 두 pump 는 서로
다른 slot (path 0 / path 1) 을 건드리므로 그 사이에도 충돌이 없다.

### 4.4 명령 스케줄

16-input chunk 단위로 testbench(실제로는 CRF)가 생성한다.

```
WR u1(k) -> WR u2(k) -> RD og0 -> RD og1 -> RD og2 -> RD og3 -> (다음 k)
```

WR:RD = 2:4. stripe 의 k sweep 이 끝나면 group 0..3 을 drain 한다.

GRF entry 는 더블버퍼다: chunk c 는 pair `c % 2` 를 쓰므로 entry {0,1} 과 {2,3}
이 번갈아 쓰인다.

### 4.5 누산기 배열

```
64 x 32b FF = 4 group x (8 out x 2 path)
slot = { out_group[1:0], path }        -> 8 slot x 8 PE
```

RD 의 `out_group` 이 group 을 고르고, 한 RD 동안 그 group 만 RMW 된다.
`drain` 은 group 단위로 `32b x 8` (= 256 bit, column word 한 개 폭) 을 path 0,
path 1 순서로 내보내며 내보낸 slot 을 그 자리에서 0 으로 지운다.

drain 은 누산기의 단일 read/write port 를 compute 와 공유한다. 그래서
**파이프라인이 빈 뒤에만** 시작할 수 있고, drain 중에는 `rd_ready_o` 가 내려간다.
동시 요청이 오면 drain 이 이긴다 — RD 쪽은 어차피 valid 를 유지하고 있으므로
drain 이 끝나는 즉시 처리되어 어느 쪽도 굶지 않는다.

---

## 5. 모듈 계층

```
rabit_pcu_top
 |- rabit_cvt_fp16_blk   convert-on-write: fp16 x16 -> {sign,mant12} x16 + e_ent
 |- rabit_pe (x8)        sign XOR/negate -> 4:2 tree(16-way) -> CPA -> shift -> 32b add
 |   |- rabit_compressor_4to2 (x7)
 |   |- rabit_align_shift
 |- rabit_acc_regfile    64 x 32b FF, group RMW port + drain port   [합성 포함]
 |- rabit_pcu_ctrl       2-pump 시퀀싱, group select, drain FSM, saturation flag

rabit_pcu_synth.sv       합성용 wrapper (파라미터 고정)
```

`rabit_pcu_top` 은 이미 input GRF / CRF 를 경계 밖에 두므로 그 자체가 합성
대상이다. wrapper 는 구성별로 이름을 고정하는 역할만 한다.

---

## 6. Top 포트

`rabit_pcu_top #(MANT_W=12, SHIFTER_EN=1, NOUT_PER_WORD=8, NPATH=2)` 기준.

### 6.1 클록 · 설정

| 포트 | 방향 | 폭 | 설명 |
|---|:--:|---:|---|
| `clk` | in | 1 | PCU clock (= tCCD_S / 2) |
| `rst_n` | in | 1 | 동기 reset, active low |
| `cfg_e0_i` | in | 6 | 기준 지수 E0. fp16 biased exponent 도메인 |

### 6.2 Convert-on-write port (GRF 저장소는 외부)

| 포트 | 방향 | 폭 | 설명 |
|---|:--:|---:|---|
| `wr_valid_i` | in | 1 | WR 명령 |
| `wr_ready_o` | out | 1 | 항상 1 (변환기가 조합논리) |
| `wr_entry_i` | in | 2 | 대상 GRF entry |
| `wr_fp16_i` | in | 256 | fp16 x 16 |
| `cvt_we_o` | out | 1 | GRF write enable |
| `cvt_entry_o` | out | 2 | GRF write address |
| `cvt_blk_o` | out | 214 | `{e_ent, {sign,mant} x 16}` |

### 6.3 Compute port

| 포트 | 방향 | 폭 | 설명 |
|---|:--:|---:|---|
| `rd_valid_i` | in | 1 | RD 명령 |
| `rd_ready_o` | out | 1 | 마지막 pump 에서만 1 |
| `rd_group_i` | in | 2 | out_group |
| `rd_pair_i` | in | 1 | in_entry_sel: GRF entry pair |
| `rd_word_i` | in | 256 | column word |
| `grf_pair_o` | out | 1 | 2-pump 동안 유지되는 pair select |
| `grf_blk_i` | in | 428 | `{u2_blk, u1_blk}` |
| `rd_done_o` | out | 1 | 마지막 pump 가 누산기에 반영된 cycle |

**핸드셰이크 규칙**: `rd_valid_i` 와 payload (`rd_word_i`, `rd_group_i`,
`rd_pair_i`, `grf_blk_i`) 는 `rd_ready_o` 를 볼 때까지 유지해야 한다. PCU 는
valid 를 본 cycle 에 곧바로 pump 0 를 처리하고 마지막 pump 에서만 ready 를
올리므로, 이 규칙만 지키면 필요한 2 cycle 동안 데이터가 저절로 고정된다.
`rd_ready_o` 는 상태만의 함수라 인터페이스에 조합 루프가 없다.
위반은 `RABIT_ASSERTIONS` 로 잡힌다.

WR 과 RD 는 같은 column command slot 을 쓰므로 동시에 valid 일 수 없다 (assertion).

### 6.4 Drain port

| 포트 | 방향 | 폭 | 설명 |
|---|:--:|---:|---|
| `drain_req_i` | in | 1 | drain 요청 |
| `drain_group_i` | in | 2 | 대상 group |
| `drain_ready_o` | out | 1 | 파이프라인이 비었을 때만 1 |
| `drain_valid_o` | out | 1 | beat 유효 |
| `drain_group_o` | out | 2 | beat 의 group |
| `drain_path_o` | out | 1 | beat 의 path |
| `drain_last_o` | out | 1 | group 의 마지막 beat |
| `drain_data_o` | out | 256 | 32b x 8 (PE 0 이 최하위) |

### 6.5 Status

| 포트 | 방향 | 폭 | 설명 |
|---|:--:|---:|---|
| `status_clr_i` | in | 1 | sticky clear |
| `status_sticky_o` | out | 3 | `[0]` 32b 누산기 saturation, `[1]` 정렬 좌 shift saturation (E0 가 범위 밖), `[2]` convert clamp (SHIFTER_EN=0 에서만) |

---

## 7. 파라미터

| 파라미터 | 기본 | 의미 |
|---|---:|---|
| `MANT_W` | 12 | block mantissa 폭 |
| `SHIFTER_EN` | 1 | 0 이면 PE barrel shifter 를 없애고 변환 단계에서 global E0 로 정렬 |
| `NOUT_PER_WORD` | 8 | PE 개수 = word 가 덮는 output 수 |
| `NPATH` | 2 | residual path 수 = pump 수 |
| `NGROUP` | 4 | 누산기 group 수 (= out_group) |
| `ACC_W` | 32 | 누산기 폭 |
| `EXP_W` | 6 | e_ent / E0 폭 |
| `SHIFT_RND` | 0 | **스펙 외 옵션, 기본 비활성.** 우 shift 에 RNE 적용 (§10 제안 P1) |

`NIN` 은 16 으로 고정이다 — word 포맷과 GRF entry 폭이 정하는 값이지 노브가
아니다. 4:2 tree 도 그 형태로 고정되어 있고 elaboration 에서 검사한다.

검증과 합성의 기준 구성은 `MANT_W=12, SHIFTER_EN=1, NOUT_PER_WORD=8, NPATH=2`.

---

## 8. 검증

| 테스트 | top | 무엇을 확인하나 |
|---|---|---|
| `rabit_cvt` | `rabit_cvt_tb` | 반올림(RNE, tie-to-even), subnormal, max-exp 경계, 지수 spread, MANT_W 12/10 및 SHIFTER_EN 0 동시 |
| `rabit_align` | `rabit_align_tb` | 지수 정렬: shift 전 범위(-64..63) x 경계 psum, `SHIFT_RND` 0/1 동시 |
| `rabit_pe` | `rabit_pe` | 부호 조합 전수, one-hot lane, 최대/최소 partial, shift 경계(`+15/+16`, `-17/-18`), 누산기 saturation 양방향, `ce_i` hold |
| `rabit_acc` | `rabit_acc_regfile` | slot 격리, wr_en 무시, clear, read-modify-write 순서, reset |
| `rabit_pcu` | `rabit_pcu` | end-to-end GEMV (64 x 4096), golden model 대조 + 정확한 유리수 reference 대조 |
| `rabit_pcu_m10` | `rabit_pcu_m10` | 같은 것, MANT_W 10 |
| `rabit_pcu_noshift` | `rabit_pcu_noshift` | 같은 것, SHIFTER_EN 0 |
| `rabit_pcu_m10_noshift` | `rabit_pcu_m10_noshift` | 같은 것, 두 노브 동시 |

`rabit_pe` 와 `rabit_pcu*` 는 설계 자체의 assertion (`RABIT_ASSERTIONS`) 을 켜고
돈다. PE 의 assertion 은 4:2 tree 의 modulo 연산 결과를 매 cycle 정확한
정수합과 대조한다.

### 8.1 Golden model

`verif/models/rabit_model.py` 는 순수 파이썬 정수 연산이다 (다른 model 들과
같은 규칙). fp16 값은 모두 dyadic rational 이므로 `Fraction` 으로 **정확한**
reference 를 만들 수 있다 — `y_ref` 는 반올림이 없는 참값이고, 상대오차는
그것과의 차이다.

### 8.2 스케줄 위반

- **WR 전 RD**: input GRF 가 합성 경계 밖이라 RTL 이 알 수 없다. testbench 의
  `Bench._drive` 가 아직 쓰이지 않은 entry 를 읽는 RD 를 assertion 으로 막는다
  (AAM barrier 모델링).
- **drain 중 RD**: `rabit_pcu_ctrl` 의 assertion 3 개가 잡고, testbench 는
  drain beat 가 떠 있는 동안 `rd_ready_o` 가 0 인지 매 cycle 확인한다.
  `phase_drain_blocks_read` 가 실제로 경합을 만든다.

### 8.3 규모 조절

| 환경변수 | 대상 | 기본 |
|---|---|---|
| `RABIT_GEMV_DOUT` / `RABIT_GEMV_DIN` | end-to-end GEMV 크기 | 64 / 4096 |
| `RABIT_SEEDS` | 시드 목록 | `1,2,3` |
| `RABIT_CVT_ITERS`, `RABIT_ALIGN_ITERS`, `RABIT_PE_ITERS`, `RABIT_ACC_ITERS` | 랜덤 반복 | 4000 / 4000 / 3000 / 2000 |

`din` 은 Llama-2-7B projection 의 k 차원 그대로다. `dout` 은 stripe 를 복제할
뿐이라 줄였고, 4096x4096 · 11008x4096 전체 형상은
`tools/rabit_accuracy.py` 가 **RTL 과 대조가 끝난 같은 model** 로 돌린다.

---

## 9. 열린 질문

스펙에 없어서 임의로 정하지 않고 기본값 + 근거만 남긴 항목이다.

**Q1. `cfg_e0_i` 의 도메인.** 스펙의 dequant 식은 `y = 2^E0 * (g1*A1 + g2*A2)`
이지만, `e_ent - E0` 가 성립하려면 E0 는 fp16 biased exponent 도메인이어야 한다.
현재 구현은 그 도메인을 쓰고 출력 스케일이 `2^(E0 - 14 - MANT_W)` 다. NPU 가
상수 `-14-MANT_W` 를 흡수하면 된다. E0 를 미리 오프셋한 값으로 받기를 원하면
포트 의미만 바꾸면 된다 (게이트 변화 없음).

**Q2. 누산기 초기화.** 스펙은 drain 만 clear 로 규정한다. 따라서 stripe 를
시작하기 전에 반드시 drain (또는 reset) 이 선행해야 한다. RD 에 `acc_clear`
비트를 두는 방식은 넣지 않았다. 필요하면 알려달라.

**Q3. binary16 의 Inf/NaN.** `exp == 31` 을 특수 처리하지 않고 `e_eff = 31`
인 보통 수로 디코드한다. u 는 NPU 가 계산한 유한 텐서의 곱이라 PCU 가 보는
포맷에는 무한대가 없고, 특수 처리는 면적만 먹는다. 다만 한 lane 의 NaN 이
`e_ent` 를 31 로 끌어올려 같은 entry 의 다른 lane 을 0 으로 밀어내므로,
NPU 가 유한성을 보장해야 한다. testbench 는 이 동작을 명시적으로 검사한다.

**Q4. WR 과 RD 의 동시성.** 둘을 별도 ready/valid 포트로 두되 같은 cycle 에
동시 valid 는 금지했다 (column command 는 한 번에 하나라는 모델). 두 포트를
독립적으로 쓰고 싶다면 assertion 만 빼면 되고 데이터패스는 그대로다.

**Q5. `SHIFT_RND`.** 스펙이 "산술 shift" 라고 못박아 기본값은 0 (truncation)
이다. 스펙 외 옵션으로만 넣었지만 검증되지 않은 RTL 을 남기지 않으려고
`rabit_align` 테스트가 두 모드를 함께 돌린다. §10 P1 참고.

**Q6. 500 MHz 목표.** 250 MHz 에서는 slack +1.16 ns 로 여유가 크다. 500 MHz
에서는 합성 리포트상 -0.04 ns (2 %) 미달이고, critical path 는
`wr_fp16_i -> cvt_blk_o` 조합 경로다 (변환기가 GRF write port 에 직결이라
의도된 구조). 이 경로에 걸린 I/O delay 예산(입출력 각 20 %)을 빼면 순수 논리
지연은 약 1.25 ns 라 2.0 ns 주기 안에 들어간다. 더 확실한 마진이 필요하면
변환 출력을 1 단 register 하는 방식이 있는데, WR->GRF 지연이 1 cycle 늘어
AAM barrier 타이밍에 영향을 주므로 구현하지 않고 제안으로만 남긴다 (§10 P2).

---

## 10. 제안 (구현하지 않음)

스펙 §9 에 따라 대안은 기록만 한다.

**P1. 정렬 우 shift 의 RNE.** 스펙이 "산술 shift" 라고 못박은 결과 chunk 마다
평균 -0.5 LSB 의 **단방향** 편향이 쌓인다. din = 4096 이면 256 chunk 이므로
-128 LSB 다. 이 편향이 이 데이터패스 오차의 지배항이고, 그래서 오차가
`mean(E0 - e_ent)` 에 따라 커진다 — 입력 한 entry 의 지수가 튀어 E0 가 1 올라가면
모든 chunk 가 한 칸 더 잘린다.

din = 4096, dout = 64, MANT_W 12 에서 seed 별 실측:

| seed | E0 | mean(E0 - e_ent) | 산술 shift (기본) | RNE |
|---:|---:|---:|---:|---:|
| 1 | 16 | 0.46 | 7.97e-4 | 1.6e-4 |
| 2 | 17 | 1.42 | 3.81e-3 | 2.0e-4 |
| 3 | 16 | 0.46 | 7.61e-4 | 1.5e-4 |

**RNE 를 켜면 오차가 shift 깊이와 무관하게 평평해진다** (1.5~2.0e-4). 즉 지금
보이는 4.8 배 산포는 정밀도 손실이 아니라 순전히 편향이다. 비용은 PE 당 34-bit
barrel shifter 와 18-bit 증분 하나. `SHIFT_RND=1` 로 켤 수 있고 `rabit_align`
테스트가 두 모드를 함께 검증하지만, 스펙을 따라 기본값은 0 이다.

E0 가 max e_ent 로 잡히는 한 최악의 경우에도 양자화 오차(약 3e-1)의 1/70
수준이라 기본 구성 그대로도 문제는 없다. 다만 din 이 더 깊어지거나 활성값
분포의 꼬리가 길어지면 이 항이 먼저 커진다는 점은 알고 있어야 한다.

**P2. Convert 출력 register.** §9 Q6.

**P3. 좌 shift 범위 확장.** 지금은 좌 shift 를 `ACC_W - PSUM_W = 15` 로 clamp
하고 넘으면 saturate 한다. psum 이 작을 때는 더 큰 좌 shift 도 32 bit 에
들어가지만, leading-sign-bit counter 와 더 넓은 shifter 가 필요하다. 권장대로
`E0 = max e_ent` 로 두면 좌 shift 자체가 일어나지 않으므로 이득이 없다.
`status_sticky_o[1]` 이 이 조건 위반을 알려준다.

**P4. Path 별 E0 분리.** 지금은 두 path 가 같은 `cfg_e0_i` 를 쓴다. `u_1` 과
`u_2` 의 동적 범위가 크게 다르면 (h_1, h_2 스케일 차이) path 별 E0 가 유리할 수
있다. 포트 하나와 mux 하나가 추가된다.

---

## 11. 결과 요약

전체 수치는 [results/designs/rabit_area_report.md](../results/designs/rabit_area_report.md).

| 항목 | 값 |
|---|---|
| 면적 (250 MHz) | **45,254 um2** = baseline 16-lane FP16 SIMD 의 **0.752x** |
| 곱셈기 | **0 개** |
| 누산기 | 64 x 32b = 2,048 FF (합성 포함) |
| 타이밍 | 250 MHz slack +1.16 ns (MET) / 500 MHz -0.04 ns |
| PCU 상대오차 (MANT_W 12) | 7.6e-4 ~ 3.8e-3 (din 4096, `mean(E0-e_ent)` 에 따라) |
| 양자화 상대오차 | 약 3e-1 — PCU 오차보다 **두~세 자릿수** 크다 |

핵심은 마지막 두 줄이다. 고정소수점 데이터패스가 만드는 오차는 residual
binarization 자체의 오차보다 최소 두 자릿수 작으므로, 이 PCU 는 RaBiT 정확도에
사실상 영향을 주지 않으면서 baseline 면적의 3/4 로 동작한다.

PCU 오차의 산포(7.6e-4 ~ 3.8e-3)는 정밀도가 아니라 **정렬 우 shift 의 단방향
편향** 때문이다. 스펙이 지정한 산술 shift 를 그대로 구현한 결과이고,
§10 P1 에 측정값과 함께 정리했다. RNE 를 켜면 1.5~2.0e-4 로 평평해진다.

면적을 더 줄여야 할 때의 노브 순서:

1. `MANT_W` 12 -> 10: -3,157 um2 (-7.0 %), PCU 오차 7.9e-4 -> 3.3e-3
   (여전히 양자화 오차의 1/100)
2. `SHIFTER_EN` off: **효과 없음** (+523 um2). 쓰지 말 것.
3. group 수 / `ACC_W`: 누산기 배열이 전체의 큰 비중이지만 둘 다 스펙이
   정하는 값이라 변경은 dataflow 변경이다.

**P5. Stage A 입력 레지스터.** 지금은 `rd_word_i` 와 `grf_blk_i` 를 PCU 안에서
등록하지 않는다 — 2 cycle 동안 붙잡는 일은 bank 와 GRF 몫이고, 그 덕에 약
684 FF (~4,000 um2) 를 아꼈다. 대가는 변환기와 8 개 PE 의 4:2 tree 가 전부
primary input 에서 시작하는 조합 경로가 된다는 점이다. 두 가지 결과가 있다.

- vectorless 전력 추정이 그 논리 전체를 가정 활성도 0.20 으로 때린다.
  rabit 행 전력의 70.7 % 가 조합 논리로 잡히는 이유이고 (p3llm 은 stage 0 에서
  피연산자를 등록한다), 활성도를 전파시키는 추정 모델을 쓰면 이 구조가 특히
  불리하게 잡힌다.
- 실제 실리콘에서도 bank/GRF 쪽 glitch 가 compressor tree 로 그대로 전파된다.

입력을 등록하면 ~4,000 um2 가 늘어 49,000 um2 정도가 되는데 여전히 baseline
(60,176) 아래다. 스펙에 없는 구조 변경이라 구현하지 않았고, 전력이 실제
관심사가 되면 먼저 검토할 항목이다. 확정하려면 vectorless 가 아니라 동일
자극(VCD) 기반 측정이 필요하다.
