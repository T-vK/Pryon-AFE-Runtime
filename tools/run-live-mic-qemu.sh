#!/bin/sh
set -eu

# The microphone remains owned by the host. Mono PCM captured on the host is
# converted to the Echo's nine-channel format and sent to a private QEMU
# serial socket. No audio or USB device is passed to QEMU.
ROOT='' KERNEL='' AFE_BINARY='' PRYON_BINARY='' MODEL_DIR=/system/local/models/keyword/en-US/ALEXA BACKEND=auto QEMU=${QEMU_SYSTEM:-qemu-system-arm} VERBOSE=0
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CACHE=${PRYON_AFE_CACHE:-$HOME/.cache/pryon-afe-runtime}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT=$2; shift 2;;
    --kernel) KERNEL=$2; shift 2;;
    --afe-binary) AFE_BINARY=$2; shift 2;;
    --pryon-binary) PRYON_BINARY=$2; shift 2;;
    --model-dir) MODEL_DIR=$2; shift 2;;
    --backend) BACKEND=$2; shift 2;;
    --qemu) QEMU=$2; shift 2;;
    --verbose) VERBOSE=1; shift;;
    --help) sed -n '1,28p' "$0"; exit 0;;
    --) shift; break;;
    *) echo "usage: $0 [--model-dir DIR] [--backend auto|pipewire|pulseaudio|jack|sox|alsa] [--verbose] [--qemu QEMU]" >&2; exit 2;;
  esac
done
[ -n "$ROOT" ] || for candidate in "$HOME/Downloads/update-kindle-biscuit_puffin-NS6574_extracted/system_root" "$CACHE/firmware/system_root"; do
  if [ -d "$candidate/system" ]; then ROOT=$candidate; break; fi
done
[ -n "$KERNEL" ] || KERNEL=$CACHE/linux-4.14.180/arch/arm/boot/zImage
[ -n "$AFE_BINARY" ] || AFE_BINARY=$PROJECT_ROOT/build-android/afe
[ -n "$PRYON_BINARY" ] || PRYON_BINARY=$PROJECT_ROOT/build-android/pryon

SETUP_LOG=${TMPDIR:-/tmp}/pryon-afe-live-setup.$$
if [ ! -d "$ROOT/system" ] || [ ! -r "$KERNEL" ]; then
  echo 'live-qemu: preparing cached firmware and kernel...' >&2
  if [ "$VERBOSE" = 1 ]; then
    PRYON_AFE_CACHE="$CACHE" sh "$PROJECT_ROOT/tools/setup-qemu.sh"
  else
    PRYON_AFE_CACHE="$CACHE" sh "$PROJECT_ROOT/tools/setup-qemu.sh" >"$SETUP_LOG" 2>&1 || {
      tail -n 30 "$SETUP_LOG" >&2
      rm -f "$SETUP_LOG"
      exit 1
    }
  fi
  rm -f "$SETUP_LOG"
  [ -d "$ROOT/system" ] || ROOT=$CACHE/firmware/system_root
  KERNEL=$CACHE/linux-4.14.180/arch/arm/boot/zImage
fi
[ -x "$AFE_BINARY" ] && [ -x "$PRYON_BINARY" ] || {
  echo 'live-qemu: building Android ARMv7 runtimes...' >&2
  NDK=${ANDROID_NDK_HOME:-}
  [ -n "$NDK" ] || for candidate in /opt/android-sdk/ndk/26.3.11579264 "$HOME/Android/Sdk/ndk/26.3.11579264"; do
    [ -d "$candidate" ] && NDK=$candidate && break
  done
  [ -n "$NDK" ] || { echo 'live-qemu: Android NDK 26.3.11579264 was not found' >&2; echo '  Linux: sdkmanager "ndk;26.3.11579264"' >&2; echo '  macOS: install Android Studio or command-line tools, then sdkmanager "ndk;26.3.11579264"' >&2; echo '  Or set ANDROID_NDK_HOME.' >&2; exit 1; }
  if [ "$VERBOSE" = 1 ]; then
    ANDROID_NDK_HOME=$NDK make -C "$PROJECT_ROOT" build-android
  else
    ANDROID_NDK_HOME=$NDK make -C "$PROJECT_ROOT" build-android >"$SETUP_LOG" 2>&1 || {
      tail -n 30 "$SETUP_LOG" >&2
      rm -f "$SETUP_LOG"
      exit 1
    }
    rm -f "$SETUP_LOG"
  fi
}
[ -d "$ROOT/system" ] || { echo 'live-qemu: --root must contain system/' >&2; exit 2; }
[ -r "$KERNEL" ] || { echo 'live-qemu: --kernel is required' >&2; exit 2; }
[ -x "$AFE_BINARY" ] || { echo 'live-qemu: --afe-binary must be executable' >&2; exit 2; }
[ -x "$PRYON_BINARY" ] || { echo 'live-qemu: --pryon-binary must be executable' >&2; exit 2; }
command -v ffmpeg >/dev/null 2>&1 || {
  echo 'live-qemu: missing dependency: ffmpeg' >&2
  echo '  Linux: sudo apt install ffmpeg' >&2
  echo '  macOS: brew install ffmpeg' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo 'live-qemu: missing dependency: python3' >&2
  echo '  Linux: sudo apt install python3' >&2
  echo '  macOS: brew install python' >&2
  exit 1
}

