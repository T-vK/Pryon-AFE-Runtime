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
$ arecord -D hw:0,24 -t raw -f S24_3LE -c 9 -r 16000 | afe | pryon --wakeword alexa
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

`afe` reads the native Echo audio format: interleaved 9-channel S24_3LE at
16 kHz, with microphone channels 0-6 from the seven-microphone array and
speaker loopback channels 7-8. It writes mono S16LE audio. `pryon` reads that
mono stream and writes one JSON event per detected wake word.

```python-repl
$ afe --help
usage: afe [--cfg PATH] [--lib PATH] [--mock]
  stdin:  9-channel S24_3LE, 16 kHz
  stdout: mono S16LE, 16 kHz, 320-sample periods
```

```python-repl
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

If `arecord` is installed on the Echo, capture that raw stream, pipe it through
`afe`, and pipe the resulting mono audio into `pryon`:

```sh
adb shell 'arecord -q -D hw:0,24 -t raw -f S24_3LE -c 9 -r 16000 | /data/local/tmp/afe | /data/local/tmp/pryon'
```

The stock firmware includes `tinycap` rather than `arecord`. `tinycap` writes a
WAV file, so capture and then remove its 44-byte WAV header before piping the
PCM through the runtimes:

```sh
adb shell 'tinycap /data/local/tmp/capture.wav -D 0 -d 24 -c 9 -r 16000 -b 24 -t 5'
```

```sh
adb shell 'dd if=/data/local/tmp/capture.wav bs=1 skip=44 2>/dev/null | /data/local/tmp/afe | /data/local/tmp/pryon'
```

The `-D 0 -d 24` selection is important on the tested Echo: it is the ALSA
endpoint that exposes the seven microphones followed by the two speaker
references. A nine-channel request on another ALSA device does not guarantee
that layout. Applications can also open `/dev/snd/pcmC0D24c` through ALSA
directly and write each captured period to `afe` stdin.

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

For debugging, `tools/run-live-mic-qemu.sh` captures audio from the host's
default microphone and runs the real ARMv7 `afe` and `pryon` binaries with the
extracted Echo libraries inside QEMU. The microphone stays on the host; audio
is sent to the guest through a private virtio-serial connection. PipeWire is
selected automatically when available, with PulseAudio, JACK, SoX, and ALSA
fallbacks.

```sh
$ ./tools/run-live-mic-qemu.sh
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.956937,"kwSampleStartIndex":10230720,"kwSampleEndIndex":10245760}
{"type":"accepted","id":"pryon_alexa","..."}
```

The script automatically finds or prepares the standard firmware and kernel
cache and builds the Android binaries when needed. It runs until interrupted
and normally prints only detected wake-word JSON events. Add `--verbose` when
debugging the QEMU guest or proprietary-library setup.

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
QEMU, converter, and live microphone tools on Linux and macOS.

## Documentation

- [AFE input, output, and library loading](docs/afe.md)
- [Pryon models, events, and library loading](docs/pryon.md)
- [Stream protocol](docs/protocol.md)
- [Firmware and ABI findings](docs/firmware-abi.md)
- [Firmware extraction](docs/firmware.md)
- [QEMU integration testing](docs/qemu.md)
- [Language examples](docs/examples.md)
- [Mock libraries](docs/mocks.md)
- [Dependencies](docs/dependencies.md)
