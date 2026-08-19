"""End-to-end regression for the RaBiT PCU.

The input GRF, the CRF, the DRAM bank and the host NPU all live here as
behavioural models -- they are outside the synthesis boundary by design. The
stimulus comes from the real offline packer (tools/pack_rabit.py), so what runs
through the RTL is the same word stream and the same command schedule a bank
would deliver.

Three things are checked at once:
  1. the RTL matches the bit-accurate golden model, transaction by transaction;
  2. the dequantized result matches an exact rational reference for the whole
     projection GEMV;
  3. the schedule rules hold -- no RD before its entries are written, no RD
     accepted while a drain is in flight.
"""

from __future__ import annotations

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from rabit_model import (
    NGROUP,
    NIN,
    NOUT_PER_WORD,
    NPATH,
    PcuGolden,
    exact_path_partial,
    relative_error,
    signed_from_bits,
)

_TOOLS = os.path.join(os.path.dirname(__file__), "..", "..", "tools")
if _TOOLS not in sys.path:
    sys.path.insert(0, os.path.abspath(_TOOLS))

import pack_rabit  # noqa: E402

MANT_W = int(os.environ.get("RABIT_MANT_W", "12"))
SHIFTER_EN = int(os.environ.get("RABIT_SHIFTER_EN", "1"))
# The acc16 build narrows the architectural accumulator and turns on the
# aligner's existing round-to-nearest-even path. MANT_W has to come down with
# it: rabit_align_shift requires ACC_W > PSUM_W = MANT_W + 5.
ACC_W = int(os.environ.get("RABIT_ACC_W", "32"))
SHIFT_RND = int(os.environ.get("RABIT_SHIFT_RND", "0"))
TRACE = bool(os.environ.get("RABIT_TRACE"))
BLK_W = NIN * (MANT_W + 1) + 6
DRAIN_W = NOUT_PER_WORD * ACC_W


# ---------------------------------------------------------------------------
# behavioural bench around the DUT
# ---------------------------------------------------------------------------


