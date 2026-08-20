#!/usr/bin/env bash
# Reproduce every row of the compute-only comparison table.
#
#   ./run_all.sh              synthesize, measure power, rebuild the table
#   ./run_all.sh synth        synthesis only
#   ./run_all.sh power        power only (needs synthesis to have run)
#   ./run_all.sh table        rebuild the table from existing results
#
# Every row includes the arithmetic datapath and architectural accumulator.
# External GRF/SRF storage, command memory and bank interfaces are excluded;
# local sequencing and state that enable the measured dataflow remain in their
# design-specific tops. The HBM-PIM baseline is a SIMD row and uses one
# binary32 accumulator per lane.
#
# Each design family is measured along up to four axes, so the accumulator
# width is no longer the same on every row:
#
#   (1) base          32-bit fixed-point accumulation, raw integer output.
#                     The rows that existed before this sweep.
#   (2) acc16         every partial sum is RNE-narrowed to 16 bits before it
#                     is accumulated, and the accumulator holds 16 bits.
#                     Nothing ahead of the accumulator changes, so the delta
#                     against (1) prices the accumulator alone.
#   (3) dequant_rne   32-bit accumulation, then dequantization inside the PU,
#                     ending in the design family's activation precision:
#                     bfloat16 for AWQ, FP8-E4M3 for P3-LLM, binary16 for
#                     RaBiT. The delta against (1) prices moving dequant off
#                     the host.
#   (4) dequant_requant
#                     SpinQuant only: dequantization followed by UINT4
#                     requantization, closing the W4A4 activation loop.
#
# Each axis lives in its own RTL directory with its own top module name, and
# both of those are load-bearing: run_block_synth.sh writes generated/${TOP}.v
# and do_power writes ${top}_power.rpt, so two rows sharing a top name would
# overwrite each other's results.
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
# Both builds are v2: i_weight_zp is one four-bit zero point per output PE
# (NUM_PES*4 bits) instead of one broadcast nibble, which is the layout AutoAWQ
# actually stores. The v1 broadcast contract is gone; the sixteen-PE port is
# therefore 64 bits rather than 4, and this row's area moved when it converted.
#
# The _acc16 and _dequant_rne directories are further copies of the same three
# modules, so they are separate source sets for the same reason: concatenating
# any two of them would define int4float_pcu/pe/align more than once.
PCU8_SOURCES=(
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_align.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_pe.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4bf16_pcu32.v"
    "${RTL}/2_awq_p3llm_8pe_v2/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_8pe_v2/compressor_4to2.sv"
)

PCU16_SOURCES=(
    "${RTL}/2_awq_p3llm_16pe_v2/int4float_align.v"
    "${RTL}/2_awq_p3llm_16pe_v2/int4float_pe.v"
    "${RTL}/2_awq_p3llm_16pe_v2/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_16pe_v2/int4bf16_pcu_top.v"
    "${RTL}/2_awq_p3llm_16pe_v2/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_16pe_v2/compressor_4to2.sv"
)

# Axis 2: the same two builds with a 16-bit accumulator. Only int4float_pe.v
# and the top differ from the sets above.
PCU8_ACC16_SOURCES=(
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/int4float_align.v"
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/int4float_pe.v"
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/int4bf16_pcu32_acc16.v"
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_8pe_v2_acc16/compressor_4to2.sv"
)

PCU16_ACC16_SOURCES=(
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/int4float_align.v"
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/int4float_pe.v"
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/int4bf16_pcu_top_acc16.v"
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_16pe_v2_acc16/compressor_4to2.sv"
)

# Axis 3: the unchanged raw PCU plus one shared dequantization engine --
# a fixed32 x bfloat16 multiplier, a binary32 accumulator adder, and a final
# RNE pack to bfloat16. sv2v --top prunes the FP16 tops that sit alongside.
PCU8_DQ_SOURCES=(
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4float_align.v"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4float_pe.v"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/compressor_4to2.sv"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/awq_dq_fixed32_float16_mul_pipe.sv"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/awq_dq_fp32_add_pipe.sv"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/awq_dq_fp32_pack_pipe.sv"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4float_pcu_dq.sv"
    "${RTL}/2_awq_p3llm_8pe_v2_dequant_rne/int4bf16_pcu32_dq.v"
)

