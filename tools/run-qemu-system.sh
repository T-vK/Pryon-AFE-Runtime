#!/bin/sh
# shellcheck disable=SC1036,SC1088,SC2034,SC2125
set -eu
ROOT='' KERNEL='' BINARY='' AFE_BINARY='' PRYON_BINARY='' MODEL_DIR=/system/local/models/keyword/en-US/ALEXA MODE=afe INPUT='' STREAM_SOCKET='' TIMEOUT=${QEMU_TIMEOUT:-45} QEMU=${QEMU_SYSTEM:-qemu-system-arm} REQUIRE_EVENT=0
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT=$2; shift 2;;
    --kernel) KERNEL=$2; shift 2;;
    --binary) BINARY=$2; shift 2;;
    --afe-binary) AFE_BINARY=$2; shift 2;;
    --pryon-binary) PRYON_BINARY=$2; shift 2;;
    --model-dir) MODEL_DIR=$2; shift 2;;
    --mode) MODE=$2; shift 2;;
    --input) INPUT=$2; shift 2;;
    --stream-socket) STREAM_SOCKET=$2; shift 2;;
    --require-event) REQUIRE_EVENT=1; shift;;
    --timeout) TIMEOUT=$2; shift 2;;
    --qemu) QEMU=$2; shift 2;;
    --) shift; break;;
  *) echo "usage: $0 --root SYSTEM_ROOT --kernel ARM_KERNEL --binary BIN [--mode afe|pryon|pipeline] [--model-dir MODEL_DIR] [--input RAW_PCM] [--stream-socket SOCKET] [--require-event]" >&2; exit 2;;
  esac
done
[ -d "$ROOT/system" ] || { echo 'qemu-system: --root must contain system/' >&2; exit 2; }
[ -r "$KERNEL" ] || { echo 'qemu-system: --kernel is required' >&2; exit 2; }
[ "$MODE" = pipeline ] && { [ -x "$AFE_BINARY" ] || [ -x "$BINARY" ] || { echo 'qemu-system: --afe-binary is required for pipeline mode' >&2; exit 2; }; [ -x "$PRYON_BINARY" ] || { echo 'qemu-system: --pryon-binary is required for pipeline mode' >&2; exit 2; }; }
[ "$MODE" != pipeline ] && { [ -x "$BINARY" ] || { echo 'qemu-system: --binary must be executable' >&2; exit 2; }; }
[ -z "$INPUT" ] || [ -r "$INPUT" ] || { echo 'qemu-system: --input must be readable' >&2; exit 2; }
[ -z "$STREAM_SOCKET" ] || { [ "$MODE" = pipeline ] || { echo 'qemu-system: --stream-socket requires pipeline mode' >&2; exit 2; }; [ -z "$INPUT" ] || { echo 'qemu-system: --input and --stream-socket are mutually exclusive' >&2; exit 2; }; }
command -v "$QEMU" >/dev/null 2>&1 || { echo "qemu-system: missing dependency: $QEMU" >&2; echo '  Linux: sudo apt install qemu-system-arm' >&2; echo '  macOS: brew install qemu' >&2; exit 1; }
command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1 || { echo 'qemu-system: missing dependency: arm-linux-gnueabihf-gcc' >&2; echo '  Linux: sudo apt install gcc-arm-linux-gnueabihf' >&2; echo '  macOS: use the documented Linux toolchain or a cross-compiler container' >&2; exit 1; }
command -v cpio >/dev/null 2>&1 || { echo 'qemu-system: missing dependency: cpio' >&2; echo '  Linux: sudo apt install cpio' >&2; echo '  macOS: brew install cpio' >&2; exit 1; }
[ "$MODE" = afe ] || [ "$MODE" = pryon ] || [ "$MODE" = pipeline ] || { echo 'qemu-system: --mode must be afe, pryon, or pipeline' >&2; exit 2; }
[ "$MODE" = pipeline ] && { [ -n "$AFE_BINARY" ] || AFE_BINARY=$BINARY; }

