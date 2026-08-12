// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtb_align.h for the primary calling header

#include "Vtb_align__pch.h"
#include "Vtb_align__Syms.h"
#include "Vtb_align___024root.h"

void Vtb_align___024root___ctor_var_reset(Vtb_align___024root* vlSelf);

Vtb_align___024root::Vtb_align___024root(Vtb_align__Syms* symsp, const char* v__name)
    : VerilatedModule{v__name}
    , vlSymsp{symsp}
 {
    // Reset structure values
    Vtb_align___024root___ctor_var_reset(this);
}

void Vtb_align___024root::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vtb_align___024root::~Vtb_align___024root() {
}
