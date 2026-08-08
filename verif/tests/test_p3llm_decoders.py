from __future__ import annotations

import cocotb
from cocotb.triggers import Timer

from common import signal_signed
from p3llm_formats import (
    decode_bitmod4,
    decode_fp8_e4m3,
    decode_fp8_s0e4m4,
    decode_int4_asym,
)


@cocotb.test()
async def test_all_decoders(dut):
    """Exhaust every raw decoder input and all selector/zero-point metadata."""

    for code in range(256):
        dut.e4m3_code.value = code
        dut.s0e4m4_code.value = code
        await Timer(1, units="ns")

        e4 = decode_fp8_e4m3(code)
        assert signal_signed(dut.e4m3_mantissa, 6) == e4.mantissa
        assert int(dut.e4m3_shift.value) == e4.shift
        assert int(dut.e4m3_zero.value) == e4.zero
        assert int(dut.e4m3_invalid.value) == e4.invalid

        s0 = decode_fp8_s0e4m4(code)
        assert signal_signed(dut.s0e4m4_mantissa, 6) == s0.mantissa
        assert int(dut.s0e4m4_shift.value) == s0.shift
        assert int(dut.s0e4m4_zero.value) == s0.zero

    # Explicit format boundaries called out by the specification.
    assert decode_fp8_e4m3(0x00).zero
    assert decode_fp8_e4m3(0x80).zero
    assert decode_fp8_e4m3(0x01).mantissa == 2
    assert decode_fp8_e4m3(0x08).shift == 1
    assert decode_fp8_e4m3(0x77).mantissa == 30
    assert decode_fp8_e4m3(0x7E).mantissa == 28
    assert decode_fp8_e4m3(0x7F).invalid
    assert decode_fp8_e4m3(0xFF).invalid

    assert decode_fp8_s0e4m4(0x00).zero
    assert decode_fp8_s0e4m4(0x01).mantissa == 1
    assert (
        decode_fp8_s0e4m4(0x0F).mantissa,
        decode_fp8_s0e4m4(0x0F).shift,
    ) == (15, 1)
    assert decode_fp8_s0e4m4(0x10).shift == 1
    assert (
        decode_fp8_s0e4m4(0x1F).mantissa,
        decode_fp8_s0e4m4(0x20).mantissa,
    ) == (31, 16)
    assert decode_fp8_s0e4m4(0x70).shift == 7
    assert decode_fp8_s0e4m4(0xEF).mantissa == 31
    assert (
        decode_fp8_s0e4m4(0xF0).mantissa,
        decode_fp8_s0e4m4(0xF0).shift,
    ) == (16, 15)

    for selector in range(4):
        for code in range(16):
            dut.bitmod_code.value = code
            dut.bitmod_special_sel.value = selector
            await Timer(1, units="ns")
            assert signal_signed(dut.bitmod_decoded, 6) == decode_bitmod4(
                code, selector
            )

    assert tuple(decode_bitmod4(0x8, selector) for selector in range(4)) == (
        10,
        -10,
        16,
        -16,
    )

    for zero_point in range(16):
        for code in range(16):
            dut.int4_code.value = code
            dut.int4_zero_point.value = zero_point
            await Timer(1, units="ns")
            assert signal_signed(dut.int4_decoded, 6) == decode_int4_asym(
                code, zero_point
            )

    for code, zero_point, expected in (
        (0, 0, 0),
        (0, 15, -15),
        (15, 0, 15),
        (15, 15, 0),
        (7, 7, 0),
    ):
        assert decode_int4_asym(code, zero_point) == expected