WORK=${TMPDIR:-/tmp}/pryon-afe-runtime-system-qemu.$$
mkdir -p "$WORK/root/usr/local/bin"
if [ "${KEEP_QEMU_WORK:-0}" = 1 ]; then trap ':' EXIT INT TERM; else trap 'rm -rf "$WORK"' EXIT INT TERM; fi
mkdir -p "$WORK/root/system/bin" "$WORK/root/system/lib" "$WORK/root/system/vendor" "$WORK/root/system/etc" "$WORK/root/system/local"
mkdir -p "$WORK/root/tmp"

# Keep the initramfs below the ARM kernel's unpack limit. Start with the
# firmware services and their ELF dependency closure, then add only the
# configuration/model trees needed by the selected test.
QUEUE="$WORK/queue"
: > "$QUEUE"
add_file() {
  rel=$1
  [ -e "$ROOT/$rel" ] || return 0
  grep -Fxq "$rel" "$QUEUE" 2>/dev/null && return 0
  mkdir -p "$WORK/root/$(dirname "$rel")"
  [ -e "$WORK/root/$rel" ] || cp -a "$ROOT/$rel" "$WORK/root/$rel"
  printf '%s\n' "$rel" >> "$QUEUE"
}
find_dep() {
  name=$1
  if [ -e "$ROOT/system/lib/$name" ]; then
    printf '%s\n' "$ROOT/system/lib/$name"
    return 0
  fi
  find "$ROOT/system/lib" "$ROOT/system/vendor/lib" -name "$name" -print -quit 2>/dev/null
}
add_file system/bin/linker
for f in sh timeout dd ls sed mkdir sleep cat toybox toolbox servicemanager dbus-daemon lipc-daemon mixer; do add_file "system/bin/$f"; done
if [ "$MODE" = afe ] || [ "$MODE" = pipeline ]; then add_file system/lib/libasp.so; fi
if [ "$MODE" = pryon ] || [ "$MODE" = pipeline ]; then add_file system/lib/libpryon.so; fi
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    found=$(find_dep "$dep" || true)
    [ -n "$found" ] || continue
    add_file "${found#"$ROOT/"}"
  done <<EOF
