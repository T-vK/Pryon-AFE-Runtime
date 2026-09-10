#!/bin/sh
set -eu

AFE=$1
ASP_MOCK=$2
TINYALSA_MOCK=$3
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

if "$AFE" --mock --card 1 </dev/null >"$TMP/out" 2>"$TMP/error"; then
  echo 'afe accepted --card without --alsa' >&2
  exit 1
fi
grep -q -- '--card and --device require --alsa' "$TMP/error"

ASP_MOCK_LIB="$ASP_MOCK" \
TINYALSA_LIB="$TINYALSA_MOCK" \
TINYALSA_MOCK_FAIL_FIRST=1 \
TINYALSA_MOCK_STATE="$TMP/state" \
  "$AFE" --mock --alsa --card 2 --device 7 2>"$TMP/alsa-error" |
  head -c 640 >"$TMP/audio"

test "$(wc -c < "$TMP/audio")" -eq 640
grep -q '^card=2 device=7 prepare=1 close=1$' "$TMP/state"
