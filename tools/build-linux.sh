#!/bin/sh
# Builds Shulker Linux: fnuecke/buildroot (branch sedna, pinned) + our external tree in linux/.
#   tools/build-linux.sh [WORKDIR]    (default work/buildroot) -> linux/dist/{Image,rootfs.ext2.gz,SHA256SUMS} (what `shulker linux` downloads)
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
# git:// (repo.or.cz) is often blocked: fetch tinycc over HTTPS from its GitHub mirror
FORCE_UNSAFE_CONFIGURE=1 make BR2_EXTERNAL="$ROOT/linux" TINYCC_SITE=https://github.com/TinyCC/tinycc.git -j"$(nproc)"
OUT="$ROOT/linux/dist"
mkdir -p "$OUT"
debugfs -R "dump /boot/Image $OUT/Image" output/images/rootfs.ext2 2>/dev/null
cp output/images/rootfs.ext2 "$OUT/rootfs.ext2"
(cd "$OUT" && sha256sum Image rootfs.ext2 > SHA256SUMS && gzip -9nf rootfs.ext2)
echo "Shulker Linux: $OUT"
ls -l "$OUT"