$(arm-linux-gnueabihf-readelf -d "$ROOT/$rel" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
EOF
done < "$QUEUE"
cp -a "$ROOT/system/etc/dbus.conf" "$WORK/root/system/etc/" 2>/dev/null || true
cp -a "$ROOT/system/etc/." "$WORK/root/system/etc/" 2>/dev/null || true
cp -a "$ROOT/system/vendor/." "$WORK/root/system/vendor/" 2>/dev/null || true
mkdir -p "$WORK/root/system/vendor/etc/audio-algorithms" 2>/dev/null || true
cp -a "$ROOT/system/vendor/etc/audio-algorithms/AFE.cfg" "$WORK/root/system/vendor/etc/audio-algorithms/" 2>/dev/null || true
mkdir -p "$WORK/root/system/local/models"
cp -a "$ROOT/system/local/models/keyword" "$WORK/root/system/local/models/" 2>/dev/null || true
ln -s system "$WORK/root/etc" 2>/dev/null || true
ln -s system/vendor "$WORK/root/vendor" 2>/dev/null || true
cp "$SCRIPT_DIR/qemu-system/dbus.conf" "$WORK/root/system/etc/dbus.conf"
if [ "$MODE" = pipeline ]; then
  cp "$AFE_BINARY" "$WORK/root/usr/local/bin/afe"
  cp "$PRYON_BINARY" "$WORK/root/usr/local/bin/pryon"
else
  cp "$BINARY" "$WORK/root/usr/local/bin/$(basename "$BINARY")"
fi
[ -z "$INPUT" ] || cp "$INPUT" "$WORK/root/tmp/pryon.in"
arm-linux-gnueabihf-gcc -Os -static -s "$SCRIPT_DIR/qemu-system/init.c" -o "$WORK/root/init"
arm-linux-gnueabihf-gcc -Os -static -s "$SCRIPT_DIR/qemu-system/dbus-launcher.c" -o "$WORK/root/usr/local/bin/dbus-launcher"

cat > "$WORK/root/qemu-init.sh" <<EOF
#!/system/bin/sh
exec >/dev/console 2>&1
export ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_CACHE=/cache
export LD_LIBRARY_PATH=/system/lib:/system/lib/alexahybrid:/system/vendor/lib
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/dev/socket/dbus
export PRYON_LOG=1
if test -n "${PRYON_TRACE:-}"; then export PRYON_TRACE=1; fi
if test -n "${PRYON_DUMP_EVENTS:-}"; then export PRYON_DUMP_EVENTS=1; fi
if test -n "${PRYON_ENUMERATED:-}"; then export PRYON_ENUMERATED=1; fi
if test -n "${PRYON_JSON_TRACE:-}"; then export PRYON_JSON_TRACE=1; fi
mkdir -p /dev/socket /data/dbus /data/misc/dbus /cache /tmp
/system/bin/servicemanager >/tmp/servicemanager.log 2>&1 &
/usr/local/bin/dbus-launcher >/tmp/dbus.log 2>&1 &
sleep 2
echo "qemu-init: dbus socket: $(ls -l /dev/socket/dbus 2>/dev/null || true)"
cat /tmp/dbus.log 2>/dev/null || true
ls -l /usr/local/bin/dbus-launcher /system/bin/dbus-daemon /dev/socket 2>/dev/null || true
ps 2>/dev/null || true
/system/bin/lipc-daemon -f >/tmp/lipc.log 2>&1 &
/system/bin/mixer >/tmp/mixer.log 2>&1 &
sleep 2
cat /tmp/lipc.log /tmp/mixer.log 2>/dev/null || true
EOF
if [ "$MODE" = afe ]; then
  cat >> "$WORK/root/qemu-init.sh" <<EOF
if test -r /tmp/pryon.in; then
  dd if=/tmp/pryon.in of=/tmp/afe.in 2>/dev/null
else
  dd if=/dev/zero bs=8640 count=4 of=/tmp/afe.in 2>/dev/null
fi
"/usr/local/bin/$(basename "$BINARY")" --cfg /system/vendor/etc/audio-algorithms/AFE.cfg --lib /system/lib/libasp.so </tmp/afe.in >/tmp/afe.out
status=\$?
bytes=\$(/system/bin/toybox wc -c </tmp/afe.out)
echo "qemu-init: real AFE status \$status bytes \$bytes"
if test "\$status" = 0 && test "\$bytes" -ge 640; then
  :
else
  echo 'qemu-init: real AFE validation failed'
  exit 1
fi
EOF
elif [ "$MODE" = pryon ]; then
  cat >> "$WORK/root/qemu-init.sh" <<EOF
if test ! -r /tmp/pryon.in; then
  dd if=/dev/zero bs=640 count=20 of=/tmp/pryon.in 2>/dev/null
fi
"/usr/local/bin/$(basename "$BINARY")" --model-dir "$MODEL_DIR" --lib /system/lib/libpryon.so </tmp/pryon.in >/tmp/pryon.out
status=\$?
cat /tmp/pryon.out
echo "qemu-init: real Pryon status \$status"
if test "\$status" = 0; then
  :
else
  echo 'qemu-init: real Pryon validation failed'
  exit 1
fi
EOF
elif [ "$MODE" = pipeline ] && [ -n "$STREAM_SOCKET" ]; then
  cat >> "$WORK/root/qemu-init.sh" <<EOF
echo 'qemu-init: waiting for host audio stream on /dev/vport0p1'
test -e /dev/vport0p1 || { echo 'qemu-init: virtio audio port /dev/vport0p1 is missing'; exit 1; }
/usr/local/bin/afe --cfg /system/vendor/etc/audio-algorithms/AFE.cfg --lib /system/lib/libasp.so < /dev/vport0p1 | /usr/local/bin/pryon --model-dir "$MODEL_DIR" --lib /system/lib/libpryon.so
status=\$?
echo "qemu-init: live pipeline status \$status"
test "\$status" = 0 || exit 1
EOF
else
  cat >> "$WORK/root/qemu-init.sh" <<EOF
if test ! -r /tmp/pryon.in; then
  echo 'qemu-init: pipeline mode requires --input 9-channel S24_3LE'
  exit 1
fi
/usr/local/bin/afe --cfg /system/vendor/etc/audio-algorithms/AFE.cfg --lib /system/lib/libasp.so </tmp/pryon.in >/tmp/afe.out
afe_status=\$?
echo "qemu-init: real AFE status \$afe_status bytes \$(/system/bin/toybox wc -c </tmp/afe.out)"
/usr/local/bin/pryon --model-dir "$MODEL_DIR" --lib /system/lib/libpryon.so </tmp/afe.out >/tmp/pryon.out
pryon_status=\$?
cat /tmp/pryon.out
echo "qemu-init: real pipeline status afe=\$afe_status pryon=\$pryon_status"
if test "\$afe_status" = 0 && test "\$pryon_status" = 0; then
  :
else
  echo 'qemu-init: real pipeline validation failed'
  exit 1
fi
EOF
fi
if test "$REQUIRE_EVENT" = 1; then
  cat >> "$WORK/root/qemu-init.sh" <<'EOF'
events=$(cat /tmp/pryon.out 2>/dev/null || true)
case "$events" in
  *'"type":"accepted"'*) : ;;
  *)
  echo 'qemu-init: confirmed wake event not observed'
  exit 1
  ;;
