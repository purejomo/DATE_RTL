# RaBiT PCU: full-scale variant against the base variant

What this measures: the area and throughput cost of moving the RaBiT
input scale h and output scale g from the NPU into the PCU.

Conditions are the repository's: Nangate45 typical (1.10 V, 25 C),
Yosys 0.52 ABC area mode + OpenROAD, logic synthesis only, no place and
route, so the numbers are cell area and carry no routing. The primary
clock point is 250 MHz, matching the HBM-PIM baseline row; the PCU
spends two cycles per column command, so 4.0 ns of PCU period is 8.0 ns
of tCCD_S. The input GRF and the CRF are outside the boundary in both
RaBiT variants; the accumulator array is inside both.

## 1. Total area

| design | area (um2) | vs base PCU | vs baseline FP16 16-lane |
|---|---:|---:|---:|
| base PCU (`rabit_pcu`, 250 MHz) | 45,254 | 1.000x | 0.752x |
| PCU-FS (`rabit_pcu_fs`, 250 MHz) | 93,522 | 2.067x | 1.554x |
| PCU-FS, `H_MUL_PIPE = 1` (closes timing) | 94,841 | 2.096x | 1.576x |
| PCU-FS, H_FMT = FP16_3WR | 106,277 | 2.348x | 1.766x |
| baseline FP16 16-lane (`hbmpim_fp16_pcu_16_lane`, 250 MHz) | 60,176 | 1.330x | 1.000x |

Delta for on-PCU scaling: **48,269 um2**, 106.7 % of the base PCU, 80.2 % of the baseline compute unit.

The timing-closing build costs 1,319 um2 more than the specified one -- one 256-bit register between the multiply array and the convert unit -- and no column slots at all. Read the `H_MUL_PIPE` row as the deliverable and the plain one as the literal reading of the specification; see section 3.

## 2. Module breakdown

Each block is synthesized on its own with registers at both ends, so an
isolated combinational block still reports a meaningful path. The sums
do not have to equal the flat tops above: the flow flattens everything,
so a top gets cross-boundary optimization the isolated blocks do not.

| module | in | instances | area each (um2) | area total (um2) | what it is |
|---|---|---:|---:|---:|---|
| `cvt_fp16_to_blk` | both | 1 | 5,002 | 5,002 | convert-on-write, fp16 x16 -> block |
| `rabit_pe` | both | 8 | 3,693 | 29,547 | negate + 4:2 tree + CPA + align + acc add |
| `acc_regfile` | both | 1 | 20,872 | 20,872 | 64 x 32b architectural accumulators |
| `h_scale_unit` | FS only | 1 | 20,651 | 20,651 | h latch + 16 x (fp16 x fp8) + fp16 pack |
| `g_buffer` | FS only | 1 | 12,484 | 12,484 | 64 x 16b output scales, 4-word fill |
| `g_dequant_unit` | FS only | 1 | 28,083 | 28,083 | 4 lanes: normalize, 12x11 mul, align-add, fp16 round |

Blocks the full-scale variant adds, summed in isolation: **61,219 um2**.
The flat-top delta is 48,269 um2; the difference is cross-boundary optimization plus the rewiring in the top (write-path sequencing, accumulator-port arbitration).

## 3. Timing

Worst setup path per row. A met slack at 2.0 ns says the design closes
at 500 MHz of PCU clock, which is 250 MHz of column-command rate.

**This is the one place the specified datapath does not hold up.** With
the h multiply, the binary16 rounding and the block convert all in one
cycle, the write path is a single combinational chain from `wr_data_i`
to `cvt_blk_o`, and it misses even the 250 MHz point. Splitting it with
`H_MUL_PIPE = 1` costs no column slots -- cycle 0 multiplies u_1, cycle 1
converts it while multiplying u_2, and the conversion of u_2 lands in the
next slot's pump 0, one cycle before pump 1 reads it. The deadline
assertion in `rabit_pcu_fs_top` checks exactly that, and the bit-exact
regression passes unchanged in both modes.

Note what the base row says before reading the 500 MHz rows: the base
variant misses 2.0 ns too, on its own convert path, so 500 MHz is not a
point either RaBiT variant closes and the comparison that matters is at
250 MHz. There, `H_MUL_PIPE = 1` has *more* slack than the base variant
(1.22 ns against 1.16 ns), because the register also shortens the base
path it inherited: the convert unit now starts from a flop instead of
from the write port with its input delay. What is left as the worst path
is the sticky h-overflow reduction across the 16 lanes, which is a status
bit and could be registered a cycle later if a faster point were needed.

| row | clock | period (ns) | slack (ns) | met | critical endpoint |
|---|---|---:|---:|:---:|---|
| `rabit_pcu_250` | 250 MHz | 4.0 | 1.160 | yes | `cvt_blk_o[125]` |
| `rabit_pcu_500` | 500 MHz | 2.0 | -0.040 | **NO** | `cvt_blk_o[125]` |
| `rabit_pcu_fs_250` | 250 MHz | 4.0 | -0.290 | **NO** | `cvt_blk_o[44]` |
| `rabit_pcu_fs_500` | 500 MHz | 2.0 | -1.490 | **NO** | `cvt_blk_o[44]` |
| `rabit_pcu_fs_p_250` | 250 MHz | 4.0 | 1.220 | yes | `u_pcu.fs_sticky_q[1]$_SDFF_PP0_` |
| `rabit_pcu_fs_p_500` | 500 MHz | 2.0 | -0.380 | **NO** | `u_pcu.fs_sticky_q[1]$_SDFF_PP0_` |
| `rabit_fs_blk_hscale_250` | 250 MHz | 4.0 | 2.490 | yes | `h_ovf_o$_SDFF_PN0_` |
| `rabit_fs_blk_hscale_500` | 500 MHz | 2.0 | 0.490 | yes | `h_ovf_o$_SDFF_PN0_` |
| `rabit_fs_blk_dq_250` | 250 MHz | 4.0 | 1.370 | yes | `u_dq.s0_q_q[86]$_SDFFE_PN0P_` |
| `rabit_fs_blk_dq_500` | 500 MHz | 2.0 | -0.230 | **NO** | `u_dq.s0_q_q[86]$_SDFFE_PN0P_` |

## 4. Throughput

Slot-level count from `tools/pack_rabit_fs.py`, which walks both command
streams. A column slot is one column command and two PCU cycles. The
inner loop is identical in both variants -- two writes and four reads per
16-input chunk -- so the whole difference is the per-stripe overhead:
four g-load writes, and a drain that holds the accumulator port for 16
cycles instead of the base's four 2-cycle drain commands.

| dout x din | base slots | FS slots | g load | drain | FS/base | cost |
|---|---:|---:|---:|---:|---:|---:|
| 4096 x 4096 | 197,120 | 198,272 | 0.258 % | 0.581 % | 99.419 % | 0.581 % |
| 4096 x 11008 | 528,896 | 530,048 | 0.097 % | 0.217 % | 99.783 % | 0.217 % |
| 1024 x 4096 | 49,280 | 49,568 | 0.258 % | 0.581 % | 99.419 % | 0.581 % |
| 128 x 512 | 784 | 820 | 1.951 % | 4.390 % | 95.610 % | 4.390 % |

The 128 x 512 row is there to show where the overhead stops being
negligible: it is a per-stripe cost amortized over the k sweep, so it
scales as 1/din. At the projection-layer shapes RaBiT targets it is
below the 1 % the specification allows.

