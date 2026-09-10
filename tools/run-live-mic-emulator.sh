#!/bin/sh
set -eu

# The microphone remains owned by the host. Mono PCM captured on the host is
# converted to the Echo's nine-channel format and sent to a private emulator
# serial socket. No audio or USB device is passed to the emulator.
ROOT='' KERNEL='' AFE_BINARY='' PRYON_BINARY='' MODEL_DIR=/system/local/models/keyword/en-US/ALEXA BACKEND=auto EMULATOR_COMMAND=${EMULATOR_COMMAND:-qemu-system-arm} VERBOSE=0 QUIET=0
RESTART_FILE=${PRYON_AFE_LIVE_RESTART_FILE:-}
STOP_FILE=${PRYON_AFE_LIVE_STOP_FILE:-}
AUDIO_FIFO=''
CAPTURE_TRIGGER=''
CAPTURE_STARTED_FILE=''
CAPTURE_STOP_TRIGGER=''
CAPTURE_STOPPED_FILE=''
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CACHE=${PRYON_AFE_CACHE:-${PRYON_AFE_EXTERNAL:-$PROJECT_ROOT/.external}/emulator}
usage() {
  cat <<EOF
usage: $0 [options]
  --root DIR                    extracted firmware system root
  --kernel FILE                 ARMv7 emulator kernel
  --afe-binary FILE             Android ARMv7 afe executable
  --pryon-binary FILE           Android ARMv7 pryon executable
  --model-dir DIR               guest model directory
  --backend NAME                auto, pipewire, pulseaudio, jack, sox, or alsa
  --emulator-command COMMAND    emulator executable (default: qemu-system-arm)
  --quiet                       print only Pryon JSON events
  --verbose                     print emulator and runtime diagnostics

Firmware, kernel, runtime, and audio-backend defaults are detected automatically.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT=$2; shift 2;;
    --kernel) KERNEL=$2; shift 2;;
    --afe-binary) AFE_BINARY=$2; shift 2;;
    --pryon-binary) PRYON_BINARY=$2; shift 2;;
    --model-dir) MODEL_DIR=$2; shift 2;;
    --backend) BACKEND=$2; shift 2;;
    --emulator-command) EMULATOR_COMMAND=$2; shift 2;;
    --verbose) VERBOSE=1; shift;;
    --quiet) QUIET=1; shift;;
    --restart-file) RESTART_FILE=$2; shift 2;;
    --stop-file) STOP_FILE=$2; shift 2;;
    --audio-fifo) AUDIO_FIFO=$2; shift 2;;
    --capture-trigger) CAPTURE_TRIGGER=$2; shift 2;;
    --capture-started-file) CAPTURE_STARTED_FILE=$2; shift 2;;
    --capture-stop-trigger) CAPTURE_STOP_TRIGGER=$2; shift 2;;
    --capture-stopped-file) CAPTURE_STOPPED_FILE=$2; shift 2;;
    --help) usage; exit 0;;
    --) shift; break;;
  *) usage >&2; exit 2;;
  esac
done
[ "$VERBOSE" -eq 1 ] && echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: script started" >&2
[ -n "$ROOT" ] || for candidate in "$HOME/Downloads/update-kindle-biscuit_puffin-NS6574_extracted/system_root" "$CACHE/firmware/system_root"; do
  if [ -d "$candidate/system" ]; then ROOT=$candidate; break; fi
done
[ -n "$KERNEL" ] || KERNEL=$CACHE/linux-4.14.180/arch/arm/boot/zImage
[ -n "$AFE_BINARY" ] || AFE_BINARY=$PROJECT_ROOT/build-android/afe
[ -n "$PRYON_BINARY" ] || PRYON_BINARY=$PROJECT_ROOT/build-android/pryon

SETUP_LOG=${TMPDIR:-/tmp}/pryon-afe-live-setup.$$
if [ ! -d "$ROOT/system" ] || [ ! -r "$KERNEL" ]; then
  echo 'live-emulator: preparing cached firmware and kernel...' >&2
  if [ "$VERBOSE" = 1 ]; then
    PRYON_AFE_CACHE="$CACHE" sh "$PROJECT_ROOT/tools/setup-emulator.sh"
  else
    PRYON_AFE_CACHE="$CACHE" sh "$PROJECT_ROOT/tools/setup-emulator.sh" >"$SETUP_LOG" 2>&1 || {
      tail -n 30 "$SETUP_LOG" >&2
      rm -f "$SETUP_LOG"
      exit 1
    }
  fi
  rm -f "$SETUP_LOG"
  [ -d "$ROOT/system" ] || ROOT=$CACHE/firmware/system_root
  KERNEL=$CACHE/linux-4.14.180/arch/arm/boot/zImage
