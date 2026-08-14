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

# 논문 5개 행을 모두 덮는다: baseline lane, awq lane, awq PCU, p3llm PCU, rabit PCU.
TESTS := fp16_mul int4fp16_mul int4bf16_mul \
         pcu_fp16_32 pcu_bf16_32 pcu_fp16_64 pcu_bf16_64 \
         p3llm_decoders p3llm_compressor p3llm_pe p3llm_pcu \
         rabit_cvt rabit_align rabit_pe rabit_acc \
         rabit_pcu rabit_pcu_m10 rabit_pcu_noshift rabit_pcu_m10_noshift \
         rabit_fs rabit_fs_pipe rabit_fs_h16 \
         p3llm_dequant_arith p3llm_dequant

.PHONY: all list distclean
# cocotb's simulator wrapper exits 0 even when a testcase fails -- it reports the
# failure in the JUnit XML and lets make carry on. Checking only the exit status
# therefore prints "all tests passed" over a red regression, so every test is
# also required to leave a results file with no <failure> element in it.
all:
	@failed=""; \
	for t in $(TESTS); do \
	    echo "=== $$t ==="; \
	    $(MAKE) --no-print-directory TEST=$$t sim || failed="$$failed $$t"; \
	    if [ ! -f $(VERIF)/build/$$t.xml ]; then \
	        echo "!!! $$t produced no results file"; failed="$$failed $$t"; \
	    elif grep -q '<failure' $(VERIF)/build/$$t.xml; then \
	        echo "!!! $$t reported a failure"; failed="$$failed $$t"; \
	    fi; \
	done; \
	if [ -n "$$failed" ]; then \
	    echo "=== regression FAILED:$$failed ==="; exit 1; \
	fi; \
	echo "=== all $(words $(TESTS)) tests passed ==="

list:
	@printf '  %s\n' $(TESTS)

TEST ?= fp16_mul

# --- lane-level tests: one multiplier, no clock ----------------------------
#
# The 16-bit adder lanes are gone. Each SIMD design now keeps its binary32
# accumulation adder locally; verif/fp32 checks both copies against the host's
# IEEE-754 arithmetic rather than duplicating that model in cocotb.

ifeq ($(TEST),fp16_mul)
COCOTB_TOPLEVEL := hbmpim_fp16_mul
MODULE          := test_fp16_mul_lane
VERILOG_SOURCES := $(RTL)/1_hbmpim/hbmpim_fp16_mul.v
endif

ifeq ($(TEST),int4bf16_mul)
COCOTB_TOPLEVEL := awq_int4bf16_mul
MODULE          := test_int4bf16_mul_lane
VERILOG_SOURCES := $(RTL)/2_awq_hbmpim/awq_int4bf16_mul.v
endif

ifeq ($(TEST),int4fp16_mul)
COCOTB_TOPLEVEL := awq_int4fp16_mul
MODULE          := test_int4fp16_mul_lane
VERILOG_SOURCES := $(RTL)/2_awq_hbmpim/awq_int4fp16_mul.v
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
VERILOG_SOURCES := $(PCU_DIR)/compressor_4to2.sv \
                   $(PCU_DIR)/int4_asym_decode.v \
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
             $(RTL)/4_p3llm/compressor_4to2.sv \
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
VERILOG_SOURCES := $(RTL)/4_p3llm/compressor_4to2.sv \
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

P3LLM_DEQUANT_DIR := $(RTL)/4_p3llm_with_dequant
P3LLM_DEQUANT_RTL := $(P3LLM_DEQUANT_DIR)/p3llm_pkg.sv \
                     $(P3LLM_DEQUANT_DIR)/fp8_e4m3_decoder.sv \
                     $(P3LLM_DEQUANT_DIR)/fp8_s0e4m4_decoder.sv \
                     $(P3LLM_DEQUANT_DIR)/bitmod4_decoder.sv \
                     $(P3LLM_DEQUANT_DIR)/int4_asym_decoder.sv \
                     $(P3LLM_DEQUANT_DIR)/fixed_mul_shift.sv \
                     $(P3LLM_DEQUANT_DIR)/compressor_4to2.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_pe.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_pcu.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fixed32_fp16_mul_pipe.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_add_pipe.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_fp16_mul_pack_pipe.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_pcu_dequant.sv

ifeq ($(TEST),p3llm_dequant_arith)
COCOTB_TOPLEVEL := p3llm_dequant_arith_tb
MODULE          := test_p3llm_dequant_arith
TESTCASE        := test_dequant_arithmetic_boundaries
VERILOG_SOURCES := $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fixed32_fp16_mul_pipe.sv \
                   $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_add_pipe.sv \
                   $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_fp16_mul_pack_pipe.sv \
                   $(VERIF)/tests/harness/p3llm_dequant_arith_tb.sv
endif

ifeq ($(TEST),p3llm_dequant)
COCOTB_TOPLEVEL := p3llm_pcu_dequant
MODULE          := test_p3llm_pcu_dequant
TESTCASE        := test_pcu_dequant_all_modes
VERILOG_SOURCES := $(P3LLM_DEQUANT_RTL)
EXTRA_ARGS      += --assert -DP3LLM_ASSERTIONS
endif

# --- RaBiT: convert-on-write, PE, accumulator array, whole PCU -------------
#
# rabit_pcu* 는 설계의 SystemVerilog assertion (RABIT_ASSERTIONS) 을 켜고 돈다.
# 입력 GRF / CRF / bank / NPU 는 합성 범위 밖이라 testbench 의 behavioral model
# 로만 존재하고, stimulus 는 tools/pack_rabit.py 가 만든 실제 word stream 이다.

