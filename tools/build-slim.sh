#!/bin/sh
# Builds the slim system image that `shulker mkdisk` writes onto blank 8 MB drives:
#   stock Sedna (from OC2's sedna-buildroot jar)
#   - MicroPython and the tcc C compiler (about 650 KB, unused by Shulker OS)
#   + the Shulker Linux kernel (RAID, ext4) from linux/dist/Image
#   + mdadm (from packages/mdadm)
#   no reserved blocks (only root uses these drives)
# Shulker OS itself is not in it: mkdisk copies the maker's own, current copy onto each drive.
#
#   tools/build-slim.sh [--sedna DIR]   -> linux/dist/sedna-slim.img.gz, line in linux/dist/SHA256SUMS
set -e
cd "$(dirname "$0")/.."
SEDNA=work/sedna
[ "$1" = --sedna ] && SEDNA=$2
[ -f "$SEDNA/rootfs.ext2" ] || tools/fetch-sedna.sh "$SEDNA"
[ -f linux/dist/Image ] || { echo "linux/dist/Image is missing: run tools/build-linux.sh" >&2; exit 1; }
B=dist/build-slim
rm -rf "$B"
mkdir -p "$B"
IMG=$B/sedna-slim.img
cp "$SEDNA/rootfs.ext2" "$IMG"
gunzip -c packages/mdadm/lib/mdadm.gz > "$B/mdadm"
{
	echo "rm /usr/bin/micropython"
	echo "rm /usr/bin/tcc"
	for f in $(debugfs -R "ls /usr/lib/tcc/include" "$IMG" 2>/dev/null | tr -s ' ' '\n' | grep '\.h$'); do
		echo "rm /usr/lib/tcc/include/$f"
	done
	echo "rmdir /usr/lib/tcc/include"
	echo "rmdir /usr/lib/tcc"
	echo "rm /boot/Image"
	echo "write linux/dist/Image /boot/Image"
	echo "write $B/mdadm /usr/sbin/mdadm"
	echo "set_inode_field /usr/sbin/mdadm mode 0100755"
	echo "ssv r_blocks_count 0"
} > "$B/cmds"
debugfs -w -f "$B/cmds" "$IMG" > "$B/debugfs.log" 2>&1
if grep -qi "could not\|no space\|not found\|error" "$B/debugfs.log"; then cat "$B/debugfs.log" >&2; exit 1; fi
e2fsck -fy "$IMG" > "$B/fsck.log" 2>&1 || [ $? -le 1 ] || { cat "$B/fsck.log" >&2; exit 1; }
e2fsck -fn "$IMG" > "$B/fsck2.log" 2>&1 || { cat "$B/fsck2.log" >&2; echo "the image does not pass e2fsck" >&2; exit 1; }
free=$(debugfs -R stats "$IMG" 2>/dev/null | awk -F: '/^Free blocks/ {gsub(/ /, "", $2); print $2}')
SUM=$(sha256sum "$IMG" | cut -d' ' -f1)
gzip -9nc "$IMG" > linux/dist/sedna-slim.img.gz
touch linux/dist/SHA256SUMS
grep -v ' sedna-slim.img$' linux/dist/SHA256SUMS > "$B/sums" || true
echo "$SUM  sedna-slim.img" >> "$B/sums"
cp "$B/sums" linux/dist/SHA256SUMS
echo "slim image: $(du -k linux/dist/sedna-slim.img.gz | cut -f1) KB compressed, $free KB free inside (before Shulker OS)"
