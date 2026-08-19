#!/usr/bin/env bash
# Synthesize the SpinQuant W4A4 PCU rows without touching the other designs.
#
#   ./run_spinquant.sh          synthesize every SpinQuant row and publish
#   ./run_spinquant.sh main     only the delivered configuration
#
# Measured at the same arithmetic boundary as every other row in the table: the
# compute datapath plus the architectural accumulators, with the input GRF, the
# CRF, the command decode and the bank interface left out. Two boundary calls
# are worth stating outright, and each has a sweep row that prices it:
#
#   - the 256-bit bank read latch is inside. It is what lets one weight beat
#     feed two tCCD_S MAC commands, so it is part of the 2-pump claim rather
#     than a buffer. spinquant_pcu_nolatch prices it by moving it out, which is
#     where the SIMD and P3-LLM rows take their weights from.
#   - the 4 x 16 x 32b accumulator file is inside, for the same reason RaBiT's
#     is: a k sweep keeps every partial sum resident from the first RD of a
#     row-buffer streak to the MAC-drain at the end of it. spinquant_blk_acc
#     reports it on its own.
#
# The clock. tCCD_S is the design target and it is 2x the tCCD_L the HBM-PIM
# baseline runs at, so the delivered row is 500 MHz, lining up with the AWQ and
# P3-LLM rows. The 250 MHz build is here so the area can also be read at the
# baseline's own clock.
#
# The carry chain. spinquant_pcu implements 24 bits inside a 32-bit
# architectural register, which is exact for every K a projection layer uses
# (K = 14336 of the worst-case product -120 is -1720320, and the chain does not
# overflow until K = 69905). spinquant_pcu_acc32 is the same design with the
# chain widened back to the register width, so the sweep prices the shortcut
# instead of just asserting it.
#
# merge_area_csv.py only replaces the labels listed below, so publishing these
# rows leaves results/area.csv rows owned by run_all.sh alone.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RTL="${ROOT}/rtl/5_spinquant"
OUT="${ROOT}/build"
RESULTS="${ROOT}/results"

SPINQUANT_SOURCES=(
    "${RTL}/spinquant_compressor_4to2.sv"
    "${RTL}/spinquant_mul_s4u4.sv"
    "${RTL}/spinquant_pe.sv"
    "${RTL}/spinquant_acc_regfile.sv"
    "${RTL}/spinquant_pcu_top.sv"
    "${RTL}/spinquant_pcu_synth.sv"
)

# label : top : clock period (ns)
MAIN_ROWS=(
    "spinquant_pcu_500           : spinquant_pcu          : 2.0"
    "spinquant_pcu_250           : spinquant_pcu          : 4.0"
)

SWEEP_ROWS=(
    "spinquant_pcu_acc32_500     : spinquant_pcu_acc32    : 2.0"
    "spinquant_pcu_nolatch_500   : spinquant_pcu_nolatch  : 2.0"
    "spinquant_blk_pe_500        : spinquant_blk_pe       : 2.0"
    "spinquant_blk_acc_500       : spinquant_blk_acc      : 2.0"
)

# Throughput scale-up points. The multiplier array is not the limit -- it closes
# at 1.0 ns with 46 % of the baseline area unused -- so these rows price the
# thing that is: every extra activation row reusing a weight beat needs
# accumulators of its own. See docs/spinquant_pcu_spec.md section 8.
SCALE_ROWS=(
    "spinquant_pcu_r2_500        : spinquant_pcu_r2       : 2.0"
    "spinquant_pcu_r2e2_500      : spinquant_pcu_r2e2     : 2.0"
    "spinquant_pcu_r4_500        : spinquant_pcu_r4       : 2.0"
    "spinquant_pcu_w512_500      : spinquant_pcu_w512     : 2.0"
)

# How much clock the arithmetic actually has left. Same top, same sources, only
# the constraint moves -- the point is to show that tCCD_S is nowhere near what
# the multiplier array can do, so throughput is an operand-supply question.
FMAX_ROWS=(
    "spinquant_pcu_1p0          : spinquant_pcu          : 1.0"
    "spinquant_pcu_0p8          : spinquant_pcu          : 0.8"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

case "${1:-all}" in
    main)  ROWS=("${MAIN_ROWS[@]}") ;;
    scale) ROWS=("${SCALE_ROWS[@]}") ;;
    fmax)  ROWS=("${FMAX_ROWS[@]}") ;;
    all)   ROWS=("${MAIN_ROWS[@]}" "${SWEEP_ROWS[@]}" "${SCALE_ROWS[@]}"
                 "${FMAX_ROWS[@]}") ;;
    *)     echo "usage: $0 [all|main|scale|fmax]" >&2; exit 2 ;;
esac

mkdir -p "${OUT}"
labels=()
for row in "${ROWS[@]}"; do
    label=$(field "${row}" 1); top=$(field "${row}" 2); period=$(field "${row}" 3)
    labels+=("${label}")
    # The scale-up rows hold up to 4 entries x 2048 bits of accumulator, which
    # is past the flow's default $mem guard. Raising the guard does not change
    # the mapping -- nangate45 has no RAM macro, so it goes to flops regardless
    # -- and the delivered rows are unaffected either way.
    CLOCK_PERIOD="${period}" FLOW_VARIANT="date_${period/./p}" \
    SYNTH_MEMORY_MAX_BITS=32768 \
        "${HERE}/run_block_synth.sh" "${label}" "${top}" "${OUT}" \
        "${SPINQUANT_SOURCES[@]}"
done

mkdir -p "${RESULTS}/reports"
python3 "${HERE}/merge_area_csv.py" \
    "${RESULTS}/area.csv" "${OUT}/area.csv" "${labels[@]}"
for label in "${labels[@]}"; do
    rm -rf "${RESULTS}/reports/${label}"
    cp -a "${OUT}/reports/${label}" "${RESULTS}/reports/${label}"
done

mkdir -p "${RESULTS}/designs"
python3 "${HERE}/build_spinquant_report.py"