class Bench:
    """Drives the PCU and keeps the behavioural GRF, mirroring PcuGolden."""

    def __init__(self, dut, e0: int):
        self.dut = dut
        self.model = PcuGolden(
            mant_w=MANT_W,
            shifter_en=SHIFTER_EN,
            acc_w=ACC_W,
            shift_rnd=SHIFT_RND,
        )
        self.model.e0 = e0
        self.grf_bits = [0] * (2 * NPATH)
        self.grf_written = [False] * (2 * NPATH)
        self.drains: list[tuple[int, int, tuple[int, ...]]] = []
        self.expected: list[tuple[int, int, tuple[int, ...]]] = []
        self.rd_ready = 0
        self.drain_ready = 0
        self.rd_accepted = 0
        self.rd_done = 0

    def idle(self):
        dut = self.dut
        dut.wr_valid_i.value = 0
        dut.wr_entry_i.value = 0
        dut.wr_fp16_i.value = 0
        dut.rd_valid_i.value = 0
        dut.rd_group_i.value = 0
        dut.rd_pair_i.value = 0
        dut.rd_word_i.value = 0
        dut.grf_blk_i.value = 0
        dut.drain_req_i.value = 0
        dut.drain_group_i.value = 0

    async def reset(self):
        dut = self.dut
        # A previous run() left the scheduler in its read-only phase; step off
        # it before driving anything.
        await FallingEdge(dut.clk)
        self.idle()
        dut.cfg_e0_i.value = self.model.e0
        dut.status_clr_i.value = 0
        dut.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
            await ReadOnly()
            assert int(dut.drain_valid_o.value) == 0
            assert int(dut.rd_ready_o.value) == 0
            assert int(dut.status_sticky_o.value) == 0
        await FallingEdge(dut.clk)
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.wr_ready_o.value) == 1
        assert int(dut.drain_ready_o.value) == 1
        self.rd_ready = int(dut.rd_ready_o.value)
        self.drain_ready = int(dut.drain_ready_o.value)
        self.model.reset()
        self.grf_written = [False] * (2 * NPATH)

    def _drive(self, cmd):
        dut = self.dut
        self.idle()
        if cmd is None:
            return
        if cmd.kind == "WR":
            dut.wr_valid_i.value = 1
            dut.wr_entry_i.value = cmd.entry
            word = 0
            for lane, code in enumerate(cmd.codes):
                word |= (code & 0xFFFF) << (lane * 16)
            dut.wr_fp16_i.value = word
        elif cmd.kind == "RD":
            # A RD whose entries were never written is a schedule violation --
            # the AAM barrier the host is supposed to place is missing.
            for path in range(NPATH):
                entry = cmd.pair * NPATH + path
                assert self.grf_written[entry], (
                    f"RD used GRF entry {entry} before any WR (missing barrier)"
                )
            dut.rd_valid_i.value = 1
            dut.rd_group_i.value = cmd.group
            dut.rd_pair_i.value = cmd.pair
            dut.rd_word_i.value = cmd.word
            pair_bits = 0
            for path in range(NPATH):
                pair_bits |= (
                    self.grf_bits[cmd.pair * NPATH + path] << (path * BLK_W)
                )
            dut.grf_blk_i.value = pair_bits
        elif cmd.kind == "DRAIN":
            dut.drain_req_i.value = 1
            dut.drain_group_i.value = cmd.group
        else:
            raise ValueError(f"unknown command {cmd.kind}")

    async def _sample(self, cmd, accepted):
        """Read the DUT after a rising edge and fold the result into the model."""

        dut = self.dut

        if cmd is not None and cmd.kind == "WR":
            assert int(dut.cvt_we_o.value) == 1
            assert int(dut.cvt_entry_o.value) == cmd.entry
            block = self.model.write(cmd.entry, cmd.codes)
            got = int(dut.cvt_blk_o.value)
            assert got == block.packed(), (
                f"cvt_blk mismatch on entry {cmd.entry}: "
                f"{got:x} != {block.packed():x}"
            )
            self.grf_bits[cmd.entry] = got
            self.grf_written[cmd.entry] = True
        else:
            assert int(dut.cvt_we_o.value) == 0

        if cmd is not None and cmd.kind == "RD":
            assert int(dut.grf_pair_o.value) == cmd.pair, (
                "grf_pair_o does not hold the pair select across the word"
            )
            if accepted:
                self.model.read(cmd.word, cmd.group, cmd.pair)

        # rd_done_o marks the cycle the word's last pump landed in the file, so
        # exactly one pulse must retire per accepted RD.
        if int(dut.rd_done_o.value):
            self.rd_done += 1

        if int(dut.drain_valid_o.value):
            assert int(dut.rd_ready_o.value) == 0, (
                "a RD was accepted while a drain was in flight"
            )
            assert int(dut.rd_done_o.value) == 0, (
                "rd_done_o pulsed during a drain"
            )
            data = int(dut.drain_data_o.value)
            values = tuple(
                signed_from_bits(
                    (data >> (pe * ACC_W)) & ((1 << ACC_W) - 1), ACC_W
                )
                for pe in range(NOUT_PER_WORD)
            )
            beat = (
                int(dut.drain_group_o.value),
                int(dut.drain_path_o.value),
                values,
            )
            assert self.expected, "the DUT drained a beat the model did not"
            want = self.expected.pop(0)
            assert beat == want, (
                f"drain beat {beat[0]}/{beat[1]} = {beat[2]} "
                f"!= model {want[0]}/{want[1]} = {want[2]}"
            )
            assert int(dut.drain_last_o.value) == int(
                beat[1] == NPATH - 1
            ), "drain_last_o did not mark the final beat of the group"
            self.drains.append(beat)

        self.rd_ready = int(dut.rd_ready_o.value)
        self.drain_ready = int(dut.drain_ready_o.value)

    async def run(self, commands, *, stall_prob: float = 0.0, seed: int = 0):
        """Issue a command stream, honouring ready/valid on both ports."""

        dut = self.dut
        rng = random.Random(seed)
        queue = list(commands)
        index = 0
        drain_beats_left = 0
        guard = 0
        limit = 64 + 8 * (len(queue) + 1) * NPATH
        # A RD that has been offered but not yet granted has already started
        # inside the PCU, so valid and the word must stay put until rd_ready.
        # Bubbles may only be injected between words.
        held = False

        while index < len(queue) or drain_beats_left:
            guard += 1
            assert guard < limit, "PCU command stream stalled"

            cmd = queue[index] if index < len(queue) else None
            if cmd is not None and not held and stall_prob and rng.random() < stall_prob:
                cmd_now = None
            else:
                cmd_now = cmd

            # rd_ready / drain_ready were sampled after the previous rising
            # edge, so they are exactly the values in force for this cycle.
            ready_now = self.rd_ready
            drain_ready_now = self.drain_ready

            await FallingEdge(dut.clk)
            self._drive(cmd_now)
            await RisingEdge(dut.clk)
            await ReadOnly()

            accepted = False
            if cmd_now is not None:
                if cmd_now.kind == "WR":
                    accepted = True
                elif cmd_now.kind == "RD":
                    accepted = bool(ready_now)
                    if accepted:
                        self.rd_accepted += 1
                elif cmd_now.kind == "DRAIN":
                    accepted = bool(drain_ready_now)
                    if accepted:
                        drain_beats_left = NPATH
                        for path, values in self.model.drain(cmd_now.group):
                            self.expected.append((cmd_now.group, path, values))

            held = (
                cmd_now is not None and cmd_now.kind == "RD" and not accepted
            )

            before = len(self.drains)
            await self._sample(cmd_now, accepted)
            drain_beats_left -= len(self.drains) - before
            assert drain_beats_left >= 0

            if TRACE:
                dut._log.info(
                    f"cmd={cmd_now.kind if cmd_now else 'idle'} "
                    f"grp={getattr(cmd_now, 'group', '-')} "
                    f"rdy={ready_now} drdy={drain_ready_now} acc={accepted} "
                    f"beats_left={drain_beats_left}"
                )

            if accepted:
                index += 1

        # Two idle cycles so the last stage-B write and the sticky register it
        # feeds have both retired before anyone samples them.
        for _ in range(2):
            await FallingEdge(dut.clk)
            self.idle()
            await RisingEdge(dut.clk)
            await ReadOnly()
        self.rd_ready = int(dut.rd_ready_o.value)
        self.drain_ready = int(dut.drain_ready_o.value)
        assert not self.expected, "the model drained beats the DUT never produced"

    def check_sticky(self):
        got = int(self.dut.status_sticky_o.value)
        assert got == self.model.sticky, (
            f"status_sticky {got:03b} != model {self.model.sticky:03b}"
        )

    def check_done(self):
        assert self.rd_done == self.rd_accepted, (
            f"rd_done_o pulsed {self.rd_done} times for "
            f"{self.rd_accepted} accepted RDs"
        )

    def take_drains(self):
        out = self.drains
        self.drains = []
        return out


