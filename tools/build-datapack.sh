#!/bin/sh
# Builds the Shulker OS Minecraft data pack for OpenComputers II:
#
#   dist/ShulkerOS-datapack-<version>.zip
#     pack.mcmeta
#     data/shulkeros/file_systems/shulkeros.zip (+ .json)   a /mnt/builtin layer: Shulker OS for every
#                                                           Linux computer, nothing written to its disk
#     data/shulkeros/block_devices/hdd/shulkeros.bin (+ .json)
#                                                           a "Shulker OS" hard drive: Sedna with Shulker
#                                                           OS preinstalled in /opt/shulker
#
#   tools/build-datapack.sh [--no-hdd] [--sedna DIR] [--layer-dir DIR]
#     --no-hdd      only the file system layer (small; no Sedna binaries redistributed)
#     --sedna DIR   where rootfs.ext2 is (default work/sedna; tools/fetch-sedna.sh makes it)
#     --layer-dir   also unpack the layer into DIR (for tests: mount it as /mnt/builtin)
set -e
cd "$(dirname "$0")/.."
HDD=1
SEDNA=work/sedna
LAYER_DIR=
while [ $# -gt 0 ]; do
	case "$1" in
		--no-hdd) HDD=0 ;;
		--sedna) SEDNA=$2; shift ;;
		--layer-dir) LAYER_DIR=$2; shift ;;
		*) echo "usage: $0 [--no-hdd] [--sedna DIR] [--layer-dir DIR]"; exit 1 ;;
	esac
	shift
done
VERSION=$(cat src/VERSION)
OUT=dist/ShulkerOS-datapack-$VERSION.zip
B=dist/build
rm -rf "$B"
mkdir -p "$B/layer/bin" "$B/layer/init.d" "$B/layer/shulker" "$B/pack/data/shulkeros/file_systems"

# ---- the /mnt/builtin layer: bin/ is on the PATH, init.d/S??* runs at boot
cp -r src/. "$B/layer/shulker/"
for f in src/bin/*; do
	n=$(basename "$f")
	[ "$n" = shulker-job ] && continue      # internal; crond calls it by its full path
	cp "$f" "$B/layer/bin/$n"
done
cp src/etc/rc.shulker "$B/layer/init.d/S60shulker"
chmod 755 "$B"/layer/bin/* "$B/layer/init.d/S60shulker" "$B"/layer/shulker/bin/*
(cd "$B/layer" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -q -X ../pack/data/shulkeros/file_systems/shulkeros.zip -@)
# higher order wins where layers overlap; ours only adds new paths
echo '{ "order": 10 }' > "$B/pack/data/shulkeros/file_systems/shulkeros.json"
if [ -n "$LAYER_DIR" ]; then
	mkdir -p "$LAYER_DIR"
	cp -r "$B/layer/." "$LAYER_DIR/"
fi

# ---- the preloaded hard drive
if [ "$HDD" = 1 ]; then
	[ -f "$SEDNA/rootfs.ext2" ] || tools/fetch-sedna.sh "$SEDNA"
	IMG="$B/pack/data/shulkeros/block_devices/hdd/shulkeros.bin"
	mkdir -p "$(dirname "$IMG")"
	cp "$SEDNA/rootfs.ext2" "$IMG"
	CMDS="$B/debugfs.cmds"
	: > "$CMDS"
	echo "mkdir /opt/shulker" >> "$CMDS"
	(cd src && find . -type d ! -name . | LC_ALL=C sort) | sed 's|^\./||' | while read -r d; do
		echo "mkdir /opt/shulker/$d" >> "$CMDS"
	done
	(cd src && find . -type f | LC_ALL=C sort) | sed 's|^\./||' | while read -r f; do
		echo "write src/$f /opt/shulker/$f" >> "$CMDS"
		case "$f" in bin/*|etc/rc.shulker) echo "set_inode_field /opt/shulker/$f mode 0100755" >> "$CMDS" ;; esac
	done
	cp manifest.txt "$B/manifest.txt"
	cat >> "$CMDS" <<EOF
write $B/manifest.txt /opt/shulker/manifest.txt
mkdir /etc/shulker
mkdir /etc/shulker/crontabs
write src/etc/profile.sh /etc/profile.d/shulker.sh
write src/etc/rc.shulker /etc/init.d/S95shulker
set_inode_field /etc/init.d/S95shulker mode 0100755
rm /etc/issue
write src/share/issue /etc/issue
write src/share/motd /etc/motd
EOF
	printf 'repo=https://raw.githubusercontent.com/LinuxDino/ShulkerOS\nbranch=main\n' > "$B/repo.conf"
	echo "write $B/repo.conf /etc/shulker/repo.conf" >> "$CMDS"
	debugfs -w -f "$CMDS" "$IMG" > "$B/debugfs.log" 2>&1
	if grep -qi "error\|could not\|no space\|not found" "$B/debugfs.log"; then
		cat "$B/debugfs.log" >&2
		echo "building the HDD image failed" >&2
		exit 1
	fi
	e2fsck -fn "$IMG" > "$B/fsck.log" 2>&1 || { cat "$B/fsck.log" >&2; echo "the HDD image does not pass e2fsck" >&2; exit 1; }
	echo '{ "name": "Shulker OS", "color": "purple" }' > "$(dirname "$IMG")/shulkeros.json"

	# the same drive as a swarm worker: DHCP from the main node, joins it at boot (`man swarm`)
	NODE="$(dirname "$IMG")/shulkeros-node.bin"
	cp "$IMG" "$NODE"
	printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > "$B/interfaces"
	printf '# Shulker Swarm (see `man swarm`)\nleader=10.42.0.1\nport=4242\nrole=worker\n' > "$B/swarm.conf"
	debugfs -w -f - "$NODE" > "$B/debugfs-node.log" 2>&1 <<NODECMDS
rm /etc/network/interfaces
write $B/interfaces /etc/network/interfaces
write $B/swarm.conf /etc/shulker/swarm.conf
set_inode_field /etc/shulker/swarm.conf mode 0100600
NODECMDS
	if grep -qi "error\|could not\|no space" "$B/debugfs-node.log"; then cat "$B/debugfs-node.log" >&2; exit 1; fi
	e2fsck -fn "$NODE" > "$B/fsck-node.log" 2>&1 || { cat "$B/fsck-node.log" >&2; echo "the node image does not pass e2fsck" >&2; exit 1; }
	echo '{ "name": "Shulker Swarm Node", "color": "magenta" }' > "$(dirname "$IMG")/shulkeros-node.json"
	free=$(debugfs -R stats "$IMG" 2>/dev/null | awk -F: '/^Free blocks/ {gsub(/ /, "", $2); print $2}')
	echo "hdd image: $(du -k "$IMG" | cut -f1) KB, $free KB free inside"
fi

cat > "$B/pack/pack.mcmeta" <<EOF
{
  "pack": {
    "description": "Shulker OS $VERSION for OpenComputers II: Linux with Claude built in",
    "min_format": 101,
    "max_format": 101
  }
}
EOF
cp README.md "$B/pack/README.md" 2>/dev/null || true
[ -f LICENSE ] && cp LICENSE "$B/pack/LICENSE"
mkdir -p dist
rm -f "$OUT"
(cd "$B/pack" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -q -X -9 "../../$(basename "$OUT")" -@)
echo "data pack: $OUT ($(du -k "$OUT" | cut -f1) KB)"
