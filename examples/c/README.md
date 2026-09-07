# C examples

`pipeline.c` is the minimal example. It demonstrates the two pipes needed to
connect an audio source to `afe` and `afe` to `pryon`. Input is nine-channel
S24_3LE at 16 kHz.

The direct-library experiments are intentionally separate under
`research/abi-examples/` and are not built or released.
