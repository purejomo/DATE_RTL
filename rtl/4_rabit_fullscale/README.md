# RaBiT PCU, full-scale variant (PCU-FS)

The base variant in [`rtl/4_rabit`](../4_rabit) computes the binary part of a
RaBiT projection layer and leaves both scales with the NPU:

```text
A_p[j] = sum_k B_p[j][k] * u_p[k]      B_p[j][k] in {+1,-1}
u_p[k] = h_p[k] * x[k]                 NPU forms this and sends it
y[j]   = g_1[j]*A_1[j] + g_2[j]*A_2[j] NPU does this after the drain
```

This directory is the same engine with both scale operations moved inside the
PCU. It exists to answer one question with numbers: **what does on-PCU scaling
cost in area and in throughput?**

Nothing here replaces the base variant. `rabit_pcu_top` is untouched, and its
modules are instantiated from this directory rather than copied — the compressor
tree, the aligner, the PE, the convert-on-write unit, the accumulator register
file and the sequencer are all the base ones. Three blocks are new.

| block | where it lives | what it does |
|---|---|---|
| `rabit_fs_h_scale_unit` | write path | `u_p = x (*) h_p`, 16 x (fp16 x fp8) |
| `rabit_fs_g_buffer` | stripe state | the stripe's 32 x 2 binary16 output scales |
| `rabit_fs_dq_unit` | drain path | `y[j] = fp16(g_1 A_1 + g_2 A_2)` |
| `rabit_fs_fp16_pack` | shared | one magnitude+exponent -> binary16 RNE primitive |
| `rabit_fs_dq_lane`, `rabit_fs_dq_add` | drain path | the dequantizer's two stages |
| `rabit_fs_drain_seq` | control | walks the accumulator port for a whole stripe |

There is **no multiplier on the read path**. h multiplies live on the write
path, g multiplies live on the drain path, and the PE array is the same
multiplier-free sign-and-add tree the base variant uses.

---

## 1. Command interface

Every command is a 256-bit column write or a 256-bit column read, and one
column slot is two PCU cycles (tCCD_S). The inner loop is byte-for-byte the
base schedule — two writes and four reads per 16-input chunk:

```text
per stripe   WR_G x 4                     load g for the 32 resident outputs
per chunk    WR_H                         {h1[k], h2[k]} as FP8-E4M3
             WR_X                         x, binary16 x 16, takes 2 PCU cycles
             RD og0 .. og3                the four output groups
per stripe   DQ                           dequantizing drain, 16 port cycles
```

`wr_kind_i` selects the write:

| kind | value | `wr_sel_i` | payload |
|---|---:|---|---|
| `WRK_X` | 0 | GRF pair | 16 binary16 x values |
| `WRK_H` | 1 | (FP16_3WR only) which h vector | 16 x 2 FP8-E4M3 scales |
| `WRK_G` | 2 | quarter 0..3 | 8 outputs x 2 paths of binary16 g |

Bit layouts, all chosen to match the weight word's `j, p, k` nesting so the
packer builds them with the index arithmetic it already has:

```text
WR_H   bit[k*16 + p*8  +: 8]  = h_(p+1)[k]
WR_G   bit[j*32 + p*16 +: 16] = g_(p+1)[quarter*8 + j]
```

**A `WRK_H` write must precede the `WRK_X` write of the same chunk.** The x
write is the column slot that consumes the latch: it holds `wr_valid_i` and
`wr_data_i` for two PCU cycles and spends cycle *p* forming `u_(p+1)`.
`wr_ready_o` is low on the first cycle and high on the second, the same
hold-until-ready rule the compute port already uses. This is checked by an
assertion.

**One command per column slot.** `wr_valid_i`, `rd_valid_i`, `drain_req_i` and
`dq_req_i` are mutually exclusive, and assertions check it. The base sequencer
resolves a raw drain against a new word internally, but the dequantizing drain
sits beside it rather than inside it: a column read presented in the same slot
as `dq_req_i` would be started and then have its stage-B write muxed away.

Two drains coexist. `drain_req_i` is the base variant's raw per-group drain,
kept for debug and for measuring the two variants against each other;
`dq_req_i` drains a whole stripe through the dequantizer and produces binary16
`y`. They share the accumulator port, so neither may overlap the other or a
column command, and `dq_ready_o` / `drain_ready_o` enforce that.

