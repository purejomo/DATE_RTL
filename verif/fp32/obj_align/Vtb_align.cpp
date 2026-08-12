// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Model implementation (design independent parts)

#include "Vtb_align__pch.h"

//============================================================
// Constructors

Vtb_align::Vtb_align(VerilatedContext* _vcontextp__, const char* _vcname__)
    : VerilatedModel{*_vcontextp__}
    , vlSymsp{new Vtb_align__Syms(contextp(), _vcname__, this)}
    , clk{vlSymsp->TOP.clk}
    , o_saturate_fp16{vlSymsp->TOP.o_saturate_fp16}
    , o_invalid_fp16{vlSymsp->TOP.o_invalid_fp16}
    , o_saturate_bf16{vlSymsp->TOP.o_saturate_bf16}
    , o_invalid_bf16{vlSymsp->TOP.o_invalid_bf16}
    , rst_n{vlSymsp->TOP.rst_n}
    , i_valid{vlSymsp->TOP.i_valid}
    , i_acc_clear{vlSymsp->TOP.i_acc_clear}
    , i_acc_enable{vlSymsp->TOP.i_acc_enable}
    , i_weight_zp{vlSymsp->TOP.i_weight_zp}
    , o_pe_valid{vlSymsp->TOP.o_pe_valid}
    , i_float{vlSymsp->TOP.i_float}
    , i_ref_exp{vlSymsp->TOP.i_ref_exp}
    , i_weight_q{vlSymsp->TOP.i_weight_q}
    , o_aligned_fp16{vlSymsp->TOP.o_aligned_fp16}
    , o_aligned_bf16{vlSymsp->TOP.o_aligned_bf16}
    , i_act0{vlSymsp->TOP.i_act0}
    , i_act1{vlSymsp->TOP.i_act1}
    , i_act2{vlSymsp->TOP.i_act2}
    , i_act3{vlSymsp->TOP.i_act3}
    , o_pe_acc{vlSymsp->TOP.o_pe_acc}
    , rootp{&(vlSymsp->TOP)}
{
    // Register model with the context
    contextp()->addModel(this);
}

Vtb_align::Vtb_align(const char* _vcname__)
    : Vtb_align(Verilated::threadContextp(), _vcname__)
{
}

//============================================================
// Destructor

Vtb_align::~Vtb_align() {
    delete vlSymsp;
}

//============================================================
// Evaluation function

#ifdef VL_DEBUG
void Vtb_align___024root___eval_debug_assertions(Vtb_align___024root* vlSelf);
#endif  // VL_DEBUG
void Vtb_align___024root___eval_static(Vtb_align___024root* vlSelf);
void Vtb_align___024root___eval_initial(Vtb_align___024root* vlSelf);
void Vtb_align___024root___eval_settle(Vtb_align___024root* vlSelf);
void Vtb_align___024root___eval(Vtb_align___024root* vlSelf);

void Vtb_align::eval_step() {
    VL_DEBUG_IF(VL_DBG_MSGF("+++++TOP Evaluate Vtb_align::eval_step\n"); );
#ifdef VL_DEBUG
    // Debug assertions
    Vtb_align___024root___eval_debug_assertions(&(vlSymsp->TOP));
#endif  // VL_DEBUG
    vlSymsp->__Vm_deleter.deleteAll();
    if (VL_UNLIKELY(!vlSymsp->__Vm_didInit)) {
        vlSymsp->__Vm_didInit = true;
        VL_DEBUG_IF(VL_DBG_MSGF("+ Initial\n"););
        Vtb_align___024root___eval_static(&(vlSymsp->TOP));
        Vtb_align___024root___eval_initial(&(vlSymsp->TOP));
        Vtb_align___024root___eval_settle(&(vlSymsp->TOP));
    }
    VL_DEBUG_IF(VL_DBG_MSGF("+ Eval\n"););
    Vtb_align___024root___eval(&(vlSymsp->TOP));
    // Evaluate cleanup
    Verilated::endOfEval(vlSymsp->__Vm_evalMsgQp);
}

//============================================================
// Events and timing
bool Vtb_align::eventsPending() { return false; }

uint64_t Vtb_align::nextTimeSlot() {
    VL_FATAL_MT(__FILE__, __LINE__, "", "No delays in the design");
    return 0;
}

//============================================================
// Utilities

const char* Vtb_align::name() const {
    return vlSymsp->name();
}

//============================================================
// Invoke final blocks

void Vtb_align___024root___eval_final(Vtb_align___024root* vlSelf);

VL_ATTR_COLD void Vtb_align::final() {
    Vtb_align___024root___eval_final(&(vlSymsp->TOP));
}

//============================================================
// Implementations of abstract methods from VerilatedModel

const char* Vtb_align::hierName() const { return vlSymsp->name(); }
const char* Vtb_align::modelName() const { return "Vtb_align"; }
unsigned Vtb_align::threads() const { return 1; }
void Vtb_align::prepareClone() const { contextp()->prepareClone(); }
void Vtb_align::atClone() const {
    contextp()->threadPoolpOnClone();
}
