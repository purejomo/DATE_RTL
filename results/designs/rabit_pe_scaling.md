# RaBiT PE 수 확장 (8 -> 16 PE) 검토

- 생성: `synth/build_rabit_pe_scaling.py` (`results/area.csv` 기반)
- 합성: `cd synth && ./run_rabit.sh`

**결론: 16 PE 는 하지 말 것.** 면적은 baseline 을 넘고 sustained throughput 은
늘지 않는다. 늘리려면 PE 가 아니라 **stripe 폭** (`NGROUP`) 을 건드려야 한다 —
같은 이득이 훨씬 싸다.

## 1. 8 PE 는 파라미터가 아니라 결과다

```
WORD_W = NIN x NOUT_PER_WORD x NPATH = 16 x 8 x 2 = 256 bit = column word 하나
```

`NIN=16` 은 GRF entry 포맷이, `NPATH=2` 는 RaBiT 2-bit 정의가, 256 bit 는
DRAM 이 정한다. 셋이 고정이면 `NOUT_PER_WORD = 256/(16x2) = 8` 하나만 남는다.

## 2. sustained throughput 은 PE 수와 무관하다

스케줄은 k chunk 마다 **2 WR + NGROUP RD** 다 (`tools/pack_rabit.py` 가
`n_rd == 2*n_wr` 로 강제). WR 도 column command 를 먹는다 (`rabit_pcu_top.sv`
가 `!(wr_valid_i && rd_valid_i)` 를 assert). stripe 폭을 S 라 하면 k chunk 당
column command `2 + S/8`, cycle 은 그 2배, 곱은 `32S` 이므로

```
sustained = 32S / (2 x (2 + S/8)) = 128 x S / (S + 16)   products/cycle
```

**NOUT (PE 수) 가 소거된다.** throughput 은 상주 stripe 폭만의 함수다.

| 구성 | stripe | sustained p/cy | GMAC/s @250MHz | duty |
|---|---:|---:|---:|---:|
| 8 PE, NGROUP 4 | 32 | 85.33 | 21.33 | 66.7 % |
| 8 PE, NGROUP 8 | 64 | 102.40 | 25.60 | 80.0 % |
| 16 PE, NGROUP 2 | 32 | 85.33 | 21.33 | 66.7 % |
| 16 PE, NGROUP 4 | 64 | 102.40 | 25.60 | 80.0 % |
| (상한: WR 이 공짜라면) | inf | 128.00 | 32.00 | 100 % |

- **16 PE NGROUP 2 == 8 PE NGROUP 4** (둘 다 stripe 32, 85.33 p/cy)
- **16 PE NGROUP 4 == 8 PE NGROUP 8** (둘 다 stripe 64, 102.4 p/cy)

비교표의 `MAC/cy = 128`, `32.0 GMAC/s` 는 **peak** 이다 (RD 중일 때 값). 다른
행도 같은 규약이라 행간 비교는 유효하나, RaBiT 의 실제 duty 는 현행 구성에서
4/6 = 66.7 %, sustained 는 21.33 GMAC/s 다.

## 3. 측정된 면적

Nangate45, 4.0 ns, 다른 행과 동일 조건. baseline = `compute_hbmpim_250`
60,176 um2.

| 구성 | label | 면적 [um2] | baseline 대비 | DFF | sustained |
|---|---|---:|---:|---:|---:|
| 8 PE NGROUP 4 — 현행 | `rabit_pcu_250` | 45,254 | 0.752x | 2208 | 85.3 p/cy |
| 8 PE NGROUP 8 — stripe 2배 | `rabit_pcu_g8_250` | 60,711 | 1.009x **초과** | 4259 | 102.4 p/cy |
| 8 PE NGROUP 8 — stripe 2배 + MANT_W 10 | `rabit_pcu_g8_m10_250` | 56,906 | 0.946x | 4243 | 102.4 p/cy |
| 16 PE NGROUP 2 — PE 2배, stripe 유지 | `rabit_pcu_16pe_250` | 69,937 | 1.162x **초과** | 2341 | 85.3 p/cy |
| 16 PE NGROUP 4 — PE 2배 + stripe 2배 | `rabit_pcu_16pe_g4_250` | 86,502 | 1.437x **초과** | 4392 | 102.4 p/cy |

읽는 법:

- **16 PE 는 어느 쪽으로 가도 baseline 초과.** stripe 를 유지해도 (NGROUP 2)
  PE array 만으로 넘고, 같이 늘리면 누산기까지 2배가 된다.
- **8 PE + NGROUP 8 = 16 PE + NGROUP 4 = 102.4 p/cy.** 같은 stripe 64 를 훨씬
  싸게 사는 것이다.
- **`MANT_W` 10 을 함께 쓰면** stripe 를 2배로 하고도 baseline 아래다.

## 4. 측정 노이즈 바닥 — 1 % 이하 차이는 해석하지 말 것

같은 RTL 을 소스 파일 **순서만 바꿔** 합성해도 면적이 최대 0.9 % 움직인다 —
ABC 가 drive strength 를 다르게 고르기 때문이다.

- `rabit_pcu`: 45,253.5 vs 45,645.9 (cell 수는 동일)
- `rabit_pcu_16pe_g4`: 85,237.6 vs 86,501.9

**행 사이 1 % 미만 차이는 설계 차이로 읽지 말 것.** 이 표의 값은 전부
`run_rabit.sh` 의 정규 소스 순서로 측정했다.

## 5. NGROUP 을 올리는 데 드는 비용 (면적 밖)

`NGROUP 4 -> 8` 은 스위치 하나가 아니다.

- **`tools/pack_rabit.py`**: `NGROUP`, `OUT_PER_STRIPE`, 그리고
  `K_CHUNKS_PER_ROW = COLS_PER_ROW // NGROUP` 이 8 -> 4 로 줄어 **같은 k sweep
  에 row activation 이 2배**가 된다. PCU 밖 비용이라 여기서 값을 매길 수 없다 —
  +20 % 를 순증으로 주장하면 안 된다.
- **CA 배치**: `{k_chunk, out_group[2:0]}` 로 변경 (docs 3장).
- **회귀**: `verif/models/rabit_model.py` 의 `NGROUP` 상수, 테스트 추가.

## 6. 16 PE 가 의미를 갖는 유일한 조건

연산이 아니라 공급을 늘려야 한다 — column word 를 512 bit 로 넓히거나, bank
두 개가 PCU 하나를 먹이거나, column 간격을 절반으로 줄이거나. 전부 bank
인터페이스 가정을 바꾸는 일이라 스펙 9장 밖이다.

**짚어둘 비대칭**: baseline `hbmpim_fp16_pcu_16_lane` 은 `i_a[255:0]` +
`i_b[255:0]` 로 **매 cycle** 256-bit column 하나를 받고, RaBiT 는 2 cycle 에
하나다. 즉 지금 표는 baseline 에 RaBiT 의 2배 column rate 를 주고 있다. 같은
rate 라면 16 PE 도 실제로 이득이 난다 (204.8 p/cy). 이 전제는 스펙이 정한
것이라 여기서 바꾸지 않았다.

