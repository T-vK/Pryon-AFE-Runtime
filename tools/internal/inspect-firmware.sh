#!/bin/sh
set -eu
ROOT=${1:-}
test -n "$ROOT" && test -d "$ROOT" || { echo "usage: $0 SYSTEM_ROOT" >&2; exit 2; }
for file in "$ROOT/system/lib/libasp.so" "$ROOT/system/lib/libpryon.so" "$ROOT/system/vendor/etc/audio-algorithms/AFE.cfg"; do
  echo "--- $file"
  test -f "$file" || { echo 'missing'; continue; }
  file "$file"
  case "$file" in
    *.so) readelf -d "$file" 2>/dev/null | sed -n '/NEEDED/p'; nm -D --defined-only "$file" 2>/dev/null | rg 'CreateAFE|asp_|Pryon(Api|Decoder|ModelSet)' || true;;
  esac
done
