# cocotb + Verilator regression for every arithmetic block in the paper.
#
#   make                       run the whole regression
#   make TEST=int4bf16_mul     run one test
#   make list                  show the test names
#   make distclean             remove build artefacts
#
# Each test names an RTL top and a golden model. The models are pure Python
# integer arithmetic with no host floating point anywhere, so a match is a
# statement about the design rather than about the simulator's FPU.

RTL   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../rtl)
VERIF := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# 논문 4개 행을 모두 덮는다: baseline lane, awq lane, awq PCU, p3llm PCU.
TESTS := fp16_mul fp16_add int4fp16_mul int4bf16_mul bf16_add \
         pcu_fp16_32 pcu_bf16_32 pcu_fp16_64 pcu_bf16_64 \
         p3llm_decoders p3llm_compressor p3llm_pe p3llm_pcu

.PHONY: all list distclean
all:
	@for t in $(TESTS); do \
	    echo "=== $$t ==="; \
	    $(MAKE) --no-print-directory TEST=$$t sim || exit 1; \
	done
	@echo "=== all $(words $(TESTS)) tests passed ==="

list:
	@printf '  %s\n' $(TESTS)

TEST ?= fp16_mul

# --- lane-level tests: one multiplier or adder, no clock -------------------

ifeq ($(TEST),fp16_mul)
COCOTB_TOPLEVEL := hbmpim_fp16_mul_lane
MODULE          := test_fp16_mul_lane
VERILOG_SOURCES := $(RTL)/1_hbmpim/hbmpim_fp16_mul_lane.v
endif

ifeq ($(TEST),fp16_add)
COCOTB_TOPLEVEL := hbmpim_fp16_add_lane
MODULE          := test_fp16_add_lane
VERILOG_SOURCES := $(RTL)/1_hbmpim/hbmpim_fp16_add_lane.v
endif

ifeq ($(TEST),int4bf16_mul)
COCOTB_TOPLEVEL := int4bf16_mul_lane
MODULE          := test_int4bf16_mul_lane
VERILOG_SOURCES := $(RTL)/common/int4_asym_decode.v \
                   $(RTL)/2_awq_hbmpim/int4bf16_mul_lane.v
endif

ifeq ($(TEST),int4fp16_mul)
COCOTB_TOPLEVEL := int4fp16_mul_lane
MODULE          := test_int4fp16_mul_lane
VERILOG_SOURCES := $(RTL)/common/int4_asym_decode.v \
                   $(RTL)/2_awq_hbmpim/int4fp16_mul_lane.v
endif

ifeq ($(TEST),bf16_add)
COCOTB_TOPLEVEL := bf16_add_lane
MODULE          := test_bf16_add_lane
VERILOG_SOURCES := $(RTL)/2_awq_hbmpim/bf16_add_lane.v
endif

# --- PCU tests: full tile through the four-stage pipeline ------------------
#
# 8-PE 빌드와 16-PE 빌드는 rtl/3_awq_p3llm_8pe, rtl/3_awq_p3llm_16pe 로 나뉘어
# 있고 각자 int4float_pcu/pe/align 사본을 들고 있다. 따라서 한 번에 한쪽
# 디렉토리만 컴파일한다. 두 벌을 함께 넣으면 세 모듈이 중복 정의된다.

ifneq ($(filter $(TEST),pcu_fp16_32 pcu_bf16_32 pcu_fp16_64 pcu_bf16_64),)
MODULE          := test_int4float_pcu
PCU_FORMAT      := $(if $(findstring bf16,$(TEST)),bf16,fp16)
PCU_NUM_PES     := $(if $(findstring _32,$(TEST)),8,16)
PCU_SUFFIX      := $(if $(findstring _32,$(TEST)),pcu32,pcu_top)
PCU_DIR         := $(RTL)/3_awq_p3llm_$(PCU_NUM_PES)pe
COCOTB_TOPLEVEL := int4$(PCU_FORMAT)_$(PCU_SUFFIX)
VERILOG_SOURCES := $(RTL)/common/compressor_4to2.sv \
                   $(RTL)/common/int4_asym_decode.v \
                   $(PCU_DIR)/int4float_align.v \
                   $(PCU_DIR)/int4float_pe.v \
                   $(PCU_DIR)/int4float_pcu.v \
                   $(PCU_DIR)/$(COCOTB_TOPLEVEL).v