`y_valid_o` carries `DQ_LANES` finished outputs per beat, eight beats per
stripe; `y_beat_o` is the beat index, so output `j = y_beat_o*4 + lane`.

---

## 2. h_scale_unit

```text
x = (-1)**sx * sig_x * 2**(e_x - 25)   sig_x 11b   e_x = max(exp, 1)
h = (-1)**sh * sig_h * 2**(e_h - 10)   sig_h  4b   e_h = max(exp, 1)
u = (-1)**(sx^sh) * (sig_x * sig_h) * 2**(e_x + e_h - 35)
```

This is deliberately **not** a binary16 multiplier: 16 multipliers of 11x4 plus
an exponent add, then one RNE rounding in `rabit_fs_fp16_pack`.

FP8-E4M3 follows OCP FN: bias 7, no infinity, `0x7F`/`0xFF` are NaN.

**Why FP8 and not binary16.** h is per-input-channel, so it changes every chunk.
Two binary16 h vectors would be a third write per chunk — eight column slots
instead of six, a 33 % throughput loss — which the specification rules out.
`H_FMT = FP16_3WR` builds exactly that as a comparison mode; see §7 for what it
costs and §8 for the open question it raises.

**Timing.** Cycle 0 of the x write forms `u_1` and cycle 1 forms `u_2`, each
converted by `rabit_cvt_fp16_blk` and written into the behavioural GRF in the
same cycle. The next column slot's `RD og0` reads GRF entry `{pair, 0}` on its
cycle 0 and `{pair, 1}` on its cycle 1, so `u_1` has two cycles of margin and
`u_2` has one. An assertion in `rabit_pcu_fs_top` checks that every pump reads
an entry that is already in the file and is not the one being converted in that
same cycle, so a schedule that violates the deadline fails the test rather than
producing quietly wrong data.

**`H_MUL_PIPE` — the one place the specified datapath does not hold up.** With
the h decode, the 11x4 multiply, the binary16 rounding and the block convert all
in one cycle, the write path is a single combinational chain from `wr_data_i` to
`cvt_blk_o`, and synthesis says it misses even the 250 MHz point (see
[`results/rabit_fs_report.md`](../../results/designs/rabit_fs_report.md) §3). Note that
the *base* variant's own convert path is already the critical one there, and it
also misses 500 MHz; the h array is what pushes it past 250 MHz too.

`H_MUL_PIPE = 1` puts one 256-bit register between the multiply array and the
convert unit. It costs **no column slots at all**, because the deadline still
works out:

```text
WR_X cycle 0   multiply u_1                  -> register
WR_X cycle 1   convert u_1 -> GRF ; multiply u_2 -> register
RD   pump 0    read entry {pair,0} ; convert u_2 -> GRF
RD   pump 1    read entry {pair,1}                   <- available, one cycle old
```

The deadline assertion checks exactly this — the entry a pump reads must already
be in the file and must not be the one being converted in that same cycle — and
the bit-exact regression passes unchanged in both modes (`make TEST=rabit_fs`
and `make TEST=rabit_fs_pipe` produce identical `y`). The default is 0, the
literal reading of the specification; the report carries both so the choice is
visible. See Q8.

**`NMULT_H = 8` is not implemented, on purpose.** Halving the array would make
the x write take four cycles, so `u_2` would be written on the same cycle
`RD og0` pump 1 reads it — a zero-cycle margin, i.e. a violated deadline, unless
the schedule inserts an idle column slot per chunk (a 17 % throughput loss). The
parameter is checked at elaboration and rejected.

### Double rounding

`rabit_cvt_fp16_blk` consumes binary16, so the 15-bit product is rounded to
binary16 before the block convert rounds it again. This is not the precision
loss it looks like. With `MANT_W = 12` the convert unit stores the entry's
largest lane as `sig << 1`, so an 11-bit binary16 significand is *exactly*
representable; only lanes that the convert unit is already right-aligning see a
second rounding, and those lanes are losing bits to the alignment anyway. The
measured datapath error (§7) confirms it: PCU-FS is as accurate as the base
variant, given the same h.

---

## 3. g_buffer

