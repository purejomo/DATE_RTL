# Post-synthesis power with VCD-annotated switching activity.
#
# The project compares four designs, so power must come from the same stimulus
# distribution for each. Activity is annotated from a VCD produced by that
# design's own cocotb regression rather than from a default toggle rate.
#
# Required: POWER_LIB, POWER_NETLIST, POWER_SDC, POWER_TOP
# Optional: POWER_VCD, POWER_VCD_SCOPE

read_lef $::env(POWER_TECH_LEF)
read_lef $::env(POWER_CELL_LEF)
read_liberty $::env(POWER_LIB)
read_verilog $::env(POWER_NETLIST)
link_design $::env(POWER_TOP)
read_sdc $::env(POWER_SDC)

if {[info exists ::env(POWER_VCD)] && $::env(POWER_VCD) ne ""
        && [file exists $::env(POWER_VCD)]} {
    if {[info exists ::env(POWER_VCD_SCOPE)] && $::env(POWER_VCD_SCOPE) ne ""} {
        read_power_activities -scope $::env(POWER_VCD_SCOPE) \
            -vcd $::env(POWER_VCD)
    } else {
        read_power_activities -vcd $::env(POWER_VCD)
    }
    puts "activity source: VCD $::env(POWER_VCD)"
} else {
    # Combinational compute boundaries have no meaningful VCD of their own, so
    # they are compared under one explicit activity instead. The rate matches
    # the AiM flow already in this repository.
    #
    # `-global` puts that activity on every net with no propagation. The
    # alternative -- annotating only the primary inputs and letting OpenSTA
    # propagate -- was measured and dropped: its transition-density model sums
    # densities at XOR gates and ignores reconvergence, so activity grows with
    # combinational depth and is reset by a flip-flop, which ranks pipeline
    # depth as much as energy. Against the P3-LLM paper's reported energy ratio
    # over HBM-PIM (3.83x) this model lands at 3.44x while the propagating one
    # gave 18.81x, and the area ratio agrees at the same time (paper 3.69x vs
    # 3.38x here).
    #
    # It still reduces to power roughly proportional to cell count, so it gives
    # no credit to a design that genuinely toggles less. Cross-design energy is
    # therefore claimed only at the ratio level; a stronger claim needs a
    # gate-level VCD, which this flow does not yet produce.
    set activity 0.20
    if {[info exists ::env(POWER_ACTIVITY)]} {
        set activity $::env(POWER_ACTIVITY)
    }
    set_power_activity -global -activity $activity -duty 0.50
    puts "activity source: vectorless global, activity $activity"
}

puts "=== report_power $::env(POWER_TOP) ==="
report_power
