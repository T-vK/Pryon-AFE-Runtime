#!/bin/sh
set -eu
BIN=$1
ROOT=$2

quiet=$(head -c $((320 * 20 * 2)) /dev/zero | env PRYON_MOCK_RMS_THRESHOLD=5000 "$BIN" --wakeword alexa --models-dir "$ROOT" --format text | wc -l)
test "$quiet" -eq 0
detected=$(python3 -c 'import sys; sys.stdout.buffer.write(b"\xd0\x07" * (320 * 25))' |
  env PRYON_MOCK_RMS_THRESHOLD=1000 "$BIN" --wakeword alexa --models-dir "$ROOT" --format text | wc -l)
test "$detected" -eq 1
