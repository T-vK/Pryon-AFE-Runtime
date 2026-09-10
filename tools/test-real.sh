#!/bin/sh
set -eu

# Real-library validation. File tests are the default; --mic adds the two
# deliberately interactive ten-second capture windows.
ADB=${ADB:-adb}
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT/build-android}
EXTERNAL=${PRYON_AFE_EXTERNAL:-$ROOT/.external}
REMOTE=/data/local/tmp/pryon-afe-real-test
MIC=0
BEEP=0
EMULATOR=0
VERBOSE=0
POSITIVE=${PRYON_WAKE_AUDIO:-}
NEGATIVE=${PRYON_NEGATIVE_AUDIO:-}

usage() {
  cat <<EOF
usage: $0 [--mic] [--beep] [--emulator] [--verbose]

Runs real-library file tests on an ADB-connected Echo. --mic adds interactive
positive and negative ten-second microphone tests. --emulator runs the tests
inside an Echo emulator instead. Audio files can be selected with
PRYON_WAKE_AUDIO and PRYON_NEGATIVE_AUDIO.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mic) MIC=1; shift;;
    --beep) BEEP=1; shift;;
    --emulator) EMULATOR=1; shift;;
    --verbose) VERBOSE=1; shift;;
    --help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done

if { [ -z "$POSITIVE" ] && [ ! -r "$EXTERNAL/audio/alexa.wav" ]; } ||
   { [ -z "$NEGATIVE" ] && [ ! -r "$EXTERNAL/audio/nowake.wav" ]; }; then
  "$ROOT/tools/download-testdata.sh" >/dev/null
fi
POSITIVE=${POSITIVE:-$EXTERNAL/audio/alexa.wav}
NEGATIVE=${NEGATIVE:-$EXTERNAL/audio/nowake.wav}
[ -r "$POSITIVE" ] || { echo "real-test: positive audio file is missing: $POSITIVE" >&2; exit 1; }
if [ -n "$NEGATIVE" ] && [ ! -r "$NEGATIVE" ]; then
  echo "real-test: negative audio file is missing: $NEGATIVE" >&2
  exit 1
fi
if [ "$VERBOSE" -eq 1 ]; then
  echo "[real-test] positive audio: $POSITIVE"
  if [ -n "$NEGATIVE" ]; then echo "[real-test] negative audio: $NEGATIVE"; fi
fi
if [ ! -x "$BUILD/afe" ] || [ ! -x "$BUILD/pryon" ]; then
  echo "real-test: build Android binaries first: make build-android" >&2
  exit 1
fi
command -v ffmpeg >/dev/null 2>&1 || { echo "real-test: missing ffmpeg (Linux: sudo apt install ffmpeg; macOS: brew install ffmpeg)" >&2; exit 1; }
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_COMMAND=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_COMMAND=gtimeout
else
  echo "real-test: missing timeout command (Linux: sudo apt install coreutils; macOS: brew install coreutils)" >&2
  exit 1
fi

TMP=$(mktemp -d)
RESTORE_LED=0
SESSION_PID=''
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$SESSION_PID" ]; then kill "$SESSION_PID" 2>/dev/null || true; wait "$SESSION_PID" 2>/dev/null || true; fi
  if [ "$RESTORE_LED" -eq 1 ]; then "$ADB" shell 'start ledcontroller >/dev/null 2>&1 || true' >/dev/null 2>&1 || true; fi
  "$ADB" shell "rm -rf '$REMOTE'" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT INT TERM