RABIT_RTL := $(RTL)/5_rabit/rabit_compressor_4to2.sv \
             $(RTL)/5_rabit/rabit_cvt_fp16_blk.sv \
             $(RTL)/5_rabit/rabit_align_shift.sv \
             $(RTL)/5_rabit/rabit_pe.sv \
             $(RTL)/5_rabit/rabit_acc_regfile.sv \
             $(RTL)/5_rabit/rabit_pcu_ctrl.sv \
             $(RTL)/5_rabit/rabit_pcu_top.sv

ifeq ($(TEST),rabit_cvt)
COCOTB_TOPLEVEL := rabit_cvt_tb
MODULE          := test_rabit_cvt
VERILOG_SOURCES := $(RTL)/5_rabit/rabit_cvt_fp16_blk.sv \
                   $(VERIF)/tests/harness/rabit_cvt_tb.sv
endif

ifeq ($(TEST),rabit_align)
COCOTB_TOPLEVEL := rabit_align_tb
MODULE          := test_rabit_align
VERILOG_SOURCES := $(RTL)/5_rabit/rabit_align_shift.sv \
                   $(VERIF)/tests/harness/rabit_align_tb.sv
endif

ifeq ($(TEST),rabit_pe)
COCOTB_TOPLEVEL := rabit_pe
MODULE          := test_rabit_pe
VERILOG_SOURCES := $(RTL)/5_rabit/rabit_compressor_4to2.sv \
                   $(RTL)/5_rabit/rabit_align_shift.sv \
                   $(RTL)/5_rabit/rabit_pe.sv
EXTRA_ARGS      += --assert -DRABIT_ASSERTIONS
endif

ifeq ($(TEST),rabit_acc)
COCOTB_TOPLEVEL := rabit_acc_regfile
MODULE          := test_rabit_acc
VERILOG_SOURCES := $(RTL)/5_rabit/rabit_acc_regfile.sv
endif

ifneq ($(filter $(TEST),rabit_pcu rabit_pcu_m10 rabit_pcu_noshift rabit_pcu_m10_noshift),)
MODULE            := test_rabit_pcu
COCOTB_TOPLEVEL   := $(TEST)
RABIT_MANT_W      := $(if $(findstring m10,$(TEST)),10,12)
RABIT_SHIFTER_EN  := $(if $(findstring noshift,$(TEST)),0,1)
VERILOG_SOURCES   := $(RABIT_RTL) $(RTL)/5_rabit/rabit_pcu_synth.sv
EXTRA_ARGS        += --assert -DRABIT_ASSERTIONS
export RABIT_MANT_W RABIT_SHIFTER_EN
endif

# --- RaBiT full-scale PCU -------------------------------------------------
#
# rtl/5_rabit holds the base variant and rtl/5_rabit_fullsacle the full-scale
# one. The full-scale top reuses the base modules rather than copying them, so
# both directories are compiled together and sv2v/Verilator see one definition
# of each shared module. rabit_fs_h16 is the same design with H_FMT = FP16_3WR,
# which changes the write schedule -- the testbench's stimulus generator picks
# it up from RABIT_FS_H_FMT.

RABIT_BASE_RTL := $(RTL)/5_rabit/rabit_compressor_4to2.sv \
                  $(RTL)/5_rabit/rabit_align_shift.sv \
                  $(RTL)/5_rabit/rabit_pe.sv \
                  $(RTL)/5_rabit/rabit_cvt_fp16_blk.sv \
                  $(RTL)/5_rabit/rabit_acc_regfile.sv \
                  $(RTL)/5_rabit/rabit_pcu_ctrl.sv

RABIT_FS_RTL := $(RABIT_BASE_RTL) \
                $(RTL)/5_rabit_fullsacle/rabit_fs_fp16_pack.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_h_scale_unit.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_g_buffer.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_dq_lane.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_dq_add.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_dq_unit.sv \
                $(RTL)/5_rabit_fullsacle/rabit_fs_drain_seq.sv \
                $(RTL)/5_rabit_fullsacle/rabit_pcu_fs_top.sv \
                $(RTL)/5_rabit_fullsacle/rabit_pcu_fs_synth.sv

ifeq ($(TEST),rabit_fs)
COCOTB_TOPLEVEL := rabit_pcu_fs
MODULE          := test_rabit_fs_pcu
VERILOG_SOURCES := $(RABIT_FS_RTL)
EXTRA_ARGS      += --assert -DRABIT_ASSERTIONS -DRABIT_FS_ASSERTIONS
RABIT_FS_H_FMT  := 0
export RABIT_FS_H_FMT
endif

ifeq ($(TEST),rabit_fs_pipe)
COCOTB_TOPLEVEL := rabit_pcu_fs_p
MODULE          := test_rabit_fs_pcu
VERILOG_SOURCES := $(RABIT_FS_RTL)
EXTRA_ARGS      += --assert -DRABIT_ASSERTIONS -DRABIT_FS_ASSERTIONS
RABIT_FS_H_FMT  := 0
export RABIT_FS_H_FMT
endif

ifeq ($(TEST),rabit_fs_h16)
COCOTB_TOPLEVEL := rabit_pcu_fs_h16
MODULE          := test_rabit_fs_pcu
VERILOG_SOURCES := $(RABIT_FS_RTL)
EXTRA_ARGS      += --assert -DRABIT_ASSERTIONS -DRABIT_FS_ASSERTIONS
RABIT_FS_H_FMT  := 1
export RABIT_FS_H_FMT
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
