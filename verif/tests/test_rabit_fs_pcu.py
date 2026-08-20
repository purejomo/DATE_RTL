"""Full-scale RaBiT PCU: bit-exact regression against the golden model.

The design under test is ``rabit_pcu_fs`` (or ``rabit_pcu_fs_h16`` for the
FP16_3WR fallback). The input GRF is outside the synthesis boundary, so it lives
here as a shadow register file: the testbench watches cvt_we_o / cvt_entry_o /
cvt_blk_o and plays the entry back on grf_blk_i, exactly as the base variant's
testbench does.

Command stream, one column slot = two PCU cycles:

    per chunk    WR_H, WR_X, RD og0, RD og1, RD og2, RD og3
    per stripe   (WR_G group, dequantize group) x 4

The checks are:
  * every y beat matches ``PcuFsGolden`` bit for bit;
  * the raw debug drain still matches the base contract;
  * the design's own assertions (RABIT_FS_ASSERTIONS) hold, which covers the
    u_p deadline, the g-buffer precondition and the drain/read exclusion;
  * the drain occupies the number of accumulator-port cycles the report claims.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from rabit_fs_model import (
    ALIGN_MAX,
    H_FMT_FP16,
    H_FMT_FP8,
    NGROUP,
    NIN,
    NPATH,
    PcuFsGolden,
    fp8_e4m3_code,
    h_scale_chunk,
    pack_fp16_word,
    pack_g_word,
    pack_h_word,
)
from rabit_model import fp16_from_float

WRK_X = 0
WRK_H = 1
WRK_G = 2

NOUT_PER_WORD = int(os.environ.get("RABIT_FS_NOUT", "8"))
DQ_LANES = int(os.environ.get("RABIT_FS_DQ_LANES", "1"))
OUT_LANES = int(os.environ.get("RABIT_FS_OUT_LANES", str(DQ_LANES)))
MANT_W = int(os.environ.get("RABIT_FS_MANT_W", "12"))
RD_CYCLES = int(os.environ.get("RABIT_FS_RD_CYCLES", "2"))
ACC_W = int(os.environ.get("RABIT_FS_ACC_W", "27"))
NOUT_STRIPE = NGROUP * NOUT_PER_WORD
NHALF = NOUT_PER_WORD // DQ_LANES
GROUP_DRAIN_CYCLES = NPATH * NHALF
DRAIN_CYCLES = NGROUP * GROUP_DRAIN_CYCLES
G_OUT_PER_WORD = 256 // (NPATH * 16)
G_WORDS = NOUT_STRIPE // G_OUT_PER_WORD

BLK_W = NIN * (MANT_W + 1) + 6
Y_BEATS_PER_GROUP = NOUT_PER_WORD // OUT_LANES


# ---------------------------------------------------------------------------
# stimulus
# ---------------------------------------------------------------------------


def h_fmt_of(dut) -> int:
    """FP8 by default; the Makefile sets RABIT_FS_H_FMT=1 for the h16 wrapper."""

    return H_FMT_FP16 if os.environ.get("RABIT_FS_H_FMT", "0") == "1" else H_FMT_FP8


def random_stimulus(rng, dout, din, h_fmt):
    """One random problem: weight bits, x, h and g, all already quantized."""

    bits = [
        [[rng.getrandbits(1) for _ in range(din)] for _ in range(dout)]
        for _ in range(NPATH)
    ]
    x_codes = [fp16_from_float(rng.gauss(0.0, 1.0)) for _ in range(din)]

    if h_fmt == H_FMT_FP8:
        h_codes = [
            [fp8_e4m3_code(rng.gauss(0.0, 0.5)) for _ in range(din)]
            for _ in range(NPATH)
        ]
    else:
        h_codes = [
            [fp16_from_float(rng.gauss(0.0, 0.5)) for _ in range(din)]
            for _ in range(NPATH)
        ]

    g_codes = [
        [fp16_from_float(rng.gauss(0.0, 0.25)) for _ in range(dout)]
        for _ in range(NPATH)
    ]
    return bits, x_codes, h_codes, g_codes


def column_word(bits, stripe, k_chunk, out_group):
    """256 bits: bit[j_local*(NPATH*NIN) + p*NIN + k] = B_(p+1)[out j][in k]."""

    word = 0
    for j_local in range(NOUT_PER_WORD):
        j = stripe * NOUT_STRIPE + out_group * NOUT_PER_WORD + j_local
        for p in range(NPATH):
            base = j_local * (NPATH * NIN) + p * NIN
            row = bits[p][j]
            for k_local in range(NIN):
                if row[k_chunk * NIN + k_local]:
                    word |= 1 << (base + k_local)
    return word


def choose_e0(x_codes, h_codes, h_fmt):
    """The largest block exponent the convert unit will see over the sweep.

    The PCU forms u itself now, so the host has to predict it, which is exactly
    what the packer does offline: run the multiply array's model over the chunk
    and take the maximum effective exponent.
    """

    best = 0
    din = len(x_codes)
    for k0 in range(0, din, NIN):
        for p in range(NPATH):
            if h_fmt == H_FMT_FP8:
                lane_h = h_codes[p][k0:k0 + NIN]
            else:
                lane_h = h_codes[p][k0:k0 + NIN]
            u_codes, _, _ = h_scale_chunk(x_codes[k0:k0 + NIN], lane_h, h_fmt)
            for code in u_codes:
                exp = (code >> 10) & 0x1F
                best = max(best, 1 if exp == 0 else exp)
    return best


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------


def drive_idle(dut):
    dut.wr_valid_i.value = 0
    dut.wr_kind_i.value = 0
    dut.wr_sel_i.value = 0
    dut.wr_data_i.value = 0
    dut.rd_valid_i.value = 0
    dut.rd_group_i.value = 0
    dut.rd_pair_i.value = 0
    dut.rd_word_i.value = 0
    dut.drain_req_i.value = 0
    dut.drain_group_i.value = 0
    dut.dq_req_i.value = 0
    dut.status_clr_i.value = 0


class Harness:
    """Shadow GRF plus the per-cycle drive/sample loop."""

    def __init__(self, dut, e0):
        self.dut = dut
        self.grf = [0] * (2 * NPATH)
        self.grf_seen = [False] * (2 * NPATH)
        self.e0 = e0
        self.pair = 0
        self.y_beats = []
        self.drain_beats = []
        self.acc_port_cycles = 0

    def set_grf_bus(self):
        value = 0
        for path in range(NPATH):
            value |= self.grf[self.pair * NPATH + path] << (path * BLK_W)
        self.dut.grf_blk_i.value = value

    async def cycle(self, drive):
        dut = self.dut
        await FallingEdge(dut.clk)
        drive_idle(dut)
        drive(dut)
        self.set_grf_bus()

        await ReadOnly()
        cvt_we = int(dut.cvt_we_o.value)
        cvt_entry = int(dut.cvt_entry_o.value)
        cvt_blk = int(dut.cvt_blk_o.value)
        snap = {
            "wr_ready": int(dut.wr_ready_o.value),
            "rd_ready": int(dut.rd_ready_o.value),
            "dq_ready": int(dut.dq_ready_o.value),
            "drain_ready": int(dut.drain_ready_o.value),
            "dq_busy": int(dut.dq_busy_o.value),
            "y_valid": int(dut.y_valid_o.value),
            "y_data": int(dut.y_data_o.value),
            "y_beat": int(dut.y_beat_o.value),
            "y_last": int(dut.y_last_o.value),
            "drain_valid": int(dut.drain_valid_o.value),
            "drain_data": int(dut.drain_data_o.value),
            "drain_path": int(dut.drain_path_o.value),
            "drain_group": int(dut.drain_group_o.value),
            "status": int(dut.status_sticky_o.value),
            "status_fs": int(dut.status_fs_o.value),
        }

        await RisingEdge(dut.clk)
        if cvt_we:
            self.grf[cvt_entry] = cvt_blk
            self.grf_seen[cvt_entry] = True
        if snap["y_valid"]:
            self.y_beats.append((snap["y_beat"], snap["y_data"], snap["y_last"]))
        if snap["drain_valid"]:
            self.drain_beats.append(
                (snap["drain_group"], snap["drain_path"], snap["drain_data"])
            )
        return snap

    async def idle(self, cycles=1):
        for _ in range(cycles):
            await self.cycle(lambda dut: None)

    # -- column commands (one slot is two PCU cycles) ---------------------
    async def wr_single(self, kind, sel, data):
        def drive(dut):
            dut.wr_valid_i.value = 1
            dut.wr_kind_i.value = kind
            dut.wr_sel_i.value = sel
            dut.wr_data_i.value = data

        snap = await self.cycle(drive)
        assert snap["wr_ready"] == 1, f"kind {kind} write was not accepted"
        await self.idle(1)

    async def wr_x(self, pair, data):
        def drive(dut):
            dut.wr_valid_i.value = 1
            dut.wr_kind_i.value = WRK_X
            dut.wr_sel_i.value = pair
            dut.wr_data_i.value = data

        first = await self.cycle(drive)
        assert first["wr_ready"] == 0, "x write finished in one cycle"
        second = await self.cycle(drive)
        assert second["wr_ready"] == 1, "x write did not finish in NPATH cycles"

    async def rd(self, pair, group, word):
        self.pair = pair

        def drive(dut):
            dut.rd_valid_i.value = 1
            dut.rd_group_i.value = group
            dut.rd_pair_i.value = pair
            dut.rd_word_i.value = word

        for cycle in range(RD_CYCLES):
            snap = await self.cycle(drive)
            expect_ready = cycle == RD_CYCLES - 1
            assert snap["rd_ready"] == expect_ready, (
                f"column word ready={snap['rd_ready']} at cycle {cycle + 1}, "
                f"expected {RD_CYCLES} cycles"
            )

    async def dq_drain(self, group):
        """Request one group's drain and collect its beats.

        dq_req_i is held until dq_ready_o goes high, the usual ready/valid rule:
        the last column word's stage B is still retiring into the accumulator
        file when the request arrives, and the sequencer refuses to start until
        the pipeline is empty.
        """

        self.y_beats = []

        def drive(dut):
            dut.dq_req_i.value = 1

        for wait in range(GROUP_DRAIN_CYCLES):
            snap = await self.cycle(drive)
            if snap["dq_ready"]:
                break
        else:
            raise AssertionError("dequantizing drain was never accepted")

        busy_cycles = 0
        for _ in range(4 * GROUP_DRAIN_CYCLES):
            snap = await self.idle_snap()
            if snap["dq_busy"]:
                busy_cycles += 1
            if len(self.y_beats) == Y_BEATS_PER_GROUP:
                return busy_cycles
        raise AssertionError(
            f"group {group} drain produced {len(self.y_beats)} of "
            f"{Y_BEATS_PER_GROUP} beats"
        )

    async def idle_snap(self):
        return await self.cycle(lambda dut: None)

    async def raw_drain(self, group):
        """Base-semantics debug drain: NPATH beats of raw accumulators."""

        self.drain_beats = []

        def drive(dut):
            dut.drain_req_i.value = 1
            dut.drain_group_i.value = group

        for _ in range(8):
            snap = await self.cycle(drive)
            if snap["drain_ready"]:
                break
        else:
            raise AssertionError("raw drain was never accepted")

        for _ in range(8):
            if len(self.drain_beats) == NPATH:
                return
            await self.idle()
        raise AssertionError(
            f"raw drain produced {len(self.drain_beats)} of {NPATH} beats"
        )


async def reset(dut):
    dut.rst_n.value = 0
    drive_idle(dut)
    dut.grf_blk_i.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# the regression
# ---------------------------------------------------------------------------


async def run_problem(dut, rng, dout, din, check_raw_drain=False):
    h_fmt = h_fmt_of(dut)
    bits, x_codes, h_codes, g_codes = random_stimulus(rng, dout, din, h_fmt)
    e0 = choose_e0(x_codes, h_codes, h_fmt)

    model = PcuFsGolden(
        h_fmt=h_fmt,
        align_max=ALIGN_MAX,
        nout=NOUT_PER_WORD,
        mant_w=MANT_W,
        acc_w=ACC_W,
    )
    model.e0 = e0

    dut.cfg_e0_i.value = e0
    harness = Harness(dut, e0)
    await harness.idle(1)

    n_kchunks = din // NIN
    n_stripes = dout // NOUT_STRIPE

    for stripe in range(n_stripes):
        # ---- the k sweep, unchanged from the base schedule
        for k_chunk in range(n_kchunks):
            pair = k_chunk % 2
            lo = k_chunk * NIN
            x_chunk = x_codes[lo:lo + NIN]

            if h_fmt == H_FMT_FP8:
                h1 = h_codes[0][lo:lo + NIN]
                h2 = h_codes[1][lo:lo + NIN]
                await harness.wr_single(WRK_H, 0, pack_h_word(h1, h2))
                model.write_h([c for k in range(NIN) for c in (h1[k], h2[k])])
            else:
                for p in range(NPATH):
                    hp = h_codes[p][lo:lo + NIN]
                    await harness.wr_single(WRK_H, p, pack_fp16_word(hp))
                    model.write_h(hp, sel=p)

            await harness.wr_x(pair, pack_fp16_word(x_chunk))
            model.write_x(pair, x_chunk)

            for out_group in range(NGROUP):
                word = column_word(bits, stripe, k_chunk, out_group)
                await harness.rd(pair, out_group, word)
                model.read(word, out_group, pair)

            for entry in range(2 * NPATH):
                if model.grf[entry] is not None:
                    assert harness.grf[entry] == model.grf[entry].packed(), (
                        f"GRF entry {entry} differs from the model at chunk {k_chunk}"
                    )

        if check_raw_drain:
            # The raw port still behaves exactly as the base variant's does.
            for group in range(NGROUP):
                await harness.raw_drain(group)
                beats = model.drain(group)
                for path in range(NPATH):
                    _, beat_path, data = harness.drain_beats[path]
                    assert beat_path == path
                    slot = beats[path][1]
                    for pe in range(NOUT_PER_WORD):
                        got = (data >> (pe * 32)) & 0xFFFFFFFF
                        want = slot[pe] & 0xFFFFFFFF
                        assert got == want, (
                            f"raw drain group {group} path {path} pe {pe}: "
                            f"{got:#010x} != {want:#010x}"
                        )
            continue

        # ---- group-streamed output scale and dequantizing drain
        for group in range(NGROUP):
            lo = stripe * NOUT_STRIPE + group * NOUT_PER_WORD
            local = [g_codes[p][lo:lo + NOUT_PER_WORD] for p in range(NPATH)]
            await harness.wr_single(
                WRK_G, group, pack_g_word(local, 0, nout=NOUT_PER_WORD)
            )
            model.write_g(group, local)

            busy = await harness.dq_drain(group)
            want = model.dq_drain(group)

            assert len(harness.y_beats) == Y_BEATS_PER_GROUP
            for index, (beat, data, last) in enumerate(harness.y_beats):
                expected_beat = group * Y_BEATS_PER_GROUP + index
                assert beat == expected_beat, (
                    f"y beat arrived out of order: {beat} != {expected_beat}"
                )
                assert last == (
                    group == NGROUP - 1 and index == Y_BEATS_PER_GROUP - 1
                )
                for lane in range(OUT_LANES):
                    got = (data >> (lane * 16)) & 0xFFFF
                    out_local = index * OUT_LANES + lane
                    expect = want[out_local]
                    assert got == expect, (
                        f"stripe {stripe} group {group} output {out_local}: "
                        f"y = {got:#06x}, model = {expect:#06x}"
                    )

            assert busy >= GROUP_DRAIN_CYCLES, (
                f"group drain claimed fewer than {GROUP_DRAIN_CYCLES} cycles "
                f"({busy})"
            )

    final = await harness.idle_snap()
    assert final["status_fs"] & 0b1000 == 0, (
        "a drain started with an incomplete g buffer"
    )
    assert model.fs_sticky & 0b1000 == 0


@cocotb.test()
async def test_fs_pcu_regression(dut):
    """Random stripes end to end, y compared bit for bit."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset(dut)

    problems = int(os.environ.get("RABIT_FS_PROBLEMS", "4"))
    rng = random.Random(int(os.environ.get("RABIT_FS_SEED", "20260814")))

    for index in range(problems):
        dout = NOUT_STRIPE * (1 + (index % 2))
        din = NIN * (2 + index)
        await run_problem(dut, rng, dout, din)
        await reset(dut)


