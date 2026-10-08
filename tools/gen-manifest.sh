#!/bin/sh
# Regenerates the download manifests from the files in the repository:
#   manifest.txt              every file under src/ (what the installer and `shulker update` fetch)
#   packages/index.txt        one line per package (from packages/descriptions.txt)
#   packages/<name>/PKG       the files of each package
# Run it after changing anything under src/ or packages/ (CI checks it's up to date).
set -e
cd "$(dirname "$0")/.."
version=$(cat src/VERSION)
# the swarm main node serves the installer to its workers: keep its copy current
cp install.sh src/share/install.sh

{
	echo "version $version"
	(cd src && find . -type f ! -name '*.tmp' | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
		printf '%s %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$f"
	done)
} > manifest.txt

# everything in one download for the installer (one TLS handshake instead of one per file, which
# matters on OC2's emulated CPU); deterministic so CI can check it is current. The installer still
# checks every file in it against manifest.txt.
tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf bundle.tar -C src .

: > packages/index.txt
while read -r name pver desc; do
	[ -d "packages/$name" ] || { echo "no packages/$name" >&2; exit 1; }
	echo "$name $pver $desc" >> packages/index.txt
	{
		echo "version $pver"
		echo "description $desc"
		(cd "packages/$name" && find . -type f ! -name PKG | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
			printf 'file %s %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$f"
		done)
	} > "packages/$name/PKG"
done < packages/descriptions.txt
echo "bundle.tar: $(du -k bundle.tar | cut -f1) KB; manifest.txt: $(($(wc -l < manifest.txt) - 1)) files, $(awk 'NR > 1 {s += $2} END {print s}' manifest.txt) bytes; $(wc -l < packages/index.txt) packages"
