"""End-to-end regression for the SpinQuant W4A4 PIM compute unit.

The DRAM bank, the CRF sequencer and the input GRF are outside the synthesis
boundary, so they live here: this file turns a projection-layer GEMV tile into
the exact per-cycle command stream a microkernel would issue, and compares
every accumulator update against verif/models/spinquant_model.py.

Command scheduling. A MAC issued in slot t multiplies whatever the weight hold
register contained during slot t, which is the beat loaded in slot t-1 -- a
load in slot t only lands on the edge that ends it. build_slots() exploits that
twice: it pipelines each load one slot ahead of the MAC that consumes it, so a
stream of distinct beats sustains one MAC per cycle with no bubble, and it
emits no load at all when consecutive MACs share a beat, which is exactly the
tCCD_S 2-pump schedule. On the slots with no load the beat bus is driven with
random garbage, so a hold register that failed to hold would be caught.

Geometry. The same file drives every configuration; the Makefile exports the
four knobs that change the port widths and the reference arithmetic:

    SPINQUANT_NPE           output channels per beat        (16, or 32 on w512)
    SPINQUANT_NROW          activation rows sharing a beat  (1, 2, 4)
    SPINQUANT_NENTRY        accumulator entries             (4, or 2 on r2e2)
    SPINQUANT_ACC_CHAIN_W   carry chain width               (24 or 32)
    SPINQUANT_W_LATCH       bank read latch inside/outside  (1 or 0)
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from spinquant_model import (
    A_MAX,
    NWAY,
    PIPELINE_EDGE_LATENCY,
    W_MAX,
    W_MIN,
    SpinQuantPcu,
    dot_w4a4,
    flatten_rows,
    gemv_w4a4,
    rne_narrow,
    pack_acts,
    pack_beat,
    tile_to_beats,
    unpack_drain,
    wrap_signed,
)

W_LATCH = int(os.environ.get("SPINQUANT_W_LATCH", "1"))
CHAIN_W = int(os.environ.get("SPINQUANT_ACC_CHAIN_W", "24"))
NPE = int(os.environ.get("SPINQUANT_NPE", "16"))
NROW = int(os.environ.get("SPINQUANT_NROW", "1"))
NENTRY = int(os.environ.get("SPINQUANT_NENTRY", "4"))
# The acc16 variant narrows the architectural accumulator and rounds the partial
# sum into it. ACC_RSH = 0 is the base design, where no narrow exists at all.
ACC_W = int(os.environ.get("SPINQUANT_ACC_W", "32"))
ACC_RSH = int(os.environ.get("SPINQUANT_ACC_RSH", "0"))

BEAT_W = NPE * NWAY * 4
NLANE = NROW * NPE


class MacOp:
    """One MAC command: a beat, NROW activation rows, an entry and a clear."""

    __slots__ = ("weights", "act_rows", "entry", "clear", "w_bits", "a_bits")

    def __init__(self, weights, act_rows, entry, clear):
        self.weights = weights
        self.act_rows = act_rows
        self.entry = entry
        self.clear = clear
        self.w_bits = pack_beat(weights, npe=NPE)
        self.a_bits = pack_acts(flatten_rows(act_rows))


def idle_slot(rng):
    return {
        "w_load": 0,
        "w_beat": rng.getrandbits(BEAT_W),
        "mac_valid": 0,
        "a": 0,
        "entry": 0,
        "clear": 0,
        "mac_index": None,
    }


def build_slots(macs, rng, gaps=None):
    """Turn a MAC list into the per-cycle command stream described above."""

    gaps = gaps if gaps is not None else [0] * len(macs)
    if len(gaps) != len(macs):
        raise ValueError("gaps must be as long as macs")

    if not W_LATCH:
        # The hold register sits outside the boundary, so the schedule has to
        # present the beat in the same slot that consumes it -- and hold it
        # steady across both pumps, which repeating w_bits does for free.
        slots = []
        for index, op in enumerate(macs):
            for _ in range(gaps[index]):
                slots.append(idle_slot(rng))
            slot = idle_slot(rng)
            slot.update(
                w_beat=op.w_bits,
                mac_valid=1,
                a=op.a_bits,
                entry=op.entry,
                clear=int(op.clear),
                mac_index=index,
            )
            slots.append(slot)
        return slots

    # Slot 0 is reserved so the first MAC's load has somewhere to go.
    slot_of = []
    total = 1
    for index in range(len(macs)):
        total += gaps[index]
        slot_of.append(total)
        total += 1

    slots = [idle_slot(rng) for _ in range(total)]
    for index, op in enumerate(macs):
        slot = slot_of[index]
        slots[slot].update(
            mac_valid=1,
            a=op.a_bits,
            entry=op.entry,
            clear=int(op.clear),
            mac_index=index,
        )
        if index == 0 or op.w_bits != macs[index - 1].w_bits:
            slots[slot - 1]["w_load"] = 1
            slots[slot - 1]["w_beat"] = op.w_bits
    return slots


def drive_slot(dut, slot):
    dut.w_load_i.value = slot["w_load"]
    dut.w_beat_i.value = slot["w_beat"]
    dut.mac_valid_i.value = slot["mac_valid"]
    dut.a_q4_i.value = slot["a"]
    dut.acc_entry_i.value = slot["entry"]
    dut.acc_clear_i.value = slot["clear"]


async def reset_pcu(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.w_load_i.value = 0
    dut.w_beat_i.value = 0
    dut.mac_valid_i.value = 0
    dut.a_q4_i.value = 0
    dut.acc_entry_i.value = 0
    dut.acc_clear_i.value = 0
    dut.drain_entry_i.value = 0
    dut.status_clr_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.mac_done_o.value) == 0
        assert int(dut.drain_data_o.value) == 0
        assert int(dut.ovf_sticky_o.value) == 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_slots(dut, macs, model, rng, gaps=None, label=""):
    """Drive one command stream and check every accumulator update."""

    slots = build_slots(macs, rng, gaps)
    pending = {}
    sticky = int(model.ovf_sticky)
    total = len(slots) + PIPELINE_EDGE_LATENCY + 1

    for cycle in range(total):
        await FallingEdge(dut.clk)
        slot = slots[cycle] if cycle < len(slots) else idle_slot(rng)
        due = pending.pop(cycle, None)
        drive_slot(dut, slot)
        # Point the drain port at whatever entry is due this cycle; when
        # nothing is due, sweep it randomly so the second read port is
        # exercised while the first one is busy accumulating.
        dut.drain_entry_i.value = due[0] if due is not None else rng.randrange(NENTRY)

        if slot["mac_index"] is not None:
            op = macs[slot["mac_index"]]
            result = model.mac(op.weights, op.act_rows, op.entry, op.clear)
            pending[cycle + PIPELINE_EDGE_LATENCY] = (
                op.entry,
                result.acc,
                int(model.ovf_sticky),
            )

        await RisingEdge(dut.clk)
        await ReadOnly()

        assert int(dut.mac_done_o.value) == (1 if due is not None else 0), (
            f"{label}: mac_done_o mismatch at cycle {cycle}"
        )
        if due is not None:
            sticky = due[2]
            actual = unpack_drain(int(dut.drain_data_o.value), nlane=NLANE, acc_w=ACC_W)
            assert actual == due[1], (
                f"{label}: accumulator mismatch at cycle {cycle}, "
                f"entry {due[0]}\nactual  ={actual}\nexpected={due[1]}"
            )
        assert int(dut.ovf_sticky_o.value) == sticky, (
            f"{label}: ovf_sticky_o mismatch at cycle {cycle}"
        )


async def drain_all_entries(dut, model, label=""):
    """Read every entry back through the drain port, one per cycle."""

    for entry in range(NENTRY):
        await FallingEdge(dut.clk)
        dut.drain_entry_i.value = entry
        await RisingEdge(dut.clk)
        await ReadOnly()
        actual = unpack_drain(int(dut.drain_data_o.value), nlane=NLANE, acc_w=ACC_W)
        expected = model.read(entry)
        assert actual == expected, (
            f"{label}: drain mismatch on entry {entry}\n"
            f"actual  ={actual}\nexpected={expected}"
        )


def new_model():
    return SpinQuantPcu(npe=NPE, nrow=NROW, nentry=NENTRY, acc_w=ACC_W,
                        chain_w=CHAIN_W, acc_rsh=ACC_RSH)


def random_tile(rng, k, nrow=NROW):
    weights = [[rng.randint(W_MIN, W_MAX) for _ in range(k)] for _ in range(NPE)]
    act_rows = [[rng.randint(0, A_MAX) for _ in range(k)] for _ in range(nrow)]
    return weights, act_rows


def expected_lanes(weights, act_rows):
    """The reference the whole design is measured against, lane by lane.

    With ACC_RSH = 0 the accumulator is exact, so the reference is the exact
    GEMV and nothing more needs saying.

    With ACC_RSH != 0 it is not, by design: the acc16 variant rounds every
    partial sum into a narrower register, so summing K products first and
    rounding once is a different number from what the hardware holds. The
    reference is therefore rebuilt beat by beat. That alone would be a weak
    check -- it re-derives the model's own arithmetic -- so it is paired with a
    bound that does not depend on the rounding at all: each beat can lose at
    most half an accumulator LSB, so the whole tile must land within
    ``beats * 2**(ACC_RSH-1)`` of the exact GEMV. That is the claim
    rtl/5_spinquant_acc16/README.md makes, checked on every tile the suite
    runs.
    """

    if ACC_RSH == 0:
        lanes = []
        for row in act_rows:
            lanes.extend(gemv_w4a4(weights, row))
        return tuple(lanes)

    lanes = [0] * NLANE
    beats = 0
    for beat_w, beat_a in tile_to_beats(weights, act_rows, npe=NPE):
        beats += 1
        for row in range(NROW):
            for pe in range(NPE):
                psum = dot_w4a4(beat_w[pe], beat_a[row])
                lanes[row * NPE + pe] += rne_narrow(psum, ACC_RSH)

    exact = []
    for row in act_rows:
        exact.extend(gemv_w4a4(weights, row))
    bound = beats * (1 << (ACC_RSH - 1))
    for lane, (narrowed, truth) in enumerate(zip(lanes, exact)):
        error = abs((narrowed << ACC_RSH) - truth)
        assert error <= bound, (
            f"lane {lane}: acc16 error {error} exceeds the half-LSB-per-beat "
            f"bound {bound} over {beats} beats"
        )

    return tuple(lanes)


def tile_macs(weights, act_rows, entry, clear_first=True):
    """The MAC stream for one tile: clear on the first beat."""

    return [
        MacOp(beat_w, beat_a, entry, clear_first and index == 0)
        for index, (beat_w, beat_a) in enumerate(
            tile_to_beats(weights, act_rows, npe=NPE))
    ]


@cocotb.test()
async def test_single_beat(dut):
    """Scenario 1: one weight beat, one activation set, one MAC."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0001)
    model = new_model()

    for _ in range(64):
        weights, act_rows = random_tile(rng, NWAY)
        entry = rng.randrange(NENTRY)
        await run_slots(dut, [MacOp(weights, act_rows, entry, True)], model, rng,
                        label="single-beat")
        # A single cleared beat is the pure dot product, so the drain has to
        # equal the reference GEMV over K = NWAY with nothing else in the way.
        assert model.read(entry) == expected_lanes(weights, act_rows)
    await drain_all_entries(dut, model, label="single-beat")


