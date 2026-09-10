#!/bin/sh
set -eu
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/out"
python3 - "$TMP/fixture.bin" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("payload.bin", b"CrAU-fixture")
    archive.writestr("payload_properties.txt", "FILE_HASH=fixture\n")
PY
cat > "$TMP/bin/payload-dumper-go" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2;;
    *) INPUT=$1; shift;;
  esac
done
test -s "$INPUT"
mkdir -p "$OUT"
: > "$OUT/system.img"
EOF
cat > "$TMP/bin/debugfs" <<'EOF'
#!/bin/sh
set -eu
command=$2
destination=${command#* / }
mkdir -p "$destination/bin" "$destination/lib" \
  "$destination/vendor/etc/audio-algorithms" "$destination/local/models/keyword/en-US/ALEXA"
: > "$destination/bin/linker"
: > "$destination/lib/libasp.so"
: > "$destination/lib/libpryon.so"
: > "$destination/vendor/etc/audio-algorithms/AFE.cfg"
: > "$destination/local/models/keyword/en-US/ALEXA/pryon.manifest"
EOF
chmod +x "$TMP/bin/payload-dumper-go" "$TMP/bin/debugfs"
# Force the fixture through the same extractor selected on the development
# host. The real image extractor may return a non-zero status for skipped
# symlinks, so the production script relies on its required-file checks.
cat > "$TMP/bin/7z" <<'EOF'
#!/bin/sh
set -eu
for arg in "$@"; do
  case "$arg" in -o*) DEST=${arg#-o};; esac
done
mkdir -p "$DEST/system/bin" "$DEST/system/lib" \
  "$DEST/system/vendor/etc/audio-algorithms" \
  "$DEST/system/local/models/keyword/en-US/ALEXA"
: > "$DEST/system/bin/linker"
: > "$DEST/system/lib/libasp.so"
: > "$DEST/system/lib/libpryon.so"
: > "$DEST/system/vendor/etc/audio-algorithms/AFE.cfg"
: > "$DEST/system/local/models/keyword/en-US/ALEXA/pryon.manifest"
EOF
chmod +x "$TMP/bin/7z"
PATH="$TMP/bin:$PATH" PAYLOAD_DUMPER=payload-dumper-go \
  "$ROOT/tools/download-firmware.sh" "file://$TMP/fixture.bin" "$TMP/out" "$(sha256sum "$TMP/fixture.bin" | awk '{print $1}')" >/dev/null
test -f "$TMP/out/images/system.img"
test -f "$TMP/out/system_root/system/lib/libasp.so"
test -f "$TMP/out/system_root/system/lib/libpryon.so"
test -f "$TMP/out/system_root/system/vendor/etc/audio-algorithms/AFE.cfg"
test -s "$TMP/out/manifest.json"
