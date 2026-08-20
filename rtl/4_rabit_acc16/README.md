# 4_rabit_acc16

[`4_rabit`](../4_rabit)의 axis-2(acc16) 변형이다. 비교 3축 중 ②에 해당한다.

| 축 | 디렉토리 | 누산 |
|---|---|---|
| ① base | `4_rabit` | `ACC_W = 32`, raw 고정소수점 drain |
| ② acc16 | **이 디렉토리** | `ACC_W = 16`, 정렬 우측 시프트에서 RNE |
| ③ dequant_rne | `4_rabit_dequant_rne` | 32b 누산 → g 스케일 → binary16 RNE 출력 |

RTL 파일은 `4_rabit`의 사본이고, **바뀐 것은 `rabit_pcu_acc16.sv`의 wrapper
하나뿐**이다. 새 산술 로직은 없다.

- top: `rabit_pcu_acc16`
- `ACC_W = 16`, `MANT_W = 10`, `SHIFTER_EN = 1`, `SHIFT_RND = 1`

## 세 파라미터가 함께 움직이는 이유

- `ACC_W = 16` — 이 축의 정의.
- `MANT_W = 10` — **선택이 아니라 강제**다. `rabit_align_shift`가
  `ACC_W > PSUM_W`를 요구하고 `PSUM_W = MANT_W + 1 + clog2(16) = MANT_W + 5`
  이므로 `MANT_W = 12`면 `PSUM_W = 17 > 16`이라 elaboration이 죽는다
  (`SHL_MAX = ACC_W - PSUM_W`가 음수가 되어 실제로 검증됨). `MANT_W = 10`이면
  15 < 16 ✓. 이 조합은 `verif`의 `rabit_pcu_m10` 회귀가 이미 검증했다.
- `SHIFT_RND = 1` — `rabit_align_shift.sv`에 이미 있는 RNE 경로를 켠다.
  RaBiT는 정렬 우측 시프트가 곧 비트를 버리는 지점이므로, "매 누산마다 RNE"가
  **새 로직 없이** 얻어진다. 이것이 다른 두 acc16 설계와 비교 가능하게 만드는
  조건이다.

## 파생 폭

| 신호 | ① | ② |
|---|---|---|
| `cvt_blk_o` (`BLK_W = 16*(MANT_W+1)+6`) | 214 | 182 |
| `grf_blk_i` (`NPATH*BLK_W`) | 428 | 364 |
| `drain_data_o` (`DRAIN_W = NOUT_PER_WORD*ACC_W`) | 256 | 128 |

## 면적 논지

`rabit_acc_regfile`이 `NSLOT × NPE × ACC_W` = 8 × 8 × 32 = 2048b 에서 1024b로
줄어든다. 이 배열이 RaBiT 합성 경계 안의 최대 storage이므로 절감이 면적 표에
바로 잡힌다.

| 축 | 클록 | 면적 (µm²) | base 대비 |
|---|---:|---:|---:|
| ① base | 500 MHz 목표 | 45,254 | — |
| ② acc16 | 500 MHz 목표 | 32,209 | −28.8% |

두 행 모두 Nangate45, 2.0 ns constraint, ABC area mode로 합성했다. setup slack은
각각 −0.04 ns와 −0.09 ns라 500 MHz는 아직 timing-closed가 아니다.
