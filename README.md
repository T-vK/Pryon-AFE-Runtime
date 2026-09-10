# Pryon AFE Runtime

Two small process adapters for running Amazon Echo wake-word detection locally.

## What are Pryon and AFE?

Pryon is the offline hotword and wake-word engine included in compatible Echo
firmware. It is similar in purpose to [OpenWakeWord](https://github.com/dscripka/openWakeWord)
and [MicroWakeWord](https://github.com/FutureProofHomes/microWakeWord), but uses
the models already shipped with the Echo. The `pryon` runtime accepts mono
audio and reports detected wake words without sending audio to the cloud.

AFE is the Echo's audio front end. It uses the seven-microphone array together
with two speaker-reference channels for beamforming, active noise cancellation,
and acoustic echo cancellation. The `afe` runtime turns that nine-channel input
into the clean mono stream expected by Pryon.

## Using the runtimes

```bash
$ cat ./alexa.wav | tools/convert-to-9ch.sh | afe | pryon --wakeword alexa
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

```bash
$ cat ./alexa.wav | tools/convert-to-1ch.sh | pryon --wakeword alexa
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

```bash
$ afe --alsa | pryon --wakeword alexa
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

`afe` reads the native Echo audio format: interleaved 9-channel S24_3LE at
16 kHz, with microphone channels 0-6 from the seven-microphone array and
speaker loopback channels 7-8. It writes mono S16LE audio. `pryon` reads that
mono stream and writes one JSON event per detected wake word.

```bash
$ afe --help
usage: afe [--alsa [--card N] [--device N]] [--cfg PATH] [--lib PATH] [--mock]
  --alsa  capture from ALSA instead of stdin (default card 0, device 24)
  --card N                      ALSA card (default: 0)
  --device N                    ALSA device (default: 24)
  --cfg PATH                    AFE.cfg path (default: /system/vendor/etc/audio-algorithms/AFE.cfg)
  --lib PATH                    libasp.so or libasp-mock.so
  --mock                        explicitly use libasp-mock.so
  stdin:  9-channel S24_3LE, 16 kHz
  stdout: mono S16LE, 16 kHz, 320-sample periods
```

```bash
$ pryon --help
usage: pryon [options]
  --list                         list available models
  --wakeword NAME                model name (default: ALEXA)
  --model-base-path PATH         model base (default: /system/local/models/keyword)
  --model-language LOCALE        model language (default: en-US)
  --model-dir PATH               select one exact model directory
  --format json|text             output format (default: json)
  --lib PATH                     libpryon.so or libpryon-mock.so
  --include-near-misses          include diagnostic NearMiss events
  --mock                         select libpryon-mock.so
  --models-dir/--root PATH       compatibility aliases for --model-base-path
  --locale/--keyword NAME        compatibility aliases
  stdin:                         mono signed 16-bit little-endian PCM, 16 kHz
  stdout:                        JSON Lines wake events (or text ids)
  stderr:                        diagnostics and errors
```

For audio files, `convert-to-9ch.sh` puts the source in all seven mic
channels and leaves both speaker references silent. `convert-to-1ch.sh` skips
AFE and creates the mono format directly. Both helpers accept any format
supported by FFmpeg on stdin.

![Runtime architecture](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/architecture-runtime.png)

## Use on an Echo

Download the [afe runtime (ARMv7, for Echo)](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/afe)
and [pryon runtime (ARMv7, for Echo)](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/pryon).

Copy both files onto the Echo:

```sh
adb push afe pryon /data/local/tmp/
adb shell chmod 755 /data/local/tmp/afe /data/local/tmp/pryon
```

On the tested Echo hardware, the microphone array is ALSA card 0, device 24
(`hw:0,24`). That device provides one interleaved stream: channels 0-6 are the
seven microphones and channels 7-8 are the two speaker references. Requesting
nine channels from an arbitrary ALSA device does not produce this layout.

`afe` can open this Echo ALSA device directly. Stop the stock audio owner, then
run the complete pipeline:

```sh
adb shell 'stop ledcontroller >/dev/null 2>&1; killall afe pryon >/dev/null 2>&1 || true; /data/local/tmp/afe --alsa | /data/local/tmp/pryon'
```

After stopping the pipeline, restore the stock audio service with
`adb shell start ledcontroller`.

The defaults are card 0 and device 24. A different compatible endpoint can be
selected with `afe --alsa --card N --device N`. Applications may also open
`/dev/snd/pcmC0D24c` through ALSA directly and write each captured period to
`afe` stdin.

Pryon writes one JSON object for each accepted detection:

```json
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

The event includes the detection type, keyword name, classification score, and
sample range reported by the firmware. Certainty and timestamps are not part of
the public event because they have not been validated.

The release also contains [afe (x86_64, for testing)](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/afe-testing),
[pryon (x86_64, for testing)](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/pryon-testing),
and explicitly named mock libraries for development on a regular Linux system.

## Run real AFE and Pryon without an Echo

For debugging, `tools/run-live-mic-emulator.sh` captures audio from the host's
default microphone and runs the real ARMv7 `afe` and `pryon` binaries with the
extracted Echo libraries inside an Echo emulator. The microphone stays on the
host; audio is sent to the guest through a private virtio-serial connection.
PipeWire is selected automatically when available, with PulseAudio, JACK, SoX,
and ALSA fallbacks.

```sh
$ ./tools/run-live-mic-emulator.sh
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.956937,"kwSampleStartIndex":10230720,"kwSampleEndIndex":10245760}
```

The script automatically finds or prepares the standard firmware and kernel
cache and builds the Android binaries when needed. It runs until interrupted
and waits for both real runtimes to finish initializing before opening the
microphone, so audio cannot build up during emulator startup. Add `--verbose`
when debugging the emulated guest or proprietary-library setup. Emulation may
process the real AFE/Pryon workload slower than real time, which can cause
delayed or increasing recognition latency. Use `--quiet` when the process must
emit only Pryon JSON events.

## Why this project exists

This project simplifies access to AFE and Pryon and makes the Echo's optimized
local processing available to other applications. It bridges the 32-bit
ARMv7/Bionic proprietary libraries to 64-bit processes, makes comparisons with
[OpenWakeWord](https://github.com/dscripka/openWakeWord) and
[MicroWakeWord](https://github.com/FutureProofHomes/microWakeWord) easier, and
helps [EchoLocal](https://github.com/ygelfand/echolocal),
[EchoMuse](https://github.com/wilbowes/EchoMuse),
[LibreEcho](https://github.com/aslater3/LibreEcho), and similar projects use
AFE and/or Pryon. Documentation, reverse-engineering
findings, helper programs, and examples are included for that purpose.

The stock Echo models and audio processing were tuned for its microphone array,
speakers, and acoustic environment, which can provide a smoother experience
than manually tuning another wake-word engine for a particular room or voice.

The stock architecture is shown below:

![Stock firmware architecture](https://github.com/T-vK/Pryon-AFE-Runtime/releases/latest/download/architecture-stock.png)

## Examples

- [Bash](examples/bash/README.md)
- [Python](examples/python/README.md)
- [Go](examples/go/README.md)
- [C](examples/c/README.md)

All examples use the same process interface and keep the audio stream outside
the application-specific code.

## Build from source

```sh
make build
make check
```

Set `ANDROID_NDK_HOME` and run `make build-android` to build the Echo-compatible
ARMv7 binaries. See [development.md](docs/development.md) for the complete build
and release workflow.

See [Dependencies](docs/dependencies.md) for the required build, firmware,
emulator, converter, and live microphone tools on Linux and macOS.

## Test

Run the host tests:

```sh
make test
```

Run the real-library file tests on an ADB-connected Echo, or use the emulator:

```sh
tools/test-real.sh
tools/test-real.sh --mic --beep
tools/test-real.sh --emulator
tools/test-real.sh --emulator --mic --beep
```

The microphone variants are interactive and give each positive and negative
check at most 10 seconds. `--beep` sounds only before the positive microphone
check. On an Echo, the test temporarily stops the service that owns the capture
device and restores it afterward. Emulator tests boot one guest and restart
only the runtimes between checks. Test audio, firmware, and kernel files are
kept under `.external/`.

## Documentation

- [AFE input, output, and library loading](docs/afe.md)
- [Pryon models, events, and library loading](docs/pryon.md)
- [Stream protocol](docs/protocol.md)
- [Firmware and ABI findings](docs/firmware-abi.md)
- [Firmware extraction](docs/firmware.md)
- [Echo emulator testing](docs/emulator.md)
- [Language examples](docs/examples.md)
- [Mock libraries](docs/mocks.md)
- [Dependencies](docs/dependencies.md)
