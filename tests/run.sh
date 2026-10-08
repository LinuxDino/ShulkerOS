#!/bin/sh
# Runs the Shulker OS tests.
#   tests/run.sh            syntax checks, manifest check, host unit tests
#   tests/run.sh --qemu     also boot the real Sedna Linux in QEMU and test the installer, the
#                           data pack layer and the preloaded HDD image against the mock API
# Needs: lua5.4 (+ luac5.4), sha256sum; for --qemu also qemu-system-riscv64, debugfs/e2fsck,
# zip, openssl, curl and python3 with pexpect.
set -e
cd "$(dirname "$0")/.."
echo "== syntax"
for f in src/lib/shulker/*.lua src/bin/* packages/*/bin/* tests/unit.lua tools/*.lua; do
	case "$(head -c 40 "$f")" in
		*/bin/sh*) sh -n "$f" ;;
		*) luac5.4 -p "$f" ;;
	esac
done
sh -n install.sh src/etc/rc.shulker src/etc/profile.sh tools/*.sh
echo "ok"

echo "== manifests up to date"
before=$(cat manifest.txt bundle.tar packages/index.txt packages/*/PKG | sha256sum)
tools/gen-manifest.sh >/dev/null
if [ "$before" != "$(cat manifest.txt bundle.tar packages/index.txt packages/*/PKG | sha256sum)" ]; then
	echo "manifest.txt or packages/*/PKG were stale (now regenerated): commit them"
	exit 1
fi
echo "ok"

echo "== unit tests"
lua5.4 tests/unit.lua
SHULKER_PURE_JSON=1 lua5.4 tests/unit.lua > /dev/null

[ "$1" = "--qemu" ] || exit 0

W=work
tools/fetch-sedna.sh $W/sedna
rm -rf $W/layer $W/builtin-ci $W/builtin-dp
tools/build-datapack.sh --sedna $W/sedna --layer-dir $W/layer
# what OC2 mounts at /mnt/builtin, minus the mod's own scripts (not needed for these tests)
mkdir -p $W/builtin-ci/bin $W/builtin-ci/init.d $W/builtin-dp
cp -r $W/builtin-ci/. $W/layer/. $W/builtin-dp/
cp dist/build/pack/data/shulkeros/block_devices/hdd/shulkeros.bin $W/shulkeros.bin
tests/mock.sh start $W
trap 'tests/mock.sh stop '$W EXIT
python3 tests/qemu/test_sedna.py --sedna $W/sedna --builtin $W/builtin-ci --mode install --log $W/vm-install.log
python3 tests/qemu/test_sedna.py --sedna $W/sedna --builtin $W/builtin-dp --mode datapack --log $W/vm-datapack.log
python3 tests/qemu/test_sedna.py --sedna $W/sedna --rootfs $W/shulkeros.bin --builtin $W/builtin-ci --mode hdd --log $W/vm-hdd.log
python3 tests/qemu/test_swarm.py --sedna $W/sedna --images dist/build/pack/data/shulkeros/block_devices/hdd --workers 3 --logdir $W