esac
echo 'qemu-init: confirmed wake event observed'
EOF
fi
cat >> "$WORK/root/qemu-init.sh" <<'EOF'
echo 'qemu-init: real validation passed'
exit 0
EOF
chmod 0755 "$WORK/root/init" "$WORK/root/qemu-init.sh" "$WORK/root/usr/local/bin/dbus-launcher"
(
  cd "$WORK/root"
  find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -1 > "$WORK/initramfs.cpio.gz"
)
LOG="$WORK/qemu.log"
set +e
if [ "$TIMEOUT" = 0 ]; then
  if [ -n "$STREAM_SOCKET" ]; then
    "$QEMU" -M virt,gic-version=2,highmem=off -cpu cortex-a7 -m 512 \
      -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio.gz" \
      -append 'console=ttyAMA0 rdinit=/init' -display none -monitor none -serial stdio -no-reboot \
      -chardev "socket,id=hostaudio,path=$STREAM_SOCKET,server=on,wait=off" \
      -device virtio-serial-device -device virtserialport,chardev=hostaudio,name=audio 2>&1 | tee "$LOG"
  else
    "$QEMU" -M virt,gic-version=2,highmem=off -cpu cortex-a7 -m 512 \
      -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio.gz" \
      -append 'console=ttyAMA0 rdinit=/init' -nographic -no-reboot >"$LOG" 2>&1
  fi
else
  if [ -n "$STREAM_SOCKET" ]; then
    timeout "$((TIMEOUT + 15))" "$QEMU" -M virt,gic-version=2,highmem=off -cpu cortex-a7 -m 512 \
      -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio.gz" \
      -append 'console=ttyAMA0 rdinit=/init' -display none -monitor none -serial stdio -no-reboot \
      -chardev "socket,id=hostaudio,path=$STREAM_SOCKET,server=on,wait=off" \
      -device virtio-serial-device -device virtserialport,chardev=hostaudio,name=audio >"$LOG" 2>&1
  else
    timeout "$((TIMEOUT + 15))" "$QEMU" -M virt,gic-version=2,highmem=off -cpu cortex-a7 -m 512 \
      -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio.gz" \
      -append 'console=ttyAMA0 rdinit=/init' -nographic -no-reboot >"$LOG" 2>&1
  fi
fi
qstatus=$?
set -e
[ -r "$LOG" ] && cat "$LOG" || true
if [ -n "$STREAM_SOCKET" ] && { [ "$qstatus" = 124 ] || [ "$qstatus" = 130 ] || [ "$qstatus" = 143 ]; }; then
  exit 130
fi
[ -r "$LOG" ] && grep -q 'qemu-init: real validation passed' "$LOG" || { echo "qemu-system: validation failed (QEMU status $qstatus)" >&2; exit 1; }
echo "qemu-system: real $MODE validation passed"