export PCU_FORMAT PCU_NUM_PES
endif

# --- P3-LLM: decoders, compressor, PE, and the whole PCU ------------------
#
# The PE and PCU tests turn on the design's own SystemVerilog assertions, so a
# violation inside the pipeline fails the run even when the output happens to
# match.

P3LLM_RTL := $(RTL)/4_p3llm/p3llm_pkg.sv \
             $(RTL)/4_p3llm/fp8_e4m3_decoder.sv \
             $(RTL)/4_p3llm/fp8_s0e4m4_decoder.sv \
             $(RTL)/4_p3llm/bitmod4_decoder.sv \
             $(RTL)/4_p3llm/int4_asym_decoder.sv \
             $(RTL)/4_p3llm/fixed_mul_shift.sv \
             $(RTL)/common/compressor_4to2.sv \
             $(RTL)/4_p3llm/p3llm_pe.sv

ifeq ($(TEST),p3llm_decoders)
COCOTB_TOPLEVEL := decoder_tb
MODULE          := test_p3llm_decoders
TESTCASE        := test_all_decoders
VERILOG_SOURCES := $(RTL)/4_p3llm/fp8_e4m3_decoder.sv \
                   $(RTL)/4_p3llm/fp8_s0e4m4_decoder.sv \
                   $(RTL)/4_p3llm/bitmod4_decoder.sv \
                   $(RTL)/4_p3llm/int4_asym_decoder.sv \
                   $(VERIF)/tests/harness/decoder_tb.sv
endif

ifeq ($(TEST),p3llm_compressor)
COCOTB_TOPLEVEL := compressor_tb
MODULE          := test_p3llm_pe
TESTCASE        := test_compressor
VERILOG_SOURCES := $(RTL)/common/compressor_4to2.sv \
                   $(VERIF)/tests/harness/compressor_tb.sv
endif

ifeq ($(TEST),p3llm_pe)
COCOTB_TOPLEVEL := p3llm_pe
MODULE          := test_p3llm_pe
TESTCASE        := test_pe_directed
VERILOG_SOURCES := $(P3LLM_RTL)
EXTRA_ARGS      += --assert -DP3LLM_DEBUG -DP3LLM_ASSERTIONS
endif

ifeq ($(TEST),p3llm_pcu)
COCOTB_TOPLEVEL := p3llm_pcu
MODULE          := test_p3llm_pcu
TESTCASE        := test_pcu_regression
VERILOG_SOURCES := $(P3LLM_RTL) $(RTL)/4_p3llm/p3llm_pcu.sv
EXTRA_ARGS      += --assert -DP3LLM_ASSERTIONS
endif

ifndef COCOTB_TOPLEVEL
$(error unknown TEST '$(TEST)'. Run 'make list'.)
endif

SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
TOPLEVEL      := $(COCOTB_TOPLEVEL)

COCOTB_TEST_MODULES  := $(MODULE)
COCOTB_RESULTS_FILE  := $(VERIF)/build/$(TEST).xml
SIM_BUILD            := $(VERIF)/build/$(TEST)

export PYTHONPATH := $(VERIF)/tests:$(VERIF)/models:$(PYTHONPATH)
COMPILE_ARGS += --timing --timescale 1ns/1ps $(EXTRA_ARGS)

distclean:
	rm -rf $(VERIF)/build

include $(shell cocotb-config --makefiles)/Makefile.sim