fi
if [ ! -x "$AFE_BINARY" ] || [ ! -x "$PRYON_BINARY" ]; then
  echo 'live-emulator: building Android ARMv7 runtimes...' >&2
  NDK=${ANDROID_NDK_HOME:-}
  [ -n "$NDK" ] || for candidate in /opt/android-sdk/ndk/26.3.11579264 "$HOME/Android/Sdk/ndk/26.3.11579264"; do
    [ -d "$candidate" ] && NDK=$candidate && break
  done
  [ -n "$NDK" ] || { echo 'live-emulator: Android NDK 26.3.11579264 was not found' >&2; echo '  Linux: sdkmanager "ndk;26.3.11579264"' >&2; echo '  macOS: install Android Studio or command-line tools, then sdkmanager "ndk;26.3.11579264"' >&2; echo '  Or set ANDROID_NDK_HOME.' >&2; exit 1; }
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
fi
[ -d "$ROOT/system" ] || { echo 'live-emulator: --root must contain system/' >&2; exit 2; }
[ -r "$KERNEL" ] || { echo 'live-emulator: --kernel is required' >&2; exit 2; }
[ -x "$AFE_BINARY" ] || { echo 'live-emulator: --afe-binary must be executable' >&2; exit 2; }
[ -x "$PRYON_BINARY" ] || { echo 'live-emulator: --pryon-binary must be executable' >&2; exit 2; }
command -v ffmpeg >/dev/null 2>&1 || {
  echo 'live-emulator: missing dependency: ffmpeg' >&2
  echo '  Linux: sudo apt install ffmpeg' >&2
  echo '  macOS: brew install ffmpeg' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo 'live-emulator: missing dependency: python3' >&2
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
      echo 'live-emulator: no supported capture command found' >&2
      echo '  Linux: sudo apt install pipewire-audio pulseaudio-utils jack-capture sox alsa-utils' >&2
      echo '  macOS: brew install pipewire pulseaudio sox (ALSA is unavailable natively)' >&2
      exit 1
    fi;;
esac
case "$BACKEND" in
  pipewire) command -v pw-record >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: pw-record (Linux: sudo apt install pipewire-audio; macOS: brew install pipewire)' >&2; exit 1; }; SOURCE_CMD='pw-record --rate 16000 --channels 1 --format s16 -';;
  pipewire-cat) command -v pw-cat >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: pw-cat (Linux: sudo apt install pipewire-audio; macOS: brew install pipewire)' >&2; exit 1; }; SOURCE_CMD='pw-cat --record --rate 16000 --channels 1 --format s16 -';;
  pulseaudio) command -v parec >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: parec (Linux: sudo apt install pulseaudio-utils; macOS: brew install pulseaudio)' >&2; exit 1; }; SOURCE_CMD='parec --raw --format=s16le --rate=16000 --channels=1';;
  jack) command -v jack_capture >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: jack_capture (Linux: sudo apt install jack-capture)' >&2; exit 1; }; SOURCE_CMD='jack_capture --raw --bits 16 --channels 1 --rate 16000 -';;
  sox) command -v sox >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: sox (Linux: sudo apt install sox; macOS: brew install sox)' >&2; exit 1; }; SOURCE_CMD='sox -q -t alsa default -t raw -r 16000 -c 1 -e signed-integer -b 16 -';;
  alsa) command -v arecord >/dev/null 2>&1 || { echo 'live-emulator: missing dependency: arecord (Linux: sudo apt install alsa-utils; unavailable natively on macOS)' >&2; exit 1; }; SOURCE_CMD='arecord -q -t raw -f S16_LE -c 1 -r 16000';;
  *) echo "live-emulator: unknown backend $BACKEND" >&2; exit 2;;
esac

