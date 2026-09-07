#!/bin/sh
set -eu

BUILD=$1
ROOT=$2
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

generate_input() {
  python3 -c 'import sys; sys.stdout.buffer.write(b"\x01\x00\x00" * (9 * 320 * 20))'
}

run_example() {
  name=$1
  shift
  if ! generate_input | (cd "$ROOT" && AFE="$BUILD/afe" PRYON="$BUILD/pryon" PRYON_MODELS_DIR="$ROOT/tests/fixtures/models" ASP_LIB="$BUILD/libasp-mock.so" PRYON_LIB="$BUILD/libpryon-mock.so" PRYON_MOCK_FORCE_DETECT=1 "$@") | grep -q 'pryon_alexa'; then
    echo "example failed: $name" >&2
    exit 1
  fi
}

run_example bash sh examples/bash/pryon_afe.sh
run_example python python3 examples/python/pryon_afe.py
run_example go sh -c 'cd examples/go && go run .'
