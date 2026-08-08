#!/usr/bin/env bash
# Post-synthesis VCD-annotated power for one design.
#   run_power.sh <top> <netlist.v> <sdc> <vcd> <vcd_scope> <out_dir>
set -euo pipefail
COMPARISON_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORFS_ROOT="${ORFS_ROOT:-/home/ghlee/.cache/openroad-user/OpenROAD-flow-scripts}"
OPENROAD_EXE="${OPENROAD_EXE:-/home/ghlee/.local/openroad-2024/usr/bin/openroad}"
export LD_LIBRARY_PATH="/home/ghlee/.local/openroad-deps/usr/lib/x86_64-linux-gnu:/home/ghlee/.local/openroad-deps/usr/lib/tcltk/x86_64-linux-gnu/tclreadline2.3.8:/home/ghlee/.local/openroad-2024/opt/or-tools/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

export POWER_TOP="$1"
export DESIGN_NAME="$1"
export CLOCK_PERIOD="${CLOCK_PERIOD:-1.0}"
export POWER_NETLIST="$2"
export POWER_SDC="$3"
export POWER_VCD="${4:-}"
export POWER_VCD_SCOPE="${5:-}"
OUT_DIR="${6:-.}"
export POWER_LIB="${ORFS_ROOT}/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
export POWER_TECH_LEF="${ORFS_ROOT}/flow/platforms/nangate45/lef/NangateOpenCellLibrary.tech.lef"
export POWER_CELL_LEF="${ORFS_ROOT}/flow/platforms/nangate45/lef/NangateOpenCellLibrary.macro.mod.lef"

mkdir -p "${OUT_DIR}"
"${OPENROAD_EXE}" -exit -no_init "${COMPARISON_DIR}/power.tcl" \
    > "${OUT_DIR}/${POWER_TOP}_power.rpt" 2>&1 || true
grep -E "^Total|activity source" "${OUT_DIR}/${POWER_TOP}_power.rpt" || \
    tail -5 "${OUT_DIR}/${POWER_TOP}_power.rpt"
