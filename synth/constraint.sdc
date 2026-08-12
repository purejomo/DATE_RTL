current_design $::env(DESIGN_NAME)

set clk_name core_clock
set clk_period $::env(CLOCK_PERIOD)
set clk_io_fraction 0.20
# Accept either spelling of the clock port. Without this a design whose clock
# is not literally named "clk" falls through to the virtual-clock branch below,
# leaving its sequential paths unconstrained. No existing row has a port named
# pim_clk, so their results are unaffected.
set clk_port [get_ports -quiet clk]
if {[llength $clk_port] == 0} {
    set clk_port [get_ports -quiet pim_clk]
}

# A virtual clock keeps the same input/output timing budget for combinational
# lane wrappers that intentionally have no clock port.
if {[llength $clk_port] > 0} {
    create_clock -name $clk_name -period $clk_period $clk_port
    set non_clock_inputs \
        [lsearch -inline -all -not -exact [all_inputs] $clk_port]
} else {
    create_clock -name $clk_name -period $clk_period
    set non_clock_inputs [all_inputs]
}

if {[llength $non_clock_inputs] > 0} {
    set_input_delay [expr $clk_period * $clk_io_fraction] \
        -clock $clk_name $non_clock_inputs
}

set design_outputs [all_outputs]
if {[llength $design_outputs] > 0} {
    set_output_delay [expr $clk_period * $clk_io_fraction] \
        -clock $clk_name $design_outputs
}
