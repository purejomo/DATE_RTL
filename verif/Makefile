# cocotb + Verilator regression for every arithmetic block in the paper.
#
#   make                       run the whole regression
#   make TEST=pcu_bf16_64      run one test
#   make list                  show the test names
#   make distclean             remove build artefacts
#
# Each test names an RTL top and a golden model. The models are pure Python
# integer arithmetic with no host floating point anywhere, so a match is a
# statement about the design rather than about the simulator's FPU.

RTL   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../rtl)
VERIF := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# 논문 5개 행을 모두 덮는다: baseline lane, awq PCU, p3llm PCU, rabit PCU,
# spinquant PCU.
TESTS := fp16_mul \
         pcu_bf16_32 pcu_fp16_32 pcu_bf16_64 \
         pcu_bf16_32_acc16 pcu_fp16_32_acc16 pcu_bf16_64_acc16 \
         p3llm_decoders p3llm_compressor p3llm_pe p3llm_pcu p3llm_pcu_acc16 \
         rabit_cvt rabit_align rabit_pe rabit_acc \
         rabit_pcu rabit_pcu_m10 rabit_pcu_noshift rabit_pcu_m10_noshift \
         rabit_pcu_acc16 \
         rabit_fs rabit_fs_pipe rabit_fs_h16 \
         p3llm_dequant_arith p3llm_dequant \
         awq_dequant_arith pcu_bf16_32_dq pcu_bf16_64_dq \
         spinquant_pe spinquant_acc \
         spinquant_pcu spinquant_pcu_nolatch spinquant_pcu_acc32 \
         spinquant_pcu_r2e2 spinquant_pcu_r2 spinquant_pcu_r4 spinquant_pcu_w512

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
# The 16-bit adder lanes are gone. The SIMD baseline keeps its binary32
# accumulation adder locally; verif/fp32 checks it against the host's IEEE-754
# arithmetic rather than duplicating that model in cocotb.

ifeq ($(TEST),fp16_mul)
COCOTB_TOPLEVEL := hbmpim_fp16_mul
MODULE          := test_fp16_mul_lane
VERILOG_SOURCES := $(RTL)/1_hbmpim/hbmpim_fp16_mul.v
endif

# --- PCU tests: full tile through the four-stage pipeline ------------------
#
# 8-PE 빌드와 16-PE 빌드는 rtl/2_awq_p3llm_8pe_v2, rtl/2_awq_p3llm_16pe_v2 로
# 나뉘어 있고 각자 int4float_pcu/pe/align 사본을 들고 있다. 따라서 한 번에 한쪽
# 디렉토리만 컴파일한다. 두 벌을 함께 넣으면 세 모듈이 중복 정의된다.
#
# 이제 두 빌드 모두 v2 계약이다: `i_weight_zp` 이 PE 당 독립 4-bit
# (NUM_PES*4 bit) 이며, v1 broadcast nibble 빌드는 트리에서 삭제됐다.
# testbench 는 PCU_ZP_PER_PE 로 계약을 받아 stimulus 와 golden model 을 함께
# 맞추는데, 양쪽 계약을 모두 지원하므로 상수 1 을 주면 된다.

PCU8_DIR  := $(RTL)/2_awq_p3llm_8pe_v2
PCU16_DIR := $(RTL)/2_awq_p3llm_16pe_v2

PCU8_ACC16_DIR  := $(RTL)/2_awq_p3llm_8pe_v2_acc16
PCU16_ACC16_DIR := $(RTL)/2_awq_p3llm_16pe_v2_acc16

AWQ_PCU_TESTS := pcu_bf16_32 pcu_bf16_64 pcu_fp16_32 \
                 pcu_bf16_32_acc16 pcu_bf16_64_acc16 pcu_fp16_32_acc16

