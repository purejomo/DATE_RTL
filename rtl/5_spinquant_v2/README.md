# SpinQuant v2

SpinQuant W4A4 PCU를 32 PE로 확장한 구성이다. 이 디렉터리의 RTL만 사용한다.

| 항목 | 값 |
|---|---|
| compute | 32 PE × 4 multiplier, 500 MHz |
| 입력 | signed INT4 weight 512 bit, unsigned INT4 activation 16 bit |
| accumulator | 4 entry × 32 PE × INT32, 24-bit carry chain |
| 출력 | 32 × INT32 = 1024 bit |
| 처리량 | 128 MAC/cycle, 64 GMAC/s |
| 합성 면적 | 64,345.400 µm² |
| 셀 / DFF | 51,673 / 3,912 |
| 69,000 µm² 예산 여유 | 4,654.600 µm² |

64 GMAC/s를 지속하려면 512-bit weight beat를 공급할 bank pair 또는 동등한 대역폭이
필요하다.

검증과 합성:

```bash
cd /home/ghlee/DATE_RTL
PATH="$PWD/.venv/bin:$PATH" make -C verif TEST=spinquant_pcu_v2 sim
./synth/run_spinquant_v2.sh
```
