#!/usr/bin/env bash
# Synthesize the RaBiT PCU rows without touching the other designs' results.
#
#   ./run_rabit.sh              synthesize every RaBiT row and publish
#   ./run_rabit.sh main         500-MHz target base and acc16 rows only
#
# The boundary includes the compute datapath, local sequencer and architectural
# accumulator array (64 x 32b). External GRF storage, command memory and the
# bank interface remain outside. The accumulator array is included because a
# RaBiT stripe keeps 32 outputs x 2 paths resident for a whole k sweep -- it is
# arithmetic state, not an input/output buffer.
#
# merge_area_csv.py only replaces the labels listed below, so publishing these
# rows leaves results/area.csv rows owned by run_all.sh alone.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl/4_rabit"
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
    "${RTL}/rabit_pcu.sv"
    "${RTL}/rabit_pcu_m10.sv"
    "${RTL}/rabit_pcu_noshift.sv"
    "${RTL}/rabit_pcu_m10_noshift.sv"
    "${RTL}/rabit_blk_cvt.sv"
    "${RTL}/rabit_blk_pe.sv"
    "${RTL}/rabit_blk_acc.sv"
    "${RTL}/rabit_pcu_16pe.sv"
    "${RTL}/rabit_pcu_16pe_g4.sv"
    "${RTL}/rabit_pcu_g8.sv"
    "${RTL}/rabit_pcu_g8_m10.sv"
)

RABIT_ACC16_RTL="${ROOT}/rtl/4_rabit_acc16"
RABIT_ACC16_SOURCES=(
    "${RABIT_ACC16_RTL}/rabit_compressor_4to2.sv"
    "${RABIT_ACC16_RTL}/rabit_cvt_fp16_blk.sv"
    "${RABIT_ACC16_RTL}/rabit_align_shift.sv"
    "${RABIT_ACC16_RTL}/rabit_pe.sv"
    "${RABIT_ACC16_RTL}/rabit_acc_regfile.sv"
    "${RABIT_ACC16_RTL}/rabit_pcu_ctrl.sv"
    "${RABIT_ACC16_RTL}/rabit_pcu_top.sv"
    "${RABIT_ACC16_RTL}/rabit_pcu_acc16.sv"
)

# label : top : clock period (ns) : source set
MAIN_ROWS=(
    "rabit_pcu_500              : rabit_pcu              : 2.0 : base"
    "rabit_pcu_acc16_500        : rabit_pcu_acc16        : 2.0 : acc16"
)

LEGACY_ROWS=(
    "rabit_pcu_250              : rabit_pcu              : 4.0 : base"
    "rabit_pcu_acc16_250        : rabit_pcu_acc16        : 4.0 : acc16"
)

SWEEP_ROWS=(
    "rabit_pcu_m10_250          : rabit_pcu_m10          : 4.0 : base"
    "rabit_pcu_noshift_250      : rabit_pcu_noshift      : 4.0 : base"
    "rabit_pcu_m10_noshift_250  : rabit_pcu_m10_noshift  : 4.0 : base"
    "rabit_blk_cvt_250          : rabit_blk_cvt          : 4.0 : base"
    "rabit_blk_pe_250           : rabit_blk_pe           : 4.0 : base"
    "rabit_blk_acc_250          : rabit_blk_acc          : 4.0 : base"
    # PE-count study. 8 PE is not a chosen number: WORD_W = NIN*NOUT*NPATH, so a
    # 256-bit column word with 16-input entries and 2 residual paths leaves
    # exactly 8 outputs. These two price what doubling it would cost -- with the
    # resident stripe held at 32 outputs (NGROUP 2) and with it doubled too
    # (NGROUP 4). Neither raises sustained throughput; see
    # docs/rabit_pcu_spec.md.
    "rabit_pcu_16pe_250         : rabit_pcu_16pe         : 4.0 : base"
    "rabit_pcu_16pe_g4_250      : rabit_pcu_16pe_g4      : 4.0 : base"
    # Stripe-width study. Sustained throughput is set by the WR:RD ratio, not by
    # the PE count: one activation entry pair (2 WR) feeds NGROUP RD commands.
    # NGROUP 4 -> 8 widens the resident stripe from 32 to 64 outputs and takes
    # the duty cycle from 4/6 to 8/10 (+20%), leaving the PE array untouched.
    "rabit_pcu_g8_250           : rabit_pcu_g8           : 4.0 : base"
    "rabit_pcu_g8_m10_250       : rabit_pcu_g8_m10       : 4.0 : base"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

case "${1:-all}" in
    main) ROWS=("${MAIN_ROWS[@]}") ;;
    all)  ROWS=("${MAIN_ROWS[@]}" "${LEGACY_ROWS[@]}" "${SWEEP_ROWS[@]}") ;;
    *)    echo "usage: $0 [all|main]" >&2; exit 2 ;;
esac

mkdir -p "${OUT}"
labels=()
for row in "${ROWS[@]}"; do
    label=$(field "${row}" 1); top=$(field "${row}" 2); period=$(field "${row}" 3)
    source_set=$(field "${row}" 4)
    labels+=("${label}")
    case "${source_set}" in
        base)  sources=("${RABIT_SOURCES[@]}") ;;
        acc16) sources=("${RABIT_ACC16_SOURCES[@]}") ;;
        *) echo "unknown source set: ${source_set}" >&2; exit 2 ;;
    esac
    CLOCK_PERIOD="${period}" FLOW_VARIANT="date_${period/./p}" \
        "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" \
        "${sources[@]}"
done

mkdir -p "${RESULTS}/reports"
python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"
for label in "${labels[@]}"; do
    rm -rf "${RESULTS}/reports/${label}"
    cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
done
