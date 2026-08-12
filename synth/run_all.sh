#!/usr/bin/env bash
# Reproduce every row of the compute-only comparison table.
#
#   ./run_all.sh              synthesize, measure power, rebuild the table
#   ./run_all.sh synth        synthesis only
#   ./run_all.sh power        power only (needs synthesis to have run)
#   ./run_all.sh table        rebuild the table from existing results
#
# Every row is measured at the same arithmetic boundary: multipliers, adders,
# and the 32-bit accumulator are included; register files, buffers, control,
# and bank interfaces are excluded. The SIMD rows use one binary32 accumulator
# per lane, while the P3-LLM-organized rows keep their fixed-point accumulators
# inside the processing elements.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

# Each SIMD implementation is self-contained in its own RTL directory. The
# source sets intentionally list every file in that directory; sv2v --top
# prunes the unused precision and lane-count wrappers from each build.
HBMPIM_SIMD_SOURCES=(
    "${RTL}/1_hbmpim/hbmpim_fp16_mul.v"
    "${RTL}/1_hbmpim/hbmpim_fp32_add.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_mac_1_lane.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_pcu_16_lane.v"
)

AWQ_SIMD_SOURCES=(
    "${RTL}/2_awq_hbmpim/awq_fp32_add.v"
    "${RTL}/2_awq_hbmpim/awq_int4fp16_mul.v"
    "${RTL}/2_awq_hbmpim/awq_int4bf16_mul.v"
    "${RTL}/2_awq_hbmpim/awq_int4fp16_mac_1_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4bf16_mac_1_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4fp16_pcu_16_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4bf16_pcu_16_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4fp16_pcu_32_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4bf16_pcu_32_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4fp16_pcu_64_lane.v"
    "${RTL}/2_awq_hbmpim/awq_int4bf16_pcu_64_lane.v"
)

# The eight-PE and sixteen-PE builds live in separate directories and each
# carries its own copy of int4float_pcu/pe/align, so the two source sets must
# never be concatenated: doing so would define those three modules twice.
PCU8_SOURCES=(
    "${RTL}/3_awq_p3llm_8pe/int4float_align.v"
    "${RTL}/3_awq_p3llm_8pe/int4float_pe.v"
    "${RTL}/3_awq_p3llm_8pe/int4float_pcu.v"
    "${RTL}/3_awq_p3llm_8pe/int4fp16_pcu32.v"
    "${RTL}/3_awq_p3llm_8pe/int4bf16_pcu32.v"
    "${RTL}/3_awq_p3llm_8pe/int4_asym_decode.v"
    "${RTL}/3_awq_p3llm_8pe/compressor_4to2.sv"
)

PCU16_SOURCES=(
    "${RTL}/3_awq_p3llm_16pe/int4float_align.v"
    "${RTL}/3_awq_p3llm_16pe/int4float_pe.v"
    "${RTL}/3_awq_p3llm_16pe/int4float_pcu.v"
    "${RTL}/3_awq_p3llm_16pe/int4fp16_pcu_top.v"
    "${RTL}/3_awq_p3llm_16pe/int4bf16_pcu_top.v"
    "${RTL}/3_awq_p3llm_16pe/int4_asym_decode.v"
    "${RTL}/3_awq_p3llm_16pe/compressor_4to2.sv"
)

P3LLM_SOURCES=(
    "${RTL}/4_p3llm/p3llm_pkg.sv"
    "${RTL}/4_p3llm/p3llm_pcu.sv"
    "${RTL}/4_p3llm/p3llm_pe.sv"
    "${RTL}/4_p3llm/fixed_mul_shift.sv"
    "${RTL}/4_p3llm/fp8_e4m3_decoder.sv"
    "${RTL}/4_p3llm/fp8_s0e4m4_decoder.sv"
    "${RTL}/4_p3llm/bitmod4_decoder.sv"
    "${RTL}/4_p3llm/int4_asym_decoder.sv"
    "${RTL}/4_p3llm/compressor_4to2.sv"
)

