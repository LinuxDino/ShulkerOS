#!/bin/sh
# Shulker OS installer for Sedna Linux (OpenComputers II).
#
#   wget -qO- https://raw.githubusercontent.com/LinuxDino/ShulkerOS/main/install.sh | sh
#   ... | sh -s -- --branch NAME        install another branch
#
# Downloads every file listed in manifest.txt to /tmp, checks its SHA-256 sum and the free disk
# space, and only then installs to /opt/shulker plus a login profile, a boot script and branding.
# Running it again updates in place; your tasks, jobs and API key (~/.shulker) are never touched.
set -u

REPO=${SHULKER_REPO:-https://raw.githubusercontent.com/LinuxDino/ShulkerOS}
BRANCH=${SHULKER_BRANCH:-main}
PREFIX=${SHULKER_PREFIX:-/opt/shulker}
while [ $# -gt 0 ]; do
	case "$1" in
		--branch) BRANCH=$2; shift ;;
		--prefix) PREFIX=$2; shift ;;
		--repo) REPO=$2; shift ;;
		*) echo "usage: install.sh [--branch NAME] [--prefix DIR]"; exit 1 ;;
	esac
	shift
done
BASE="$REPO/$BRANCH"
STAGE=/tmp/shulker-install.$$

if [ -t 1 ]; then P=$(printf '\033[35m') L=$(printf '\033[95m') G=$(printf '\033[92m') Rd=$(printf '\033[91m') N=$(printf '\033[0m'); else P= L= G= Rd= N=; fi
say() { echo "${P}::${N} $*"; }
die() { echo "${Rd}error:${N} $*" >&2; rm -rf "$STAGE"; exit 1; }

for t in wget sha256sum lua awk df; do
	command -v $t >/dev/null 2>&1 || die "$t is missing (this installer is for Sedna Linux)"
done
[ "$(id -u)" = 0 ] || die "run this as root"

say "Installing ${L}Shulker OS${N} from $BASE"

mkdir -p "$STAGE" || die "cannot create $STAGE"
wget -q -T 30 -O "$STAGE/manifest.txt" "$BASE/manifest.txt" 2>"$STAGE/wget.err" ||
	die "could not download $BASE/manifest.txt. Is the network up? (netcfg auto; netcfg test)"
version=$(awk '$1 == "version" {print $2; exit}' "$STAGE/manifest.txt")
count=$(awk 'NF == 3 && length($1) == 64' "$STAGE/manifest.txt" | wc -l)
bytes=$(awk 'NF == 3 && length($1) == 64 {s += $2} END {print s + 0}' "$STAGE/manifest.txt")
[ "$count" -gt 0 ] || die "the manifest lists no files"

# disk space: the files (rounded up to 1 KB blocks) plus 64 KB to spare
need=$(awk 'NF == 3 && length($1) == 64 {s += int(($2 + 1023) / 1024) + 1} END {print s + 64}' "$STAGE/manifest.txt")
target=$(dirname "$PREFIX"); while [ ! -d "$target" ]; do target=$(dirname "$target"); done
free=$(df -k "$target" | awk 'NR > 1 {v = $(NF - 2)} END {print v + 0}')
[ "$free" -ge "$need" ] || die "not enough disk space on $target: need $need KB, $free KB free"
say "version $version: $count files, $((bytes / 1024)) KB ($free KB free)"

awk 'NF == 3 && length($1) == 64' "$STAGE/manifest.txt" > "$STAGE/files"
mkdir -p "$STAGE/src"
# one download with everything (fast on OC2's slow CPU); any file that is missing from it or
# doesn't match the manifest is fetched on its own below
if wget -q -T 60 -O "$STAGE/bundle.tar" "$BASE/bundle.tar" 2>"$STAGE/wget.err" &&
	tar -xf "$STAGE/bundle.tar" -C "$STAGE/src" 2>/dev/null; then
	say "downloaded the bundle, checking every file"
fi
rm -f "$STAGE/bundle.tar"
i=0
while read -r sum size path; do
	i=$((i + 1))
	case "$path" in /*|*..*) die "unsafe path in manifest: $path" ;; esac
	[ -t 1 ] && printf '\r   %d/%d %s\033[K' "$i" "$count" "$path"
	if [ -f "$STAGE/src/$path" ] && [ "$(sha256sum "$STAGE/src/$path" | cut -d' ' -f1)" = "$sum" ]; then
		continue
	fi
	mkdir -p "$STAGE/src/$(dirname "$path")"
	ok=0
	for try in 1 2 3; do
		# BusyBox wget notes on every HTTPS download that it can't verify certificates: keep quiet
		if wget -q -T 30 -O "$STAGE/src/$path" "$BASE/src/$path" 2>"$STAGE/wget.err"; then ok=1; break; fi
		sleep $try
	done
	[ $ok = 1 ] || die "download failed: $path ($(grep -v 'certificate validation' "$STAGE/wget.err" | head -n 1))"
	got=$(sha256sum "$STAGE/src/$path" | cut -d' ' -f1)
	[ "$got" = "$sum" ] || die "checksum mismatch for $path (the download was damaged; try again)"
done < "$STAGE/files"
# only what the manifest lists gets installed
(cd "$STAGE/src" && find . -type f | sed 's|^\./||') | while read -r f; do
	grep -q " $f\$" "$STAGE/files" || rm -f "$STAGE/src/$f"
done
[ -t 1 ] && printf '\r\033[K'
say "all files downloaded and verified"

# install: replace the files, drop ones that are no longer part of Shulker OS
mkdir -p "$PREFIX" || die "cannot create $PREFIX"
if [ -f "$PREFIX/manifest.txt" ]; then
	awk 'NF == 3 && length($1) == 64 {print $3}' "$PREFIX/manifest.txt" | while read -r old; do
		grep -q " $old\$" "$STAGE/files" || rm -f "$PREFIX/$old"
	done
fi
cp -r "$STAGE/src/." "$PREFIX/" || die "copying to $PREFIX failed (disk full?)"
cp "$STAGE/manifest.txt" "$PREFIX/manifest.txt"
chmod 755 "$PREFIX"/bin/* "$PREFIX/etc/rc.shulker"
sync

# system integration
mkdir -p /etc/shulker/crontabs /etc/profile.d
[ -f /etc/shulker/repo.conf ] || printf 'repo=%s\nbranch=%s\n' "$REPO" "$BRANCH" > /etc/shulker/repo.conf
sed -i "s|^branch=.*|branch=$BRANCH|" /etc/shulker/repo.conf
cp "$PREFIX/etc/profile.sh" /etc/profile.d/shulker.sh
cp "$PREFIX/etc/rc.shulker" /etc/init.d/S95shulker && chmod 755 /etc/init.d/S95shulker
if [ ! -f /etc/shulker/no-branding ]; then
	cp "$PREFIX/share/issue" /etc/issue
	cp "$PREFIX/share/motd" /etc/motd
fi
pidof crond >/dev/null 2>&1 || crond -b -c /etc/shulker/crontabs -L /tmp/crond.log
rm -rf "$STAGE"
sync

echo
say "${G}Shulker OS $version is installed${N} in $PREFIX ($(du -sk "$PREFIX" | cut -f1) KB)."
echo "   Log out and back in (or run: ${L}. /etc/profile${N}), then try:"
echo "     ${L}shulkerfetch${N}   ${L}claude${N}   ${L}task${N}   ${L}man intro${N}"
echo "   Update later with: ${L}shulker update${N}"
