#!/bin/sh
set -eu

ROOT=${1:-}
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo 'usage: validate-firmware.sh SYSTEM_ROOT' >&2
  exit 2
fi
command -v readelf >/dev/null 2>&1 || {
  echo 'firmware validation: missing dependency: readelf' >&2
  echo '  Linux: sudo apt install binutils' >&2
  echo '  macOS: brew install binutils (then set PATH so greadelf is available)' >&2
  exit 1
}
command -v nm >/dev/null 2>&1 || {
  echo 'firmware validation: missing dependency: nm' >&2
  echo '  Linux: sudo apt install binutils' >&2
  echo '  macOS: Xcode Command Line Tools or brew install binutils' >&2
  exit 1
}

test -x "$ROOT/system/bin/linker" || { echo "missing Android linker: $ROOT/system/bin/linker" >&2; exit 1; }
test -r "$ROOT/system/vendor/etc/audio-algorithms/AFE.cfg" || { echo 'missing AFE.cfg' >&2; exit 1; }
find "$ROOT/system/local/models/keyword" -name pryon.manifest -type f -print -quit 2>/dev/null | grep -q . || {
  echo 'no Pryon model manifest found below system/local/models/keyword' >&2
  exit 1
}

for lib in libasp.so libpryon.so; do
  path="$ROOT/system/lib/$lib"
  test -r "$path" || { echo "missing $path" >&2; exit 1; }
  file "$path" | grep -Eq 'ELF 32-bit.*ARM' || { echo "$lib is not an ARMv7 ELF" >&2; exit 1; }
  echo "[$lib] $path"
  case "$lib" in
    libasp.so) symbols='asp_process asp_parameterized_init asp_create_pipeline asp_destroy_pipeline asp_deinit' ;;
    libpryon.so) symbols='PryonDecoder_PushAudioEventSamples PryonApi_SetDecodeEventCallback PryonApi_GetDecodeEventCallbackVersion PryonDecoder_Delete PryonModelSet_Delete' ;;
  esac
  exports=$(nm -D --defined-only "$path" 2>/dev/null || true)
  for symbol in $symbols; do
    echo "$exports" | awk '{print $3}' | grep -Fxq "$symbol" || {
      echo "missing required export: $lib:$symbol" >&2
      exit 1
    }
  done
  if [ "$lib" = libpryon.so ]; then
    echo "$exports" | awk '{print $3}' | grep -Eq 'PryonModelSet_New(Simple)?' || { echo 'missing model-set constructor' >&2; exit 1; }
    echo "$exports" | awk '{print $3}' | grep -Eq 'PryonDecoder_New(Simple|PcmInt16)' || { echo 'missing decoder constructor' >&2; exit 1; }
  fi
  deps=$(readelf -d "$path" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  for dep in $deps; do
    find "$ROOT/system" -type f -name "$dep" -print -quit | grep -q . || {
      echo "missing dependency for $lib: $dep" >&2
      exit 1
    }
  done
done
echo 'static firmware validation passed; no proprietary code was copied into the project'