PCU16_DQ_SOURCES=(
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4float_align.v"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4float_pe.v"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4float_pcu.v"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4_asym_decode.v"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/compressor_4to2.sv"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/awq_dq_fixed32_float16_mul_pipe.sv"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/awq_dq_fp32_add_pipe.sv"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/awq_dq_fp32_pack_pipe.sv"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4float_pcu_dq.sv"
    "${RTL}/2_awq_p3llm_16pe_v2_dequant_rne/int4bf16_pcu_top_dq.v"
)

P3LLM_SOURCES=(
    "${RTL}/3_p3llm/p3llm_pkg.sv"
    "${RTL}/3_p3llm/p3llm_pcu.sv"
    "${RTL}/3_p3llm/p3llm_pe.sv"
    "${RTL}/3_p3llm/fixed_mul_shift.sv"
    "${RTL}/3_p3llm/fixed_product_shift.sv"
    "${RTL}/3_p3llm/fp8_e4m3_decoder.sv"
    "${RTL}/3_p3llm/fp8_s0e4m4_decoder.sv"
    "${RTL}/3_p3llm/bitmod4_decoder.sv"
    "${RTL}/3_p3llm/int4_asym_decoder.sv"
    "${RTL}/3_p3llm/compressor_4to2.sv"
)

# P3-LLM axis 2: the same raw PCU with a 16-bit accumulator. Only p3llm_pe.sv
# and the top differ, and the package keeps its name because the source sets
# are compiled separately.
P3LLM_ACC16_SOURCES=(
    "${RTL}/3_p3llm_acc16/p3llm_pkg.sv"
    "${RTL}/3_p3llm_acc16/p3llm_pcu_acc16.sv"
    "${RTL}/3_p3llm_acc16/p3llm_pe.sv"
    "${RTL}/3_p3llm_acc16/fixed_mul_shift.sv"
    "${RTL}/3_p3llm_acc16/fixed_product_shift.sv"
    "${RTL}/3_p3llm_acc16/fp8_e4m3_decoder.sv"
    "${RTL}/3_p3llm_acc16/fp8_s0e4m4_decoder.sv"
    "${RTL}/3_p3llm_acc16/bitmod4_decoder.sv"
    "${RTL}/3_p3llm_acc16/int4_asym_decoder.sv"
    "${RTL}/3_p3llm_acc16/compressor_4to2.sv"
)

# P3-LLM with one PCU-shared post-accumulator dequantization pipeline.  Keep
# this source set separate from the paper baseline: both directories define the
# same raw p3llm_* modules, while only this set adds the fixed32/FP scale path,
# cross-group FP32 state, and final FP8-E4M3 output packing.
P3LLM_DEQUANT_SOURCES=(
    "${RTL}/3_p3llm_dequant_rne/p3llm_pkg.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_pcu.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_pe.sv"
    "${RTL}/3_p3llm_dequant_rne/fixed_mul_shift.sv"
    "${RTL}/3_p3llm_dequant_rne/fixed_product_shift.sv"
    "${RTL}/3_p3llm_dequant_rne/fp8_e4m3_decoder.sv"
    "${RTL}/3_p3llm_dequant_rne/fp8_s0e4m4_decoder.sv"
    "${RTL}/3_p3llm_dequant_rne/bitmod4_decoder.sv"
    "${RTL}/3_p3llm_dequant_rne/int4_asym_decoder.sv"
    "${RTL}/3_p3llm_dequant_rne/compressor_4to2.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_dequant_fixed32_fp16_mul_pipe.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_dequant_fp32_add_pipe.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_dequant_fp32_fp8_mul_pack_pipe.sv"
    "${RTL}/3_p3llm_dequant_rne/p3llm_pcu_dequant.sv"
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
    "${RTL}/4_rabit/rabit_pcu.sv"
)

