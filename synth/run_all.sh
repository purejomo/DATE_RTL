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
# and bank interfaces are excluded. The HBM-PIM baseline is a SIMD row and uses
# one binary32 accumulator per lane; every other row is P3-LLM-organized and
# keeps its fixed-point accumulator inside the processing elements.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

# The HBM-PIM baseline. Self-contained in its own RTL directory; sv2v --top
# prunes whatever the selected top does not reach.
HBMPIM_SIMD_SOURCES=(
    "${RTL}/1_hbmpim/hbmpim_fp16_mul.v"
    "${RTL}/1_hbmpim/hbmpim_fp32_add.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_mac_1_lane.v"
    "${RTL}/1_hbmpim/hbmpim_fp16_pcu_16_lane.v"
)

# AWQ INT4 x BF16 in the P3-LLM organization. The eight-PE and sixteen-PE
# builds live in separate directories and each carries its own copy of
# int4float_pcu/pe/align, so the two source sets must never be concatenated:
# doing so would define those three modules twice.
#
# The eight-PE build is v2: i_weight_zp is one four-bit zero point per output
# PE (NUM_PES*4 bits) instead of one broadcast nibble, which is the layout
# AutoAWQ actually stores. The sixteen-PE build is still the v1 broadcast
# contract -- that is why the two tops differ in port width.
PCU8_SOURCES=(
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_align.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_pe.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4bf16_pcu32.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_8pe_v2/compressor_4to2.sv"
)

PCU16_SOURCES=(
    "${RTL}/2_awq_p3llm_16pe/int4float_align.v"
    "${RTL}/2_awq_p3llm_16pe/int4float_pe.v"
    "${RTL}/2_awq_p3llm_16pe/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_16pe/int4bf16_pcu_top.v"
    "${RTL}/2_awq_p3llm_16pe/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_16pe/compressor_4to2.sv"
)

P3LLM_SOURCES=(
    "${RTL}/3_p3llm/p3llm_pkg.sv"
    "${RTL}/3_p3llm/p3llm_pcu.sv"
    "${RTL}/3_p3llm/p3llm_pe.sv"
    "${RTL}/3_p3llm/fixed_mul_shift.sv"
    "${RTL}/3_p3llm/fp8_e4m3_decoder.sv"
    "${RTL}/3_p3llm/fp8_s0e4m4_decoder.sv"
    "${RTL}/3_p3llm/bitmod4_decoder.sv"
    "${RTL}/3_p3llm/int4_asym_decoder.sv"
    "${RTL}/3_p3llm/compressor_4to2.sv"
)

# P3-LLM with one PCU-shared post-accumulator dequantization pipeline.  Keep
# this source set separate from the paper baseline: both directories define the
# same raw p3llm_* modules, while only this set adds the fixed32/FP scale path,
# cross-group FP32 state, and final FP16 output packing.
P3LLM_DEQUANT_SOURCES=(
    "${RTL}/3_p3llm_with_dequant/p3llm_pkg.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_pcu.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_pe.sv"
    "${RTL}/3_p3llm_with_dequant/fixed_mul_shift.sv"
    "${RTL}/3_p3llm_with_dequant/fp8_e4m3_decoder.sv"
    "${RTL}/3_p3llm_with_dequant/fp8_s0e4m4_decoder.sv"
    "${RTL}/3_p3llm_with_dequant/bitmod4_decoder.sv"
    "${RTL}/3_p3llm_with_dequant/int4_asym_decoder.sv"
    "${RTL}/3_p3llm_with_dequant/compressor_4to2.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_dequant_fixed32_fp16_mul_pipe.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_dequant_fp32_add_pipe.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_dequant_fp32_fp16_mul_pack_pipe.sv"
    "${RTL}/3_p3llm_with_dequant/p3llm_pcu_dequant.sv"
)

# RaBiT 2-bit residual binarization. No multiplier at all, so the arithmetic
# boundary is the convert-on-write unit, the eight PEs and the accumulator
# array. That array is inside the boundary on purpose: a stripe keeps 32
# outputs x 2 paths resident for a whole k sweep, which makes it arithmetic
# state rather than a buffer. synth/run_rabit.sh builds the same rows plus the
# MANT_W / SHIFTER_EN sweep and the per-module breakdown without re-running the
# other designs.
RABIT_BASE_SOURCES=(
    "${RTL}/4_rabit/rabit_compressor_4to2.sv"
    "${RTL}/4_rabit/rabit_cvt_fp16_blk.sv"
    "${RTL}/4_rabit/rabit_align_shift.sv"
    "${RTL}/4_rabit/rabit_pe.sv"
    "${RTL}/4_rabit/rabit_acc_regfile.sv"
    "${RTL}/4_rabit/rabit_pcu_ctrl.sv"
    "${RTL}/4_rabit/rabit_pcu_top.sv"
    "${RTL}/4_rabit/rabit_pcu_synth.sv"
)

