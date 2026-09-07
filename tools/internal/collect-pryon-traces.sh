#!/bin/sh
set -eu

# Collect reproducible real-firmware callback traces.  Inputs are raw 9-channel
# S24_3LE files, kept outside the repository.  The QEMU console log is the
# primary record: it includes loader/model/lifecycle messages, raw callback
# bytes (when PRYON_DUMP_EVENTS is enabled), and process status.

ROOT=''
KERNEL=''
AFE=''
PRYON=''
CORPUS=''
OUT=${PRYON_TRACE_OUT:-"$PWD/pryon-traces-$(date -u +%Y%m%dT%H%M%SZ)"}
MODEL_DIR=/system/local/models/keyword/en-US/ALEXA
TIMEOUT=${QEMU_TIMEOUT:-45}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)

usage() {
  echo "usage: $0 --root SYSTEM_ROOT --kernel ZIMAGE --afe-binary AFE --pryon-binary PRYON [--corpus DIR] [--model-dir GUEST_DIR] [--output DIR]"
  echo "  corpus files must be raw 9-channel S24_3LE; each file becomes one case"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT=$2; shift 2;;
    --kernel) KERNEL=$2; shift 2;;
    --afe-binary) AFE=$2; shift 2;;
    --pryon-binary) PRYON=$2; shift 2;;
    --corpus) CORPUS=$2; shift 2;;
    --model-dir) MODEL_DIR=$2; shift 2;;
    --output) OUT=$2; shift 2;;
    --help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[ -d "$ROOT/system" ] || { echo 'trace: --root must contain system/' >&2; exit 2; }
[ -r "$KERNEL" ] || { echo 'trace: --kernel is required' >&2; exit 2; }
[ -x "$AFE" ] || { echo 'trace: --afe-binary is required' >&2; exit 2; }
[ -x "$PRYON" ] || { echo 'trace: --pryon-binary is required' >&2; exit 2; }
[ -z "$CORPUS" ] || [ -d "$CORPUS" ] || { echo 'trace: corpus is not a directory' >&2; exit 2; }

mkdir -p "$OUT/cases" "$OUT/generated"
INDEX="$OUT/index.jsonl"
: > "$INDEX"

# Generate controls and deterministic gain variants without external audio
# utilities.  Speech samples should be supplied by the caller in the corpus.
python3 - "$CORPUS" "$OUT/generated" <<'PY'
import glob, math, os, struct, sys

corpus, out = sys.argv[1:]
os.makedirs(out, exist_ok=True)
files = sorted(glob.glob(os.path.join(corpus, '*.s24_3le'))) if corpus else []
if not files:
    print('trace: no corpus files supplied; collecting generated controls only', file=sys.stderr)

def unpack(data):
    n = len(data) // 3
    vals = []
    for i in range(n):
        x = data[i*3] | (data[i*3+1] << 8) | (data[i*3+2] << 16)
        if x & 0x800000: x -= 1 << 24
        vals.append(x)
    return vals

def pack(vals):
    b = bytearray()
    for x in vals:
        x = max(-(1 << 23), min((1 << 23)-1, int(x))) & 0xffffff
        b += bytes((x & 255, (x >> 8) & 255, (x >> 16) & 255))
    return b

def write_noise(path, frames, mode):
    vals = []
    state = 0x12345678
    for frame in range(frames):
        for ch in range(9):
            if mode == 'silence': x = 0
            else:
                state = (1664525 * state + 1013904223) & 0xffffffff
                x = ((state >> 8) & 0xffff) - 32768
                x *= 32
            vals.append(x)
    open(path, 'wb').write(pack(vals))

write_noise(os.path.join(out, 'silence.s24_3le'), 16000 * 4, 'silence')
write_noise(os.path.join(out, 'noise.s24_3le'), 16000 * 4, 'noise')

for source in files:
    name = os.path.splitext(os.path.basename(source))[0]
    data = open(source, 'rb').read()
    vals = unpack(data)
    # Apply deterministic attenuation and clipping to every packed sample.
    for label, factor, clip in (('gain-half', 0.5, False), ('clipped', 1.8, True)):
        changed = []
        for x in vals:
            y = x * factor
            if clip: y = max(-4000000, min(4000000, y))
            changed.append(y)
        open(os.path.join(out, name + '-' + label + '.s24_3le'), 'wb').write(pack(changed))
PY

set --
if [ -n "$CORPUS" ]; then
  for f in "$CORPUS"/*.s24_3le; do [ -f "$f" ] && set -- "$@" "$f"; done
fi
for f in "$OUT/generated"/*.s24_3le; do [ -f "$f" ] && set -- "$@" "$f"; done

[ "$#" -gt 0 ] || { echo 'trace: no input cases found' >&2; exit 2; }
for input in "$@"; do
  case_name=$(basename "$input" .s24_3le)
  case_dir="$OUT/cases/$case_name"
  mkdir -p "$case_dir"
  cp "$input" "$case_dir/input.s24_3le"
  sha=$(sha256sum "$input" | awk '{print $1}')
  bytes=$(wc -c < "$input" | tr -d ' ')
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  PRYON_DUMP_EVENTS=1 PRYON_TRACE=1 QEMU_TIMEOUT="$TIMEOUT" \
    "$PROJECT_ROOT/tools/run-qemu-system.sh" --root "$ROOT" --kernel "$KERNEL" \
    --mode pipeline --afe-binary "$AFE" --pryon-binary "$PRYON" \
    --model-dir "$MODEL_DIR" --input "$input" >"$case_dir/qemu.log" 2>&1
  status=$?
  set -e
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 - "$INDEX" "$case_name" "$input" "$sha" "$bytes" "$status" "$start" "$end" <<'PY'
import json, sys
index, name, path, sha, size, status, start, end = sys.argv[1:]
json.dump({'case': name, 'input': path,
           'sha256': sha, 'bytes': int(size), 'qemu_status': int(status),
           'started_utc': start, 'finished_utc': end}, open(index, 'a'))
open(index, 'a').write('\n')
PY
  echo "trace: $case_name status=$status log=$case_dir/qemu.log"
done

echo "trace: collection complete: $OUT"
