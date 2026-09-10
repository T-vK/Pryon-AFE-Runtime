# Dependencies

The runtime binaries do not need host audio libraries. They use only the
standard C library, `dlopen`, and the proprietary Echo libraries at runtime.
The tools and tests have additional requirements.

## Linux build and tests

On Debian or Ubuntu:

```sh
sudo apt install \
  build-essential cmake ninja-build python3 golang-go ffmpeg shellcheck
```

## Android ARMv7 build

Install Android NDK `26.3.11579264`, then set:

```sh
export ANDROID_NDK_HOME=/path/to/android-sdk/ndk/26.3.11579264
make build-android
```

The Android build does not need the proprietary libraries or models because
they are loaded later on the Echo or in the emulator.

## Firmware and emulator tools

The reproducible emulator setup additionally requires QEMU system emulation:

```sh
sudo apt install qemu-system-arm gcc-arm-linux-gnueabihf make cpio curl unzip e2fsprogs
```

Go is also required when `payload-dumper-go` is not already installed. The
firmware extractor uses `debugfs` from `e2fsprogs`, or `7z` as an alternative.

On macOS, the closest Homebrew equivalents are:

```sh
brew install cmake ninja python go ffmpeg shellcheck qemu cpio curl unzip e2fsprogs
```

Android NDK is installed separately through Android Studio or `sdkmanager`.
The Linux ARM kernel compiler and some emulator guest-building steps are Linux
or container oriented; macOS users may use a Linux VM/container for those
steps.

## Live host microphone capture

`tools/run-live-mic-emulator.sh` needs `ffmpeg`, Python 3, QEMU, the ARM compiler,
and `cpio`. It automatically selects the first available capture command:

| Backend | Command | Debian/Ubuntu package | Homebrew package |
| --- | --- | --- | --- |
| PipeWire | `pw-record` or `pw-cat` | `pipewire-audio` | `pipewire` |
| PulseAudio | `parec` | `pulseaudio-utils` | `pulseaudio` |
| JACK | `jack_capture` | `jack-capture` | install the JACK capture utility separately |
| SoX | `sox` | `sox` | `sox` |
| ALSA | `arecord` | `alsa-utils` | not available natively on macOS |

No backend is installed automatically. The live tool keeps the microphone on
the host and sends audio to the emulator through a virtio-serial socket.

`tools/download-testdata.sh` downloads pinned `alexa.wav` and `nowake.wav`
fixtures from the [MicroWakeWord test corpus](https://github.com/zserge/microwakeword/tree/bfaf3840114e/testdata)
into `.external/audio/`. Their SHA-256 hashes are checked before they are used.

## Missing dependency errors

The public scripts check their direct dependencies before doing work and print
the relevant Linux package and Homebrew package where there is a direct
equivalent. Dependency failures are never silently treated as successful
runtime tests.
