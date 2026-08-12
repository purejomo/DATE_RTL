// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vtb_align.h for the primary calling header

#ifndef VERILATED_VTB_ALIGN___024ROOT_H_
#define VERILATED_VTB_ALIGN___024ROOT_H_  // guard

#include "verilated.h"


class Vtb_align__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vtb_align___024root final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    VL_IN8(clk,0,0);
    VL_OUT8(o_saturate_fp16,0,0);
    VL_OUT8(o_invalid_fp16,0,0);
    VL_OUT8(o_saturate_bf16,0,0);
    VL_OUT8(o_invalid_bf16,0,0);
    VL_IN8(rst_n,0,0);
    VL_IN8(i_valid,0,0);
    VL_IN8(i_acc_clear,0,0);
    VL_IN8(i_acc_enable,0,0);
    VL_IN8(i_weight_zp,3,0);
    VL_OUT8(o_pe_valid,0,0);
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s0_valid_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s0_clear_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s0_enable_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s1_valid_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s1_clear_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s1_enable_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s2_valid_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s2_clear_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s2_enable_q;
    CData/*0:0*/ tb_align__DOT__u_pe__DOT__s3_valid_q;
    CData/*0:0*/ __VstlFirstIteration;
    CData/*0:0*/ __VicoFirstIteration;
    CData/*0:0*/ __Vtrigprevexpr___TOP__clk__0;
    CData/*0:0*/ __VactContinue;
    VL_IN16(i_float,15,0);
    VL_IN16(i_ref_exp,9,0);
    VL_IN16(i_weight_q,15,0);
    VL_OUT(o_aligned_fp16,19,0);
    VL_OUT(o_aligned_bf16,16,0);
    VL_IN(i_act0,19,0);
    VL_IN(i_act1,19,0);
    VL_IN(i_act2,19,0);
    VL_IN(i_act3,19,0);
    VL_OUT(o_pe_acc,31,0);
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__s2_sum_q;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__s2_carry_q;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__compressor_sum;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__compressor_carry;
    IData/*31:0*/ tb_align__DOT__u_pe__DOT__acc_q;
    IData/*31:0*/ tb_align__DOT__u_pe__DOT__partial_sum_32;
    IData/*31:0*/ __VactIterCount;
    QData/*32:0*/ tb_align__DOT__u_pe__DOT__acc_wide;
    VlUnpacked<IData/*19:0*/, 4> tb_align__DOT__u_pe__DOT__s0_act_q;
    VlUnpacked<CData/*4:0*/, 4> tb_align__DOT__u_pe__DOT__s0_weight_q;
    VlUnpacked<CData/*4:0*/, 4> tb_align__DOT__u_pe__DOT__weight_signed;
    VlUnpacked<IData/*24:0*/, 4> tb_align__DOT__u_pe__DOT__s1_product_q;
    VlTriggerVec<1> __VstlTriggered;
    VlTriggerVec<1> __VicoTriggered;
    VlTriggerVec<1> __VactTriggered;
    VlTriggerVec<1> __VnbaTriggered;

    // INTERNAL VARIABLES
    Vtb_align__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vtb_align___024root(Vtb_align__Syms* symsp, const char* v__name);
    ~Vtb_align___024root();
    VL_UNCOPYABLE(Vtb_align___024root);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
