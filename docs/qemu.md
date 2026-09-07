# QEMU

`tools/setup-qemu.sh` is the reproducible entry point. It downloads and verifies
the firmware and pinned kernel into an external cache, builds the ARMv7 kernel,
and writes a machine-readable `qemu-env` manifest. `tools/run-qemu-system.sh`
then runs a selected Android ARMv7 binary with the firmware userspace and
libraries.

This is sufficient for real Pryon model construction/PCM processing, real AFE
processing, and direct real-library wake-event testing. For
real AFE processing, use system emulation with an ARMv7 kernel. `libasp.so`
requires the Android init-style D-Bus socket activation and binder device;
`tools/run-qemu-system.sh` supplies both, starts the firmware's own
`servicemanager` and `dbus-daemon`, and runs the real graph against finite PCM
input. No proprietary file is copied into this repository.

```sh
tools/run-qemu-system.sh \
  --root /path/to/extracted/system_root \
  --kernel /path/to/armv7/zImage \
  --binary build-android/afe --mode afe
```

The kernel must provide ARMv7 userspace support, Unix sockets, and legacy
Android binder (`/dev/binder`, major 10 minor 63). This was tested with a
Linux 4.14 ARMv7 kernel against the supplied Biscuit firmware: real
`libasp.so` returned status 0 and emitted the exact expected output for a
multi-period nine-channel fixture. The real `libpryon.so` created the Alexa
model and decoder, accepted finite PCM, and completed decoder/model teardown.
Its JSON-data callback produced a real `kwDetectionType=Accept` result for a
human Alexa recording and no accepted result for silence, deterministic noise,
or a severely corrupted version of that recording. The runner also starts the
firmware LIPC/audio helper processes when they are available; this matches the
service environment needed by the real ASP graph.

For a positive end-to-end check, prepare a nine-channel S24_3LE fixture and
run:

```sh
tools/run-qemu-system.sh \
  --root /path/to/system_root \
  --kernel /path/to/zImage \
  --mode pipeline \
  --afe-binary build-android/afe \
  --pryon-binary build-android/pryon \
  --input /path/to/audio.s24_3le \
  --require-event
```

The runner reports success only after both processes exit successfully and,
when requested, an accepted event is present. A model listing, library load,
or decoder construction alone is not a wake-word validation. The repeatable
positive/negative matrix is provided by
`tools/internal/test-real-pryon.sh`; it requires a user-supplied human PCM
recording and is intentionally local rather than a default CI job.

Low-level inspection helpers live under `tools/internal/`. The public workflow
does not treat a loader probe or `--list` as real decoder validation.

## Collecting callback traces

To compare silence, deterministic noise, and supplied keyword recordings, use
the internal corpus collector. Put raw nine-channel S24_3LE recordings in a
directory outside the repository and run:

```sh
tools/internal/collect-pryon-traces.sh \
  --root /path/to/system_root \
  --kernel /path/to/zImage \
  --afe-binary build-android/afe \
  --pryon-binary build-android/pryon \
  --corpus /path/to/corpus \
  --output /path/to/trace-results
```

The collector adds deterministic silence and noise controls and attenuation
and clipping variants for every corpus recording. Each case gets its own raw
input copy, SHA-256, byte count, timestamps, exit status, and complete QEMU
console log. The logs include `PRYON_DUMP_EVENTS=1` callback bytes, loader and
model messages, lifecycle traces, and process status. Results are indexed in
`index.jsonl`. The generated trace directory is intentionally outside source
control because recordings and firmware logs may contain sensitive material.

QEMU execution is a local integration tool. GitHub Actions uses host mocks and
does not download or execute proprietary firmware by default.

## Live host microphone input

`tools/run-live-mic-qemu.sh` keeps the host microphone on the host and streams
converted audio into a virtio-serial port. The guest still executes the real
ARMv7 `afe` and `pryon` binaries with the extracted firmware libraries; no USB,
ALSA, or other host audio device is passed through to QEMU.

```sh
tools/run-live-mic-qemu.sh
```

With the standard cache layout, the script finds or prepares the firmware and
kernel in `$HOME/.cache/pryon-afe-runtime`, finds or builds the Android
ARMv7 runtimes in `build-android/`, and uses the default Alexa model. Override
individual paths with `--root`, `--kernel`, `--afe-binary`, `--pryon-binary`,
or `--model-dir` when needed. Use `--verbose` to show QEMU boot and capture
diagnostics.

The tool selects the first available host capture command in this order:
PipeWire (`pw-record` or `pw-cat`), PulseAudio (`parec`), JACK
(`jack_capture`), SoX, and ALSA (`arecord`). Select one explicitly with
`--backend`. Capture is mono S16LE at 16 kHz; the host converter duplicates it
into the seven microphone channels and supplies silent speaker references
before sending the nine-channel stream to the guest. Stop it with Ctrl-C.
