#!/bin/sh
set -eu

ADB=${ADB:-adb}
BUILD=${BUILD:-build-android}
CFG=${AFE_CFG_DEVICE:-/vendor/etc/audio-algorithms/AFE.cfg}
LIBDIR=${FIRMWARE_LIBDIR_DEVICE:-/system/lib}
REMOTE=/data/local/tmp/pryon-afe-runtime-smoke.$$
INPUT=${TMPDIR:-/tmp}/pryon-afe-device-input.$$.pcm
OUTPUT=${TMPDIR:-/tmp}/pryon-afe-device-output.$$.pcm
LOG=${TMPDIR:-/tmp}/pryon-afe-device-log.$$.txt

cleanup() {
  "$ADB" shell "killall par-afe-device 2>/dev/null || true; rm -rf '$REMOTE'" >/dev/null 2>&1 || true
  rm -f "$INPUT" "$OUTPUT" "$LOG"
}
trap cleanup EXIT INT TERM

command -v "$ADB" >/dev/null 2>&1 || {
  echo "device-test: missing dependency: $ADB" >&2
  echo '  Linux: sudo apt install android-tools-adb' >&2
  echo '  macOS: brew install android-platform-tools' >&2
  exit 1
}
test -x "$BUILD/afe" || { echo "device-test: missing $BUILD/afe; build Android first" >&2; exit 1; }
test -x "$BUILD/pryon" || { echo "device-test: missing $BUILD/pryon; build Android first" >&2; exit 1; }

"$ADB" get-state >/dev/null
"$ADB" shell "mkdir '$REMOTE'"
"$ADB" push "$BUILD/afe" "$REMOTE/par-afe-device" >/dev/null
"$ADB" push "$BUILD/pryon" "$REMOTE/pryon-device" >/dev/null
"$ADB" shell "chmod 755 '$REMOTE/par-afe-device' '$REMOTE/pryon-device'"

echo '[device] Pryon model discovery'
"$ADB" shell "$REMOTE/pryon-device --root /system/local/models/keyword --lib '$LIBDIR/libpryon.so' --list"

dd if=/dev/zero of="$INPUT" bs=8640 count=4 2>/dev/null
"$ADB" push "$INPUT" "$REMOTE/input.pcm" >/dev/null
echo '[device] real AFE processing'
"$ADB" shell \
  "'$REMOTE/par-afe-device' --cfg '$CFG' --lib '$LIBDIR/libasp.so' < '$REMOTE/input.pcm' > '$REMOTE/output.pcm' 2> '$REMOTE/afe.log'" \
  >/dev/null 2>&1 &
adb_pid=$!
status=124
deadline=$(($(date +%s) + ${DEVICE_TEST_TIMEOUT:-30}))
while [ "$(date +%s)" -lt "$deadline" ]; do
  "$ADB" pull "$REMOTE/output.pcm" "$OUTPUT" >/dev/null 2>&1 || true
  if [ -f "$OUTPUT" ] && [ "$(wc -c < "$OUTPUT")" -eq 2560 ]; then
    status=0
    break
  fi
  sleep 1
done
kill "$adb_pid" 2>/dev/null || true
wait "$adb_pid" 2>/dev/null || true
"$ADB" pull "$REMOTE/output.pcm" "$OUTPUT" >/dev/null
"$ADB" pull "$REMOTE/afe.log" "$LOG" >/dev/null 2>&1 || true
test "$status" -eq 0 || {
  echo "device-test: AFE command exited with status $status" >&2
  sed -n '1,120p' "$LOG" >&2 || true
  exit "$status"
}
test "$(wc -c < "$OUTPUT")" -eq 2560 || {
  echo "device-test: expected 2560 output bytes, got $(wc -c < "$OUTPUT")" >&2
  exit 1
}
echo '[device] real AFE smoke test passed (2560 bytes / 4 periods)'
