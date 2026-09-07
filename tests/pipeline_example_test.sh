#!/bin/sh
set -eu
PIPELINE=$1
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
AFE=${AFE:-$ROOT/build/afe}
PRYON=${PRYON:-$ROOT/build/pryon}
output=$(python3 -c 'import sys; sys.stdout.buffer.write(b"\x01\x00\x00" * (9 * 320 * 20))' |
  AFE="$AFE" PRYON="$PRYON" "$PIPELINE")
echo "$output" | grep -q 'pryon_alexa'
