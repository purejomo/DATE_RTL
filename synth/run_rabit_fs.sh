#!/usr/bin/env bash
# Synthesize the full-scale RaBiT PCU rows without touching the other designs.
#
# These are RaBiT's axis-3 (dequant_rne) rows of the three-axis comparison, so
# the directory is rtl/4_rabit_dequant_rne. The label, top and file names keep
# the historical `fs` spelling: verif/models/rabit_fs_model.py,
# synth/build_rabit_fs_report.py and the results/ artefact names all key off
# them, and renaming would invalidate the area history.
#
# Caveat for the axis-3 comparison, also recorded in that directory's README:
# unlike the other axis-3 designs this one contains the write-path h scale unit
# on top of the drain-path dequantization, so the RaBiT axis-3 area is
# over-counted by the rabit_fs_blk_hscale_* contribution. That block is
# synthesized on its own below, so the over-count can be subtracted rather than
# estimated.
#
#   ./run_rabit_fs.sh           every full-scale row and the per-module breakdown
#   ./run_rabit_fs.sh main      only the delivered configuration
#
# Companion to run_rabit.sh, which owns the base variant's rows. The two scripts
# publish disjoint labels, so either can be re-run on its own and
# merge_area_csv.py leaves the other's rows in results/area.csv alone.
#
# Boundary. Identical to the base variant's, plus the three blocks the full-scale
# variant adds: the convert-on-write unit, the eight PEs, the accumulator array,
# the h multiply array, the g buffer and the dequantizer. The input GRF and the
# CRF stay outside, as behavioural models in the testbench.
#
# The clock. The base RaBiT row's primary point is 250 MHz, matching the
# HBM-PIM baseline, so the full-scale rows are measured there too and the area
# delta is like for like. The 500 MHz rows line up with the AWQ and P3-LLM rows
# and are what says whether the h multiply on the write path still closes at
# tCCD_S = 2 ns per PCU cycle.
#
# The source set deliberately reuses rtl/4_rabit rather than copying it. Do not
# add rabit_pcu_top.sv / rabit_pcu_synth.sv here: those are the base variant's
# own tops and sv2v --top would prune them anyway, but listing them would
# suggest the two variants share a top, which they do not.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
BASE_RTL="${ROOT}/rtl/4_rabit"
FS_RTL="${ROOT}/rtl/4_rabit_dequant_rne"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

RABIT_FS_SOURCES=(
    "${BASE_RTL}/rabit_compressor_4to2.sv"
    "${BASE_RTL}/rabit_cvt_fp16_blk.sv"
    "${BASE_RTL}/rabit_align_shift.sv"
    "${BASE_RTL}/rabit_pe.sv"
    "${BASE_RTL}/rabit_acc_regfile.sv"
    "${BASE_RTL}/rabit_pcu_ctrl.sv"
    "${FS_RTL}/rabit_fs_fp16_pack.sv"
    "${FS_RTL}/rabit_fs_h_scale_unit.sv"
    "${FS_RTL}/rabit_fs_g_buffer.sv"
    "${FS_RTL}/rabit_fs_dq_lane.sv"
    "${FS_RTL}/rabit_fs_dq_add.sv"
    "${FS_RTL}/rabit_fs_dq_unit.sv"
    "${FS_RTL}/rabit_fs_drain_seq.sv"
    "${FS_RTL}/rabit_pcu_fs_top.sv"
    "${FS_RTL}/rabit_pcu_fs_synth.sv"
)

# label : top : clock period (ns)
MAIN_ROWS=(
    "rabit_pcu_fs_250           : rabit_pcu_fs           : 4.0"
    "rabit_pcu_fs_500           : rabit_pcu_fs           : 2.0"
    "rabit_pcu_fs_p_250         : rabit_pcu_fs_p         : 4.0"
    "rabit_pcu_fs_p_500         : rabit_pcu_fs_p         : 2.0"
)

SWEEP_ROWS=(
    "rabit_pcu_fs_h16_250       : rabit_pcu_fs_h16       : 4.0"
    "rabit_fs_blk_hscale_250    : rabit_fs_blk_hscale    : 4.0"
    "rabit_fs_blk_gbuf_250      : rabit_fs_blk_gbuf      : 4.0"
    "rabit_fs_blk_dq_250        : rabit_fs_blk_dq        : 4.0"
    "rabit_fs_blk_hscale_500    : rabit_fs_blk_hscale    : 2.0"
    "rabit_fs_blk_dq_500        : rabit_fs_blk_dq        : 2.0"
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
        "${RABIT_FS_SOURCES[@]}"
done

mkdir -p "${RESULTS}/reports" "${RESULTS}/designs"
python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"
for label in "${labels[@]}"; do
    rm -rf "${RESULTS}/reports/${label}"
    cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
done

python3 "${ROOT}/tools/pack_rabit_fs.py" --markdown --dout 64 --din 512 --seeds 3 \
    > "${RESULTS}/designs/rabit_fs_accuracy.md"
python3 "${HERE}/build_rabit_fs_report.py"