@cocotb.test()
async def test_fs_raw_drain_matches_base(dut):
    """The debug drain still exposes raw A_1 / A_2 with base semantics."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset(dut)

    rng = random.Random(int(os.environ.get("RABIT_FS_SEED", "20260814")) + 1)
    await run_problem(dut, rng, NOUT_STRIPE, NIN * 3, check_raw_drain=True)


@cocotb.test()
async def test_fs_drain_cost(dut):
    """The dequantizing drain costs exactly DRAIN_CYCLES accumulator cycles."""

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset(dut)

    rng = random.Random(7)
    h_fmt = h_fmt_of(dut)
    bits, x_codes, h_codes, g_codes = random_stimulus(rng, NOUT_STRIPE, NIN, h_fmt)
    e0 = choose_e0(x_codes, h_codes, h_fmt)
    dut.cfg_e0_i.value = e0

    harness = Harness(dut, e0)
    await harness.idle(1)

    if h_fmt == H_FMT_FP8:
        await harness.wr_single(
            WRK_H, 0, pack_h_word(h_codes[0][:NIN], h_codes[1][:NIN])
        )
    else:
        for p in range(NPATH):
            await harness.wr_single(WRK_H, p, pack_fp16_word(h_codes[p][:NIN]))
    await harness.wr_x(0, pack_fp16_word(x_codes[:NIN]))
    for out_group in range(NGROUP):
        await harness.rd(0, out_group, column_word(bits, 0, 0, out_group))

    local = [g_codes[p][:NOUT_PER_WORD] for p in range(NPATH)]
    await harness.wr_single(WRK_G, 0, pack_g_word(local, 0, nout=NOUT_PER_WORD))

    # Count the cycles the sequencer holds the accumulator port by watching how
    # long a read is refused.
    harness.y_beats = []
    dut.dq_req_i.value = 0

    def request(dut_):
        dut_.dq_req_i.value = 1

    for _ in range(GROUP_DRAIN_CYCLES):
        snap = await harness.cycle(request)
        if snap["dq_ready"]:
            break
    else:
        raise AssertionError("dequantizing drain was never accepted")

    stalled = 0
    for _ in range(4 * GROUP_DRAIN_CYCLES):
        snap = await harness.idle_snap()
        if snap["dq_busy"]:
            stalled += 1
        if len(harness.y_beats) == Y_BEATS_PER_GROUP:
            break

    # 16 port cycles plus the three pipeline stages behind them.
    assert stalled == GROUP_DRAIN_CYCLES + 3, (
        f"drain held the design busy for {stalled} cycles, expected "
        f"{GROUP_DRAIN_CYCLES + 3}"
    )
