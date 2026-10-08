#!/bin/sh
# Shulker Linux post-build: Shulker OS preinstalled in /opt/shulker, branding, os-release.
set -e
TARGET_DIR="$1"
SRC="$BR2_EXTERNAL_SHULKER_PATH/../src"
mkdir -p "$TARGET_DIR/opt/shulker" "$TARGET_DIR/etc/shulker/crontabs" "$TARGET_DIR/etc/profile.d"
cp -r "$SRC/." "$TARGET_DIR/opt/shulker/"
cp "$BR2_EXTERNAL_SHULKER_PATH/../manifest.txt" "$TARGET_DIR/opt/shulker/manifest.txt"
chmod 755 "$TARGET_DIR"/opt/shulker/bin/* "$TARGET_DIR/opt/shulker/etc/rc.shulker"
cp "$SRC/etc/profile.sh" "$TARGET_DIR/etc/profile.d/shulker.sh"
cp "$SRC/etc/rc.shulker" "$TARGET_DIR/etc/init.d/S95shulker"
chmod 755 "$TARGET_DIR/etc/init.d/S95shulker"
cp "$SRC/share/issue" "$TARGET_DIR/etc/issue"
cp "$SRC/share/motd" "$TARGET_DIR/etc/motd"
printf 'repo=https://raw.githubusercontent.com/LinuxDino/ShulkerOS\nbranch=main\n' > "$TARGET_DIR/etc/shulker/repo.conf"
VERSION=$(cat "$SRC/VERSION")
cat > "$TARGET_DIR/etc/os-release" <<OSR
NAME="Shulker Linux"
VERSION="$VERSION"
ID=shulker
ID_LIKE=buildroot
PRETTY_NAME="Shulker Linux $VERSION (Sedna)"
HOME_URL="https://github.com/LinuxDino/ShulkerOS"
OSR
