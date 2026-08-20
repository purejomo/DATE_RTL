#!/usr/bin/env bash
# Synthesize and publish the 32PE SpinQuant v2 axes.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

BASE="${ROOT}/rtl/5_spinquant_v2"
ACC16="${ROOT}/rtl/5_spinquant_v2_acc16"
DQ="${ROOT}/rtl/5_spinquant_v2_dequant_rne"
RQ="${ROOT}/rtl/5_spinquant_v2_dequant_requant"

BASE_SOURCES=(
    "${BASE}/spinquant_compressor_4to2.sv"
    "${BASE}/spinquant_mul_s4u4.sv"
    "${BASE}/spinquant_pe.sv"
    "${BASE}/spinquant_acc_regfile.sv"
    "${BASE}/spinquant_pcu_top.sv"
    "${BASE}/spinquant_pcu_v2.sv"
)

ACC16_SOURCES=(
    "${ACC16}/spinquant_compressor_4to2.sv"
    "${ACC16}/spinquant_mul_s4u4.sv"
    "${ACC16}/spinquant_pe.sv"
    "${ACC16}/spinquant_acc_regfile.sv"
    "${ACC16}/spinquant_pcu_top.sv"
    "${ACC16}/spinquant_pcu_v2_acc16.sv"
)

DQ_SOURCES=(
    "${DQ}/spinquant_compressor_4to2.sv"
    "${DQ}/spinquant_mul_s4u4.sv"
    "${DQ}/spinquant_pe.sv"
    "${DQ}/spinquant_acc_regfile.sv"
    "${DQ}/spinquant_pcu_top.sv"
    "${DQ}/spinquant_dq_fixed32_float16_mul_pipe.sv"
    "${DQ}/spinquant_dq_fp32_pack_pipe.sv"
    "${DQ}/spinquant_pcu_dq_top.sv"
    "${DQ}/spinquant_pcu_v2_dq.sv"
)

RQ_SOURCES=(
    "${RQ}/spinquant_compressor_4to2.sv"
    "${RQ}/spinquant_mul_s4u4.sv"
    "${RQ}/spinquant_pe.sv"
    "${RQ}/spinquant_acc_regfile.sv"
    "${RQ}/spinquant_pcu_top.sv"
    "${RQ}/spinquant_dq_fixed32_float16_mul_pipe.sv"
    "${RQ}/spinquant_dq_fp32_pack_pipe.sv"
    "${RQ}/spinquant_rq_minmax.sv"
    "${RQ}/spinquant_rq_fp32_to_int4.sv"
    "${RQ}/spinquant_pcu_rq_top.sv"
    "${RQ}/spinquant_pcu_v2_rq.sv"
)

BASE_ROWS=("spinquant_pcu_v2_500:spinquant_pcu_v2:BASE_SOURCES")
AXIS_ROWS=(
    "spinquant_pcu_v2_acc16_500:spinquant_pcu_v2_acc16:ACC16_SOURCES"
    "spinquant_pcu_v2_dq_500:spinquant_pcu_v2_dq:DQ_SOURCES"
    "spinquant_pcu_v2_rq_500:spinquant_pcu_v2_rq:RQ_SOURCES"
)

case "${1:-all}" in
    base) rows=("${BASE_ROWS[@]}") ;;
    axes) rows=("${AXIS_ROWS[@]}") ;;
    acc16) rows=("${AXIS_ROWS[0]}") ;;
    dq) rows=("${AXIS_ROWS[1]}") ;;
    rq) rows=("${AXIS_ROWS[2]}") ;;
    all)  rows=("${BASE_ROWS[@]}" "${AXIS_ROWS[@]}") ;;
    *) echo "usage: $0 [all|base|axes|acc16|dq|rq]" >&2; exit 2 ;;
esac

mkdir -p "${OUT}" "${RESULTS}/reports"
labels=()
for row in "${rows[@]}"; do
    IFS=: read -r label top source_name <<<"${row}"
    declare -n sources="${source_name}"
    labels+=("${label}")
    CLOCK_PERIOD=2.0 FLOW_VARIANT=date_2p0 SYNTH_MEMORY_MAX_BITS=32768 \
        "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" \
        "${sources[@]}"
done

python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"

for label in "${labels[@]}"; do
    rm -rf "${RESULTS}/reports/${label}"
    cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
done

echo "published: ${labels[*]}"
