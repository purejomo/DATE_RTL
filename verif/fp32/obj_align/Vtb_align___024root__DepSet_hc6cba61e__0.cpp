// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtb_align.h for the primary calling header

#include "Vtb_align__pch.h"
#include "Vtb_align___024root.h"

void Vtb_align___024root___ico_sequent__TOP__0(Vtb_align___024root* vlSelf);

void Vtb_align___024root___eval_ico(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_ico\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VicoTriggered.word(0U))) {
        Vtb_align___024root___ico_sequent__TOP__0(vlSelf);
    }
}

VL_INLINE_OPT void Vtb_align___024root___ico_sequent__TOP__0(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___ico_sequent__TOP__0\n"); );
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
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__0__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__1__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__2__KET____DOT__u_decode__o_magnitude = 0;
    CData/*3:0*/ tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude;
    tb_align__DOT__u_pe__DOT____Vcellout__g_decode__BRA__3__KET____DOT__u_decode__o_magnitude = 0;
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

void Vtb_align___024root___eval_triggers__ico(Vtb_align___024root* vlSelf);

bool Vtb_align___024root___eval_phase__ico(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_phase__ico\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    CData/*0:0*/ __VicoExecute;
    // Body
    Vtb_align___024root___eval_triggers__ico(vlSelf);
    __VicoExecute = vlSelfRef.__VicoTriggered.any();
    if (__VicoExecute) {
        Vtb_align___024root___eval_ico(vlSelf);
    }
    return (__VicoExecute);
}

void Vtb_align___024root___eval_act(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_act\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

void Vtb_align___024root___nba_sequent__TOP__0(Vtb_align___024root* vlSelf);

void Vtb_align___024root___eval_nba(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_nba\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VnbaTriggered.word(0U))) {
        Vtb_align___024root___nba_sequent__TOP__0(vlSelf);
    }
}

