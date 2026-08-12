// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtb_align.h for the primary calling header

#include "Vtb_align__pch.h"
#include "Vtb_align___024root.h"

VL_ATTR_COLD void Vtb_align___024root___eval_static(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_static\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

VL_ATTR_COLD void Vtb_align___024root___eval_initial(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_initial\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__Vtrigprevexpr___TOP__clk__0 = vlSelfRef.clk;
}

VL_ATTR_COLD void Vtb_align___024root___eval_final(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_final\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__stl(Vtb_align___024root* vlSelf);
#endif  // VL_DEBUG
VL_ATTR_COLD bool Vtb_align___024root___eval_phase__stl(Vtb_align___024root* vlSelf);

VL_ATTR_COLD void Vtb_align___024root___eval_settle(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_settle\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    IData/*31:0*/ __VstlIterCount;
    CData/*0:0*/ __VstlContinue;
    // Body
    __VstlIterCount = 0U;
    vlSelfRef.__VstlFirstIteration = 1U;
    __VstlContinue = 1U;
    while (__VstlContinue) {
        if (VL_UNLIKELY((0x64U < __VstlIterCount))) {
#ifdef VL_DEBUG
            Vtb_align___024root___dump_triggers__stl(vlSelf);
#endif
            VL_FATAL_MT("tb_align.v", 4, "", "Settle region did not converge.");
        }
        __VstlIterCount = ((IData)(1U) + __VstlIterCount);
        __VstlContinue = 0U;
        if (Vtb_align___024root___eval_phase__stl(vlSelf)) {
            __VstlContinue = 1U;
        }
        vlSelfRef.__VstlFirstIteration = 0U;
    }
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__stl(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___dump_triggers__stl\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1U & (~ vlSelfRef.__VstlTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
    if ((1ULL & vlSelfRef.__VstlTriggered.word(0U))) {
        VL_DBG_MSGF("         'stl' region trigger index 0 is active: Internal 'stl' trigger - first iteration\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD void Vtb_align___024root___stl_sequent__TOP__0(Vtb_align___024root* vlSelf);

VL_ATTR_COLD void Vtb_align___024root___eval_stl(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_stl\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VstlTriggered.word(0U))) {
        Vtb_align___024root___stl_sequent__TOP__0(vlSelf);
    }
}

VL_ATTR_COLD void Vtb_align___024root___stl_sequent__TOP__0(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___stl_sequent__TOP__0\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    CData/*0:0*/ tb_align__DOT__u_fp16__DOT__is_zero;
    tb_align__DOT__u_fp16__DOT__is_zero = 0;
    IData/*31:0*/ tb_align__DOT__u_fp16__DOT__shift_signed;
    tb_align__DOT__u_fp16__DOT__shift_signed = 0;
    IData/*31:0*/ tb_align__DOT__u_fp16__DOT__shift_amount;
    tb_align__DOT__u_fp16__DOT__shift_amount = 0;
    IData/*18:0*/ tb_align__DOT__u_fp16__DOT__widened;
    tb_align__DOT__u_fp16__DOT__widened = 0;
    IData/*18:0*/ tb_align__DOT__u_fp16__DOT__shifted;
    tb_align__DOT__u_fp16__DOT__shifted = 0;
    IData/*18:0*/ tb_align__DOT__u_fp16__DOT__guard_mask;
    tb_align__DOT__u_fp16__DOT__guard_mask = 0;
    IData/*19:0*/ tb_align__DOT__u_fp16__DOT____VdfgRegularize_h6b0cdb44_0_0;
    tb_align__DOT__u_fp16__DOT____VdfgRegularize_h6b0cdb44_0_0 = 0;
    CData/*0:0*/ tb_align__DOT__u_bf16__DOT__is_zero;
    tb_align__DOT__u_bf16__DOT__is_zero = 0;
    IData/*31:0*/ tb_align__DOT__u_bf16__DOT__shift_signed;
    tb_align__DOT__u_bf16__DOT__shift_signed = 0;
    IData/*31:0*/ tb_align__DOT__u_bf16__DOT__shift_amount;
    tb_align__DOT__u_bf16__DOT__shift_amount = 0;
    SData/*15:0*/ tb_align__DOT__u_bf16__DOT__widened;
    tb_align__DOT__u_bf16__DOT__widened = 0;
    SData/*15:0*/ tb_align__DOT__u_bf16__DOT__shifted;
    tb_align__DOT__u_bf16__DOT__shifted = 0;
    SData/*15:0*/ tb_align__DOT__u_bf16__DOT__guard_mask;
    tb_align__DOT__u_bf16__DOT__guard_mask = 0;
    IData/*16:0*/ tb_align__DOT__u_bf16__DOT____VdfgRegularize_h6cf623b2_0_0;
    tb_align__DOT__u_bf16__DOT____VdfgRegularize_h6cf623b2_0_0 = 0;
    IData/*25:0*/ tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in3_i;
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in3_i = 0;
    IData/*25:0*/ tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in2_i;
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in2_i = 0;
    IData/*25:0*/ tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in1_i;
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in1_i = 0;
    IData/*25:0*/ tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in0_i;
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in0_i = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__partial_sum;
    tb_align__DOT__u_pe__DOT__partial_sum = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand0;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand0 = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1 = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2 = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3 = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_sum;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_sum = 0;
    IData/*27:0*/ tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry;
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry = 0;
    CData/*4:0*/ tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference;
    tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference = 0;
    CData/*4:0*/ tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference;
    tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference = 0;
    CData/*4:0*/ tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference;
    tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference = 0;
    CData/*4:0*/ tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference;
    tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference = 0;
    IData/*31:0*/ __VdfgRegularize_hd87f99a1_0_1;
    __VdfgRegularize_hd87f99a1_0_1 = 0;
    // Body
    vlSelfRef.o_pe_valid = vlSelfRef.tb_align__DOT__u_pe__DOT__s3_valid_q;
    vlSelfRef.o_pe_acc = vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q;
    tb_align__DOT__u_pe__DOT__partial_sum = (0xfffffffU 
                                             & (vlSelfRef.tb_align__DOT__u_pe__DOT__s2_carry_q 
                                                + vlSelfRef.tb_align__DOT__u_pe__DOT__s2_sum_q));
    vlSelfRef.o_invalid_fp16 = (0x1fU == (0x1fU & ((IData)(vlSelfRef.i_float) 
                                                   >> 0xaU)));
    vlSelfRef.o_invalid_bf16 = (0xffU == (0xffU & ((IData)(vlSelfRef.i_float) 
                                                   >> 7U)));
    tb_align__DOT__u_fp16__DOT__is_zero = (IData)((0U 
                                                   == 
                                                   (0x7fffU 
                                                    & (IData)(vlSelfRef.i_float))));
    tb_align__DOT__u_bf16__DOT__is_zero = (IData)((0U 
                                                   == 
                                                   (0x7fffU 
                                                    & (IData)(vlSelfRef.i_float))));
    tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference 
        = (0x1fU & ((0xfU & (IData)(vlSelfRef.i_weight_q)) 
                    - (IData)(vlSelfRef.i_weight_zp)));
    tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference 
        = (0x1fU & ((0xfU & ((IData)(vlSelfRef.i_weight_q) 
                             >> 4U)) - (IData)(vlSelfRef.i_weight_zp)));
    tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference 
        = (0x1fU & ((0xfU & ((IData)(vlSelfRef.i_weight_q) 
                             >> 8U)) - (IData)(vlSelfRef.i_weight_zp)));
    tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference 
        = (0x1fU & ((0xfU & ((IData)(vlSelfRef.i_weight_q) 
                             >> 0xcU)) - (IData)(vlSelfRef.i_weight_zp)));
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in0_i 
        = ((0x2000000U & (vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
                          [0U] << 1U)) | vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
           [0U]);
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in1_i 
        = ((0x2000000U & (vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
                          [1U] << 1U)) | vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
           [1U]);
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in2_i 
        = ((0x2000000U & (vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
                          [2U] << 1U)) | vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
           [2U]);
    tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in3_i 
        = ((0x2000000U & (vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
                          [3U] << 1U)) | vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q
           [3U]);
    tb_align__DOT__u_fp16__DOT__widened = (((0U == 
                                             (0x1fU 
                                              & ((IData)(vlSelfRef.i_float) 
                                                 >> 0xaU)))
                                             ? (0x3ffU 
                                                & (IData)(vlSelfRef.i_float))
                                             : (0x400U 
                                                | (0x3ffU 
                                                   & (IData)(vlSelfRef.i_float)))) 
                                           << 8U);
    tb_align__DOT__u_bf16__DOT__widened = (((0U == 
                                             (0xffU 
                                              & ((IData)(vlSelfRef.i_float) 
                                                 >> 7U)))
                                             ? (0x7fU 
                                                & (IData)(vlSelfRef.i_float))
                                             : (0x80U 
                                                | (0x7fU 
                                                   & (IData)(vlSelfRef.i_float)))) 
                                           << 8U);
    __VdfgRegularize_hd87f99a1_0_1 = (((- (IData)((1U 
                                                   & ((IData)(vlSelfRef.i_ref_exp) 
                                                      >> 9U)))) 
                                       << 0xaU) | (IData)(vlSelfRef.i_ref_exp));
    vlSelfRef.tb_align__DOT__u_pe__DOT__partial_sum_32 
        = (((- (IData)((1U & (tb_align__DOT__u_pe__DOT__partial_sum 
                              >> 0x1bU)))) << 0x1cU) 
           | tb_align__DOT__u_pe__DOT__partial_sum);
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude 
        = (0xfU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference))
                    ? ((IData)(1U) + (~ (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference)))
                    : (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference)));
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude 
        = (0xfU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference))
                    ? ((IData)(1U) + (~ (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference)))
                    : (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference)));
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude 
        = (0xfU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference))
                    ? ((IData)(1U) + (~ (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference)))
                    : (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference)));
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude 
        = (0xfU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference))
                    ? ((IData)(1U) + (~ (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference)))
                    : (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference)));
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand0 
        = ((0xc000000U & ((- (IData)((1U & (tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in0_i 
                                            >> 0x19U)))) 
                          << 0x1aU)) | tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in0_i);
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1 
        = ((0xc000000U & ((- (IData)((1U & (tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in1_i 
                                            >> 0x19U)))) 
                          << 0x1aU)) | tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in1_i);
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2 
        = ((0xc000000U & ((- (IData)((1U & (tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in2_i 
                                            >> 0x19U)))) 
                          << 0x1aU)) | tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in2_i);
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3 
        = ((0xc000000U & ((- (IData)((1U & (tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in3_i 
                                            >> 0x19U)))) 
                          << 0x1aU)) | tb_align__DOT__u_pe__DOT____Vcellinp__u_compressor__in3_i);
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_sum 
        = ((tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand0 
            ^ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1) 
           ^ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2);
    tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry 
        = (0xfffffffU & (((tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand0 
                           & (tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1 
                              | tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2)) 
                          | (tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand1 
                             & tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand2)) 
                         << 1U));
    vlSelfRef.tb_align__DOT__u_pe__DOT__compressor_sum 
        = ((tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_sum 
            ^ tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry) 
           ^ tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3);
    vlSelfRef.tb_align__DOT__u_pe__DOT__compressor_carry 
        = (0xfffffffU & (((tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_sum 
                           & (tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry 
                              | tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3)) 
                          | (tb_align__DOT__u_pe__DOT__u_compressor__DOT__level1_carry 
                             & tb_align__DOT__u_pe__DOT__u_compressor__DOT__operand3)) 
                         << 1U));
    tb_align__DOT__u_fp16__DOT__shift_signed = (__VdfgRegularize_hd87f99a1_0_1 
                                                - (
                                                   (0U 
                                                    == 
                                                    (0x1fU 
                                                     & ((IData)(vlSelfRef.i_float) 
                                                        >> 0xaU)))
                                                    ? 0xffffffe8U
                                                    : 
                                                   (((0x1fU 
                                                      & ((IData)(vlSelfRef.i_float) 
                                                         >> 0xaU)) 
                                                     - (IData)(0xfU)) 
                                                    - (IData)(0xaU))));
    tb_align__DOT__u_bf16__DOT__shift_signed = (__VdfgRegularize_hd87f99a1_0_1 
                                                - (
                                                   (0U 
                                                    == 
                                                    (0xffU 
                                                     & ((IData)(vlSelfRef.i_float) 
                                                        >> 7U)))
                                                    ? 0xffffff7bU
                                                    : 
                                                   (((0xffU 
                                                      & ((IData)(vlSelfRef.i_float) 
                                                         >> 7U)) 
                                                     - (IData)(0x7fU)) 
                                                    - (IData)(7U))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__acc_wide = 
        (0x1ffffffffULL & ((((QData)((IData)((vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q 
                                              >> 0x1fU))) 
                             << 0x20U) | (QData)((IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q))) 
                           + (((QData)((IData)((1U 
                                                & (tb_align__DOT__u_pe__DOT__partial_sum 
                                                   >> 0x1bU)))) 
                               << 0x20U) | (QData)((IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__partial_sum_32)))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed[0U] 
        = ((0U == (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference))
            ? 0U : (0x1fU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__0__KET____DOT__u_decode__DOT__difference))
                              ? (- (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude))
                              : (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed[1U] 
        = ((0U == (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference))
            ? 0U : (0x1fU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__1__KET____DOT__u_decode__DOT__difference))
                              ? (- (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude))
                              : (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed[2U] 
        = ((0U == (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference))
            ? 0U : (0x1fU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__2__KET____DOT__u_decode__DOT__difference))
                              ? (- (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude))
                              : (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed[3U] 
        = ((0U == (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference))
            ? 0U : (0x1fU & ((0x10U & (IData)(tb_align__DOT__u_pe__DOT__g_decode__BRA__3__KET____DOT__u_decode__DOT__difference))
                              ? (- (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude))
                              : (IData)(tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude))));
    if ((tb_align__DOT__u_fp16__DOT__shift_signed >> 0x1fU)) {
        vlSelfRef.o_saturate_fp16 = (1U & (~ ((IData)(tb_align__DOT__u_fp16__DOT__is_zero) 
                                              | (IData)(vlSelfRef.o_invalid_fp16))));
        tb_align__DOT__u_fp16__DOT__shift_amount = 0U;
    } else {
        vlSelfRef.o_saturate_fp16 = 0U;
        tb_align__DOT__u_fp16__DOT__shift_amount = tb_align__DOT__u_fp16__DOT__shift_signed;
    }
    if ((tb_align__DOT__u_bf16__DOT__shift_signed >> 0x1fU)) {
        vlSelfRef.o_saturate_bf16 = (1U & (~ ((IData)(tb_align__DOT__u_bf16__DOT__is_zero) 
                                              | (IData)(vlSelfRef.o_invalid_bf16))));
        tb_align__DOT__u_bf16__DOT__shift_amount = 0U;
    } else {
        vlSelfRef.o_saturate_bf16 = 0U;
        tb_align__DOT__u_bf16__DOT__shift_amount = tb_align__DOT__u_bf16__DOT__shift_signed;
    }
    tb_align__DOT__u_fp16__DOT__guard_mask = ((0U == tb_align__DOT__u_fp16__DOT__shift_amount)
                                               ? 0U
                                               : (0x7ffffU 
                                                  & VL_SHIFTL_III(19,19,32, (IData)(1U), 
                                                                  (tb_align__DOT__u_fp16__DOT__shift_amount 
                                                                   - (IData)(1U)))));
    tb_align__DOT__u_fp16__DOT__shifted = (0x7ffffU 
                                           & VL_SHIFTR_III(19,19,32, tb_align__DOT__u_fp16__DOT__widened, tb_align__DOT__u_fp16__DOT__shift_amount));
    tb_align__DOT__u_bf16__DOT__guard_mask = ((0U == tb_align__DOT__u_bf16__DOT__shift_amount)
                                               ? 0U
                                               : (0xffffU 
                                                  & VL_SHIFTL_III(16,16,32, (IData)(1U), 
                                                                  (tb_align__DOT__u_bf16__DOT__shift_amount 
                                                                   - (IData)(1U)))));
    tb_align__DOT__u_bf16__DOT__shifted = (0xffffU 
                                           & VL_SHIFTR_III(16,16,32, (IData)(tb_align__DOT__u_bf16__DOT__widened), tb_align__DOT__u_bf16__DOT__shift_amount));
    tb_align__DOT__u_fp16__DOT____VdfgRegularize_h6b0cdb44_0_0 
        = (((IData)(tb_align__DOT__u_fp16__DOT__is_zero) 
            | ((IData)(vlSelfRef.o_invalid_fp16) | 
               ((~ (tb_align__DOT__u_fp16__DOT__shift_signed 
                    >> 0x1fU)) & (0x13U < tb_align__DOT__u_fp16__DOT__shift_signed))))
            ? 0U : (0x7ffffU & (tb_align__DOT__u_fp16__DOT__shifted 
                                + ((0U != (tb_align__DOT__u_fp16__DOT__widened 
                                           & tb_align__DOT__u_fp16__DOT__guard_mask)) 
                                   & ((0U != (tb_align__DOT__u_fp16__DOT__widened 
                                              & ((2U 
                                                  > tb_align__DOT__u_fp16__DOT__shift_amount)
                                                  ? 0U
                                                  : 
                                                 (tb_align__DOT__u_fp16__DOT__guard_mask 
                                                  - (IData)(1U))))) 
                                      | tb_align__DOT__u_fp16__DOT__shifted)))));
    tb_align__DOT__u_bf16__DOT____VdfgRegularize_h6cf623b2_0_0 
        = (((IData)(tb_align__DOT__u_bf16__DOT__is_zero) 
            | ((IData)(vlSelfRef.o_invalid_bf16) | 
               ((~ (tb_align__DOT__u_bf16__DOT__shift_signed 
                    >> 0x1fU)) & (0x10U < tb_align__DOT__u_bf16__DOT__shift_signed))))
            ? 0U : (0xffffU & ((IData)(tb_align__DOT__u_bf16__DOT__shifted) 
                               + ((0U != ((IData)(tb_align__DOT__u_bf16__DOT__widened) 
                                          & (IData)(tb_align__DOT__u_bf16__DOT__guard_mask))) 
                                  & ((0U != ((IData)(tb_align__DOT__u_bf16__DOT__widened) 
                                             & ((2U 
                                                 > tb_align__DOT__u_bf16__DOT__shift_amount)
                                                 ? 0U
                                                 : 
                                                ((IData)(tb_align__DOT__u_bf16__DOT__guard_mask) 
                                                 - (IData)(1U))))) 
                                     | (IData)(tb_align__DOT__u_bf16__DOT__shifted))))));
    if ((0x8000U & (IData)(vlSelfRef.i_float))) {
        vlSelfRef.o_aligned_fp16 = (0xfffffU & (- tb_align__DOT__u_fp16__DOT____VdfgRegularize_h6b0cdb44_0_0));
        vlSelfRef.o_aligned_bf16 = (0x1ffffU & (- tb_align__DOT__u_bf16__DOT____VdfgRegularize_h6cf623b2_0_0));
    } else {
        vlSelfRef.o_aligned_fp16 = (0xfffffU & tb_align__DOT__u_fp16__DOT____VdfgRegularize_h6b0cdb44_0_0);
        vlSelfRef.o_aligned_bf16 = (0x1ffffU & tb_align__DOT__u_bf16__DOT____VdfgRegularize_h6cf623b2_0_0);
    }
}

VL_ATTR_COLD void Vtb_align___024root___eval_triggers__stl(Vtb_align___024root* vlSelf);

VL_ATTR_COLD bool Vtb_align___024root___eval_phase__stl(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_phase__stl\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    CData/*0:0*/ __VstlExecute;
    // Body
    Vtb_align___024root___eval_triggers__stl(vlSelf);
    __VstlExecute = vlSelfRef.__VstlTriggered.any();
    if (__VstlExecute) {
        Vtb_align___024root___eval_stl(vlSelf);
    }
    return (__VstlExecute);
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__ico(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___dump_triggers__ico\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1U & (~ vlSelfRef.__VicoTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
    if ((1ULL & vlSelfRef.__VicoTriggered.word(0U))) {
        VL_DBG_MSGF("         'ico' region trigger index 0 is active: Internal 'ico' trigger - first iteration\n");
    }
}
#endif  // VL_DEBUG

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__act(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___dump_triggers__act\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1U & (~ vlSelfRef.__VactTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
    if ((1ULL & vlSelfRef.__VactTriggered.word(0U))) {
        VL_DBG_MSGF("         'act' region trigger index 0 is active: @(posedge clk)\n");
    }
}
#endif  // VL_DEBUG

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__nba(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___dump_triggers__nba\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1U & (~ vlSelfRef.__VnbaTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
    if ((1ULL & vlSelfRef.__VnbaTriggered.word(0U))) {
        VL_DBG_MSGF("         'nba' region trigger index 0 is active: @(posedge clk)\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD void Vtb_align___024root___ctor_var_reset(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___ctor_var_reset\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelf->i_float = VL_RAND_RESET_I(16);
    vlSelf->i_ref_exp = VL_RAND_RESET_I(10);
    vlSelf->o_aligned_fp16 = VL_RAND_RESET_I(20);
    vlSelf->o_saturate_fp16 = VL_RAND_RESET_I(1);
    vlSelf->o_invalid_fp16 = VL_RAND_RESET_I(1);
    vlSelf->o_aligned_bf16 = VL_RAND_RESET_I(17);
    vlSelf->o_saturate_bf16 = VL_RAND_RESET_I(1);
    vlSelf->o_invalid_bf16 = VL_RAND_RESET_I(1);
    vlSelf->clk = VL_RAND_RESET_I(1);
    vlSelf->rst_n = VL_RAND_RESET_I(1);
    vlSelf->i_valid = VL_RAND_RESET_I(1);
    vlSelf->i_acc_clear = VL_RAND_RESET_I(1);
    vlSelf->i_acc_enable = VL_RAND_RESET_I(1);
    vlSelf->i_act0 = VL_RAND_RESET_I(20);
    vlSelf->i_act1 = VL_RAND_RESET_I(20);
    vlSelf->i_act2 = VL_RAND_RESET_I(20);
    vlSelf->i_act3 = VL_RAND_RESET_I(20);
    vlSelf->i_weight_q = VL_RAND_RESET_I(16);
    vlSelf->i_weight_zp = VL_RAND_RESET_I(4);
    vlSelf->o_pe_valid = VL_RAND_RESET_I(1);
    vlSelf->o_pe_acc = VL_RAND_RESET_I(32);
    vlSelf->tb_align__DOT__u_pe__DOT__s0_valid_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s0_clear_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s0_enable_q = VL_RAND_RESET_I(1);
    for (int __Vi0 = 0; __Vi0 < 4; ++__Vi0) {
        vlSelf->tb_align__DOT__u_pe__DOT__s0_act_q[__Vi0] = VL_RAND_RESET_I(20);
    }
    for (int __Vi0 = 0; __Vi0 < 4; ++__Vi0) {
        vlSelf->tb_align__DOT__u_pe__DOT__s0_weight_q[__Vi0] = VL_RAND_RESET_I(5);
    }
    for (int __Vi0 = 0; __Vi0 < 4; ++__Vi0) {
        vlSelf->tb_align__DOT__u_pe__DOT__weight_signed[__Vi0] = VL_RAND_RESET_I(5);
    }
    vlSelf->tb_align__DOT__u_pe__DOT__s1_valid_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s1_clear_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s1_enable_q = VL_RAND_RESET_I(1);
    for (int __Vi0 = 0; __Vi0 < 4; ++__Vi0) {
        vlSelf->tb_align__DOT__u_pe__DOT__s1_product_q[__Vi0] = VL_RAND_RESET_I(25);
    }
    vlSelf->tb_align__DOT__u_pe__DOT__s2_valid_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s2_clear_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s2_enable_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__s2_sum_q = VL_RAND_RESET_I(28);
    vlSelf->tb_align__DOT__u_pe__DOT__s2_carry_q = VL_RAND_RESET_I(28);
    vlSelf->tb_align__DOT__u_pe__DOT__compressor_sum = VL_RAND_RESET_I(28);
    vlSelf->tb_align__DOT__u_pe__DOT__compressor_carry = VL_RAND_RESET_I(28);
    vlSelf->tb_align__DOT__u_pe__DOT__s3_valid_q = VL_RAND_RESET_I(1);
    vlSelf->tb_align__DOT__u_pe__DOT__acc_q = VL_RAND_RESET_I(32);
    vlSelf->tb_align__DOT__u_pe__DOT__partial_sum_32 = VL_RAND_RESET_I(32);
    vlSelf->tb_align__DOT__u_pe__DOT__acc_wide = VL_RAND_RESET_Q(33);
    vlSelf->__Vtrigprevexpr___TOP__clk__0 = VL_RAND_RESET_I(1);
}
