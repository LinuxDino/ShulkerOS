# Shulker Linux

Our own Sedna: the same Buildroot recipe OpenComputers II builds its Linux from
([fnuecke/buildroot](https://github.com/fnuecke/buildroot), branch `sedna`, pinned to commit `4118cfeb`), plus:

- kernel: RAID (linear, raid0, raid1), ext4, overlayfs, loop devices (`board/linux.fragment`)
- `mdadm`, `tmux`, `curl` with BearSSL and the Mozilla CA bundle (HTTPS that verifies certificates)
- a 16 MB drive with Shulker OS preinstalled in `/opt/shulker`

This directory is a Buildroot external tree (`BR2_EXTERNAL`). Build with `tools/build-linux.sh` (about an hour
the first time); the result is `dist/shulker-linux/rootfs.ext2` (the drive) and `Image` (the kernel).