64 x 16b of flip-flops — 32 outputs x 2 paths — filled by four ordinary column
writes at the top of a stripe. Writing word 0 restarts the fill count, so a
partial reload cannot read as complete, and `dq_req_i` with an incomplete buffer
raises `status_fs_o[3]` and fails an assertion.

Four slots against a stripe's whole k sweep is 0.26 % at din = 4096 (§7).

**The DRAM-resident alternative is deliberately not implemented.** g could live
in the bank next to the weights and arrive on `RD` instead of `WR`, which would
cost zero host bandwidth. It was rejected for this experiment because it changes
the address map and the weight layout — a `RD` that returns scales rather than a
weight word needs its own column region and its own decode — and because the
measured cost of the `WR` path is already 0.26 %. If the g load ever becomes the
bottleneck (very small din), that is the change to make.

---

## 4. g_dequant_unit

```text
A_p[j] = acc * 2**(E0 - 14 - MANT_W)       the base variant's drain contract
y[j]   = fp16( g_1[j]*A_1[j] + g_2[j]*A_2[j] )
```

Three pipeline stages, one result per cycle:

```text
S0  lane   32b acc -> sign + 12b mantissa (LZC, RNE) ; g -> normalized 11b
           significand ; 12 x 11 multiply ; exponent add
S1  add    align the two paths to the larger exponent, add in two's complement
S2  pack   normalize the sum and round once, to binary16
```

### Why four lanes across the output axis

The specification suggests two outputs per cycle, each with both of its paths in
parallel. That needs two accumulator slots read in one cycle, and
`rabit_acc_regfile` has a single read port — which this variant is not allowed
to change. So the lanes go across the *output* axis and the *path* axis is
serialized:

```text
cycle 0   slot (group, path 0), outputs 0..3   -> parked partial
cycle 1   slot (group, path 0), outputs 4..7   -> parked partial
cycle 2   slot (group, path 1), outputs 0..3   -> y beat
cycle 3   slot (group, path 1), outputs 4..7   -> y beat
```

Four cycles per group, **16 cycles for the stripe's 32 outputs**, an average of
two finished outputs per cycle, and a `16b x 4` output beat every other cycle —
all exactly as specified. The slot is read twice, which costs nothing on a
register file, and it is cleared on the second of the two reads.

The price of the single read port is `DQ_LANES` adders and packers instead of
`DQ_LANES/2`, plus a parked-partial bank of `2 x 4 x 34` bits. That is the
honest cost of not touching the base register file, and it is in the area
breakdown.

`acc_busy_o` is asserted only for the 16 port cycles. The three pipeline stages
behind it keep running for three more cycles, but column commands may already
restart, so the drain stall is 16 cycles and not 19.

### Numeric policy

Shared with `rabit_fs_h_scale_unit` through `rabit_fs_fp16_pack`, and the same
"no special cases" spirit as the base variant:

* **Overflow** saturates to the largest finite binary16 (`0x7BFF`) and raises a
  sticky status bit. No infinity is ever produced, because
  `rabit_cvt_fp16_blk` does not special case `exp == 31` and would decode one as
  an ordinary number.
* **Subnormals** are produced exactly, never flushed. The convert unit
  represents them exactly, so flushing would only lose accuracy. A subnormal
  that rounds up to 1024 already reads as `{exp = 1, frac = 0}`, the smallest
  normal, so the boundary needs no extra logic.
* **Subnormal g** is normalized rather than flushed, which keeps the exponent
  difference the adder sees a faithful magnitude ratio.
* **Rounding** is round-to-nearest-even everywhere.
* **The accumulator is rounded to 12 bits before the g multiply.** That is the
  specified datapath; it caps the multiplier at 12x11 and is far below what a
  binary16 output can show.
* **Alignment** is lossless for exponent differences up to `ALIGN_MAX = 16`.
  Both lanes normalize before multiplying, so a term dropped there is below
  2^-15 of the other one while the result keeps 11 bits: it can only change a
  round-to-nearest tie. Cancellation is unaffected, because two terms that
  cancel have nearly equal exponents and are aligned exactly.

---

## 5. Status bits

`status_sticky_o` keeps the base meaning. `status_fs_o` is what this variant
adds:

| bit | meaning |
|---:|---|
| 0 | an FP8-E4M3 h code was a NaN encoding |
| 1 | an `h*x` product saturated to the largest finite binary16 |
| 2 | a dequantized `y` saturated to the largest finite binary16 |
| 3 | a dequantizing drain started with an incomplete g buffer |