# ---------------------------------------------------------------------------
# phases
# ---------------------------------------------------------------------------


def make_cmd(kind, **kwargs):
    return pack_rabit.Command(kind=kind, **kwargs)


async def phase_directed(dut):
    """A hand-built word: every PE, path and group has to land in its own slot.

    The expected integers are derived by hand rather than taken from the model,
    so this phase checks the model too. Entry 0 holds 1.0 in every lane, which
    gives e_ent = 15 = E0 and therefore an alignment shift of zero. Entry 1
    holds 0.5, so its block exponent is 14 and the whole path-2 partial sum is
    shifted right by one. Both entries store the same mantissa pattern -- that
    is exactly what a shared exponent buys.
    """

    from rabit_model import fp16_from_float

    bench = Bench(dut, e0=15)
    await bench.reset()

    ones = tuple(fp16_from_float(1.0) for _ in range(NIN))
    halves = tuple(fp16_from_float(0.5) for _ in range(NIN))

    mant_one = 2048 >> (12 - MANT_W)  # 1.0 aligned to its own block exponent
    if SHIFTER_EN:
        expect = {0: NIN * mant_one, 1: (NIN * mant_one) >> 1}
    else:
        # Without the PE shifter the converter aligns to E0 = 15 instead, so
        # the 0.5 entry loses one bit at convert time and nothing shifts later.
        expect = {0: NIN * mant_one, 1: NIN * (mant_one >> 1)}

    cmds = [
        make_cmd("WR", entry=0, codes=ones),
        make_cmd("WR", entry=1, codes=halves),
    ]
    # Word with all bits zero: every weight is +1.
    for group in range(NGROUP):
        cmds.append(make_cmd("RD", pair=0, group=group, word=0))
    for group in range(NGROUP):
        cmds.append(make_cmd("DRAIN", group=group))

    await bench.run(cmds)
    drains = bench.take_drains()
    assert len(drains) == NGROUP * NPATH

    for group, path, values in drains:
        assert values == (expect[path],) * NOUT_PER_WORD, (
            f"group {group} path {path} drained {values}, expected "
            f"{expect[path]}"
        )

    # Everything must be zero after a drain.
    for group in range(NGROUP):
        await bench.run([make_cmd("DRAIN", group=group)])
    for _, _, values in bench.take_drains():
        assert values == (0,) * NOUT_PER_WORD, "drain did not clear the group"

    # One-hot over PEs and paths: bit j*32 + p*16 + k must reach exactly the
    # accumulator slot for output j, path p, and flip that lane's sign to -1.
    for path in range(NPATH):
        for pe in range(NOUT_PER_WORD):
            for group in range(NGROUP):
                word = 0
                for k in range(NIN):
                    word |= 1 << (pe * (NPATH * NIN) + path * NIN + k)
                await bench.run([make_cmd("RD", pair=0, group=group, word=word)])
                await bench.run([make_cmd("DRAIN", group=group)])
                for dgroup, dpath, values in bench.take_drains():
                    for other in range(NOUT_PER_WORD):
                        want = expect[dpath]
                        if dpath == path and other == pe:
                            want = -expect[dpath]
                        assert values[other] == want, (
                            f"one-hot pe {pe} path {path}: group {dgroup} "
                            f"path {dpath} pe {other} = {values[other]}, "
                            f"expected {want}"
                        )

    bench.check_sticky()
    bench.check_done()