ifneq ($(filter $(TEST),$(AWQ_PCU_TESTS)),)
MODULE          := test_int4float_pcu
PCU_IS_8PE      := $(findstring _32,$(TEST))
PCU_IS_ACC16    := $(findstring acc16,$(TEST))
PCU_NUM_PES     := $(if $(PCU_IS_8PE),8,16)
PCU_ZP_PER_PE   := 1
PCU_FMT         := $(if $(findstring fp16,$(TEST)),fp16,bf16)
PCU_SUFFIX      := $(if $(PCU_IS_8PE),pcu32,pcu_top)
# acc16 keeps the same PE count and format but narrows the accumulator. The
# shift is the worst-case-safe value the RTL defaults to: 12 for bfloat16
# (ALIGNED_W 17) and 15 for binary16 (ALIGNED_W 20). See int4float_pe.v.
PCU_ACC_W       := $(if $(PCU_IS_ACC16),16,32)
PCU_ACC_RSH     := $(if $(PCU_IS_ACC16),$(if $(findstring fp16,$(TEST)),15,12),0)
PCU_DIR         := $(if $(PCU_IS_ACC16),\
                     $(if $(PCU_IS_8PE),$(PCU8_ACC16_DIR),$(PCU16_ACC16_DIR)),\
                     $(if $(PCU_IS_8PE),$(PCU8_DIR),$(PCU16_DIR)))
COCOTB_TOPLEVEL := int4$(PCU_FMT)_$(PCU_SUFFIX)$(if $(PCU_IS_ACC16),_acc16,)
VERILOG_SOURCES := $(PCU_DIR)/compressor_4to2.sv \
                   $(PCU_DIR)/int4_asym_decode.v \
                   $(PCU_DIR)/int4float_align.v \
                   $(PCU_DIR)/int4float_pe.v \
                   $(PCU_DIR)/int4float_pcu.v \
                   $(PCU_DIR)/$(COCOTB_TOPLEVEL).v
export PCU_NUM_PES PCU_ZP_PER_PE PCU_FMT PCU_ACC_W PCU_ACC_RSH
endif

# --- P3-LLM: decoders, compressor, PE, and the whole PCU ------------------
#
# The PE and PCU tests turn on the design's own SystemVerilog assertions, so a
# violation inside the pipeline fails the run even when the output happens to
# match.

P3LLM_RTL := $(RTL)/3_p3llm/p3llm_pkg.sv \
             $(RTL)/3_p3llm/fp8_e4m3_decoder.sv \
             $(RTL)/3_p3llm/fp8_s0e4m4_decoder.sv \
             $(RTL)/3_p3llm/bitmod4_decoder.sv \
             $(RTL)/3_p3llm/int4_asym_decoder.sv \
             $(RTL)/3_p3llm/fixed_mul_shift.sv \
             $(RTL)/3_p3llm/compressor_4to2.sv \
             $(RTL)/3_p3llm/p3llm_pe.sv

ifeq ($(TEST),p3llm_decoders)
COCOTB_TOPLEVEL := decoder_tb
MODULE          := test_p3llm_decoders
TESTCASE        := test_all_decoders
VERILOG_SOURCES := $(RTL)/3_p3llm/fp8_e4m3_decoder.sv \
                   $(RTL)/3_p3llm/fp8_s0e4m4_decoder.sv \
                   $(RTL)/3_p3llm/bitmod4_decoder.sv \
                   $(RTL)/3_p3llm/int4_asym_decoder.sv \
                   $(VERIF)/tests/harness/decoder_tb.sv
endif

ifeq ($(TEST),p3llm_compressor)
COCOTB_TOPLEVEL := compressor_tb
MODULE          := test_p3llm_pe
TESTCASE        := test_compressor
VERILOG_SOURCES := $(RTL)/3_p3llm/compressor_4to2.sv \
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
VERILOG_SOURCES := $(P3LLM_RTL) $(RTL)/3_p3llm/p3llm_pcu.sv
EXTRA_ARGS      += --assert -DP3LLM_ASSERTIONS
endif

# The acc16 axis. rtl/3_p3llm_acc16 is a full copy of rtl/3_p3llm -- both
# define p3llm_pkg and every p3llm_* module -- so the two are never compiled
# together. ACC_RSH 16 is the RTL default: it is the smallest shift for which a
# 128-element group cannot saturate in any op_mode, which is also "keep the top
# 16 bits of the base build's accumulator". See p3llm_pe.sv for the derivation.

