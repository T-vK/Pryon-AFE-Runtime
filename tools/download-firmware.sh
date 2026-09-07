#!/bin/sh
set -eu
DEFAULT_URL=https://d1s31zyz7dcc2d.cloudfront.net/2026/8/3/f49aaff7-dd63-4d9c-9e9a-c17498267de5/update-kindle-biscuit_puffin-NS6574_user_7623_0013121734532.bin
DEFAULT_SHA256=64ab6d2dd85f8093abdd62c275d229c7e9fdd68e4d46892b48bdbd1d100d46d8
URL=${1:-$DEFAULT_URL}
OUT=${2:-firmware-extracted}
SHA256=${3:-${FIRMWARE_SHA256:-}}
if [ "$URL" = "$DEFAULT_URL" ] && [ -z "$SHA256" ]; then SHA256=$DEFAULT_SHA256; fi
if [ -z "$SHA256" ]; then
  echo 'firmware: custom URLs require a SHA-256 checksum as the third argument' >&2
  exit 2
fi
WORK=${TMPDIR:-/tmp}/pryon-afe-firmware.$$
STAGE="$OUT.tmp.$$"
rm -rf "$STAGE"
trap 'rm -rf "$WORK" "$STAGE"' EXIT INT TERM
mkdir -p "$WORK" "$STAGE/images" "$STAGE/system_root"
ARCHIVE="$WORK/update.bin"
if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then wget -O "$ARCHIVE" "$URL"
else echo 'firmware: missing dependency: curl or wget' >&2; echo '  Linux: sudo apt install curl' >&2; echo '  macOS: brew install curl' >&2; exit 1; fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null
command -v unzip >/dev/null 2>&1 || { echo 'firmware: missing dependency: unzip' >&2; echo '  Linux: sudo apt install unzip' >&2; echo '  macOS: brew install unzip' >&2; exit 1; }
unzip -q "$ARCHIVE" -d "$WORK/ota"
test -f "$WORK/ota/payload.bin" || { echo 'firmware: OTA has no payload.bin' >&2; exit 1; }
PAYLOAD_DUMPER=${PAYLOAD_DUMPER:-payload-dumper-go}
if ! command -v "$PAYLOAD_DUMPER" >/dev/null 2>&1; then
  if command -v go >/dev/null 2>&1; then
    # This is an untagged upstream module; pin the exact audited commit and
    # install only into the temporary workspace, never into the host PATH.
    PAYLOAD_DUMPER_VERSION=${PAYLOAD_DUMPER_VERSION:-v0.0.0-20210623033701-412e5a9dd12f}
    mkdir -p "$WORK/bin"
    GOBIN="$WORK/bin" go install "github.com/ssut/payload-dumper-go@$PAYLOAD_DUMPER_VERSION"
    PAYLOAD_DUMPER="$WORK/bin/payload-dumper-go"
  else
    echo 'firmware: missing dependency: payload-dumper-go or Go' >&2
    echo '  Linux: sudo apt install golang-go' >&2
    echo '  macOS: brew install go' >&2
    echo 'Set PAYLOAD_DUMPER to an existing pinned payload-dumper-go binary, or install Go.' >&2
    exit 1
  fi
fi
"$PAYLOAD_DUMPER" -o "$WORK/images" "$WORK/ota/payload.bin"
cp -a "$WORK/ota/." "$STAGE/"
find "$WORK/images" -maxdepth 1 -type f -name '*.img' -exec cp -f {} "$STAGE/images/" \;
SYSTEM_IMG="$STAGE/images/system.img"
test -f "$SYSTEM_IMG" || { echo "firmware: system.img was not produced" >&2; exit 1; }
if command -v debugfs >/dev/null 2>&1; then
  debugfs -R "rdump / $STAGE/system_root" "$SYSTEM_IMG" >/dev/null 2>&1
elif command -v 7z >/dev/null 2>&1; then
  7z x -y "$SYSTEM_IMG" "-o$STAGE/system_root" >/dev/null
else
  echo 'firmware: missing dependency: debugfs or 7z' >&2
  echo '  Linux: sudo apt install e2fsprogs (or p7zip-full)' >&2
  echo '  macOS: brew install e2fsprogs p7zip' >&2
  exit 1
fi
printf '{\n  "firmware_url": "%s",\n  "firmware_sha256": "%s",\n  "payload_dumper": "%s",\n  "files": {\n    "system_img_sha256": "%s",\n    "libasp_sha256": "%s",\n    "libpryon_sha256": "%s",\n    "afe_cfg_sha256": "%s"\n  }\n}\n' \
  "$URL" "$SHA256" "${PAYLOAD_DUMPER_VERSION:-external}" \
  "$(sha256sum "$SYSTEM_IMG" | awk '{print $1}')" \
  "$(sha256sum "$STAGE/system_root/system/lib/libasp.so" | awk '{print $1}')" \
  "$(sha256sum "$STAGE/system_root/system/lib/libpryon.so" | awk '{print $1}')" \
  "$(sha256sum "$STAGE/system_root/system/vendor/etc/audio-algorithms/AFE.cfg" | awk '{print $1}')" \
  > "$STAGE/manifest.json"
rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "Firmware extracted to: $OUT"
echo "System root:          $OUT/system_root"
echo "Pryon library:        $OUT/system_root/system/lib/libpryon.so"
echo "ASP library:          $OUT/system_root/system/lib/libasp.so"
echo "AFE config:           $OUT/system_root/system/vendor/etc/audio-algorithms/AFE.cfg"
