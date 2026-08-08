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
    # they are compared under one explicit input activity instead. The rate
    # matches the AiM flow already in this repository.
    set input_activity 0.20
    if {[info exists ::env(POWER_INPUT_ACTIVITY)]} {
        set input_activity $::env(POWER_INPUT_ACTIVITY)
    }
    set_power_activity -input -activity $input_activity -duty 0.50
    puts "activity source: vectorless, input activity $input_activity"
}

puts "=== report_power $::env(POWER_TOP) ==="
report_power