P3LLM_ACC16_RTL := $(RTL)/3_p3llm_acc16/p3llm_pkg.sv \
                   $(RTL)/3_p3llm_acc16/fp8_e4m3_decoder.sv \
                   $(RTL)/3_p3llm_acc16/fp8_s0e4m4_decoder.sv \
                   $(RTL)/3_p3llm_acc16/bitmod4_decoder.sv \
                   $(RTL)/3_p3llm_acc16/int4_asym_decoder.sv \
                   $(RTL)/3_p3llm_acc16/fixed_mul_shift.sv \
                   $(RTL)/3_p3llm_acc16/compressor_4to2.sv \
                   $(RTL)/3_p3llm_acc16/p3llm_pe.sv \
                   $(RTL)/3_p3llm_acc16/p3llm_pcu_acc16.sv

ifeq ($(TEST),p3llm_pcu_acc16)
COCOTB_TOPLEVEL := p3llm_pcu_acc16
MODULE          := test_p3llm_pcu
TESTCASE        := test_pcu_regression
VERILOG_SOURCES := $(P3LLM_ACC16_RTL)
EXTRA_ARGS      += --assert -DP3LLM_ASSERTIONS
P3LLM_ACC_W     := 16
P3LLM_ACC_RSH   := 16
export P3LLM_ACC_W P3LLM_ACC_RSH
endif

P3LLM_DEQUANT_DIR := $(RTL)/3_p3llm_dequant_rne
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
                     $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_fp8_mul_pack_pipe.sv \
                     $(P3LLM_DEQUANT_DIR)/p3llm_pcu_dequant.sv

# --- AWQ in-PCU dequantization ------------------------------------------
#
# The AWQ dequant_rne directories carry their own parameterized copies of the
# three shared FP pipes: the multiplier takes the scale format as a parameter
# and a wider signed binary exponent, and the packer has no second scale. The
# harness instantiates both bfloat16 and binary16 variants, so one run covers
# both activation formats.

AWQ_DQ_DIR := $(RTL)/2_awq_p3llm_8pe_v2_dequant_rne

AWQ_DQ8_DIR  := $(RTL)/2_awq_p3llm_8pe_v2_dequant_rne
AWQ_DQ16_DIR := $(RTL)/2_awq_p3llm_16pe_v2_dequant_rne

AWQ_DQ_PCU_TESTS := pcu_bf16_32_dq pcu_bf16_64_dq pcu_fp16_32_dq

ifneq ($(filter $(TEST),$(AWQ_DQ_PCU_TESTS)),)
MODULE          := test_int4float_pcu_dq
PCU_IS_8PE      := $(findstring _32,$(TEST))
PCU_NUM_PES     := $(if $(PCU_IS_8PE),8,16)
PCU_FMT         := $(if $(findstring fp16,$(TEST)),fp16,bf16)
PCU_SUFFIX      := $(if $(PCU_IS_8PE),pcu32,pcu_top)
DQ_DIR          := $(if $(PCU_IS_8PE),$(AWQ_DQ8_DIR),$(AWQ_DQ16_DIR))
COCOTB_TOPLEVEL := int4$(PCU_FMT)_$(PCU_SUFFIX)_dq
VERILOG_SOURCES := $(DQ_DIR)/compressor_4to2.sv \
                   $(DQ_DIR)/int4_asym_decode.v \
                   $(DQ_DIR)/int4float_align.v \
                   $(DQ_DIR)/int4float_pe.v \
                   $(DQ_DIR)/int4float_pcu.v \
                   $(DQ_DIR)/awq_dq_fixed32_float16_mul_pipe.sv \
                   $(DQ_DIR)/awq_dq_fp32_add_pipe.sv \
                   $(DQ_DIR)/awq_dq_fp32_pack_pipe.sv \
                   $(DQ_DIR)/int4float_pcu_dq.sv \
                   $(DQ_DIR)/$(COCOTB_TOPLEVEL).v