VL_INLINE_OPT void Vtb_align___024root___nba_sequent__TOP__0(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___nba_sequent__TOP__0\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
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
    IData/*24:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v0;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v0 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v0;
    __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v0 = 0;
    IData/*24:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v1;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v1 = 0;
    IData/*24:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v2;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v2 = 0;
    IData/*24:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v3;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v3 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v4;
    __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v4 = 0;
    CData/*4:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v0;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v0 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v0;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v0 = 0;
    CData/*4:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v1;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v1 = 0;
    CData/*4:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v2;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v2 = 0;
    CData/*4:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v3;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v3 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v4;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v4 = 0;
    IData/*19:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v0;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v0 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v0;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v0 = 0;
    IData/*19:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v1;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v1 = 0;
    IData/*19:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v2;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v2 = 0;
    IData/*19:0*/ __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v3;
    __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v3 = 0;
    CData/*0:0*/ __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v4;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v4 = 0;
    // Body
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v0 = 0U;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v4 = 0U;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v0 = 0U;
    __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v4 = 0U;
    __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v0 = 0U;
    __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v4 = 0U;
    if (vlSelfRef.rst_n) {
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v0 
            = vlSelfRef.i_act0;
        __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v0 = 1U;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v1 
            = vlSelfRef.i_act1;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v2 
            = vlSelfRef.i_act2;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v3 
            = vlSelfRef.i_act3;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v0 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed
            [0U];
        __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v0 = 1U;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v1 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed
            [1U];
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v2 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed
            [2U];
        __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v3 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__weight_signed
            [3U];
        __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v0 
            = (0x1ffffffU & VL_MULS_III(25, (0x1ffffffU 
                                             & VL_EXTENDS_II(25,20, 
                                                             vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q
                                                             [0U])), 
                                        (0x1ffffffU 
                                         & VL_EXTENDS_II(25,5, 
                                                         vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q
                                                         [0U]))));
        __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v0 = 1U;
        __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v1 
            = (0x1ffffffU & VL_MULS_III(25, (0x1ffffffU 
                                             & VL_EXTENDS_II(25,20, 
                                                             vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q
                                                             [1U])), 
                                        (0x1ffffffU 
                                         & VL_EXTENDS_II(25,5, 
                                                         vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q
                                                         [1U]))));
        __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v2 
            = (0x1ffffffU & VL_MULS_III(25, (0x1ffffffU 
                                             & VL_EXTENDS_II(25,20, 
                                                             vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q
                                                             [2U])), 
                                        (0x1ffffffU 
                                         & VL_EXTENDS_II(25,5, 
                                                         vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q
                                                         [2U]))));
        __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v3 
            = (0x1ffffffU & VL_MULS_III(25, (0x1ffffffU 
                                             & VL_EXTENDS_II(25,20, 
                                                             vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q
                                                             [3U])), 
                                        (0x1ffffffU 
                                         & VL_EXTENDS_II(25,5, 
                                                         vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q
                                                         [3U]))));
        vlSelfRef.tb_align__DOT__u_pe__DOT__s2_carry_q 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__compressor_carry;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s2_sum_q 
            = vlSelfRef.tb_align__DOT__u_pe__DOT__compressor_sum;
        if (vlSelfRef.tb_align__DOT__u_pe__DOT__s2_valid_q) {
            vlSelfRef.tb_align__DOT__u_pe__DOT__s3_valid_q = 1U;
            if (vlSelfRef.tb_align__DOT__u_pe__DOT__s2_clear_q) {
                vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q 
                    = vlSelfRef.tb_align__DOT__u_pe__DOT__partial_sum_32;
            } else if (vlSelfRef.tb_align__DOT__u_pe__DOT__s2_enable_q) {
                vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q 
                    = ((1U & VL_REDXOR_64((0x180000000ULL 
                                           & vlSelfRef.tb_align__DOT__u_pe__DOT__acc_wide)))
                        ? ((1U & (IData)((vlSelfRef.tb_align__DOT__u_pe__DOT__acc_wide 
                                          >> 0x20U)))
                            ? 0x80000000U : 0x7fffffffU)
                        : (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__acc_wide));
            }
        } else {
            vlSelfRef.tb_align__DOT__u_pe__DOT__s3_valid_q = 0U;
        }
    } else {
        __VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v4 = 1U;
        __VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v4 = 1U;
        __VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v4 = 1U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s2_carry_q = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s2_sum_q = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s3_valid_q = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q = 0U;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v0) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[0U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v0;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[1U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v1;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[2U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v2;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[3U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_act_q__v3;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s0_act_q__v4) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[0U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[1U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[2U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_act_q[3U] = 0U;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v0) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[0U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v0;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[1U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v1;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[2U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v2;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[3U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s0_weight_q__v3;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s0_weight_q__v4) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[0U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[1U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[2U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s0_weight_q[3U] = 0U;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v0) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[0U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v0;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[1U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v1;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[2U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v2;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[3U] 
            = __VdlyVal__tb_align__DOT__u_pe__DOT__s1_product_q__v3;
    }
    if (__VdlySet__tb_align__DOT__u_pe__DOT__s1_product_q__v4) {
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[0U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[1U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[2U] = 0U;
        vlSelfRef.tb_align__DOT__u_pe__DOT__s1_product_q[3U] = 0U;
    }
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
    tb_align__DOT__u_pe__DOT__partial_sum = (0xfffffffU 
                                             & (vlSelfRef.tb_align__DOT__u_pe__DOT__s2_carry_q 
                                                + vlSelfRef.tb_align__DOT__u_pe__DOT__s2_sum_q));
    vlSelfRef.o_pe_valid = vlSelfRef.tb_align__DOT__u_pe__DOT__s3_valid_q;
    vlSelfRef.o_pe_acc = vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q;
    vlSelfRef.tb_align__DOT__u_pe__DOT__s2_valid_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s1_valid_q));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s2_clear_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s1_clear_q));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s2_enable_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s1_enable_q));
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
    vlSelfRef.tb_align__DOT__u_pe__DOT__partial_sum_32 
        = (((- (IData)((1U & (tb_align__DOT__u_pe__DOT__partial_sum 
                              >> 0x1bU)))) << 0x1cU) 
           | tb_align__DOT__u_pe__DOT__partial_sum);
    vlSelfRef.tb_align__DOT__u_pe__DOT__acc_wide = 
        (0x1ffffffffULL & ((((QData)((IData)((vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q 
                                              >> 0x1fU))) 
                             << 0x20U) | (QData)((IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__acc_q))) 
                           + (((QData)((IData)((1U 
                                                & (tb_align__DOT__u_pe__DOT__partial_sum 
                                                   >> 0x1bU)))) 
                               << 0x20U) | (QData)((IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__partial_sum_32)))));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s1_valid_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s0_valid_q));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s1_clear_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s0_clear_q));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s1_enable_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.tb_align__DOT__u_pe__DOT__s0_enable_q));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s0_valid_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.i_valid));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s0_clear_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.i_acc_clear));
    vlSelfRef.tb_align__DOT__u_pe__DOT__s0_enable_q 
        = ((IData)(vlSelfRef.rst_n) && (IData)(vlSelfRef.i_acc_enable));
}

void Vtb_align___024root___eval_triggers__act(Vtb_align___024root* vlSelf);

bool Vtb_align___024root___eval_phase__act(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_phase__act\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    VlTriggerVec<1> __VpreTriggered;
    CData/*0:0*/ __VactExecute;
    // Body
    Vtb_align___024root___eval_triggers__act(vlSelf);
    __VactExecute = vlSelfRef.__VactTriggered.any();
    if (__VactExecute) {
        __VpreTriggered.andNot(vlSelfRef.__VactTriggered, vlSelfRef.__VnbaTriggered);
        vlSelfRef.__VnbaTriggered.thisOr(vlSelfRef.__VactTriggered);
        Vtb_align___024root___eval_act(vlSelf);
    }
    return (__VactExecute);
}

