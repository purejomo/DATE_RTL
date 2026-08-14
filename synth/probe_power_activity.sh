#!/usr/bin/env bash
# Diagnostic: how much of the reported power comes from the activity model?
#
# power.tcl falls back to `set_power_activity -input -activity 0.20` when no VCD
# is supplied, which is what every row in the comparison tables currently uses.
# OpenSTA then propagates that activity forward with a transition-density model.
# For independent inputs an XOR gate's output density is the SUM of its input
# densities, so density grows with combinational depth and a flip-flop resets it.
# Designs are therefore amplified by wildly different factors depending on how
# deep their logic is and where their registers sit -- which is a property of the
# pipeline, not of the energy the design actually burns.
#
# This script measures that amplification directly. For every row it reports
# power twice on the identical netlist, SDC, library and corner:
#
#   -input    0.20 on primary inputs, propagated  (what the tables use today)
#   -global   0.20 on every net, no propagation   (uniform across designs)
#
# If the two orderings disagree, the published power column is ranking designs
# by combinational depth rather than by energy.
#
#   ./probe_power_activity.sh              # all rows, prints a table
#
# See results/power_activity_probe.md for the recorded result.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
ORFS_ROOT="${ORFS_ROOT:-/home/ghlee/.cache/openroad-user/OpenROAD-flow-scripts}"
OPENROAD_EXE="${OPENROAD_EXE:-/home/ghlee/.local/openroad-2024/usr/bin/openroad}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export LD_LIBRARY_PATH="/home/ghlee/.local/openroad-deps/usr/lib/x86_64-linux-gnu:/home/ghlee/.local/openroad-deps/usr/lib/tcltk/x86_64-linux-gnu/tclreadline2.3.8:/home/ghlee/.local/openroad-2024/opt/or-tools/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export POWER_LIB="${ORFS_ROOT}/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
export POWER_TECH_LEF="${ORFS_ROOT}/flow/platforms/nangate45/lef/NangateOpenCellLibrary.tech.lef"
export POWER_CELL_LEF="${ORFS_ROOT}/flow/platforms/nangate45/lef/NangateOpenCellLibrary.macro.mod.lef"
export POWER_SDC="${HERE}/constraint.sdc"

cat > "${WORK}/probe.tcl" <<'TCL'
read_lef $::env(POWER_TECH_LEF)
read_lef $::env(POWER_CELL_LEF)
read_liberty $::env(POWER_LIB)
read_verilog $::env(POWER_NETLIST)
link_design $::env(POWER_TOP)
read_sdc $::env(POWER_SDC)
if {$::env(PROBE_MODE) eq "input"} {
    set_power_activity -input -activity 0.20 -duty 0.50
} else {
    set_power_activity -global -activity 0.20 -duty 0.50
}
report_power
TCL

# top : label : clock period (ns)
ROWS=(
    "hbmpim_fp16_pcu_16_lane  : compute_hbmpim_250       : 4.0"
    "awq_int4fp16_pcu_16_lane : int4fp16_compute_16_500  : 2.0"
    "awq_int4bf16_pcu_16_lane : int4bf16_compute_16_500  : 2.0"
    "awq_int4fp16_pcu_64_lane : int4fp16_compute_64_500  : 2.0"
    "awq_int4bf16_pcu_64_lane : int4bf16_compute_64_500  : 2.0"
    "int4fp16_pcu32           : int4fp16_pcu32_500       : 2.0"
    "int4bf16_pcu32           : int4bf16_pcu32_500       : 2.0"
    "int4fp16_pcu_top         : int4fp16_pcu_top_pcu500  : 2.0"
    "int4bf16_pcu_top         : int4bf16_pcu_top_pcu500  : 2.0"
    "p3llm_pcu                : p3llm_pcu_500            : 2.0"
    "p3llm_pcu_dequant        : p3llm_pcu_dequant_500    : 2.0"
    "rabit_pcu                : rabit_pcu_250            : 4.0"
)

field() { echo "$1" | cut -d: -f"$2" | tr -d ' '; }

csv="${WORK}/probe.csv"
for row in "${ROWS[@]}"; do
    top=$(field "${row}" 1); label=$(field "${row}" 2); period=$(field "${row}" 3)
    netlist="${ROOT}/build/results/${label}/1_synth.v"
    [[ -f "${netlist}" ]] || { echo "skip ${top}: no netlist" >&2; continue; }
    export POWER_TOP="${top}" DESIGN_NAME="${top}" CLOCK_PERIOD="${period}"
    export POWER_NETLIST="${netlist}"
    for mode in input global; do
        export PROBE_MODE="${mode}"
        value=$("${OPENROAD_EXE}" -exit "${WORK}/probe.tcl" 2>/dev/null \
            | awk '/^Total/{print $5}')
        echo "${top},${label},${period},${mode},${value}" >> "${csv}"
    done
done

python3 - "${csv}" "${ROOT}/results/area.csv" <<'PY'
import csv, sys
probe, area_csv = sys.argv[1], sys.argv[2]
area = {r["label"]: r for r in csv.DictReader(open(area_csv))}
data = {}
for top, label, period, mode, value in csv.reader(open(probe)):
    data.setdefault((top, label, float(period)), {})[mode] = float(value)

print(f"{'top':<26}{'cells':>8}{'ns':>5} | {'-input W':>10}{'-global W':>11}"
      f"{'amp':>7} | {'nW/cell @2ns':>13}")
print("-" * 92)
rows = []
for (top, label, period), m in data.items():
    cells = int(area[label]["cells"])
    # Normalize to one clock period so designs at 250 and 500 MHz compare.
    per_cell = m["global"] * (period / 2.0) / cells * 1e9
    rows.append((m["input"] / m["global"], top, cells, period,
                 m["input"], m["global"], per_cell))
for amp, top, cells, period, vin, vg, per_cell in sorted(rows):
    print(f"{top:<26}{cells:>8}{period:>5} | {vin:>10.4f}{vg:>11.4f}"
          f"{amp:>6.1f}x | {per_cell:>13.1f}")

per = [r[6] for r in rows]
amps = [r[0] for r in rows]
print()
print(f"-global nW/cell : {min(per):.1f} .. {max(per):.1f}  "
      f"(spread {max(per)/min(per):.2f}x)  <- tracks cell count, as it should")
print(f"-input/-global  : {min(amps):.1f}x .. {max(amps):.1f}x  "
      f"(spread {max(amps)/min(amps):.1f}x) <- what the tables actually rank")
PY