beep() {
  [ "$BEEP" -eq 1 ] || return 0
  if command -v pw-play >/dev/null 2>&1; then
    ffmpeg -loglevel quiet -f lavfi -i 'sine=frequency=880:duration=0.15' -f wav - |
      pw-play - >/dev/null 2>&1 &
  elif command -v paplay >/dev/null 2>&1; then
    ffmpeg -loglevel quiet -f lavfi -i 'sine=frequency=880:duration=0.15' -f wav - |
      paplay - >/dev/null 2>&1 &
  elif command -v aplay >/dev/null 2>&1; then
    ffmpeg -loglevel quiet -f lavfi -i 'sine=frequency=880:duration=0.15' -f wav - |
      aplay -q - >/dev/null 2>&1 &
  else
    printf '\007' >&2
  fi
}
make_input() {
  "$ROOT/tools/convert-to-9ch.sh" < "$1" > "$2"
  # The stream adapter intentionally rejects a final partial public period.
  # Pad finite test files to an exact 320-sample boundary.
  size=$(wc -c < "$2")
  remainder=$((size % 8640))
  if [ "$remainder" -ne 0 ]; then
    dd if=/dev/zero bs=1 count=$((8640 - remainder)) >> "$2" 2>/dev/null
  fi
}
expect_event() {
  grep -q '"type":"accepted"' "$1" || { echo "real-test: expected wake event was not observed" >&2; return 1; }
}
expect_no_event() {
  ! grep -q '"type":"accepted"' "$1" || { echo "real-test: unexpected wake event observed" >&2; return 1; }
}

run_emulator_single_session() {
  ready_file="$TMP/emulator-session-ready"
  restart_file="$TMP/emulator-session-restart"
  stop_file="$TMP/emulator-session-stop"
  capture_trigger="$TMP/emulator-session-capture"
  capture_started_file="$TMP/emulator-session-capture-started"
  capture_stop_trigger="$TMP/emulator-session-stop-capture"
  capture_stopped_file="$TMP/emulator-session-capture-stopped"
  audio_fifo="$TMP/emulator-session-audio"
  session_log="$TMP/emulator-session.json"
  LIVE_VERBOSE=''
  [ "$VERBOSE" -eq 1 ] && LIVE_VERBOSE=--verbose
  restart_session() {
    old_ready=$(cat "$ready_file")
    : > "$restart_file"
    for _ in $(seq 1 600); do
      new_ready=$(cat "$ready_file" 2>/dev/null || echo "$old_ready")
      [ "$new_ready" -gt "$old_ready" ] && return 0
      sleep 0.05
    done
    echo 'real-test: afe/pryon restart failed' >&2
    return 1
  }
  event_after() {
    awk -v base="$1" 'NR > base && /"type":"accepted"/' "$session_log" | grep -q .
  }
  stop_session() {
    : > "$stop_file"
    for _ in $(seq 1 200); do
      kill -0 "$SESSION_PID" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$SESSION_PID" 2>/dev/null; then kill "$SESSION_PID" 2>/dev/null || true; fi
    wait "$SESSION_PID" 2>/dev/null || true
    SESSION_PID=''
  }
  mkfifo "$audio_fifo"
  : > "$session_log"
  echo 'Starting emulator for the complete test run...'
  if [ "$VERBOSE" -eq 1 ]; then
    PRYON_AFE_LIVE_READY_FILE="$ready_file" PRYON_AFE_LIVE_RESTART_FILE="$restart_file" PRYON_AFE_LIVE_STOP_FILE="$stop_file" \
      "$ROOT/tools/run-live-mic-emulator.sh" $LIVE_VERBOSE --audio-fifo "$audio_fifo" \
      --capture-trigger "$capture_trigger" --capture-started-file "$capture_started_file" --capture-stop-trigger "$capture_stop_trigger" \
      --capture-stopped-file "$capture_stopped_file" >"$session_log" &
  else
    PRYON_AFE_LIVE_READY_FILE="$ready_file" PRYON_AFE_LIVE_RESTART_FILE="$restart_file" PRYON_AFE_LIVE_STOP_FILE="$stop_file" \
      "$ROOT/tools/run-live-mic-emulator.sh" $LIVE_VERBOSE --audio-fifo "$audio_fifo" \
      --capture-trigger "$capture_trigger" --capture-started-file "$capture_started_file" --capture-stop-trigger "$capture_stop_trigger" \
      --capture-stopped-file "$capture_stopped_file" >"$session_log" 2>/dev/null &
  fi
  SESSION_PID=$!
  for _ in $(seq 1 300); do
    [ -s "$ready_file" ] && break
    kill -0 "$SESSION_PID" 2>/dev/null || { wait "$SESSION_PID" 2>/dev/null || true; SESSION_PID=''; echo 'real-test: emulator stopped before becoming ready' >&2; return 1; }
    sleep 0.1
  done
  [ -s "$ready_file" ] || { echo 'real-test: emulator did not become ready' >&2; return 1; }

  if [ "$MIC" -eq 1 ]; then
    touch "$capture_trigger"
    for _ in $(seq 1 100); do [ -e "$capture_started_file" ] && break; sleep 0.05; done
    [ -e "$capture_started_file" ] || { echo 'real-test: host microphone capture did not start' >&2; return 1; }
    baseline=$(wc -l < "$session_log")
    echo 'Starting positive microphone test (up to 10 seconds).'
    echo 'Please say the wake word now.'
    beep
    deadline=$(($(date +%s) + 10))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if event_after "$baseline"; then awk -v base="$baseline" 'NR > base && /"type":"accepted"/ { print; exit }' "$session_log"; break; fi
      sleep 0.05
    done
    event_after "$baseline" || { echo 'Failed: positive microphone test did not detect a wake word.' >&2; return 1; }
    echo 'Passed: positive microphone test.'
    restart_session
    baseline=$(wc -l < "$session_log")
    echo 'Starting negative microphone test (up to 10 seconds).'
    echo 'Please do not say the wake word.'
    deadline=$(($(date +%s) + 10))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if event_after "$baseline"; then echo 'Failed: negative microphone test detected a wake word.' >&2; return 1; fi
      sleep 0.05
    done
    echo 'Passed: negative microphone test.'
    : > "$capture_stop_trigger"
    for _ in $(seq 1 200); do [ -e "$capture_stopped_file" ] && break; sleep 0.05; done
    [ -e "$capture_stopped_file" ] || { echo 'real-test: host microphone capture did not stop' >&2; return 1; }
  fi

  restart_session
  baseline=$(wc -l < "$session_log")
  echo 'Starting positive file test (up to 10 seconds).'
  cat "$TMP/positive.pcm" > "$audio_fifo" &
  feed_pid=$!
  deadline=$(($(date +%s) + 10))
  while [ "$(date +%s)" -lt "$deadline" ] && ! event_after "$baseline"; do sleep 0.05; done
  kill "$feed_pid" 2>/dev/null || true; wait "$feed_pid" 2>/dev/null || true
  event_after "$baseline" || { echo 'Failed: positive file test did not detect a wake word.' >&2; return 1; }
  echo 'Passed: positive file test.'

  if [ -n "$NEGATIVE" ]; then
    restart_session
    baseline=$(wc -l < "$session_log")
    echo 'Starting negative file test (up to 10 seconds).'
    cat "$TMP/negative.pcm" > "$audio_fifo" &
    feed_pid=$!
    deadline=$(($(date +%s) + 10))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if event_after "$baseline"; then kill "$feed_pid" 2>/dev/null || true; wait "$feed_pid" 2>/dev/null || true; echo 'Failed: negative file test detected a wake word.' >&2; return 1; fi
      sleep 0.05
    done
    kill "$feed_pid" 2>/dev/null || true; wait "$feed_pid" 2>/dev/null || true
    echo 'Passed: negative file test.'
  fi
  stop_session
}

