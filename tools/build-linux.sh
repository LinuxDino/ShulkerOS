#!/bin/sh
# Builds Shulker Linux: fnuecke/buildroot (branch sedna, pinned) + our external tree in linux/.
#   tools/build-linux.sh [WORKDIR]    (default work/buildroot) -> dist/shulker-linux/{rootfs.ext2,Image}
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BR=${1:-work/buildroot}
COMMIT=4118cfeb8b765e45baa4944db330f4e16bcd1a0c
if [ ! -d "$BR/.git" ]; then
	git clone -q --depth 1 -b sedna https://github.com/fnuecke/buildroot "$BR"
fi
[ "$(git -C "$BR" rev-parse HEAD)" = "$COMMIT" ] || echo "note: buildroot is not at the pinned commit $COMMIT"
tools/gen-manifest.sh >/dev/null
cd "$BR"
make BR2_EXTERNAL="$ROOT/linux" sedna-riscv64_defconfig >/dev/null
support/kconfig/merge_config.sh -m .config "$ROOT/linux/buildroot.fragment" >/dev/null
make BR2_EXTERNAL="$ROOT/linux" olddefconfig >/dev/null
FORCE_UNSAFE_CONFIGURE=1 make BR2_EXTERNAL="$ROOT/linux" -j"$(nproc)"
mkdir -p "$ROOT/dist/shulker-linux"
cp output/images/rootfs.ext2 "$ROOT/dist/shulker-linux/rootfs.ext2"
debugfs -R "dump /boot/Image $ROOT/dist/shulker-linux/Image" output/images/rootfs.ext2 2>/dev/null
(cd "$ROOT/dist/shulker-linux" && sha256sum rootfs.ext2 Image > SHA256SUMS)
echo "Shulker Linux: $ROOT/dist/shulker-linux"
