#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
OUT=${1:-release-assets}
DRAWIO=${DRAWIO:-drawio}
command -v "$DRAWIO" >/dev/null 2>&1 || {
  echo "render-diagrams: missing dependency: $DRAWIO" >&2
  echo '  Linux: install draw.io Desktop or set DRAWIO to its executable path' >&2
  echo '  macOS: brew install --cask drawio' >&2
  exit 1
}
mkdir -p "$OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd)

render() {
  name=$1
  "$DRAWIO" -x -f png -o "$OUT/$name.png" \
    "$ROOT/docs/diagrams/$name.drawio" >/dev/null 2>&1
  test -s "$OUT/$name.png" || {
    echo "render-diagrams: empty $name.png" >&2
    exit 1
  }
  echo "render-diagrams: wrote $name.png"
}

render architecture-runtime
render architecture-stock