WORK=${TMPDIR:-/tmp}/pryon-afe-runtime-live-emulator.$$
mkdir -p "$WORK"
SOCKET="$WORK/audio.sock"
CONTROL_SOCKET="$WORK/control.sock"
INPUT_FIFO=${AUDIO_FIFO:-$WORK/audio.pcm}
START_FILE="$WORK/start-audio"
CONNECTED_FILE="$WORK/audio-connected"
EMULATOR_PID=''
FILTER_PID=''
BRIDGE_PID=''
READY_MONITOR_PID=''
CONTROL_WATCH_PID=''
CAPTURE_PID=''
kill_tree() {
  parent=$1
  [ -n "$parent" ] || return 0
  for child in $(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }'); do
    kill_tree "$child"
  done
  kill "$parent" 2>/dev/null || true
}
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$CAPTURE_PID" ]; then kill_tree "$CAPTURE_PID"; fi
  kill_tree "$FILTER_PID"
  kill_tree "$BRIDGE_PID"
  kill_tree "$READY_MONITOR_PID"
  kill_tree "$CONTROL_WATCH_PID"
  kill_tree "$EMULATOR_PID"
  wait "$CAPTURE_PID" 2>/dev/null || true
  wait "$FILTER_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
  wait "$READY_MONITOR_PID" 2>/dev/null || true
  wait "$CONTROL_WATCH_PID" 2>/dev/null || true
  wait "$EMULATOR_PID" 2>/dev/null || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT INT TERM

# A zero timeout keeps the guest alive until the capture process is stopped.
# The emulator creates the host socket before the guest libraries are ready. Keep its
# output in a host-side log so the host can wait for the explicit handshake.
EMULATOR_OUTPUT="$WORK/emulator-output.log"
if [ "$QUIET" -eq 0 ] && [ "$VERBOSE" -eq 0 ]; then
  echo 'Starting Echo emulator... (This might take a couple seconds.)' >&2
  echo 'Warning: the emulator may process AFE/Pryon audio slower than real time; recognition can be delayed while audio is streaming.' >&2
