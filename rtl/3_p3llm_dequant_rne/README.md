# P3-LLM PCU-local dequantization — the P3-LLM dequant_rne design point

This directory is P3-LLM's column ③ (`dequant_rne`) of the three-axis
comparison:

| 축 | 디렉토리 | 출력 |
|---|---|---|
| ① base | [`3_p3llm`](../3_p3llm) | raw INT32 (`acc_out`) |
| ② acc16 | [`3_p3llm_acc16`](../3_p3llm_acc16) | raw INT16 |
| ③ dequant_rne | **이 디렉토리** | FP8-E4M3 activation (`fp8_out_o`) |

It keeps the original 16-PE raw P3-LLM PCU and adds one shared
post-processing engine. The raw PCU still accepts 64 low-precision products per
cycle. At each quantization-group boundary, its sixteen signed INT32
accumulators are snapshotted and serialized through the shared floating-point
datapath.

## Numeric contract

For PE `p` and group `g`, the hardware computes

```text
product32[p] = RNE32(raw_int32[p] * vector_scale16[p] * 2^mode_offset)
fp_acc32[p]  = RNE32(fp_acc32[p] + product32[p])
result8[p]   = RNE_E4M3(fp_acc32[p] * final_scale16)
```

The final output is **OCP FP8-E4M3FN**, not binary16.  P3-LLM's activations are
FP8: [`p3llm_pe.sv`](p3llm_pe.sv) decodes the LHS as E4M3 in `OP_LINEAR` and
`OP_QK` and as S0E4M4 in `OP_PV`.  Ending in binary16 would leave the
requantization to the host, which is the data movement this design exists to
remove, so the PCU emits the format the next layer reads.

| mode | activation (LHS, 8b) | RHS (4b) | output |
| --- | --- | --- | --- |
| `OP_LINEAR` | FP8 E4M3 (signed) | BitMoD FP4 | E4M3 |
| `OP_QK` | FP8 E4M3 (query) | INT4 asym (key) | E4M3 |
| `OP_PV` | FP8 S0E4M4 (unsigned, softmax) | INT4 asym (value) | E4M3 |

All three modes emit E4M3.  S0E4M4 is the format softmax *produces*, so it only
ever appears as a PCU input: an `OP_QK` result is the signed score that goes to
softmax, and an `OP_PV` result is the activation of the output projection.
Neither is an unsigned probability.

The packer is the exact inverse of [`fp8_e4m3_decoder.sv`](fp8_e4m3_decoder.sv);
`verif`'s `p3llm_dequant_arith` regression checks the round trip over all 254
finite codes.  E4M3FN has no infinity, so an overflow **saturates to the largest
finite code** (0x7e / 0xfe, magnitude 448) and raises the sticky overflow
status — the same range policy `rabit_fs_fp16_pack.sv` uses, and for the same
reason: emitting 0x7f would make the decoder read a NaN where the arithmetic
produced a large finite number.

The FP32 accumulator state stays 32 bits.  The only narrowing is the one final
pack.

The exact mode offsets inherited from the raw decoder binary points are:

| Mode | Offset | Intended scale split |
| --- | ---: | --- |
| `OP_LINEAR` | -12 | per-group/per-output weight scale, then token activation scale |
| `OP_QK` | -11 | key scale, then common query scale |
| `OP_PV` | -19 | fused probability/value scale, with `final_scale16=1` when no second factor is needed |

The first multiplier uses the full signed INT32 magnitude and the full FP16
significand before one FP32 RNE operation. It does not first round INT32 to
FP16/FP32. The accumulator state is FP32; only the final output is rounded, to
E4M3. Positive finite FP16 scales, including zero and subnormals, are supported.
Negative, infinity, and NaN scales produce canonical NaN and set the sticky
invalid status.

## Control contract

- `acc_clear_i` starts each raw integer quantization group.
- `group_last_i` marks the final accepted raw tile of that group. On that same
  transfer, `vector_scale_by_pe_i`, `fp_acc_clear_i`, `dot_last_i`, and
  `final_scale_i` are sampled.
- `fp_acc_clear_i` starts a new cross-group FP32 accumulation chain.
- `dot_last_i` requests the final common scale and FP8 vector output on
  `fp8_out_o` (16 lanes x 8 bits = 128 bits).
- `result_valid_o/result_ready_i` is a retaining ready/valid interface. Raw
  input backpressure is exposed through `in_ready_o`.

Two 16xINT32 snapshot slots decouple the non-stallable raw pipeline from the
shared dequantizer. The arithmetic engine issues one PE per cycle (II=1), so a
16-lane group is post-processed in sixteen issue cycles. For the paper's
group-size 128 and four raw lanes per PE, a group arrives every 32 accepted raw
cycles, leaving enough throughput margin for one shared engine.

## Files

- `p3llm_pcu_dequant.sv`: wrapper, snapshot queues, FP32 state bank, status,
  and output handshake.
- `p3llm_dequant_fixed32_fp16_mul_pipe.sv`: exact INT32 x FP16 scale to FP32.
- `p3llm_dequant_fp32_add_pipe.sv`: FP32 RNE accumulator adder.
- `p3llm_dequant_fp32_fp8_mul_pack_pipe.sv`: common scale and final E4M3 RNE.
  The file name keeps `mul` because the stage really does apply the common
  scale before packing; only the format in the name changed.

The current experiment has one FP accumulator context. Batch/context
interleaving therefore requires banking or context tagging in a future variant.
The original raw INT32 saturation behavior is unchanged and is not exported as
a separate status bit; group sizes beyond the paper baseline must be range
checked separately.
