#!/bin/sh
set -eu
BIN=$1
bytes=$(head -c 8640 /dev/zero | "$BIN" --cfg test.cfg | wc -c)
test "$bytes" -eq 640