# label : top : clock period (ns) : source set
ROWS=(
    "compute_hbmpim_250      : hbmpim_fp16_pcu_16_lane       : 4.0 : hbmpim_simd"
    "int4fp16_compute_16_500 : awq_int4fp16_pcu_16_lane      : 2.0 : awq_simd"
    "int4bf16_compute_16_500 : awq_int4bf16_pcu_16_lane      : 2.0 : awq_simd"
    "int4fp16_compute_32_500 : awq_int4fp16_pcu_32_lane      : 2.0 : awq_simd"
    "int4bf16_compute_32_500 : awq_int4bf16_pcu_32_lane      : 2.0 : awq_simd"
    "int4fp16_compute_64_500 : awq_int4fp16_pcu_64_lane      : 2.0 : awq_simd"
    "int4bf16_compute_64_500 : awq_int4bf16_pcu_64_lane      : 2.0 : awq_simd"
    "int4fp16_pcu32_500      : int4fp16_pcu32       : 2.0 : pcu8"
    "int4bf16_pcu32_500      : int4bf16_pcu32       : 2.0 : pcu8"
    "int4fp16_pcu_top_pcu500 : int4fp16_pcu_top     : 2.0 : pcu16"
    "int4bf16_pcu_top_pcu500 : int4bf16_pcu_top     : 2.0 : pcu16"
    "p3llm_pcu_500           : p3llm_pcu            : 2.0 : p3llm"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

sources_for() {
    case "$1" in
        hbmpim_simd) printf '%s\n' "${HBMPIM_SIMD_SOURCES[@]}" ;;
        awq_simd)    printf '%s\n' "${AWQ_SIMD_SOURCES[@]}" ;;
        pcu8)        printf '%s\n' "${PCU8_SOURCES[@]}" ;;
        pcu16)       printf '%s\n' "${PCU16_SOURCES[@]}" ;;
        p3llm)       printf '%s\n' "${P3LLM_SOURCES[@]}" ;;
    esac
}

do_synth() {
    mkdir -p "${OUT}"
    rm -f "${OUT}/area.csv"
    rm -rf "${OUT}/reports"
    for row in "${ROWS[@]}"; do
        label=$(field "${row}" 1); top=$(field "${row}" 2)
        period=$(field "${row}" 3); set_name=$(field "${row}" 4)
        mapfile -t sources < <(sources_for "${set_name}")
        CLOCK_PERIOD="${period}" FLOW_VARIANT="date_${period/./p}" \
            "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" "${sources[@]}"
    done
    mkdir -p "${RESULTS}/reports"
    labels=()
    for row in "${ROWS[@]}"; do labels+=("$(field "${row}" 1)"); done
    python3 "${HERE}/merge_area_csv.py" \
        "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"
    for label in "${labels[@]}"; do
        rm -rf "${RESULTS}/reports/${label}"
        cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
    done
}

do_power() {
    mkdir -p "${RESULTS}/power"
    for row in "${ROWS[@]}"; do
        label=$(field "${row}" 1); top=$(field "${row}" 2)
        period=$(field "${row}" 3)
        netlist="${OUT}/results/${label}/1_synth.v"
        [[ -f "${netlist}" ]] || { echo "missing netlist: ${netlist}" >&2; continue; }
        rm -f "${RESULTS}/power/${top}_power.rpt"
        printf '%-26s ' "${label}"
        CLOCK_PERIOD="${period}" "${HERE}/run_power.sh" \
            "${top}" "${netlist}" "${HERE}/constraint.sdc" "" "" \
            "${RESULTS}/power" 2>/dev/null \
            | grep -E "^Total" | awk '{printf "TOTAL=%s W\n", $5}'
    done
}

do_table() {
    python3 "${HERE}/build_compute_table.py"
}

case "${1:-all}" in
    synth) do_synth ;;
    power) do_power ;;
    table) do_table ;;
    all)   do_synth; do_power; do_table ;;
    *)     echo "usage: $0 [all|synth|power|table]" >&2; exit 2 ;;
esac