EXTRA_ARGS      += --assert -DAWQ_DQ_ASSERTIONS
export PCU_NUM_PES PCU_FMT
endif

ifeq ($(TEST),awq_dequant_arith)
COCOTB_TOPLEVEL := awq_dequant_arith_tb
MODULE          := test_awq_dequant_arith
TESTCASE        := test_awq_dequant_arithmetic
VERILOG_SOURCES := $(AWQ_DQ_DIR)/awq_dq_fixed32_float16_mul_pipe.sv \
                   $(AWQ_DQ_DIR)/awq_dq_fp32_add_pipe.sv \
                   $(AWQ_DQ_DIR)/awq_dq_fp32_pack_pipe.sv \
                   $(VERIF)/tests/harness/awq_dequant_arith_tb.sv
endif

ifeq ($(TEST),p3llm_dequant_arith)
COCOTB_TOPLEVEL := p3llm_dequant_arith_tb
MODULE          := test_p3llm_dequant_arith
TESTCASE        := test_dequant_arithmetic_boundaries
VERILOG_SOURCES := $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fixed32_fp16_mul_pipe.sv \
                   $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_add_pipe.sv \
                   $(P3LLM_DEQUANT_DIR)/p3llm_dequant_fp32_fp8_mul_pack_pipe.sv \
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

RABIT_RTL := $(RTL)/4_rabit/rabit_compressor_4to2.sv \
             $(RTL)/4_rabit/rabit_cvt_fp16_blk.sv \
             $(RTL)/4_rabit/rabit_align_shift.sv \
             $(RTL)/4_rabit/rabit_pe.sv \
             $(RTL)/4_rabit/rabit_acc_regfile.sv \
             $(RTL)/4_rabit/rabit_pcu_ctrl.sv \
             $(RTL)/4_rabit/rabit_pcu_top.sv

ifeq ($(TEST),rabit_cvt)
COCOTB_TOPLEVEL := rabit_cvt_tb
MODULE          := test_rabit_cvt
VERILOG_SOURCES := $(RTL)/4_rabit/rabit_cvt_fp16_blk.sv \
                   $(VERIF)/tests/harness/rabit_cvt_tb.sv
endif

ifeq ($(TEST),rabit_align)
COCOTB_TOPLEVEL := rabit_align_tb
MODULE          := test_rabit_align
VERILOG_SOURCES := $(RTL)/4_rabit/rabit_align_shift.sv \
                   $(VERIF)/tests/harness/rabit_align_tb.sv
endif

ifeq ($(TEST),rabit_pe)
COCOTB_TOPLEVEL := rabit_pe
MODULE          := test_rabit_pe
VERILOG_SOURCES := $(RTL)/4_rabit/rabit_compressor_4to2.sv \
                   $(RTL)/4_rabit/rabit_align_shift.sv \
                   $(RTL)/4_rabit/rabit_pe.sv
EXTRA_ARGS      += --assert -DRABIT_ASSERTIONS
endif

ifeq ($(TEST),rabit_acc)
COCOTB_TOPLEVEL := rabit_acc_regfile
MODULE          := test_rabit_acc
VERILOG_SOURCES := $(RTL)/4_rabit/rabit_acc_regfile.sv
endif

RABIT_PCU_TESTS := rabit_pcu rabit_pcu_m10 rabit_pcu_noshift \
                   rabit_pcu_m10_noshift

ifneq ($(filter $(TEST),$(RABIT_PCU_TESTS)),)
MODULE            := test_rabit_pcu
COCOTB_TOPLEVEL   := $(TEST)
RABIT_MANT_W      := $(if $(findstring m10,$(TEST)),10,12)
RABIT_SHIFTER_EN  := $(if $(findstring noshift,$(TEST)),0,1)
RABIT_ACC_W       := 32
RABIT_SHIFT_RND   := 0
VERILOG_SOURCES   := $(RABIT_RTL) $(RTL)/4_rabit/rabit_pcu_synth.sv
EXTRA_ARGS        += --assert -DRABIT_ASSERTIONS
export RABIT_MANT_W RABIT_SHIFTER_EN RABIT_ACC_W RABIT_SHIFT_RND
endif

