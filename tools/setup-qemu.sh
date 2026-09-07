#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
CACHE=${PRYON_AFE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pryon-afe-runtime}
FIRMWARE_OUT=${1:-$CACHE/firmware}
KERNEL_DIR=$CACHE/linux-4.14.180
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.14.180.tar.xz
KERNEL_SHA256=444ef973d9b6a6ea174e4a9086f0aea980d8575d13302e431ad688f22e27ed0e
FIRMWARE_URL=https://d1s31zyz7dcc2d.cloudfront.net/2026/8/3/f49aaff7-dd63-4d9c-9e9a-c17498267de5/update-kindle-biscuit_puffin-NS6574_user_7623_0013121734532.bin
FIRMWARE_SHA256=64ab6d2dd85f8093abdd62c275d229c7e9fdd68e4d46892b48bdbd1d100d46d8
ARCHIVE=$CACHE/linux-4.14.180.tar.xz

need_command() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "setup-qemu: missing dependency: $1" >&2
  echo "  Linux: sudo apt install $2" >&2
  echo "  macOS: brew install $3" >&2
  exit 1
}
need_command qemu-system-arm qemu-system-arm qemu
need_command arm-linux-gnueabihf-gcc gcc-arm-linux-gnueabihf 'gcc-arm-embedded (not an Android toolchain)'
need_command make build-essential make
need_command cpio cpio cpio
mkdir -p "$CACHE"

if [ ! -s "$FIRMWARE_OUT/system_root/system/lib/libasp.so" ]; then
  "$ROOT/tools/download-firmware.sh" "$FIRMWARE_URL" "$FIRMWARE_OUT" "$FIRMWARE_SHA256"
fi
"$ROOT/tools/internal/validate-firmware.sh" "$FIRMWARE_OUT/system_root" >/dev/null

if [ ! -s "$ARCHIVE" ]; then
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 "$KERNEL_URL" -o "$ARCHIVE"
  elif command -v wget >/dev/null 2>&1; then wget -O "$ARCHIVE" "$KERNEL_URL"
  else echo 'setup-qemu: curl or wget is required' >&2; exit 1; fi
fi
printf '%s  %s\n' "$KERNEL_SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null
NEED_KERNEL=0
if [ ! -s "$KERNEL_DIR/arch/arm/boot/zImage" ] ||
   [ ! -r "$KERNEL_DIR/.config" ] ||
   ! grep -q '^CONFIG_ANDROID=y$' "$KERNEL_DIR/.config" ||
   ! grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$KERNEL_DIR/.config" ||
   ! grep -q '^CONFIG_ANDROID_BINDER_IPC_32BIT=y$' "$KERNEL_DIR/.config"; then
  NEED_KERNEL=1
fi
if [ "$NEED_KERNEL" -eq 1 ]; then
  if [ ! -r "$KERNEL_DIR/Makefile" ]; then tar -xJf "$ARCHIVE" -C "$CACHE"; fi
  cd "$KERNEL_DIR"
  if [ ! -r .config ]; then
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- multi_v7_defconfig
  fi
  # The old 4.14 source does not build its unused ATA code with current GCC.
  # QEMU's virt machine does not need ATA, so leave that driver out of the
  # reproducible helper kernel.
  scripts/config --disable CONFIG_ATA
  scripts/config --disable CONFIG_SATA_AHCI
  scripts/config --enable CONFIG_ANDROID
  scripts/config --enable CONFIG_ANDROID_BINDER_IPC
  scripts/config --enable CONFIG_ANDROID_BINDER_IPC_32BIT
  scripts/config --set-str CONFIG_ANDROID_BINDER_DEVICES binder
  scripts/config --enable CONFIG_UNIX
  scripts/config --enable CONFIG_DEVTMPFS
  scripts/config --enable CONFIG_DEVTMPFS_MOUNT
  scripts/config --enable CONFIG_VFP
  scripts/config --enable CONFIG_VFPv3
  # Binutils 2.42 no longer accepts the old preprocessor spelling used by
  # this kernel's ARM section declarations.
  find arch/arm -type f \( -name '*.S' -o -name '*.s' \) -print0 |
    xargs -0 sed -i \
      -e 's/,#alloc,#execinstr/,"ax"/g' \
      -e 's/,#alloc/,"ax"/g' \
      -e 's/, #alloc, #execinstr/, "ax"/g' \
      -e 's/, #alloc/, "ax"/g'
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
    ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KCFLAGS=-march=armv7-a zImage
fi

printf '{\n  "firmware_root": "%s",\n  "firmware_sha256": "%s",\n  "kernel": "%s",\n  "kernel_sha256": "%s",\n  "tools": {\n    "qemu_system_arm": "%s",\n    "arm_compiler": "%s"\n  }\n}\n' \
  "$FIRMWARE_OUT/system_root" "$FIRMWARE_SHA256" \
  "$KERNEL_DIR/arch/arm/boot/zImage" "$KERNEL_SHA256" \
  "$(qemu-system-arm --version | head -1)" "$(arm-linux-gnueabihf-gcc --version | head -1)" \
  > "$CACHE/qemu-manifest.json"

cat > "$CACHE/qemu-env" <<EOF
QEMU_FIRMWARE_ROOT=$FIRMWARE_OUT/system_root
QEMU_KERNEL=$KERNEL_DIR/arch/arm/boot/zImage
FIRMWARE_SHA256=$FIRMWARE_SHA256
KERNEL_SHA256=$KERNEL_SHA256
EOF
echo "QEMU_FIRMWARE_ROOT=$FIRMWARE_OUT/system_root"
echo "QEMU_KERNEL=$KERNEL_DIR/arch/arm/boot/zImage"
echo "QEMU setup complete; environment: $CACHE/qemu-env"
echo "QEMU setup manifest: $CACHE/qemu-manifest.json"