# RaBiT axis 2. rtl/4_rabit_acc16 is a full copy of rtl/4_rabit whose only
# difference is the synthesis wrapper: ACC_W 16, MANT_W 10 and SHIFT_RND 1.
# MANT_W has to move with ACC_W because rabit_align_shift requires
# ACC_W > PSUM_W = MANT_W + 5, and SHIFT_RND turns on the aligner's existing
# round-to-nearest-even path, which is where RaBiT discards bits. Do not mix
# these files with RABIT_BASE_SOURCES: both define every rabit_* module.
RABIT_ACC16_SOURCES=(
    "${RTL}/4_rabit_acc16/rabit_compressor_4to2.sv"
    "${RTL}/4_rabit_acc16/rabit_cvt_fp16_blk.sv"
    "${RTL}/4_rabit_acc16/rabit_align_shift.sv"
    "${RTL}/4_rabit_acc16/rabit_pe.sv"
    "${RTL}/4_rabit_acc16/rabit_acc_regfile.sv"
    "${RTL}/4_rabit_acc16/rabit_pcu_ctrl.sv"
    "${RTL}/4_rabit_acc16/rabit_pcu_top.sv"
    "${RTL}/4_rabit_acc16/rabit_pcu_acc16.sv"
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
    "${RTL}/5_spinquant/spinquant_pcu.sv"
)

# SpinQuant axis 2: the accumulator narrowed to 16 bits, MSBs kept. The
# multipliers, the compressor and the sequencing are bit-identical to the base
# row; only spinquant_pe's accumulate stage and the register file width change.
SPINQUANT_ACC16_SOURCES=(
    "${RTL}/5_spinquant_acc16/spinquant_compressor_4to2.sv"
    "${RTL}/5_spinquant_acc16/spinquant_mul_s4u4.sv"
    "${RTL}/5_spinquant_acc16/spinquant_pe.sv"
    "${RTL}/5_spinquant_acc16/spinquant_acc_regfile.sv"
    "${RTL}/5_spinquant_acc16/spinquant_pcu_top.sv"
    "${RTL}/5_spinquant_acc16/spinquant_pcu_acc16.sv"
)

# SpinQuant axis 3: the raw engine plus one shared dequantization pipe. Note
# this row does NOT remove the host kernel -- SpinQuant is W4A4, so a binary16
# output still has to be quantized before the next layer reads it. It is the
# ablation midpoint for the row below.
SPINQUANT_DQ_SOURCES=(
    "${RTL}/5_spinquant_dequant_rne/spinquant_compressor_4to2.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_mul_s4u4.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_pe.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_acc_regfile.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_pcu_top.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_dq_fixed32_float16_mul_pipe.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_dq_fp32_pack_pipe.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_pcu_dq_top.sv"
    "${RTL}/5_spinquant_dequant_rne/spinquant_pcu_dq.sv"
)

# SpinQuant axis 4: the same plus the requantizer, so the output is the INT4 the
# next layer reads and no host kernel runs at all. KEEP_FP16_OUT = 1 makes this
# a strict superset of the row above, so the two differ by the requantizer and
# nothing else. Their area totals are not decomposable, though: this row uses
# 1062 more cells and 139 more flops and still lands 274 um2 lower, because ABC
# maps the bigger netlist with cheaper cells. Quote the cell/flop deltas.
SPINQUANT_RQ_SOURCES=(
    "${RTL}/5_spinquant_dequant_requant/spinquant_compressor_4to2.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_mul_s4u4.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_pe.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_acc_regfile.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_pcu_top.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_dq_fixed32_float16_mul_pipe.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_dq_fp32_pack_pipe.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_rq_minmax.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_rq_fp32_to_int4.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_pcu_rq_top.sv"
    "${RTL}/5_spinquant_dequant_requant/spinquant_pcu_rq.sv"
)

