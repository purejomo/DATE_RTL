| shape | config | mean(E0-e_ent) | PCU rel err (mean) | PCU rel err (worst seed) | quantization rel err | sat |
|---|---|---:|---:|---:|---:|:--:|
| 4096x4096 | MANT_W 12, shifter on | 0.48 | 7.116e-04 | 1.151e-03 | 4.163e-01 | no |
| 4096x4096 | MANT_W 10, shifter on | 0.48 | 3.104e-03 | 4.994e-03 | 4.165e-01 | no |
| 4096x4096 | MANT_W 12, shifter off | 0.00 | 2.804e-04 | 4.533e-04 | 4.162e-01 | no |
| 4096x4096 | MANT_W 10, shifter off | 0.00 | 1.199e-03 | 1.518e-03 | 4.163e-01 | no |
| 4096x4096 | MANT_W 12, shifter on + RNE | 0.48 | 1.959e-04 | 2.969e-04 | 4.162e-01 | no |
| 11008x4096 | MANT_W 12, shifter on | 0.48 | 6.608e-04 | 9.982e-04 | 3.309e-01 | no |
| 11008x4096 | MANT_W 10, shifter on | 0.48 | 2.862e-03 | 3.458e-03 | 3.310e-01 | no |
| 11008x4096 | MANT_W 12, shifter off | 0.00 | 2.441e-04 | 3.217e-04 | 3.308e-01 | no |
| 11008x4096 | MANT_W 10, shifter off | 0.00 | 1.089e-03 | 1.402e-03 | 3.308e-01 | no |
| 11008x4096 | MANT_W 12, shifter on + RNE | 0.48 | 2.152e-04 | 3.093e-04 | 3.308e-01 | no |

8 seeds x 16 sampled output rows per cell; errors are L2-relative.

The worst-seed column is the one to read for the truncating rows: the arithmetic right shift floors, so its error is a one-sided bias that grows with mean(E0-e_ent). The `+ RNE` row shows what removing that bias would buy (proposal P1 in docs/rabit_pcu_spec.md); it is not the delivered default.

These rows hold h = 1 (see _fit_row), which keeps the block exponents close together. Trained per-input-channel h spreads them further and pushes E0 up, so the truncating rows get worse while the RNE row does not: the RTL regression, whose stimulus comes from the packer's fitted h, sees 7.6e-4 to 3.8e-3 at MANT_W 12 for exactly this reason.
