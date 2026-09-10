#!/bin/sh
set -eu

# Compatibility entry point for older documentation and Makefile invocations.
# The maintained device test is test-real.sh, which covers the complete real
# AFE-to-Pryon path and the optional microphone test.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/test-real.sh" "$@"
