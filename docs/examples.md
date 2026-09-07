# Examples

The examples show the public process interface, not the proprietary ABI. Each
one expects the same input as `afe`: interleaved nine-channel S24_3LE at 16 kHz
on standard input. `afe` writes mono S16LE, which is connected directly to
`pryon`.

The examples intentionally do not capture from a microphone, decode WAV files,
resample, or invoke a media utility. Those choices keep the data format visible
and make the examples useful on an Echo, in QEMU, or in a test harness.

## Bash

```sh
cat audio.s24_3le | ./build/afe | ./build/pryon
```

See [examples/bash/pryon_afe.sh](../examples/bash/pryon_afe.sh) for the small
script version.

## Python

```sh
cat audio.s24_3le | python3 examples/python/pryon_afe.py
```

See [examples/python/pryon_afe.py](../examples/python/pryon_afe.py).

## Go

```sh
cat audio.s24_3le | go run ./examples/go
```

See [examples/go/main.go](../examples/go/main.go). Audio capture remains the
caller's responsibility, so EchoLocal and other applications can connect their
existing ALSA stream without another audio abstraction in this repository.

## C

```sh
cc examples/c/pipeline.c -o pipeline
cat audio.s24_3le | ./pipeline
```

See [examples/c/pipeline.c](../examples/c/pipeline.c) for the equivalent
`fork`, `pipe`, and `dup2` topology.

## Environment overrides

The examples use `./build/afe` and `./build/pryon` by default. Set `AFE` and
`PRYON` to choose other executables. The runtimes select the standard Alexa
model by default; set `PRYON_MODEL_DIR` for a specific model directory.
