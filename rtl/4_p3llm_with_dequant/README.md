# P3-LLM PCU-local dequantization experiment

This directory keeps the original 16-PE raw P3-LLM PCU and adds one shared
post-processing engine. The raw PCU still accepts 64 low-precision products per
cycle. At each quantization-group boundary, its sixteen signed INT32
accumulators are snapshotted and serialized through the shared floating-point
datapath.

## Numeric contract

For PE `p` and group `g`, the hardware computes

```text
product32[p] = RNE32(raw_int32[p] * vector_scale16[p] * 2^mode_offset)
fp_acc32[p]  = RNE32(fp_acc32[p] + product32[p])
result16[p]  = RNE16(fp_acc32[p] * final_scale16)
```

The exact mode offsets inherited from the raw decoder binary points are:

| Mode | Offset | Intended scale split |
| --- | ---: | --- |
| `OP_LINEAR` | -12 | per-group/per-output weight scale, then token activation scale |
| `OP_QK` | -11 | key scale, then common query scale |
| `OP_PV` | -19 | fused probability/value scale, with `final_scale16=1` when no second factor is needed |

The first multiplier uses the full signed INT32 magnitude and the full FP16
significand before one FP32 RNE operation. It does not first round INT32 to
FP16/FP32. The accumulator state is FP32; only the final output is rounded to
FP16. Positive finite FP16 scales, including zero and subnormals, are supported.
Negative, infinity, and NaN scales produce canonical NaN and set the sticky
invalid status.

## Control contract

- `acc_clear_i` starts each raw integer quantization group.
- `group_last_i` marks the final accepted raw tile of that group. On that same
  transfer, `vector_scale_by_pe_i`, `fp_acc_clear_i`, `dot_last_i`, and
  `final_scale_i` are sampled.
- `fp_acc_clear_i` starts a new cross-group FP32 accumulation chain.
- `dot_last_i` requests the final common scale and FP16 vector output.
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
- `p3llm_dequant_fp32_fp16_mul_pack_pipe.sv`: common scale and final FP16 RNE.

The current experiment has one FP accumulator context. Batch/context
interleaving therefore requires banking or context tagging in a future variant.
The original raw INT32 saturation behavior is unchanged and is not exported as
a separate status bit; group sizes beyond the paper baseline must be range
checked separately.
