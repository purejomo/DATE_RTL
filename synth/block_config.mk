ifndef BLOCK_DESIGN_NAME
$(error BLOCK_DESIGN_NAME is required)
endif

ifndef BLOCK_VERILOG_FILE
$(error BLOCK_VERILOG_FILE is required)
endif

ifndef BLOCK_SDC_FILE
$(error BLOCK_SDC_FILE is required)
endif

export DESIGN_NAME = $(BLOCK_DESIGN_NAME)
export PLATFORM = nangate45
export VERILOG_FILES = $(BLOCK_VERILOG_FILE)
export SDC_FILE = $(BLOCK_SDC_FILE)

export CLOCK_PERIOD ?= 1.0
export ABC_CLOCK_PERIOD_IN_PS = $(shell awk 'BEGIN {printf "%.0f", ($(CLOCK_PERIOD)) * 1000}')
export CORE_UTILIZATION ?= 40
export PLACE_DENSITY ?= 0.55
export ABC_AREA ?= 1
export ADDER_MAP_FILE :=
export TNS_END_PERCENT = 100