# SpinQuant W4A4. A pure integer dot-product engine: signed INT4 weights out of
# the bank, unsigned INT4 activations out of the input GRF, and nothing else --
# the rotations are merged into the weights offline, the activation zero point
# is folded into the NPU bias, and both dequantization scales are applied by the
# NPU. So the boundary is the 256-bit bank read latch, 16 PEs of four
# multipliers each, and the 4 x 16 x 32b accumulator file. That file is inside
# the boundary for the same reason RaBiT's is: a k sweep has to keep every
# partial sum resident from the first RD of a row-buffer streak to the drain.
# synth/run_spinquant.sh builds the same row plus the parameter sweep and the
# per-module breakdown without re-running the other designs.
SPINQUANT_SOURCES=(
    "${RTL}/5_spinquant/spinquant_compressor_4to2.sv"
    "${RTL}/5_spinquant/spinquant_mul_s4u4.sv"
    "${RTL}/5_spinquant/spinquant_pe.sv"
    "${RTL}/5_spinquant/spinquant_acc_regfile.sv"
    "${RTL}/5_spinquant/spinquant_pcu_top.sv"
    "${RTL}/5_spinquant/spinquant_pcu_synth.sv"
)

# label : top : clock period (ns) : source set
ROWS=(
    "compute_hbmpim_250      : hbmpim_fp16_pcu_16_lane       : 4.0 : hbmpim_simd"
    "int4bf16_pcu32_500      : int4bf16_pcu32       : 2.0 : pcu8"
    "int4bf16_pcu_top_pcu500 : int4bf16_pcu_top     : 2.0 : pcu16"
    "p3llm_pcu_500           : p3llm_pcu            : 2.0 : p3llm"
    "p3llm_pcu_dequant_500   : p3llm_pcu_dequant    : 2.0 : p3llm_dequant"
    # Only the 250 MHz build is a table row. The 500 MHz build misses setup by
    # 0.04 ns, and both share the top name rabit_pcu -- do_power writes one
    # report per top, so listing both here would leave the 250 MHz row reading
    # 500 MHz power. The 500 MHz point lives in run_rabit.sh with the rest of
    # the sweep, which does not run power.
    "rabit_pcu_250           : rabit_pcu            : 4.0 : rabit"
    # tCCD_S, which is 2x the tCCD_L the HBM-PIM baseline row runs at. The
    # tCCD_L build is a sweep point in run_spinquant.sh, not a row here: both
    # share the top name spinquant_pcu and do_power writes one report per top.
    "spinquant_pcu_500       : spinquant_pcu        : 2.0 : spinquant"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

sources_for() {
    case "$1" in
        hbmpim_simd) printf '%s\n' "${HBMPIM_SIMD_SOURCES[@]}" ;;
        pcu8)        printf '%s\n' "${PCU8_SOURCES[@]}" ;;
        pcu16)       printf '%s\n' "${PCU16_SOURCES[@]}" ;;
        p3llm)       printf '%s\n' "${P3LLM_SOURCES[@]}" ;;
        p3llm_dequant) printf '%s\n' "${P3LLM_DEQUANT_SOURCES[@]}" ;;
        rabit)       printf '%s\n' "${RABIT_BASE_SOURCES[@]}" ;;
        spinquant)   printf '%s\n' "${SPINQUANT_SOURCES[@]}" ;;
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
            | grep -E "^Total" | awk '{printf "%s W", $5}'
        echo
    done
}

do_table() {
    python3 "${HERE}/build_compute_table.py"
    python3 "${HERE}/build_awq_report.py"
}

case "${1:-all}" in
    synth) do_synth ;;
    power) do_power ;;
    table) do_table ;;
    all)   do_synth; do_power; do_table ;;
    *)     echo "usage: $0 [all|synth|power|table]" >&2; exit 2 ;;
esac
