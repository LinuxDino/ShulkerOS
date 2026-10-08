#!/bin/sh
# Fetches the Sedna Linux that OC2 boots (the sedna-buildroot jar from fnuecke's Maven repository)
# and extracts the root file system image and the kernel, for tests and for building the HDD image.
#   tools/fetch-sedna.sh [DIR]      (default work/sedna) -> DIR/rootfs.ext2, DIR/Image
set -e
VERSION=${SEDNA_BUILDROOT_VERSION:-0.2.9}
DIR=${1:-work/sedna}
mkdir -p "$DIR"
JAR="$DIR/sedna-buildroot-$VERSION.jar"
if [ ! -f "$JAR" ]; then
	curl -sSfL -o "$JAR.part" "https://fnuecke.github.io/maven/li/cil/sedna/sedna-buildroot/$VERSION/sedna-buildroot-$VERSION.jar"
	mv "$JAR.part" "$JAR"
fi
unzip -p "$JAR" generated/rootfs.ext2 > "$DIR/rootfs.ext2"
debugfs -R "dump /boot/Image $DIR/Image" "$DIR/rootfs.ext2" 2>/dev/null
[ -s "$DIR/Image" ] || { echo "could not extract the kernel (is debugfs from e2fsprogs installed?)" >&2; exit 1; }
echo "Sedna $VERSION: $DIR/rootfs.ext2 ($(du -k "$DIR/rootfs.ext2" | cut -f1) KB), $DIR/Image"
