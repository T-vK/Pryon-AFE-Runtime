#!/bin/sh
set -eu
BIN=$1
"$BIN" --list | grep -q 'pryon_alexa'
head -c 12800 /dev/zero | "$BIN" --format json |
  grep -Eq '^\{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0\.99,"kwSampleStartIndex":4800,"kwSampleEndIndex":5120\}$'
if head -c 12800 /dev/zero | "$BIN" --format json --include-certainty >/dev/null 2>&1; then
  echo 'certainty unexpectedly exposed' >&2
  exit 1
fi
head -c 12800 /dev/zero | "$BIN" --format json --include-near-misses |
  grep -Eq '^\{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0\.99,"kwSampleStartIndex":4800,"kwSampleEndIndex":5120\}$'
if head -c 12800 /dev/zero | PRYON_MOCK_CALLBACK_VERSION=2 "$BIN" >/dev/null 2>&1; then
  echo 'unsupported callback version unexpectedly accepted' >&2
  exit 1
fi
