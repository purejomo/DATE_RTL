#!/usr/bin/env bash
# Synthesize the RaBiT PCU rows without touching the other designs' results.
#
#   ./run_rabit.sh              synthesize every RaBiT row and publish
#   ./run_rabit.sh main         only the delivered configuration
#
# Measured at the same arithmetic boundary as every other row in the table:
# the compute datapath plus the architectural accumulators, with register
# files, buffers, command storage and the bank interface left out. The one
# deliberate difference is that the RaBiT accumulator array (64 x 32b) is
# inside the boundary, because a RaBiT stripe has to keep 32 outputs x 2 paths
# resident for a whole k sweep -- it is arithmetic state, not a buffer.
#
# The clock. The baseline HBM-PIM row runs at 250 MHz, so the primary RaBiT row
# does too, which makes the area comparison like for like. The PCU spends two
# cycles per column command, so 4.0 ns of PCU period is 8.0 ns of tCCD_S. The
# 500 MHz rows are there to line up with the AWQ and P3-LLM rows.
#
# merge_area_csv.py only replaces the labels listed below, so publishing these
# rows leaves results/area.csv rows owned by run_all.sh alone.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl/5_rabit"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

RABIT_SOURCES=(
    "${RTL}/rabit_compressor_4to2.sv"
    "${RTL}/rabit_cvt_fp16_blk.sv"
    "${RTL}/rabit_align_shift.sv"
    "${RTL}/rabit_pe.sv"
    "${RTL}/rabit_acc_regfile.sv"
    "${RTL}/rabit_pcu_ctrl.sv"
    "${RTL}/rabit_pcu_top.sv"
    "${RTL}/rabit_pcu_synth.sv"
)

# label : top : clock period (ns)
MAIN_ROWS=(
    "rabit_pcu_250              : rabit_pcu              : 4.0"
    "rabit_pcu_500              : rabit_pcu              : 2.0"
)

SWEEP_ROWS=(
    "rabit_pcu_m10_250          : rabit_pcu_m10          : 4.0"
    "rabit_pcu_noshift_250      : rabit_pcu_noshift      : 4.0"
    "rabit_pcu_m10_noshift_250  : rabit_pcu_m10_noshift  : 4.0"
    "rabit_blk_cvt_250          : rabit_blk_cvt          : 4.0"
    "rabit_blk_pe_250           : rabit_blk_pe           : 4.0"
    "rabit_blk_acc_250          : rabit_blk_acc          : 4.0"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

case "${1:-all}" in
    main) ROWS=("${MAIN_ROWS[@]}") ;;
    all)  ROWS=("${MAIN_ROWS[@]}" "${SWEEP_ROWS[@]}") ;;
    *)    echo "usage: $0 [all|main]" >&2; exit 2 ;;
esac

mkdir -p "${OUT}"
labels=()
for row in "${ROWS[@]}"; do
    label=$(field "${row}" 1); top=$(field "${row}" 2); period=$(field "${row}" 3)
    labels+=("${label}")
    CLOCK_PERIOD="${period}" FLOW_VARIANT="date_${period/./p}" \
        "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" \
        "${RABIT_SOURCES[@]}"
done

mkdir -p "${RESULTS}/reports"
python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"
for label in "${labels[@]}"; do
    rm -rf "${RESULTS}/reports/${label}"
    cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
done

mkdir -p "${RESULTS}/designs"
python3 "${ROOT}/tools/rabit_accuracy.py" > "${RESULTS}/designs/rabit_accuracy.md"
python3 "${HERE}/build_rabit_report.py"
