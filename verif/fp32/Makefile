# Verilator checks for the binary32 accumulation path added to the SIMD rows.
#
#   make            build and run every check
#   make arith      the localized binary32 adder only
#   make mac        the four-stage MAC lane pipeline only
#   make clean
#
# The rest of verif/ runs on cocotb with Python golden models. These two run on
# Verilator with a C++ main instead, because the golden model here is the host's
# own IEEE-754 binary32 arithmetic. Comparing the lane against it directly is
# both stronger and simpler than restating the rounding rules, and it means the
# check runs with nothing installed beyond Verilator and a C++ compiler.
#
# What each covers:
#
#   arith  the local FP32 adder over its finite DAZ/FTZ contract, plus four
#          million randomized pairs weighted toward cancellation, alignment
#          and subnormal-input cases.
#   mac    the internal binary16 widening, stage alignment, and the acc_clear /
#          acc_enable semantics across a randomized stream with bubbles. The
#          multiplier is taken as given, since it has its own exhaustive
#          regression under verif/tests.

RTL       := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../rtl)
VERILATOR ?= verilator
VFLAGS    := --cc --exe --build -j 4 \
             -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

ARITH_SOURCES := $(RTL)/1_hbmpim/hbmpim_fp32_add.v

MAC_SOURCES := $(ARITH_SOURCES) \
               $(RTL)/1_hbmpim/hbmpim_fp16_mul.v \
               $(RTL)/1_hbmpim/hbmpim_fp16_mac_1_lane.v

PCU_SOURCES := $(RTL)/2_awq_p3llm_16pe/compressor_4to2.sv \
               $(RTL)/2_awq_p3llm_16pe/int4_asym_decode.v \
               $(RTL)/2_awq_p3llm_16pe/int4float_align.v \
               $(RTL)/2_awq_p3llm_16pe/int4float_pe.v

.PHONY: all arith mac align clean

all: arith mac align
	@echo "=== fp32 checks passed ==="

arith:
	@$(VERILATOR) $(VFLAGS) -Mdir obj_arith --top-module tb_top \
	    tb_top.v $(ARITH_SOURCES) main.cpp -o tbarith > /dev/null
	@./obj_arith/tbarith

mac:
	@$(VERILATOR) $(VFLAGS) -Mdir obj_mac --top-module tb_mac \
	    tb_mac.v $(MAC_SOURCES) main_mac.cpp -o tbmac > /dev/null
	@./obj_mac/tbmac

align:
	@$(VERILATOR) $(VFLAGS) -Mdir obj_align --top-module tb_align \
	    tb_align.v $(PCU_SOURCES) main_align.cpp -o tbalign > /dev/null
	@./obj_align/tbalign

clean:
	rm -rf obj_arith obj_mac obj_align
