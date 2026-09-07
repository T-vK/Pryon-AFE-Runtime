#!/bin/sh
set -eu
BUILD=${1:-build}; OUT=${2:-dist}; VERSION=${3:-}
test -n "$VERSION" || { echo 'usage: package.sh BUILD OUT VERSION' >&2; exit 2; }
rm -rf "$OUT"
mkdir -p "$OUT"

release_files() {
  build_dir=$1; include_mocks=$2; suffix=$3
  cp "$build_dir/afe" "$OUT/afe$suffix"
  cp "$build_dir/pryon" "$OUT/pryon$suffix"
  (cd "$OUT" && sha256sum "afe$suffix" > "afe$suffix.sha256")
  (cd "$OUT" && sha256sum "pryon$suffix" > "pryon$suffix.sha256")
  if [ "$include_mocks" = 1 ]; then
    cp "$build_dir/libasp-mock.so" "$OUT/libasp-mock$suffix.so"
    cp "$build_dir/libpryon-mock.so" "$OUT/libpryon-mock$suffix.so"
    (cd "$OUT" && sha256sum "libasp-mock$suffix.so" > "libasp-mock$suffix.so.sha256")
    (cd "$OUT" && sha256sum "libpryon-mock$suffix.so" > "libpryon-mock$suffix.so.sha256")
  fi
}

test -x "$BUILD/afe" || { echo "package: missing $BUILD/afe; run make build first" >&2; exit 1; }
release_files "$BUILD" 1 -testing
[ -x build-android/afe ] && release_files build-android 0 '' || true
echo "Created individual release files in $OUT"