case "$BACKEND" in
  auto)
    if command -v pw-record >/dev/null 2>&1; then BACKEND=pipewire
    elif command -v pw-cat >/dev/null 2>&1; then BACKEND=pipewire-cat
    elif command -v parec >/dev/null 2>&1; then BACKEND=pulseaudio
    elif command -v jack_capture >/dev/null 2>&1; then BACKEND=jack
    elif command -v sox >/dev/null 2>&1; then BACKEND=sox
    elif command -v arecord >/dev/null 2>&1; then BACKEND=alsa
    else
      echo 'live-qemu: no supported capture command found' >&2
      echo '  Linux: sudo apt install pipewire-audio pulseaudio-utils jack-capture sox alsa-utils' >&2
      echo '  macOS: brew install pipewire pulseaudio sox (ALSA is unavailable natively)' >&2
      exit 1
    fi;;
esac
case "$BACKEND" in
  pipewire) command -v pw-record >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: pw-record (Linux: sudo apt install pipewire-audio; macOS: brew install pipewire)' >&2; exit 1; }; SOURCE_CMD='pw-record --rate 16000 --channels 1 --format s16 -';;
  pipewire-cat) command -v pw-cat >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: pw-cat (Linux: sudo apt install pipewire-audio; macOS: brew install pipewire)' >&2; exit 1; }; SOURCE_CMD='pw-cat --record --rate 16000 --channels 1 --format s16 -';;
  pulseaudio) command -v parec >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: parec (Linux: sudo apt install pulseaudio-utils; macOS: brew install pulseaudio)' >&2; exit 1; }; SOURCE_CMD='parec --raw --format=s16le --rate=16000 --channels=1';;
  jack) command -v jack_capture >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: jack_capture (Linux: sudo apt install jack-capture)' >&2; exit 1; }; SOURCE_CMD='jack_capture --raw --bits 16 --channels 1 --rate 16000 -';;
  sox) command -v sox >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: sox (Linux: sudo apt install sox; macOS: brew install sox)' >&2; exit 1; }; SOURCE_CMD='sox -q -t alsa default -t raw -r 16000 -c 1 -e signed-integer -b 16 -';;
  alsa) command -v arecord >/dev/null 2>&1 || { echo 'live-qemu: missing dependency: arecord (Linux: sudo apt install alsa-utils; unavailable natively on macOS)' >&2; exit 1; }; SOURCE_CMD='arecord -q -t raw -f S16_LE -c 1 -r 16000';;
  *) echo "live-qemu: unknown backend $BACKEND" >&2; exit 2;;
esac

WORK=${TMPDIR:-/tmp}/pryon-afe-runtime-live-qemu.$$
mkdir -p "$WORK"
SOCKET="$WORK/audio.sock"
cleanup() {
  status=$?
  trap - EXIT INT TERM
  kill "$FILTER_PID" 2>/dev/null || true
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT INT TERM

# A zero timeout keeps the guest alive until the capture process is stopped.
if [ "$VERBOSE" = 1 ]; then
  FILTER='cat'
else
  FILTER='awk '\''/^\{"type"/ || /qemu-init: (live pipeline status|real validation failed)/ { print; fflush() }'\'''
fi
# Keep boot noise out of the normal output while preserving wake events.
"$SCRIPT_DIR/run-qemu-system.sh" --root "$ROOT" --kernel "$KERNEL" \
  --mode pipeline --afe-binary "$AFE_BINARY" --pryon-binary "$PRYON_BINARY" \
  --model-dir "$MODEL_DIR" --stream-socket "$SOCKET" --timeout 0 --qemu "$QEMU" 2>&1 | sh -c "$FILTER" &
QEMU_PID=$!
FILTER_PID=$QEMU_PID
for _ in $(seq 1 300); do
  [ -S "$SOCKET" ] && break
  kill -0 "$QEMU_PID" 2>/dev/null || { wait "$QEMU_PID"; exit $?; }
  sleep 0.1
done
[ -S "$SOCKET" ] || { echo 'live-qemu: QEMU audio socket did not appear' >&2; exit 1; }
# The selected capture command produces raw mono S16LE at 16 kHz.
if [ "$VERBOSE" = 1 ]; then
  sh -c "$SOURCE_CMD" | "$SCRIPT_DIR/convert-to-9ch.sh" --raw-s16le | \
    python3 "$SCRIPT_DIR/internal/write-unix-socket.py" "$SOCKET"
else
  sh -c "$SOURCE_CMD" 2>/dev/null | "$SCRIPT_DIR/convert-to-9ch.sh" --raw-s16le 2>/dev/null | \
    python3 "$SCRIPT_DIR/internal/write-unix-socket.py" "$SOCKET"
fi
wait "$QEMU_PID"
