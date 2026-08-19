# results

모든 파일은 생성물이다. 직접 편집하지 말고 `synth/` 의 스크립트로 다시 만든다

| 경로 | 범위 | 만드는 것 |
|---|---|---|
| `area.csv` | **공통** — label 단위 원시 합성값 | `run_all.sh synth`, `run_rabit.sh`, `run_rabit_fs.sh`, `run_spinquant.sh` (label 단위 병합) |
| `comparison_compute.csv` | **공통** — 논문 compute 비교표 (45nm) | `build_compute_table.py` |
| `comparison_22nm.csv` | **공통** — 22nm 투영 비교표 | `build_comparison_22nm.py` |
| `reports/<label>/` | **공통** — label 단위 Yosys·OpenROAD 리포트 | `run_block_synth.sh` |
| `power/<top>_power.rpt` | **공통** — vectorless 전력, `-global` 0.20 모델 | `run_power.sh` |
| `designs/` | **설계별** — 한 설계에만 해당하는 분석 | `build_awq_report.py`, `build_rabit_report.py`, `build_rabit_fs_report.py`, `build_rabit_pe_scaling.py`, `build_spinquant_report.py`, `tools/rabit_accuracy.py`, `tools/pack_rabit_fs.py` |


## 현재 `designs/`

| 파일 | 내용 |
|---|---|
| `awq_p3llm_v2_area_report.md` | baseline 대비 면적·타이밍, v1(broadcast ZP) → v2(PE 별 ZP) 차이 (`build_awq_report.py`) |
| `rabit_area_report.md` | baseline 대비 면적·타이밍, 모듈별 분해, `MANT_W`/`SHIFTER_EN` 스윕, 전력 해석 |
| `rabit_accuracy.md` | 4096x4096 · 11008x4096 정확도 스윕 (`tools/rabit_accuracy.py`) |
| `rabit_pe_scaling.md` | 8 -> 16 PE 확장 검토: column word 제약, 대역폭 포화, 면적 실측 |
| `rabit_fs_report.md` | full-scale 변종 면적 비교 |
| `rabit_fs_accuracy.md` | full-scale 변종 정확도 (`tools/pack_rabit_fs.py`) |
| `spinquant_area_report.md` | baseline 대비 면적·타이밍, 모듈별 분해, 경계·carry chain·처리량 스윕 |
