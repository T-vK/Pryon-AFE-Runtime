#!/bin/sh
set -eu
BIN=$1
OUTPUT=$(head -c 12800 /dev/zero | "$BIN" --wakeword alexa --format text)
echo "$OUTPUT" | grep -q 'pryon_alexa'
if printf '\0' | "$BIN" --wakeword alexa </dev/stdin >/dev/null 2>&1; then
  echo 'truncated Pryon input unexpectedly succeeded' >&2
  exit 1
fi
