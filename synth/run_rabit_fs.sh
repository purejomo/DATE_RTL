#!/usr/bin/env bash
# Synthesize and publish the final RaBiT dequant_rne design.
#
# The design keeps both input-scale processing (s_in * x) and output
# dequantization inside the PCU. Every source is local to
# rtl/4_rabit_dequant_rne; no module is pulled from the base RaBiT directory.
#
#   ./run_rabit_fs.sh
#   ./run_rabit_fs.sh main
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl/4_rabit_dequant_rne"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

RABIT_FS_SOURCES=(
    "${RTL}/rabit_compressor_4to2.sv"
    "${RTL}/rabit_cvt_fp16_blk.sv"
    "${RTL}/rabit_align_shift.sv"
    "${RTL}/rabit_pe.sv"
    "${RTL}/rabit_acc_regfile.sv"
    "${RTL}/rabit_pcu_ctrl.sv"
    "${RTL}/rabit_fs_fp16_pack.sv"
    "${RTL}/rabit_fs_h_scale_unit.sv"
    "${RTL}/rabit_fs_g_group_buffer.sv"
    "${RTL}/rabit_fs_dq_lane.sv"
    "${RTL}/rabit_fs_dq_add.sv"
    "${RTL}/rabit_fs_dq_unit.sv"
    "${RTL}/rabit_fs_group_drain_seq.sv"
    "${RTL}/rabit_pcu_fs_top.sv"
    "${RTL}/rabit_fs_y_pack1to4.sv"
    "${RTL}/rabit_pcu_fs.sv"
)

LABEL="rabit_pcu_fs_500"
TOP="rabit_pcu_fs"

case "${1:-main}" in
    main) ;;
    *) echo "usage: $0 [main]" >&2; exit 2 ;;
esac

mkdir -p "${OUT}"
CLOCK_PERIOD=2.0 FLOW_VARIANT=date_2p0 \
    "${HERE}/run_block_synth.sh" "${LABEL}" "${TOP}" "${OUT}" \
    "${RABIT_FS_SOURCES[@]}"

mkdir -p "${RESULTS}/reports"
python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${LABEL}"

rm -rf "${RESULTS}/reports/${LABEL}"
cp -a "${OUT}/reports/${LABEL}" "${RESULTS}/reports/${LABEL}"

echo "published ${LABEL} to results/area.csv and results/reports/${LABEL}"