bool Vtb_align___024root___eval_phase__nba(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_phase__nba\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    CData/*0:0*/ __VnbaExecute;
    // Body
    __VnbaExecute = vlSelfRef.__VnbaTriggered.any();
    if (__VnbaExecute) {
        Vtb_align___024root___eval_nba(vlSelf);
        vlSelfRef.__VnbaTriggered.clear();
    }
    return (__VnbaExecute);
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__ico(Vtb_align___024root* vlSelf);
#endif  // VL_DEBUG
#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__nba(Vtb_align___024root* vlSelf);
#endif  // VL_DEBUG
#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_align___024root___dump_triggers__act(Vtb_align___024root* vlSelf);
#endif  // VL_DEBUG

void Vtb_align___024root___eval(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Init
    IData/*31:0*/ __VicoIterCount;
    CData/*0:0*/ __VicoContinue;
    IData/*31:0*/ __VnbaIterCount;
    CData/*0:0*/ __VnbaContinue;
    // Body
    __VicoIterCount = 0U;
    vlSelfRef.__VicoFirstIteration = 1U;
    __VicoContinue = 1U;
    while (__VicoContinue) {
        if (VL_UNLIKELY((0x64U < __VicoIterCount))) {
#ifdef VL_DEBUG
            Vtb_align___024root___dump_triggers__ico(vlSelf);
#endif
            VL_FATAL_MT("tb_align.v", 4, "", "Input combinational region did not converge.");
        }
        __VicoIterCount = ((IData)(1U) + __VicoIterCount);
        __VicoContinue = 0U;
        if (Vtb_align___024root___eval_phase__ico(vlSelf)) {
            __VicoContinue = 1U;
        }
        vlSelfRef.__VicoFirstIteration = 0U;
    }
    __VnbaIterCount = 0U;
    __VnbaContinue = 1U;
    while (__VnbaContinue) {
        if (VL_UNLIKELY((0x64U < __VnbaIterCount))) {
#ifdef VL_DEBUG
            Vtb_align___024root___dump_triggers__nba(vlSelf);
#endif
            VL_FATAL_MT("tb_align.v", 4, "", "NBA region did not converge.");
        }
        __VnbaIterCount = ((IData)(1U) + __VnbaIterCount);
        __VnbaContinue = 0U;
        vlSelfRef.__VactIterCount = 0U;
        vlSelfRef.__VactContinue = 1U;
        while (vlSelfRef.__VactContinue) {
            if (VL_UNLIKELY((0x64U < vlSelfRef.__VactIterCount))) {
#ifdef VL_DEBUG
                Vtb_align___024root___dump_triggers__act(vlSelf);
#endif
                VL_FATAL_MT("tb_align.v", 4, "", "Active region did not converge.");
            }
            vlSelfRef.__VactIterCount = ((IData)(1U) 
                                         + vlSelfRef.__VactIterCount);
            vlSelfRef.__VactContinue = 0U;
            if (Vtb_align___024root___eval_phase__act(vlSelf)) {
                vlSelfRef.__VactContinue = 1U;
            }
        }
        if (Vtb_align___024root___eval_phase__nba(vlSelf)) {
            __VnbaContinue = 1U;
        }
    }
}

#ifdef VL_DEBUG
void Vtb_align___024root___eval_debug_assertions(Vtb_align___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtb_align__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_align___024root___eval_debug_assertions\n"); );
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if (VL_UNLIKELY((vlSelfRef.i_ref_exp & 0xfc00U))) {
        Verilated::overWidthError("i_ref_exp");}
    if (VL_UNLIKELY((vlSelfRef.clk & 0xfeU))) {
        Verilated::overWidthError("clk");}
    if (VL_UNLIKELY((vlSelfRef.rst_n & 0xfeU))) {
        Verilated::overWidthError("rst_n");}
    if (VL_UNLIKELY((vlSelfRef.i_valid & 0xfeU))) {
        Verilated::overWidthError("i_valid");}
    if (VL_UNLIKELY((vlSelfRef.i_acc_clear & 0xfeU))) {
        Verilated::overWidthError("i_acc_clear");}
    if (VL_UNLIKELY((vlSelfRef.i_acc_enable & 0xfeU))) {
        Verilated::overWidthError("i_acc_enable");}
    if (VL_UNLIKELY((vlSelfRef.i_act0 & 0xfff00000U))) {
        Verilated::overWidthError("i_act0");}
    if (VL_UNLIKELY((vlSelfRef.i_act1 & 0xfff00000U))) {
        Verilated::overWidthError("i_act1");}
    if (VL_UNLIKELY((vlSelfRef.i_act2 & 0xfff00000U))) {
        Verilated::overWidthError("i_act2");}
    if (VL_UNLIKELY((vlSelfRef.i_act3 & 0xfff00000U))) {
        Verilated::overWidthError("i_act3");}
    if (VL_UNLIKELY((vlSelfRef.i_weight_zp & 0xf0U))) {
        Verilated::overWidthError("i_weight_zp");}
}
#endif  // VL_DEBUG
