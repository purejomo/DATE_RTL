#!/usr/bin/env bash
# Generic Nangate45 block synthesis for one top module.
#
# Every design in this project is measured under identical conditions, so the
# flow lives here once instead of being copied into each row's synth/ folder.
#
#   run_block_synth.sh <label> <top_module> <out_dir> <rtl_file> [rtl_file ...]
#
# Results land in <out_dir>/{generated,reports,logs,results} and one line is
# appended to <out_dir>/area.csv.
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: $0 <label> <top_module> <out_dir> <rtl_file> [rtl_file ...]" >&2
    exit 2
fi

LABEL="$1"; shift
TOP="$1"; shift
OUT_DIR="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
RTL_SOURCES=("$@")

ORFS_ROOT="${ORFS_ROOT:-/home/ghlee/.cache/openroad-user/OpenROAD-flow-scripts}"
OPENROAD_EXE="${OPENROAD_EXE:-/home/ghlee/.local/openroad-2024/usr/bin/openroad}"
YOSYS_EXE="${YOSYS_EXE:-/home/ghlee/.local/yosys-0.52/usr/bin/yosys}"
SV2V_EXE="${SV2V_EXE:-/home/ghlee/.local/sv2v-0.0.13/sv2v-Linux/sv2v}"
CLOCK_PERIOD="${CLOCK_PERIOD:-1.0}"
FLOW_VARIANT="${FLOW_VARIANT:-block_area_1ghz}"
COMPARISON_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export OPENROAD_EXE YOSYS_EXE CLOCK_PERIOD
export YOSYS_DATDIR="${YOSYS_DATDIR:-/home/ghlee/.local/yosys-0.52/usr/share/yosys}"
export LD_LIBRARY_PATH="/home/ghlee/.local/openroad-deps/usr/lib/x86_64-linux-gnu:/home/ghlee/.local/openroad-deps/usr/lib/tcltk/x86_64-linux-gnu/tclreadline2.3.8:/home/ghlee/.local/openroad-2024/opt/or-tools/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

for executable in "${OPENROAD_EXE}" "${YOSYS_EXE}" "${SV2V_EXE}"; do
    [[ -x "${executable}" ]] || { echo "missing: ${executable}" >&2; exit 1; }
done
[[ -f "${ORFS_ROOT}/flow/Makefile" ]] || {
    echo "OpenROAD-flow-scripts not found: ${ORFS_ROOT}" >&2; exit 1; }

mkdir -p "${OUT_DIR}"/{generated,reports,logs,results}
GENERATED="${OUT_DIR}/generated/${TOP}.v"

"${SV2V_EXE}" --define=SYNTHESIS --top="${TOP}" "${RTL_SOURCES[@]}" > "${GENERATED}"

make -C "${ORFS_ROOT}/flow" \
    DESIGN_CONFIG="${COMPARISON_DIR}/block_config.mk" \
    BLOCK_DESIGN_NAME="${TOP}" \
    BLOCK_VERILOG_FILE="${GENERATED}" \
    BLOCK_SDC_FILE="${COMPARISON_DIR}/constraint.sdc" \
    FLOW_VARIANT="${FLOW_VARIANT}" \
    CLOCK_PERIOD="${CLOCK_PERIOD}" \
    synth-report

flow_reports="${ORFS_ROOT}/flow/reports/nangate45/${TOP}/${FLOW_VARIANT}"
flow_logs="${ORFS_ROOT}/flow/logs/nangate45/${TOP}/${FLOW_VARIANT}"
flow_results="${ORFS_ROOT}/flow/results/nangate45/${TOP}/${FLOW_VARIANT}"
cp -a "${flow_reports}/." "${OUT_DIR}/reports/${LABEL}/" 2>/dev/null || {
    mkdir -p "${OUT_DIR}/reports/${LABEL}"; cp -a "${flow_reports}/." "${OUT_DIR}/reports/${LABEL}/"; }
mkdir -p "${OUT_DIR}/logs/${LABEL}" "${OUT_DIR}/results/${LABEL}"
cp -a "${flow_logs}/." "${OUT_DIR}/logs/${LABEL}/" 2>/dev/null || true
for artifact in 1_synth.v 1_synth.sdc; do
    [[ -f "${flow_results}/${artifact}" ]] && \
        cp -a "${flow_results}/${artifact}" "${OUT_DIR}/results/${LABEL}/"
done

stat_file="${OUT_DIR}/reports/${LABEL}/synth_stat.txt"
rpt_file="${OUT_DIR}/reports/${LABEL}/1_Post_synthesis.rpt"
area=$(grep -oP "Chip area for module '\\\\${TOP}': \K[0-9.]+" "${stat_file}" | tail -1)
cells=$(grep -oP 'Number of cells:\s+\K[0-9]+' "${stat_file}" | tail -1)
dffs=$(grep -cE '^\s+DFF_X' "${stat_file}" || true)
dff_count=$(awk '/^\s+DFF_X/ {sum += $2} END {print sum+0}' "${stat_file}")
wns=$(awk '/^wns/ {print $2}' "${rpt_file}" | tail -1)
tns=$(awk '/^tns/ {print $2}' "${rpt_file}" | tail -1)

csv="${OUT_DIR}/area.csv"
[[ -f "${csv}" ]] || \
    echo "label,top,area_um2,cells,dffs,wns_ns,tns_ns,clock_ns" > "${csv}"
grep -v "^${LABEL}," "${csv}" > "${csv}.tmp" 2>/dev/null || true
mv "${csv}.tmp" "${csv}" 2>/dev/null || true
echo "${LABEL},${TOP},${area},${cells},${dff_count},${wns},${tns},${CLOCK_PERIOD}" >> "${csv}"

printf '%-28s area=%12s um2  cells=%7s  dff=%5s  wns=%8s  tns=%10s\n' \
    "${LABEL}" "${area}" "${cells}" "${dff_count}" "${wns}" "${tns}"