# The acc16 design point lives in its own directory, which is a full copy of
# rtl/4_rabit: the two must never be compiled together, because both define
# every rabit_* module. Only the synthesis wrapper differs -- ACC_W 16,
# MANT_W 10, SHIFT_RND 1 -- so the same testbench and golden model cover it
# once they take those three as parameters.

RABIT_ACC16_RTL := $(RTL)/4_rabit_acc16/rabit_compressor_4to2.sv \
                   $(RTL)/4_rabit_acc16/rabit_cvt_fp16_blk.sv \
                   $(RTL)/4_rabit_acc16/rabit_align_shift.sv \
                   $(RTL)/4_rabit_acc16/rabit_pe.sv \
                   $(RTL)/4_rabit_acc16/rabit_acc_regfile.sv \
                   $(RTL)/4_rabit_acc16/rabit_pcu_ctrl.sv \
                   $(RTL)/4_rabit_acc16/rabit_pcu_top.sv \
                   $(RTL)/4_rabit_acc16/rabit_pcu_synth.sv

ifeq ($(TEST),rabit_pcu_acc16)
MODULE            := test_rabit_pcu
COCOTB_TOPLEVEL   := rabit_pcu_acc16
RABIT_MANT_W      := 10
RABIT_SHIFTER_EN  := 1
RABIT_ACC_W       := 16
RABIT_SHIFT_RND   := 1
# The end-to-end GEMV runs to k = 1024 here rather than the 4096 the 32-bit
# rows use, because a 16-bit accumulator cannot represent a 4096-deep sweep:
# one chunk contributes up to NIN * 2**MANT_W = 16384 accumulator LSB and there
# are 4096/16 = 256 chunks, so the worst case needs 23 bits. Measured relative
# error against the exact rational reference, one seed, 64 x k:
#
#     k =  256   1.1e-03      k = 2048   4.9e-02
#     k =  512   8.8e-04      k = 4096   1.8e-01
#     k = 1024   8.9e-04
#
# Flat at the MANT_W = 10 quantization floor to k = 1024, then the accumulator
# starts saturating. The RTL still matches the golden model bit for bit at
# every depth -- status_sticky[0] reports the saturation and check_sticky
# compares it -- so this is a property of the design point, not a defect. It is
# the accuracy side of the area saving this row exists to measure, and it is
# why the acc16 axis needs the accuracy sweep the extension plan leaves open.
RABIT_GEMV_DIN    := 1024
VERILOG_SOURCES   := $(RABIT_ACC16_RTL)
EXTRA_ARGS        += --assert -DRABIT_ASSERTIONS
export RABIT_MANT_W RABIT_SHIFTER_EN RABIT_ACC_W RABIT_SHIFT_RND RABIT_GEMV_DIN
endif

# --- RaBiT full-scale PCU -------------------------------------------------
#
# rtl/4_rabit holds the base variant and rtl/4_rabit_dequant_rne the full-scale
# one, which is RaBiT's axis-3 design point. The full-scale top reuses the base
# modules rather than copying them, so both directories are compiled together
# and sv2v/Verilator see one definition of each shared module. The test names
# (rabit_fs*) and the top names (rabit_pcu_fs*) keep the historical `fs`
# spelling: verif/models/rabit_fs_model.py, synth/build_rabit_fs_report.py and
# the results/ artefact names all key off them. rabit_fs_h16 is the same design
# with H_FMT = FP16_3WR, which changes the write schedule -- the testbench's
# stimulus generator picks it up from RABIT_FS_H_FMT.

RABIT_BASE_RTL := $(RTL)/4_rabit/rabit_compressor_4to2.sv \
                  $(RTL)/4_rabit/rabit_align_shift.sv \
                  $(RTL)/4_rabit/rabit_pe.sv \
                  $(RTL)/4_rabit/rabit_cvt_fp16_blk.sv \
                  $(RTL)/4_rabit/rabit_acc_regfile.sv \
                  $(RTL)/4_rabit/rabit_pcu_ctrl.sv

