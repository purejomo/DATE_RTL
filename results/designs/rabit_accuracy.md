| shape | config | mean(E0-e_ent) | PCU rel err (mean) | PCU rel err (worst seed) | quantization rel err | sat |
|---|---|---:|---:|---:|---:|:--:|
| 4096x4096 | MANT_W 12, shifter on | 0.48 | 7.869e-04 | 1.151e-03 | 4.307e-01 | no |
| 4096x4096 | MANT_W 10, shifter on | 0.48 | 3.317e-03 | 4.994e-03 | 4.308e-01 | no |
| 4096x4096 | MANT_W 12, shifter off | 0.00 | 3.178e-04 | 4.533e-04 | 4.307e-01 | no |
| 4096x4096 | MANT_W 10, shifter off | 0.00 | 1.297e-03 | 1.518e-03 | 4.308e-01 | no |
| 4096x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.108e-04 | 2.969e-04 | 4.307e-01 | no |
| 11008x4096 | MANT_W 12, shifter on | 0.48 | 6.609e-04 | 9.982e-04 | 2.983e-01 | no |
| 11008x4096 | MANT_W 10, shifter on | 0.48 | 2.838e-03 | 3.458e-03 | 2.982e-01 | no |
| 11008x4096 | MANT_W 12, shifter off | 0.00 | 2.407e-04 | 3.217e-04 | 2.982e-01 | no |
| 11008x4096 | MANT_W 10, shifter off | 0.00 | 1.085e-03 | 1.402e-03 | 2.982e-01 | no |
| 11008x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.131e-04 | 3.093e-04 | 2.983e-01 | no |

5 seeds x 16 sampled output rows per cell; errors are L2-relative.

- **Read the worst-seed column for the truncating rows.** The arithmetic right
  shift floors, so its error is a one-sided bias that grows with
  mean(E0-e_ent).
- **The `+ RNE` row removes only that bias** (proposal P1 in
  docs/rabit_pcu_spec.md). It is not the delivered default.
- **These rows hold h = 1** (see `_fit_row`), which keeps the block exponents
  close together. Trained per-input-channel h spreads them and pushes E0 up, so
  the truncating rows get worse while the RNE row does not — that is why the RTL
  regression, whose stimulus comes from the packer's fitted h, sees 7.6e-4 to
  3.8e-3 at MANT_W 12.