---

## 6. Verification

```bash
cd verif
make TEST=rabit_fs          # FP8-E4M3 h, the specified datapath
make TEST=rabit_fs_pipe     # the same with H_MUL_PIPE = 1 (closes timing)
make TEST=rabit_fs_h16      # H_FMT = FP16_3WR, three writes per chunk
RABIT_FS_PROBLEMS=16 make TEST=rabit_fs    # longer regression
```

All three produce the same `y` for the same stimulus; `rabit_fs_pipe` differs
only in when the convert unit runs.

`verif/models/rabit_fs_model.py` is the bit-accurate golden model — Python
integers only on the comparison path, so a match is a statement about the design
and not about the simulator's FPU. Every `y` beat is compared bit for bit. The
tests also run the design's own assertions (`RABIT_FS_ASSERTIONS`): the `u_p`
deadline, the g-buffer precondition, the drain/read exclusion and the write
hold rule.

`test_fs_drain_cost` pins the drain to exactly 16 accumulator-port cycles plus
three pipeline cycles, so the throughput claim in the report cannot drift
without a test failing.

The schedule itself is checked separately:

```bash
python3 tools/pack_rabit_fs.py --self-test
```

which walks the real command stream and asserts that the inner loop is the same
six column slots per chunk as the base variant.

---

## 7. Measured results

* [`results/rabit_fs_report.md`](../../results/designs/rabit_fs_report.md) — area,
  module breakdown, timing and the throughput ratio
* [`results/rabit_fs_accuracy.md`](../../results/designs/rabit_fs_accuracy.md) — what
  the FP8 h format costs, isolated from the datapath

Reproduce with:

```bash
cd synth && ./run_rabit_fs.sh        # synthesis, then both reports
python3 tools/pack_rabit_fs.py --throughput --dout 4096 --din 4096
```

Area, Nangate45 typical, logic synthesis only, 250 MHz:

| design | area (um2) | vs base PCU | vs baseline FP16 16-lane |
|---|---:|---:|---:|
| base PCU | 45,254 | 1.000x | 0.752x |
| PCU-FS, specified datapath | 93,522 | 2.067x | 1.554x |
| **PCU-FS, `H_MUL_PIPE = 1`** | **94,841** | **2.096x** | **1.576x** |
| PCU-FS, `H_FMT = FP16_3WR` | 106,277 | 2.348x | 1.766x |
| baseline FP16 16-lane | 60,176 | 1.330x | 1.000x |

Blocks, synthesized in isolation: `h_scale_unit` 20,651, `g_buffer` 12,484,
`g_dequant_unit` 28,083 — 61,219 um2 summed, against a flat-top delta of
48,269 um2 once the flow flattens and optimizes across the boundaries. For
reference the base variant's own blocks are `cvt` 5,002, `rabit_pe` 3,693 x 8
and the accumulator array 20,872.

Timing at 250 MHz: base +1.16 ns, PCU-FS **-0.29 ns**, PCU-FS with
`H_MUL_PIPE = 1` **+1.22 ns**. Neither RaBiT variant closes 500 MHz — the base
misses it by 0.04 ns on its own convert path — so 250 MHz is the comparison
point.

Throughput, from the slot-level walk:

| dout x din | base slots | FS slots | FS/base |
|---|---:|---:|---:|
| 4096 x 4096 | 197,120 | 198,272 | 99.42 % |
| 4096 x 11008 | 528,896 | 530,048 | 99.78 % |
| 128 x 512 | 784 | 820 | 95.61 % |

The overhead is per stripe and amortized over the k sweep, so it scales as
1/din. At the projection-layer shapes RaBiT targets it is 0.6 % or less, inside
the 1 % the specification allows. The 128 x 512 row shows where that stops
being true.

Accuracy, L2 relative error against an exact rational reference (three seeds,
64 x 512):

| quantity | L2 rel err |
|---|---:|
| `h_format_only` — FP8-E4M3 h, everything else exact | 2.6 % .. 3.2 % |
| `fs_vs_fp8_ref` — the PCU-FS datapath itself | 4.0e-4 .. 1.4e-3 |
| `base_vs_fp16_ref` — the base variant, h in binary16 | 3.5e-4 .. 1.3e-3 |

