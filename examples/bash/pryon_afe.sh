#!/bin/sh
# Read nine-channel S24_3LE, then connect afe to pryon.
set -eu

AFE=${AFE:-./build/afe}
PRYON=${PRYON:-./build/pryon}
if [ -n "${PRYON_MODEL_DIR:-}" ]; then
  exec "$AFE" | "$PRYON" --model-dir "$PRYON_MODEL_DIR"
fi
exec "$AFE" | "$PRYON"