async def phase_drain_blocks_read(dut):
    """A RD offered during a drain must wait, and must not corrupt the drain."""

    from rabit_model import fp16_from_float

    bench = Bench(dut, e0=15)
    await bench.reset()

    ones = tuple(fp16_from_float(1.0) for _ in range(NIN))
    await bench.run(
        [
            make_cmd("WR", entry=0, codes=ones),
            make_cmd("WR", entry=1, codes=ones),
            make_cmd("RD", pair=0, group=0, word=0),
        ]
    )

    # Offer the drain and a RD to a different group at the same time. The drain
    # wins; the RD is held off until the drain retires. Bench.run asserts that
    # rd_ready_o stays low for every cycle a drain beat is on the bus.
    await bench.run(
        [
            make_cmd("DRAIN", group=0),
            make_cmd("RD", pair=0, group=1, word=0),
            make_cmd("DRAIN", group=1),
        ]
    )

    drains = bench.take_drains()
    assert len(drains) == 2 * NPATH
    expect = NIN * (2048 >> (12 - MANT_W))
    for group, path, values in drains:
        assert values == (expect,) * NOUT_PER_WORD, (
            f"group {group} path {path} drained {values} under drain/read "
            f"contention, expected {expect}"
        )
    bench.check_sticky()
    bench.check_done()


