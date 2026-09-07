#!/bin/sh
set -eu
AFE=$1
PRYON=$2
ROOT=$3

if "$AFE" --lib /lib/x86_64-linux-gnu/libc.so.6 --cfg test.cfg </dev/zero >/dev/null 2>&1; then
  echo 'AFE unexpectedly accepted libc.so.6' >&2
  exit 1
fi
if "$PRYON" --lib /lib/x86_64-linux-gnu/libc.so.6 --wakeword alexa --models-dir "$ROOT" </dev/zero >/dev/null 2>&1; then
  echo 'Pryon unexpectedly accepted libc.so.6' >&2
  exit 1
fi
