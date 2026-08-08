"""Shared cocotb helpers."""

from __future__ import annotations

from typing import Iterable


def signed_from_bits(value: int, width: int) -> int:
    value &= (1 << width) - 1
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def signal_signed(signal, width: int) -> int:
    return signed_from_bits(int(signal.value), width)


def unpack_signed_bus(value: int, width: int, count: int) -> tuple[int, ...]:
    mask = (1 << width) - 1
    return tuple(
        signed_from_bits((value >> (index * width)) & mask, width)
        for index in range(count)
    )


def chunks(values: Iterable[int], size: int):
    chunk = []
    for value in values:
        chunk.append(value)
        if len(chunk) == size:
            yield tuple(chunk)
            chunk = []
    if chunk:
        yield tuple(chunk)

