#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
OUT=${PRYON_AFE_EXTERNAL:-$ROOT/.external}/audio
BASE=https://raw.githubusercontent.com/zserge/microwakeword/bfaf3840114e/testdata
trap 'rm -f "$OUT"/*.tmp.$$' EXIT INT TERM
verify_sha256() {
  expected=$1 file=$2
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    [ "$(shasum -a 256 "$file" | awk '{print $1}')" = "$expected" ]
  else
    echo 'testdata: missing SHA-256 tool (Linux: coreutils; macOS: shasum is built in)' >&2
    exit 1
  fi
}
download() {
  name=$1 hash=$2 target=$OUT/$1 tmp=$OUT/$1.tmp.$$
  if [ -s "$target" ] && verify_sha256 "$hash" "$target"; then return; fi
  mkdir -p "$OUT"
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 "$BASE/$name" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then wget -O "$tmp" "$BASE/$name"
  else echo 'testdata: missing curl or wget (Linux: sudo apt install curl; macOS: brew install curl)' >&2; exit 1; fi
  verify_sha256 "$hash" "$tmp"
  mv "$tmp" "$target"
}
download alexa.wav b920ecbef3e15e86edc8a9a652ad0d11e92a0cd26bce1cd6283d8adbb11609e8
download nowake.wav 1fa865a424e9f10bc9adfda336069bae8bbe5236e524ad7653302eee05769b9e
echo "Test audio available in: $OUT"