# label : top : clock period (ns) : source set
ROWS=(
    "compute_hbmpim_250      : hbmpim_fp16_pcu_16_lane       : 4.0 : hbmpim_simd"
    "int4bf16_pcu32_500      : int4bf16_pcu32       : 2.0 : pcu8"
    "int4bf16_pcu_top_pcu500 : int4bf16_pcu_top     : 2.0 : pcu16"
    "p3llm_pcu_500           : p3llm_pcu            : 2.0 : p3llm"
    "p3llm_pcu_dequant_500   : p3llm_pcu_dequant    : 2.0 : p3llm_dequant"
    # The current RaBiT target row uses a 500-MHz constraint but misses setup;
    # the timing-closed 250-MHz point remains in run_rabit.sh `all`.
    "rabit_pcu_500           : rabit_pcu            : 2.0 : rabit"
    # tCCD_S, which is 2x the tCCD_L the HBM-PIM baseline row runs at. The
    # tCCD_L build is a sweep point in run_spinquant.sh, not a row here: both
    # share the top name spinquant_pcu and do_power writes one report per top.
    "spinquant_pcu_500       : spinquant_pcu        : 2.0 : spinquant"

    # ---- axis 2: narrowed accumulator --------------------------------
    #
    # Each of these pairs with the base row directly above its family. The
    # tops are distinct module names, so no two rows share a generated
    # netlist or a power report.
    "int4bf16_pcu32_acc16_500   : int4bf16_pcu32_acc16   : 2.0 : pcu8_acc16"
    "int4bf16_pcu_top_acc16_500 : int4bf16_pcu_top_acc16 : 2.0 : pcu16_acc16"
    "p3llm_pcu_acc16_500        : p3llm_pcu_acc16        : 2.0 : p3llm_acc16"
    # RaBiT acc16 uses the same 500-MHz target as its base row and also misses setup.
    "rabit_pcu_acc16_500        : rabit_pcu_acc16        : 2.0 : rabit_acc16"
    # SpinQuant keeps the MSBs rather than the LSBs: its accumulator holds an
    # exact integer dot product whose live value needs 22 bits at K = 14336, so
    # keeping the same LSB weight in 16 bits would cap the design at K = 273.
    "spinquant_pcu_acc16_500    : spinquant_pcu_acc16    : 2.0 : spinquant_acc16"

    # ---- axis 3: dequantization inside the PU ------------------------
    #
    # p3llm_pcu_dequant_500 above is P3-LLM's axis-3 row; RaBiT's lives in
    # run_rabit_fs.sh with the rest of the full-scale sweep.
    "int4bf16_pcu32_dq_500      : int4bf16_pcu32_dq      : 2.0 : pcu8_dq"
    "int4bf16_pcu_top_dq_500    : int4bf16_pcu_top_dq    : 2.0 : pcu16_dq"
    # SpinQuant's axis-3 row is an ablation, not a loop-closing row: W4A4 means
    # a binary16 output still needs a host quantization kernel. Read it only
    # against the axis-4 row below it.
    "spinquant_pcu_dq_500       : spinquant_pcu_dq       : 2.0 : spinquant_dq"

    # ---- axis 4: dequantization AND requantization -------------------
    #
    # SpinQuant only. It is the one design here whose activations are
    # quantized, so it is the one design where finishing the postprocess in the
    # PU means a requantizer. Output is 4 bit/element against the base row's
    # 32, and no host kernel runs.
    "spinquant_pcu_rq_500       : spinquant_pcu_rq       : 2.0 : spinquant_rq"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

sources_for() {
    case "$1" in
        hbmpim_simd) printf '%s\n' "${HBMPIM_SIMD_SOURCES[@]}" ;;
        pcu8)        printf '%s\n' "${PCU8_SOURCES[@]}" ;;
        pcu16)       printf '%s\n' "${PCU16_SOURCES[@]}" ;;
        pcu8_acc16)  printf '%s\n' "${PCU8_ACC16_SOURCES[@]}" ;;
        pcu16_acc16) printf '%s\n' "${PCU16_ACC16_SOURCES[@]}" ;;
        pcu8_dq)     printf '%s\n' "${PCU8_DQ_SOURCES[@]}" ;;
        pcu16_dq)    printf '%s\n' "${PCU16_DQ_SOURCES[@]}" ;;
        p3llm)       printf '%s\n' "${P3LLM_SOURCES[@]}" ;;
        p3llm_acc16) printf '%s\n' "${P3LLM_ACC16_SOURCES[@]}" ;;
        p3llm_dequant) printf '%s\n' "${P3LLM_DEQUANT_SOURCES[@]}" ;;
        rabit)       printf '%s\n' "${RABIT_BASE_SOURCES[@]}" ;;
        rabit_acc16) printf '%s\n' "${RABIT_ACC16_SOURCES[@]}" ;;
        spinquant)   printf '%s\n' "${SPINQUANT_SOURCES[@]}" ;;
        spinquant_acc16) printf '%s\n' "${SPINQUANT_ACC16_SOURCES[@]}" ;;
        spinquant_dq)    printf '%s\n' "${SPINQUANT_DQ_SOURCES[@]}" ;;
        spinquant_rq)    printf '%s\n' "${SPINQUANT_RQ_SOURCES[@]}" ;;
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
}

case "${1:-all}" in
    synth) do_synth ;;
    power) do_power ;;
    table) do_table ;;
    all)   do_synth; do_power; do_table ;;
    *)     echo "usage: $0 [all|synth|power|table]" >&2; exit 2 ;;
esac