fi
if [ "$VERBOSE" -eq 1 ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: starting emulator" >&2
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: warning: emulated AFE/Pryon processing may not keep up with real time" >&2
fi
(exec setsid "$SCRIPT_DIR/run-emulator.sh" --root "$ROOT" --kernel "$KERNEL" \
  --mode pipeline --afe-binary "$AFE_BINARY" --pryon-binary "$PRYON_BINARY" \
  --model-dir "$MODEL_DIR" --stream-socket "$SOCKET" --control-socket "$CONTROL_SOCKET" \
  --timeout 0 --emulator-command "$EMULATOR_COMMAND" >"$EMULATOR_OUTPUT" 2>&1) &
EMULATOR_PID=$!
if [ "$VERBOSE" -eq 1 ]; then
  # shellcheck disable=SC2016
  (exec setsid sh -c 'tail -n +1 -f "$1"' sh "$EMULATOR_OUTPUT") &
elif [ "$QUIET" -eq 1 ]; then
  # shellcheck disable=SC2016
  (exec setsid sh -c 'tail -n +1 -f "$1" | awk '\''/^\{"type"/ { print; fflush() }'\''' sh "$EMULATOR_OUTPUT") &
else
  # shellcheck disable=SC2016
  (exec setsid sh -c 'tail -n +1 -f "$1" | awk '\''/^\{"type"/ || /emulator-init: (live pipeline status|real validation failed)/ { print; fflush() }'\''' sh "$EMULATOR_OUTPUT") &
fi
FILTER_PID=$!
for _ in $(seq 1 300); do
  [ -S "$SOCKET" ] && break
  kill -0 "$EMULATOR_PID" 2>/dev/null || { wait "$EMULATOR_PID"; exit $?; }
  sleep 0.1
done
[ -S "$SOCKET" ] || { echo 'live-emulator: audio socket did not appear' >&2; exit 1; }
[ -n "$RESTART_FILE" ] && {
  python3 "$SCRIPT_DIR/internal/watch-emulator-control.py" "$CONTROL_SOCKET" "$RESTART_FILE" "$STOP_FILE" &
  CONTROL_WATCH_PID=$!
}
if [ "$VERBOSE" -eq 1 ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: emulator socket ready; connecting host audio bridge" >&2
fi
if [ ! -p "$INPUT_FIFO" ]; then mkfifo "$INPUT_FIFO"; fi
python3 "$SCRIPT_DIR/internal/write-unix-socket.py" "$SOCKET" \
  "$INPUT_FIFO" "$START_FILE" "$CONNECTED_FILE" --keep-open \
  ${CAPTURE_STARTED_FILE:+--activity-file "$CAPTURE_STARTED_FILE"} &
BRIDGE_PID=$!
for _ in $(seq 1 100); do
  [ -e "$CONNECTED_FILE" ] && break
  kill -0 "$BRIDGE_PID" 2>/dev/null || { echo 'live-emulator: audio socket bridge stopped' >&2; exit 1; }
  sleep 0.1
done
[ -e "$CONNECTED_FILE" ] || { echo 'live-emulator: audio socket connection failed' >&2; exit 1; }
for _ in $(seq 1 300); do
  grep -Fq 'emulator-init: live pipeline ready' "$EMULATOR_OUTPUT" && break
  kill -0 "$EMULATOR_PID" 2>/dev/null || {
    echo 'live-emulator: emulator stopped before the runtime became ready' >&2
    exit 1
  }
  sleep 0.1
done
grep -Fq 'emulator-init: live pipeline ready' "$EMULATOR_OUTPUT" || {
  echo 'live-emulator: AFE/Pryon runtime did not become ready within 30 seconds' >&2
  exit 1
}
if [ "$QUIET" -eq 0 ]; then
  if [ -n "$CAPTURE_TRIGGER" ]; then echo 'Emulator ready.' >&2; else echo 'Done! Listening now...' >&2; fi
fi
if [ "$VERBOSE" -eq 1 ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: AFE and Pryon are ready" >&2
fi
: > "$START_FILE"
if [ -n "${PRYON_AFE_LIVE_READY_FILE:-}" ]; then
  printf '1\n' > "$PRYON_AFE_LIVE_READY_FILE"
  (
    seen=1
    while kill -0 "$EMULATOR_PID" 2>/dev/null; do
      count=$(grep -c 'emulator-init: live pipeline ready' "$EMULATOR_OUTPUT" 2>/dev/null || true)
      if [ "$count" -gt "$seen" ]; then
        printf '%s\n' "$count" > "$PRYON_AFE_LIVE_READY_FILE"
        seen=$count
      fi
      sleep 0.05
    done
  ) &
  READY_MONITOR_PID=$!
fi
# The selected capture command produces raw mono S16LE at 16 kHz. Put the
# complete capture pipeline in its own process group so cleanup cannot leave
# pw-record/parec/arecord or the converter behind.
if [ -n "$CAPTURE_TRIGGER" ]; then
  while [ ! -e "$CAPTURE_TRIGGER" ]; do
    kill -0 "$EMULATOR_PID" 2>/dev/null || exit 1
    sleep 0.05
  done
  rm -f "$CAPTURE_TRIGGER"
fi
(exec setsid sh -c "sh -c '$SOURCE_CMD' 2>/dev/null | '$SCRIPT_DIR/convert-to-9ch.sh' --raw-s16le 2>/dev/null > '$INPUT_FIFO'") &
CAPTURE_PID=$!
sleep 0.2
kill -0 "$CAPTURE_PID" 2>/dev/null || { wait "$CAPTURE_PID" 2>/dev/null || true; echo 'live-emulator: microphone capture failed to start' >&2; exit 1; }
[ "$VERBOSE" -eq 0 ] || echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] live-emulator: host microphone capture started" >&2
if [ -n "$CAPTURE_STOP_TRIGGER" ]; then
  while [ ! -e "$CAPTURE_STOP_TRIGGER" ]; do
    kill -0 "$EMULATOR_PID" 2>/dev/null || exit 1
    sleep 0.05
  done
  kill_tree "$CAPTURE_PID"
  wait "$CAPTURE_PID" 2>/dev/null || true
  CAPTURE_PID=''
  [ -z "$CAPTURE_STOPPED_FILE" ] || : > "$CAPTURE_STOPPED_FILE"
fi
wait "$BRIDGE_PID" 2>/dev/null || true
wait "$EMULATOR_PID"