@cocotb.test()
async def test_k_loop_accumulation(dut):
    """Scenario 2: a row-buffer streak accumulated to the end of K."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0002)

    for k in (128, 1024, 14336):
        # Each sweep starts from a cleared file so the drain check below can
        # insist that the entries this sweep never touched are still zero.
        await reset_pcu(dut)
        model = new_model()
        weights, act_rows = random_tile(rng, k)
        entry = (k // 128) % NENTRY
        await run_slots(dut, tile_macs(weights, act_rows, entry), model, rng,
                        label=f"K={k}")

        assert model.read(entry) == expected_lanes(weights, act_rows), (
            f"K={k}: golden model diverged from the GEMV reference"
        )
        await drain_all_entries(dut, model, label=f"K={k}")
        assert int(dut.ovf_sticky_o.value) == 0, (
            f"K={k}: the {CHAIN_W}-bit chain reported an overflow it must not have"
        )


@cocotb.test()
async def test_two_pump_reuse(dut):
    """Scenario 3: one beat, two tCCD_S MACs, two entries.

    With NROW > 1 this is the temporal reuse stacked on top of the spatial
    rows, so the beat feeds 2*NROW activation rows in total.
    """

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0003)
    model = new_model()

    k = 256
    weights, pump0_rows = random_tile(rng, k)
    _, pump1_rows = random_tile(rng, k)

    macs = []
    beats0 = list(tile_to_beats(weights, pump0_rows, npe=NPE))
    beats1 = list(tile_to_beats(weights, pump1_rows, npe=NPE))
    for index, (beat_w, beat_a0) in enumerate(beats0):
        # Same beat, back to back, differing only in the activation set and
        # the accumulator entry. build_slots emits one load for the pair.
        macs.append(MacOp(beat_w, beat_a0, 0, index == 0))
        macs.append(MacOp(beat_w, beats1[index][1], 1, index == 0))

    await run_slots(dut, macs, model, rng, label="2-pump")

    assert model.read(0) == expected_lanes(weights, pump0_rows)
    assert model.read(1) == expected_lanes(weights, pump1_rows)
    await drain_all_entries(dut, model, label="2-pump")


@cocotb.test()
async def test_entry_interleave(dut):
    """Scenario 4: independent k sweeps interleaved over every entry."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0004)
    model = new_model()

    k = 128
    tiles = [random_tile(rng, k) for _ in range(NENTRY)]
    per_entry = [list(tile_to_beats(w, a, npe=NPE)) for w, a in tiles]

    macs = []
    for beat in range(k // NWAY):
        for entry in range(NENTRY):
            beat_w, beat_a = per_entry[entry][beat]
            macs.append(MacOp(beat_w, beat_a, entry, beat == 0))

    await run_slots(dut, macs, model, rng, label="interleave")

    for entry, (weights, act_rows) in enumerate(tiles):
        assert model.read(entry) == expected_lanes(weights, act_rows)
    await drain_all_entries(dut, model, label="interleave")


@cocotb.test()
async def test_drain_and_clear_boundaries(dut):
    """Scenario 5: acc_clear restarts an entry, idle cycles hold it."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0005)
    model = new_model()

    k = 64
    target = NENTRY - 2
    spare = NENTRY - 1
    first_w, first_a = random_tile(rng, k)
    second_w, second_a = random_tile(rng, k)

    # Sweep one tile, drain it, then clear the same entry and sweep another:
    # the second result must not carry a trace of the first.
    await run_slots(dut, tile_macs(first_w, first_a, target), model, rng,
                    label="clear-boundary-1")
    assert model.read(target) == expected_lanes(first_w, first_a)
    await drain_all_entries(dut, model, label="clear-boundary-1")

    await run_slots(dut, tile_macs(second_w, second_a, target), model, rng,
                    label="clear-boundary-2")
    assert model.read(target) == expected_lanes(second_w, second_a)
    await drain_all_entries(dut, model, label="clear-boundary-2")

    # Now the other direction: no clear, so the same tile accumulates twice.
    macs = tile_macs(second_w, second_a, target, clear_first=False)
    await run_slots(dut, macs, model, rng, label="no-clear")
    doubled = tuple(2 * value for value in expected_lanes(second_w, second_a))
    assert model.read(target) == doubled

    # Idle cycles between MACs must not disturb anything.
    macs = tile_macs(first_w, first_a, spare)
    gaps = [rng.randrange(3) for _ in macs]
    await run_slots(dut, macs, model, rng, gaps=gaps, label="gapped")
    assert model.read(spare) == expected_lanes(first_w, first_a)
    await drain_all_entries(dut, model, label="gapped")

    # Reset has to clear the whole file, not only the entries just touched.
    await reset_pcu(dut)
    model.reset()
    await drain_all_entries(dut, model, label="post-reset")


@cocotb.test()
async def test_worst_case_accumulation(dut):
    """Scenario 6: the corner the carry chain was sized for.

    Every weight -8 and every activation 15 over K = 14336 gives -1720320,
    which needs 22 bits. The mirror case, +7 and 15, gives 1505280. Neither may
    raise the overflow flag.

    This is also the corner that decides ACC_RSH for the acc16 variant. There
    every beat contributes rne_narrow(-480, 7) = -4, so the tile lands on
    -14336 -- inside a 16-bit signed accumulator with room to spare, which is
    exactly what shifting the accumulator up by seven bits was for. Keeping the
    base design's LSB weight instead would have wrapped here at 1/50th of this
    K, so this assertion is the one that would catch that mistake.
    """

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0006)

    k = 14336
    beats = k // NWAY

    def corner_total(weight):
        """What the accumulator holds after ``beats`` identical beats."""
        return beats * rne_narrow(weight * A_MAX * NWAY, ACC_RSH)

    for weight, entry, expected in ((W_MIN, 0, corner_total(W_MIN)),
                                    (W_MAX, 1, corner_total(W_MAX))):
        model = new_model()
        beat_w = [[weight] * NWAY for _ in range(NPE)]
        beat_a = [[A_MAX] * NWAY for _ in range(NROW)]
        head = MacOp(beat_w, beat_a, entry, True)
        body = MacOp(beat_w, beat_a, entry, False)
        macs = [head] + [body] * (beats - 1)

        await run_slots(dut, macs, model, rng, label=f"corner w={weight}")
        assert model.read(entry) == tuple([expected] * NLANE), (
            f"corner w={weight}: model produced {model.read(entry)[0]}, "
            f"expected {expected}"
        )
        assert int(dut.ovf_sticky_o.value) == 0, (
            f"corner w={weight}: the {CHAIN_W}-bit chain overflowed at K={k}"
        )
        await reset_pcu(dut)


@cocotb.test()
async def test_overflow_is_reported(dut):
    """Past the supported K the chain wraps, and it says so.

    No K a projection layer uses can reach here -- the 24-bit chain survives to
    K = 69905 -- but a design that wraps silently is a design whose bound
    nobody can check, so the flag is part of the contract.
    """

    if CHAIN_W != 24:
        raise cocotb.result.TestSuccess(
            f"chain width {CHAIN_W} needs an impractically long stream"
        )

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0007)
    model = new_model()

    beat_w = [[W_MIN] * NWAY for _ in range(NPE)]
    beat_a = [[A_MAX] * NWAY for _ in range(NROW)]
    per_mac = W_MIN * A_MAX * NWAY               # -480
    to_overflow = (1 << (CHAIN_W - 1)) // -per_mac + 2

    head = MacOp(beat_w, beat_a, 0, True)
    body = MacOp(beat_w, beat_a, 0, False)
    macs = [head] + [body] * to_overflow

    await run_slots(dut, macs, model, rng, label="overflow")
    assert model.ovf_sticky, "the stimulus failed to overflow the chain"
    assert int(dut.ovf_sticky_o.value) == 1
    # And the wrapped value is exactly the modular one, not a saturation.
    assert model.read(0) == tuple(
        [wrap_signed(per_mac * (to_overflow + 1), CHAIN_W)] * NLANE
    )

    # status_clr_i drops the flag.
    await FallingEdge(dut.clk)
    dut.status_clr_i.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.status_clr_i.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.ovf_sticky_o.value) == 0, "status_clr_i did not clear"
    model.status_clear()

    await reset_pcu(dut)


@cocotb.test()
async def test_random_stream(dut):
    """Scenario 7: bulk random commands over every entry, with idle gaps."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_pcu(dut)
    rng = random.Random(0x0008)
    model = new_model()

    count = int(os.environ.get("SPINQUANT_PCU_ITERS", "6000"))
    macs = []
    gaps = []
    for index in range(count):
        weights, act_rows = random_tile(rng, NWAY)
        macs.append(MacOp(weights, act_rows, rng.randrange(NENTRY),
                          index % 512 == 0 or rng.random() < 0.02))
        gaps.append(0 if rng.random() < 0.8 else rng.randrange(1, 4))

    await run_slots(dut, macs, model, rng, gaps=gaps, label="random")
    await drain_all_entries(dut, model, label="random")
    assert int(dut.ovf_sticky_o.value) == int(model.ovf_sticky)
