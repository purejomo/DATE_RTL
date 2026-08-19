# RaBiT full-scale PCU: what the FP8 h format costs

Four quantities, all measured against an exact rational reference, so no host
floating point enters the comparison:

| name | what it isolates |
|---|---|
| `h_format_only` | quantizing h to FP8-E4M3, everything else exact |
| `fs_vs_fp8_ref` | the PCU-FS datapath, given the FP8 h it was handed |
| `fs_vs_fp16_ref` | the two together: PCU-FS against binary16 h |
| `base_vs_fp16_ref` | the base variant, whose h stays binary16 on the NPU |

- `fs_vs_fp8_ref` is the honest measure of the hardware; the other rows are the
  cost of the format decision the write budget forced.
- **Read the L2 column.** A per-output relative error is dominated by outputs
  that land near zero through cancellation, which is why the max column is
  large and uninformative.

| shape | seed | quantity | max rel err | mean rel err | L2 rel err |
|---|---:|---|---:|---:|---:|
| 64 x 512 | 0 | `h_format_only` | 1.215e+00 | 1.075e-01 | 3.176e-02 |
| 64 x 512 | 0 | `fs_vs_fp8_ref` | 1.048e-01 | 2.427e-03 | 3.976e-04 |
| 64 x 512 | 0 | `fs_vs_fp16_ref` | 1.237e+00 | 1.079e-01 | 3.187e-02 |
| 64 x 512 | 0 | `base_vs_fp16_ref` | 3.259e-02 | 1.277e-03 | 3.516e-04 |
| 64 x 512 | 1 | `h_format_only` | 1.739e+00 | 9.241e-02 | 2.919e-02 |
| 64 x 512 | 1 | `fs_vs_fp8_ref` | 1.605e-02 | 9.801e-04 | 4.260e-04 |
| 64 x 512 | 1 | `fs_vs_fp16_ref` | 1.733e+00 | 9.237e-02 | 2.919e-02 |
| 64 x 512 | 1 | `base_vs_fp16_ref` | 2.332e-02 | 1.326e-03 | 4.048e-04 |
| 64 x 512 | 2 | `h_format_only` | 3.309e+00 | 1.151e-01 | 2.623e-02 |
| 64 x 512 | 2 | `fs_vs_fp8_ref` | 1.560e-01 | 7.294e-03 | 1.398e-03 |
| 64 x 512 | 2 | `fs_vs_fp16_ref` | 3.981e+00 | 1.256e-01 | 2.627e-02 |
| 64 x 512 | 2 | `base_vs_fp16_ref` | 4.870e-01 | 1.183e-02 | 1.343e-03 |

Reproduce with:

```bash
python3 tools/pack_rabit_fs.py --accuracy --dout 64 --din 512 --seeds 3
```
