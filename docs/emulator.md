# Echo emulator

`tools/setup-emulator.sh` is the reproducible entry point. It downloads and
verifies the firmware and pinned kernel into an external cache, builds the
ARMv7 kernel, and writes machine-readable `emulator-env` and
`emulator-manifest.json` files. `tools/run-emulator.sh` then runs a selected
Android ARMv7 binary with the firmware userspace and libraries.

This is sufficient for real Pryon model construction/PCM processing, real AFE
processing, and direct real-library wake-event testing. For
real AFE processing, use system emulation with an ARMv7 kernel. `libasp.so`
requires the Android init-style D-Bus socket activation and binder device;
`tools/run-emulator.sh` supplies both, starts the firmware's own
`servicemanager` and `dbus-daemon`, and runs the real graph against finite PCM
input. No proprietary file is copied into this repository.

```sh
tools/run-emulator.sh \
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
tools/run-emulator.sh \
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
input copy, SHA-256, byte count, timestamps, exit status, and complete emulator
console log. The logs include `PRYON_DUMP_EVENTS=1` callback bytes, loader and
model messages, lifecycle traces, and process status. Results are indexed in
`index.jsonl`. The generated trace directory is intentionally outside source
control because recordings and firmware logs may contain sensitive material.

The emulator is a local integration tool. GitHub Actions uses host mocks and
does not download or execute proprietary firmware by default.

## Live host microphone input

`tools/run-live-mic-emulator.sh` keeps the host microphone on the host and
streams converted audio into a virtio-serial port. The guest still executes
the real ARMv7 `afe` and `pryon` binaries with the extracted firmware
libraries; no USB, ALSA, or other host audio device is passed through to the
emulator.

```sh
tools/run-live-mic-emulator.sh
```

With the standard cache layout, the script finds or prepares the firmware and
kernel in `.external/emulator/`, finds or builds the Android
ARMv7 runtimes in `build-android/`, and uses the default Alexa model. Override
individual paths with `--root`, `--kernel`, `--afe-binary`, `--pryon-binary`,
or `--model-dir` when needed. The live runner waits for AFE and Pryon to signal
that their real libraries and model are initialized before it starts the host
capture stream. Use `--verbose` to show emulator boot and capture diagnostics, or
`--quiet` to emit only JSON wake events.

When used by `tools/test-real.sh --emulator --mic`, the emulator is booted
once. A private control channel restarts only `afe` and `pryon` between every
test, avoiding another slow boot and preventing decoder state from carrying
between checks.

The interactive run checks, in order, positive microphone audio, negative
microphone audio, the positive file, and the negative file. Every check lasts
at most 10 seconds. Positive checks finish as soon as a wake event arrives;
negative checks fail immediately if one arrives. `--beep` sounds only before
the positive microphone prompt. File paths and emulator diagnostics are shown
only with `--verbose`.

The tool selects the first available host capture command in this order:
PipeWire (`pw-record` or `pw-cat`), PulseAudio (`parec`), JACK
(`jack_capture`), SoX, and ALSA (`arecord`). Select one explicitly with
`--backend`. Capture is mono S16LE at 16 kHz; the host converter duplicates it
into the seven microphone channels and supplies silent speaker references
before sending the nine-channel stream to the guest. Stop it with Ctrl-C.