if [ "$EMULATOR" -eq 0 ]; then
  command -v "$ADB" >/dev/null 2>&1 || { echo "real-test: missing adb (Linux: sudo apt install android-tools-adb; macOS: brew install android-platform-tools)" >&2; exit 1; }
  "$ADB" get-state >/dev/null
fi
make_input "$POSITIVE" "$TMP/positive.pcm"
[ -z "$NEGATIVE" ] || make_input "$NEGATIVE" "$TMP/negative.pcm"

if [ "$EMULATOR" -eq 1 ]; then
  emulator_command=${EMULATOR_COMMAND:-qemu-system-arm}
  command -v "$emulator_command" >/dev/null 2>&1 || {
    echo "real-test: missing emulator executable: $emulator_command" >&2
    echo '  Linux: sudo apt install qemu-system-arm' >&2
    echo '  macOS: brew install qemu' >&2
    exit 1
  }
  run_emulator_single_session
  exit 0
fi

"$ADB" shell "mkdir -p '$REMOTE'"
"$ADB" push "$BUILD/afe" "$BUILD/pryon" "$TMP/positive.pcm" "$REMOTE/" >/dev/null
"$ADB" shell "chmod 755 '$REMOTE/afe' '$REMOTE/pryon'"
if [ "$MIC" -eq 1 ]; then
LED_STATE=$($ADB shell getprop init.svc.ledcontroller 2>/dev/null | tr -d '\r')
if [ "$LED_STATE" = running ]; then
  echo 'Temporarily stopping the audio service to release the microphone...' >&2
  "$ADB" shell 'stop ledcontroller' >/dev/null
  RESTORE_LED=1