RABIT_FS_RTL := $(RABIT_BASE_RTL) \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_fp16_pack.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_h_scale_unit.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_g_buffer.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_dq_lane.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_dq_add.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_dq_unit.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_fs_drain_seq.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_pcu_fs_top.sv \
                $(RTL)/4_rabit_dequant_rne/rabit_pcu_fs_synth.sv

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

# --- SpinQuant W4A4: PE, accumulator file, whole PCU -----------------------
#
# 입력 GRF / CRF / bank / NPU 는 합성 범위 밖이라 testbench 의 behavioral model
# 로만 존재한다. testbench 가 [16 x K] weight tile 을 256b beat stream 으로 잘라
# microkernel 이 낼 command 순서를 그대로 재현하고, golden model 은 순수 정수
# GEMV 다 (verif/models/spinquant_model.py).
#
# 세 PCU 행은 같은 top 을 파라미터만 바꿔 감싼다. nolatch 는 256b bank read
# latch 를 경계 밖으로 빼고 (P3-LLM / SIMD 행이 weight 를 받는 방식), acc32 는
# carry chain 을 register 폭과 같은 32b 로 되돌린다. testbench 는 두 knob 을
# 환경변수로 받아 command 스케줄과 golden model 을 함께 맞춘다.

SPINQUANT_RTL := $(RTL)/5_spinquant/spinquant_compressor_4to2.sv \
                 $(RTL)/5_spinquant/spinquant_mul_s4u4.sv \
                 $(RTL)/5_spinquant/spinquant_pe.sv \
                 $(RTL)/5_spinquant/spinquant_acc_regfile.sv \
                 $(RTL)/5_spinquant/spinquant_pcu_top.sv

ifeq ($(TEST),spinquant_pe)
COCOTB_TOPLEVEL := spinquant_pe
MODULE          := test_spinquant_pe
VERILOG_SOURCES := $(RTL)/5_spinquant/spinquant_compressor_4to2.sv \
                   $(RTL)/5_spinquant/spinquant_mul_s4u4.sv \
                   $(RTL)/5_spinquant/spinquant_pe.sv
EXTRA_ARGS      += --assert -DSPINQUANT_ASSERTIONS
endif

ifeq ($(TEST),spinquant_acc)
COCOTB_TOPLEVEL := spinquant_acc_regfile
MODULE          := test_spinquant_acc
VERILOG_SOURCES := $(RTL)/5_spinquant/spinquant_acc_regfile.sv
endif

SPINQUANT_PCU_TESTS := spinquant_pcu spinquant_pcu_nolatch spinquant_pcu_acc32 \
                       spinquant_pcu_r2 spinquant_pcu_r2e2 spinquant_pcu_r4 \
                       spinquant_pcu_w512

ifneq ($(filter $(TEST),$(SPINQUANT_PCU_TESTS)),)
MODULE                := test_spinquant_pcu
COCOTB_TOPLEVEL       := $(TEST)
SPINQUANT_W_LATCH     := $(if $(findstring nolatch,$(TEST)),0,1)
SPINQUANT_ACC_CHAIN_W := $(if $(findstring acc32,$(TEST)),32,24)
SPINQUANT_NPE         := $(if $(findstring w512,$(TEST)),32,16)
SPINQUANT_NROW        := $(if $(findstring _r2,$(TEST)),2,$(if $(findstring _r4,$(TEST)),4,1))
SPINQUANT_NENTRY      := $(if $(findstring r2e2,$(TEST)),2,4)
VERILOG_SOURCES       := $(SPINQUANT_RTL) \
                         $(RTL)/5_spinquant/spinquant_pcu_synth.sv
EXTRA_ARGS            += --assert -DSPINQUANT_ASSERTIONS
export SPINQUANT_W_LATCH SPINQUANT_ACC_CHAIN_W
export SPINQUANT_NPE SPINQUANT_NROW SPINQUANT_NENTRY
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