**Read that carefully.** The full-scale datapath is as accurate as the base
one. The 3 % is entirely the FP8 format, and it is roughly two orders of
magnitude larger than anything the hardware does. That is the evidence the
specification asked for, and it is not a comfortable result — see Q1.

### The answer, in one line

Moving both RaBiT scales into the PCU costs **about 2.1x the area** and
**about 0.6 % of the throughput** at projection-layer shapes. The throughput
side of that trade is cheap, exactly as the specification hoped. The area side
is not: the PCU-FS is 1.58x the FP16 16-lane baseline compute unit it is
supposed to beat, where the base RaBiT PCU is 0.75x it. Roughly three fifths of
the added area is the g path (buffer plus dequantizer) and two fifths the h
multiply array. And the h format that made the throughput number possible costs
~3 % output error, which is the largest single term in the whole design's error
budget.

---

## 8. Open questions

Recorded rather than decided, because the specification does not answer them.

**Q1 — is FP8-E4M3 for h acceptable?** It costs ~3 % L2 relative error on the
layer output, about 80x the PCU datapath's own contribution, and the RaBiT
reference kernel keeps both scales in binary16 (`scale_h_0` is a `half`
pointer). The specification chose FP8 to hold the write budget at two slots per
chunk; the measurement says that budget is expensive. Three ways out, none of
them specified:
  1. ship `H_FMT = FP16_3WR` — exact h, three writes per chunk, ~33 % fewer
     column slots for compute. Built and verified here, so the area and
     throughput of this option are both measured.
  2. a block format for h — 16 mantissas plus a shared exponent per chunk, still
     256 bits and still one write. Not specified, not built. A 7-bit shared-
     exponent mantissa would put the format error below the datapath's.
  3. keep h on the NPU, i.e. the base variant, and move only g on-PCU. This is a
     real intermediate design point and the numbers here bound it: g costs the
     g_buffer plus the dequantizer, h costs the multiply array.

**Q2 — FP8 NaN policy.** `0x7F`/`0xFF` currently decode as an ordinary number
(`sig 15, e 15`) and raise `status_fs_o[0]`, matching the base variant's
decision not to special case binary16 `exp == 31`. Should a NaN h instead force
the lane to zero?

**Q3 — h overflow policy.** An `x*h` product beyond binary16 range saturates to
`0x7BFF`. The alternative is to let the exponent field reach 31 and have the
convert unit treat it as an ordinary large number, which loses the status bit
but is one comparator cheaper.

**Q4 — does the g buffer need clearing between stripes?** It currently holds its
contents until the next `WR_G` word 0, so two stripes that share scales would
not need a reload. No such case exists in the current mapping; if one appears,
the `WR_G` count per stripe drops and the throughput number improves.

**Q5 — is the raw debug drain part of the delivered configuration?** It costs
nothing extra in datapath (it is the same register-file read) but it keeps the
base sequencer's drain FSM alive. Removing it would shrink the control logic
slightly and remove a way to compare the two variants at the same k sweep.

**Q6 — who computes `cfg_e0` now?** The base variant's host could read the block
exponent straight off the `u` values it was about to send. The full-scale host
cannot: the PCU forms `u` itself. `choose_e0_fs()` in `tools/pack_rabit_fs.py`
runs the multiply array's model over the chunk, which is cheap and exact, but it
means the packer has to model the hardware. Should `E0` instead be fixed per
layer from a calibration pass?

**Q8 — should `H_MUL_PIPE` be the default?** The specification describes the
unpipelined datapath ("cycle 0: u1 계산·변환하여 input entry에 기록"), so that is
what `H_MUL_PIPE = 0` builds and what the default is. It does not meet tCCD_S at
either clock point. `H_MUL_PIPE = 1` does, at the cost of one 256-bit register
and no column slots; both are built, verified bit-identical and synthesized, so
the switch is a one-parameter decision. Recommendation: ship the pipelined one.

**Q7 — `ALIGN_MAX` tie behaviour.** A path term more than 16 binades below the
other is dropped rather than folded into a sticky bit, so an exact
round-to-nearest tie can round the wrong way. Adding a sticky bit costs one OR
tree per lane. Worth it?
