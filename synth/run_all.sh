#!/usr/bin/env bash
# Reproduce every row of the compute-only comparison table.
#
#   ./run_all.sh              synthesize, measure power, rebuild the table
#   ./run_all.sh synth        synthesis only
#   ./run_all.sh power        power only (needs synthesis to have run)
#   ./run_all.sh table        rebuild the table from existing results
#
# Every row is measured at the same boundary: multipliers and adders only.
# No register file, no buffer, no control, no bank interface. The SIMD rows
# are therefore purely combinational, because those designs accumulate into
# the GRF, which is excluded. The P3-LLM-organized rows are measured at their
# PCU boundary, since their accumulators live inside the processing elements
# and cannot be separated from the arithmetic.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

# Every SIMD top lives in one wrapper file; sv2v --top prunes what it does not
# need, so the same source list serves all of them.
SIMD_SOURCES=(
    "${RTL}/common/compute_only_tops.v"
    "${RTL}/common/int4_asym_decode.v"
    "${RTL}/1_hbmpim/hbmpim_simd_mul.v"
    "${RTL}/1_hbmpim/hbmpim_simd_add.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_mul_lane.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_add_lane.v"
    "${RTL}/2_awq_hbmpim/int4fp16_mul_lane.v"
    "${RTL}/2_awq_hbmpim/int4bf16_mul_lane.v"
    "${RTL}/2_awq_hbmpim/bf16_add_lane.v"
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
    "${RTL}/common/int4_asym_decode.v"
    "${RTL}/common/compressor_4to2.sv"
)

PCU16_SOURCES=(
    "${RTL}/3_awq_p3llm_16pe/int4float_align.v"
    "${RTL}/3_awq_p3llm_16pe/int4float_pe.v"
    "${RTL}/3_awq_p3llm_16pe/int4float_pcu.v"
    "${RTL}/3_awq_p3llm_16pe/int4fp16_pcu_top.v"
    "${RTL}/3_awq_p3llm_16pe/int4bf16_pcu_top.v"
    "${RTL}/common/int4_asym_decode.v"
    "${RTL}/common/compressor_4to2.sv"
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
    "${RTL}/common/compressor_4to2.sv"
)

# label : top : clock period (ns) : source set
ROWS=(
    "compute_hbmpim_250      : hbmpim_compute_16    : 4.0 : simd"
    "int4fp16_compute_16_500 : int4fp16_compute_16  : 2.0 : simd"
    "int4bf16_compute_16_500 : int4bf16_compute_16  : 2.0 : simd"
    "int4fp16_compute_32_500 : int4fp16_compute_32  : 2.0 : simd"
    "int4bf16_compute_32_500 : int4bf16_compute_32  : 2.0 : simd"
    "int4fp16_compute_64_500 : int4fp16_compute_64  : 2.0 : simd"
    "int4bf16_compute_64_500 : int4bf16_compute_64  : 2.0 : simd"
    "int4fp16_pcu32_500      : int4fp16_pcu32       : 2.0 : pcu8"
    "int4bf16_pcu32_500      : int4bf16_pcu32       : 2.0 : pcu8"
    "int4fp16_pcu_top_pcu500 : int4fp16_pcu_top     : 2.0 : pcu16"
    "int4bf16_pcu_top_pcu500 : int4bf16_pcu_top     : 2.0 : pcu16"
    "p3llm_pcu_500           : p3llm_pcu            : 2.0 : p3llm"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

sources_for() {
    case "$1" in
        simd)  printf '%s\n' "${SIMD_SOURCES[@]}" ;;
        pcu8)  printf '%s\n' "${PCU8_SOURCES[@]}" ;;
        pcu16) printf '%s\n' "${PCU16_SOURCES[@]}" ;;
        p3llm) printf '%s\n' "${P3LLM_SOURCES[@]}" ;;
    esac
}

do_synth() {
    mkdir -p "${OUT}"
    for row in "${ROWS[@]}"; do
        label=$(field "${row}" 1); top=$(field "${row}" 2)
        period=$(field "${row}" 3); set_name=$(field "${row}" 4)
        mapfile -t sources < <(sources_for "${set_name}")
        CLOCK_PERIOD="${period}" FLOW_VARIANT="date_${period/./p}" \
            "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" "${sources[@]}"
    done
    mkdir -p "${RESULTS}"
    cp "${OUT}/area.csv" "${RESULTS}/area.csv"
    rm -rf "${RESULTS}/reports"; cp -a "${OUT}/reports" "${RESULTS}/reports"
}

do_power() {
    mkdir -p "${RESULTS}/power"
    for row in "${ROWS[@]}"; do
        label=$(field "${row}" 1); top=$(field "${row}" 2)
        period=$(field "${row}" 3)
        netlist="${OUT}/results/${label}/1_synth.v"
        [[ -f "${netlist}" ]] || { echo "missing netlist: ${netlist}" >&2; continue; }
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