fi

POSITIVE_CAPTURE="$TMP/mic-positive.json"
: > "$POSITIVE_CAPTURE"
echo 'Starting positive microphone test (up to 10 seconds).'
"$TIMEOUT_COMMAND" 10 "$ADB" shell "'$REMOTE/afe' --alsa 2>/dev/null | '$REMOTE/pryon' 2>/dev/null" \
  >"$POSITIVE_CAPTURE" 2>/dev/null &
CAPTURE_PID=$!
sleep 0.2
echo 'Please say the wake word now.'
beep
DETECTED=0
while kill -0 "$CAPTURE_PID" 2>/dev/null; do
  if grep -q '"type":"accepted"' "$POSITIVE_CAPTURE"; then
    DETECTED=1
    kill "$CAPTURE_PID" 2>/dev/null || true
    break
  fi
  sleep 0.05
done
wait "$CAPTURE_PID" 2>/dev/null || true
if [ "$DETECTED" -eq 0 ] && grep -q '"type":"accepted"' "$POSITIVE_CAPTURE"; then
  DETECTED=1
fi
if [ "$DETECTED" -eq 1 ]; then
  grep '"type":"accepted"' "$POSITIVE_CAPTURE" | sed -n '1p'
fi
expect_event "$TMP/mic-positive.json"
echo 'Passed: positive microphone test.'

echo 'Starting negative microphone test (up to 10 seconds).'
: > "$TMP/mic-negative.json"
"$TIMEOUT_COMMAND" 10 "$ADB" shell "'$REMOTE/afe' --alsa 2>/dev/null | '$REMOTE/pryon' 2>/dev/null" >"$TMP/mic-negative.json" 2>/dev/null &
CAPTURE_PID=$!
sleep 0.2
echo 'Please do not say the wake word.'
while kill -0 "$CAPTURE_PID" 2>/dev/null; do
  if grep -q '"type":"accepted"' "$TMP/mic-negative.json"; then
    kill "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
    grep '"type":"accepted"' "$TMP/mic-negative.json" | sed -n '1p' >&2
    echo 'Failed: negative microphone test detected a wake word.' >&2
    exit 1
  fi
  sleep 0.05
done
wait "$CAPTURE_PID" 2>/dev/null || true
expect_no_event "$TMP/mic-negative.json"
echo 'Passed: negative microphone test.'
fi

echo 'Starting positive file test (up to 10 seconds).'
"$TIMEOUT_COMMAND" 10 "$ADB" shell "'$REMOTE/afe' 2>/dev/null < '$REMOTE/positive.pcm' | '$REMOTE/pryon' 2>/dev/null" >"$TMP/positive.json" 2>/dev/null || true
grep '"type":"accepted"' "$TMP/positive.json" | sed -n '1p' || true
expect_event "$TMP/positive.json"
echo 'Passed: positive file test.'
if [ -n "$NEGATIVE" ]; then
  "$ADB" push "$TMP/negative.pcm" "$REMOTE/negative.pcm" >/dev/null
  echo 'Starting negative file test (up to 10 seconds).'
  "$TIMEOUT_COMMAND" 10 "$ADB" shell "'$REMOTE/afe' 2>/dev/null < '$REMOTE/negative.pcm' | '$REMOTE/pryon' 2>/dev/null" > "$TMP/negative.json" 2>/dev/null || true
  expect_no_event "$TMP/negative.json"
  echo 'Passed: negative file test.'
else
  echo '[real-test] negative WAV not found; skipped (set PRYON_NEGATIVE_AUDIO to enable)' >&2
fi
