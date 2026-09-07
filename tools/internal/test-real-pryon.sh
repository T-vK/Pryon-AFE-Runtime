#!/bin/sh
set -eu

ROOT=''
KERNEL=''
BINARY=''
HUMAN=''
OUT=${PRYON_REAL_TEST_OUT:-"$PWD/real-pryon-test-$(date -u +%Y%m%dT%H%M%SZ)"}
MODEL_DIR=/system/local/models/keyword/en-US/ALEXA

usage() {
  echo "usage: $0 --root SYSTEM_ROOT --kernel ZIMAGE --binary PRYON --human SAMPLE.pcm [--output DIR] [--model-dir GUEST_DIR]"
  echo "  SAMPLE.pcm must be mono signed 16-bit little-endian PCM at 16 kHz"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT=$2; shift 2;;
    --kernel) KERNEL=$2; shift 2;;
    --binary) BINARY=$2; shift 2;;
    --human) HUMAN=$2; shift 2;;
    --output) OUT=$2; shift 2;;
    --model-dir) MODEL_DIR=$2; shift 2;;
    --help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[ -d "$ROOT/system" ] || { echo 'real-pryon-test: invalid --root' >&2; exit 2; }
[ -r "$KERNEL" ] || { echo 'real-pryon-test: invalid --kernel' >&2; exit 2; }
[ -x "$BINARY" ] || { echo 'real-pryon-test: invalid --binary' >&2; exit 2; }
[ -r "$HUMAN" ] || { echo 'real-pryon-test: invalid --human' >&2; exit 2; }

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
mkdir -p "$OUT"
cp "$HUMAN" "$OUT/human.pcm"

python3 - "$HUMAN" "$OUT" <<'PY'
import os, struct, sys
source, out = sys.argv[1:]
raw = open(source, 'rb').read()
raw = raw[:len(raw) - len(raw) % 2]
samples = list(struct.unpack('<%dh' % (len(raw) // 2), raw))

# Produce a deterministic corruption sweep. A percentage of samples is
# replaced by loud pseudo-random noise; the rest is attenuated. This lets the
# result table show where this particular recording/model stops accepting,
# while the 100% case remains a strict negative control.
for percent_text in ('5', '2.5', '1.25', '0.625', '0.3125', '0.15625',
                     '10', '25', '50', '75', '90', '100'):
    percent = float(percent_text)
    state = 0x6d2b79f5 ^ int(percent * 1000)
    corrupt = []
    for sample in samples:
        state = (1664525 * state + 1013904223) & 0xffffffff
        noise = ((state >> 16) & 0x7fff) - 16384
        replace = ((state >> 8) % 10000) < int(percent * 100)
        attenuation = 1 + int(percent // 25)
        value = noise if percent >= 100 else (noise * 2 if replace else sample // attenuation)
        corrupt.append(max(-32768, min(32767, value)))
    path = os.path.join(out, 'distorted-%s.pcm' % percent_text)
    open(path, 'wb').write(struct.pack('<%dh' % len(corrupt), *corrupt))

state = 0x12345678
noise = []
for _ in samples:
    state = (1664525 * state + 1013904223) & 0xffffffff
    noise.append(((state >> 16) & 0x7fff) - 16384)
open(os.path.join(out, 'noise.pcm'), 'wb').write(struct.pack('<%dh' % len(noise), *noise))
open(os.path.join(out, 'silence.pcm'), 'wb').write(b'\0' * len(raw))
PY

printf 'case\tdetected\n' > "$OUT/results.tsv"

run_case() {
  name=$1
  input=$2
  expected=$3
  log="$OUT/$name.qemu.log"
  set +e
  "$PROJECT_ROOT/tools/run-qemu-system.sh" \
    --root "$ROOT" --kernel "$KERNEL" --mode pryon --binary "$BINARY" \
    --model-dir "$MODEL_DIR" --input "$input" >"$log" 2>&1
  status=$?
  set -e
  events=$(grep -E '^\{"type":"accepted"' "$log" || true)
  if [ "$status" -ne 0 ]; then
    echo "real-pryon-test: $name failed to execute (status $status); see $log" >&2
    return 1
  fi
  case "$expected" in
    yes)
      printf '%s\n' "$events" | grep -q '"id":"pryon_alexa"' || {
        echo "real-pryon-test: $name did not produce an accepted event; see $log" >&2
        return 1
      }
      ;;
    any)
      if [ -n "$events" ]; then detected=yes; else detected=no; fi
      printf '%s\t%s\n' "$name" "$detected" >> "$OUT/results.tsv"
      ;;
    no)
      [ -z "$events" ] || {
        echo "real-pryon-test: negative case $name produced an accepted event; see $log" >&2
        return 1
      }
      ;;
  esac
  echo "real-pryon-test: $name passed log=$log"
}

run_case human "$OUT/human.pcm" yes
for percent in 5 2.5 1.25 0.625 0.3125 0.15625 10 25 50 75 90 100; do
  run_case "distorted-$percent" "$OUT/distorted-$percent.pcm" any
done
grep -Eq '^distorted-100\tno$' "$OUT/results.tsv" || {
  echo 'real-pryon-test: 100% corruption was accepted' >&2
  exit 1
}
run_case noise "$OUT/noise.pcm" no
run_case silence "$OUT/silence.pcm" no
echo "real-pryon-test: distortion results are in $OUT/results.tsv"
echo "real-pryon-test: all cases passed output=$OUT"