async def phase_gemv(dut, dout: int, din: int, seed: int, stall_prob: float):
    """Run a whole projection GEMV through the packer, the RTL and the model."""

    weights = pack_rabit.random_matrix(dout, din, seed)
    packing, scales = pack_rabit.build_packing(weights, npath=NPATH)

    rng = random.Random(seed ^ 0x5EED)
    x = [rng.gauss(0.0, 1.0) for _ in range(din)]
    u_codes = pack_rabit.pack_activations(x, scales, npath=NPATH)
    e0 = pack_rabit.choose_e0(u_codes)

    bench = Bench(dut, e0=e0)
    await bench.reset()

    cmds = list(pack_rabit.schedule(packing, u_codes))
    await bench.run(cmds, stall_prob=stall_prob, seed=seed)

    # ---- RTL against the golden model --------------------------------
    #
    # Bench.run already folded every accepted transaction into the model, so a
    # drained beat only has to match what the model drained at the same point.
    # Rebuild both sides indexed by dout position.
    beats = bench.take_drains()
    assert len(beats) == packing.n_stripes * NGROUP * NPATH, (
        f"expected {packing.n_stripes * NGROUP * NPATH} drain beats, "
        f"got {len(beats)}"
    )

    partials = [[0] * dout for _ in range(NPATH)]
    cursor = 0
    for stripe in range(packing.n_stripes):
        for group in range(NGROUP):
            for _ in range(NPATH):
                dgroup, dpath, values = beats[cursor]
                cursor += 1
                assert dgroup == group, f"drain group {dgroup} != {group}"
                for pe, value in enumerate(values):
                    j = stripe * NOUT_PER_WORD * NGROUP + group * NOUT_PER_WORD + pe
                    partials[dpath][j] = value

    bench.check_sticky()
    bench.check_done()
    assert bench.model.sticky & 0b010 == 0, (
        "the alignment shifter saturated: cfg_e0 is out of range"
    )

    # ---- dequantized result against an exact reference ----------------
    reference = []
    for j in range(dout):
        total = 0.0
        for p in range(NPATH):
            row = packing.core_row(p, j)
            total += scales.g[p][j] * float(
                exact_path_partial(row, u_codes[p])
            )
        reference.append(total)

    weight = float(2.0) ** (e0 - 14 - MANT_W)
    actual = [
        sum(scales.g[p][j] * partials[p][j] * weight for p in range(NPATH))
        for j in range(dout)
    ]
    rel = relative_error(actual, reference)

    # Bound the error analytically from this stimulus instead of asserting a
    # tuned constant, because the dominant term moves with the data. Per k
    # chunk the datapath loses at most:
    #
    #   convert  16 lanes x 1/2 ulp of the block  = 8 * 2**(e_ent - E0) acc LSB
    #            and e_ent <= E0 by construction, so at most 8
    #   align    the arithmetic shift floors      < 1 acc LSB
    #
    # so |A_p error| < 9 * chunks accumulator LSB, and the y error follows by
    # the g scaling. The alignment term is one-sided, which is exactly why a
    # deeper k sweep or a wider E0 spread costs accuracy: see proposal P1 in
    # docs/rabit_pcu_spec.md, where round-to-nearest removes it entirely.
    chunks = din // NIN
    bound_per_output = 9.0 * chunks * weight
    bound = [
        sum(abs(scales.g[p][j]) for p in range(NPATH)) * bound_per_output
        for j in range(dout)
    ]
    rel_bound = relative_error(
        [reference[j] + bound[j] for j in range(dout)], reference
    )

    mean_shift = sum(
        e0 - pack_rabit.entry_exponent(u_codes[p][c * NIN:(c + 1) * NIN])
        for p in range(NPATH)
        for c in range(chunks)
    ) / (NPATH * chunks)

    dut._log.info(
        f"GEMV {dout}x{din} seed {seed}: MANT_W {MANT_W} ACC_W {ACC_W} "
        f"SHIFT_RND {SHIFT_RND} SHIFTER_EN "
        f"{SHIFTER_EN} E0 {e0} mean(E0-e_ent) {mean_shift:.2f} -> "
        f"relative error {rel:.3e} (bound {rel_bound:.3e})"
    )

    assert rel < rel_bound, (
        f"relative error {rel:.3e} exceeds the analytic bound {rel_bound:.3e}"
    )
    # A second, absolute guard so a catastrophically wrong E0 or a datapath that
    # merely stays inside a loose bound still fails.
    ceiling = float(os.environ.get("RABIT_REL_TOL", "2e-2"))
    assert rel < ceiling, f"relative error {rel:.3e} exceeds {ceiling:.3e}"
    return rel


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------


@cocotb.test()
async def test_rabit_pcu(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())

    await phase_directed(dut)
    await phase_drain_blocks_read(dut)

    # din is the full Llama-2-7B projection k dimension, so the accumulation
    # depth -- 256 chunks into one resident accumulator -- is the real thing.
    # dout is cut down because it only replicates stripes; tools/rabit_accuracy.py
    # sweeps the full 4096x4096 and 11008x4096 shapes through the same model.
    dout = int(os.environ.get("RABIT_GEMV_DOUT", "64"))
    din = int(os.environ.get("RABIT_GEMV_DIN", "4096"))
    seeds = [int(s) for s in os.environ.get("RABIT_SEEDS", "1,2,3").split(",")]

    errors = []
    for index, seed in enumerate(seeds):
        # One seed runs with random bubbles on the command stream so the
        # handshake is exercised, not just the fixed 2-pump cadence.
        stall = 0.25 if index == len(seeds) - 1 else 0.0
        errors.append(await phase_gemv(dut, dout, din, seed, stall))

    dut._log.info(
        f"{len(errors)} GEMV seeds, relative error "
        f"min {min(errors):.3e} max {max(errors):.3e}"
    )
