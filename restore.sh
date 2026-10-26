#!/usr/bin/env bash
# Restore a Crosslink feature-net node (zebrad v15) from a chain snapshot instead of syncing from genesis.
#
#   bash restore.sh [--cache-dir DIR] [--file SNAPSHOT.tar.zst] [--yes]
#
#   --cache-dir  the [state] cache_dir from your zebrad.toml. Default is zebrad's own default:
#                ~/.cache/zebra on Linux, ~/Library/Caches/zebra on macOS.
#   --file       use a snapshot you already downloaded (its .sha256 file has to be next to it).
#   --yes        don't ask before replacing the chain data.
#
# Stop your node first. Your current chain data is moved aside (state.bak-<time>), not deleted.
# secret.seed (your node identity) is never touched.
set -euo pipefail

REPO=0xking-sol/crosslink-snapshots
ASSET=crosslink-v15-state.tar.zst
INFO=crosslink-v15-state.json
NET=crosslink_featurenet_20260929_staking3d
DBV=v31

die() { echo "error: $*" >&2; exit 1; }
say() { echo "> $*"; }

CACHE="" FILE="" YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cache-dir) [ $# -ge 2 ] || die "--cache-dir needs a path"; CACHE=$2; shift 2 ;;
        --file) [ $# -ge 2 ] || die "--file needs a path"; FILE=$2; shift 2 ;;
        --yes|-y) YES=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done

if [ -z "$CACHE" ]; then
    case "$(uname -s)" in
        Darwin) CACHE=$HOME/Library/Caches/zebra ;;
        *) CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/zebra ;;
    esac
fi
case "$CACHE" in /*) ;; *) CACHE=$(pwd)/$CACHE ;; esac
TARGET=$CACHE/$NET

for c in tar zstd; do command -v "$c" >/dev/null || die "$c isn't installed (eg apt install zstd, or brew install zstd)"; done
if command -v sha256sum >/dev/null; then SHA256="sha256sum"
elif command -v shasum >/dev/null; then SHA256="shasum -a 256"
else die "need sha256sum or shasum"; fi
[ -n "$FILE" ] || command -v curl >/dev/null || die "curl isn't installed"

# A running node would keep writing into the folders we move away. zebrad holds its database's LOCK file open
# the whole time, so check that file. Without lsof, refuse while any zebrad runs.
LOCKF=$TARGET/state/$DBV/unknowntestnet/LOCK
if command -v lsof >/dev/null; then
    if [ -e "$LOCKF" ] && lsof "$LOCKF" >/dev/null 2>&1; then die "your node is running (it has the database open), stop it first"; fi
elif pgrep -x zebrad >/dev/null 2>&1; then
    die "zebrad is running, stop your node first"
fi

mkdir -p "$CACHE"
WORK=$CACHE/.snapshot-download
if [ -z "$FILE" ]; then
    url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
        die "can't reach github.com"
    TAG=${url##*/}
    case "$url" in */releases/tag/*) ;; *) die "no snapshot release found at https://github.com/$REPO/releases" ;; esac
    BASE=https://github.com/$REPO/releases/download/$TAG
    if [ -d "$WORK" ] && [ ! -d "$WORK/$TAG" ]; then rm -rf "$WORK"; fi   # a part download of an older snapshot
    mkdir -p "$WORK/$TAG"
    FILE=$WORK/$TAG/$ASSET
    curl -fsSL --retry 5 -o "$FILE.sha256" "$BASE/$ASSET.sha256" || die "couldn't fetch the sha256 for $TAG"
    curl -fsSL --retry 5 -o "$WORK/$TAG/$INFO" "$BASE/$INFO" || true
    want=$(awk '{print $1; exit}' "$FILE.sha256")
    if [ -f "$FILE" ] && [ "$($SHA256 "$FILE" | awk '{print $1}')" = "$want" ]; then
        say "snapshot $TAG already downloaded"
    else
        say "downloading snapshot $TAG"
        curl -fL --retry 5 --retry-delay 3 -C - -o "$FILE" "$BASE/$ASSET" ||
            { rm -f "$FILE"; curl -fL --retry 5 --retry-delay 3 -o "$FILE" "$BASE/$ASSET"; } ||
            die "download failed, run again to resume"
    fi
fi
[ -f "$FILE" ] || die "no such file: $FILE"
[ -f "$FILE.sha256" ] || die "missing $FILE.sha256"
want=$(awk '{print $1; exit}' "$FILE.sha256")

say "checking sha256"
got=$($SHA256 "$FILE" | awk '{print $1}')
[ "$got" = "$want" ] || die "sha256 doesn't match ($got vs $want). Delete $FILE and run again"

# Only the two chain folders, plain files and folders, nothing that climbs out of the cache dir.
LIST=$(mktemp); trap 'rm -f "$LIST" "$LIST.v"' EXIT
zstd -dc "$FILE" | tar -tf - > "$LIST" || die "can't read the archive"
bad=$(grep -v -E "^$NET/(state|non_finalized_state)(/[A-Za-z0-9._-]+)*/?\$" "$LIST" | head -3 || true)
[ -z "$bad" ] || die "unexpected path in the archive: $bad"
! grep -q -E '(^|/)\.\.(/|$)' "$LIST" || die "archive has '..' paths"
grep -q "^$NET/state/$DBV/unknowntestnet/CURRENT\$" "$LIST" || die "archive has no state/$DBV database"
zstd -dc "$FILE" | tar -tvf - > "$LIST.v"
[ "$(grep -c -v -E '^[-d]' "$LIST.v" || true)" = 0 ] || die "archive has links or special files"

need_kb=$(( $(zstd -dc "$FILE" | wc -c) / 1024 + 102400 ))
avail_kb=$(df -Pk "$CACHE" | awk 'NR==2{print $4}')
[ "$avail_kb" -gt "$need_kb" ] || die "not enough space in $CACHE: need $(( need_kb / 1024 )) MB, have $(( avail_kb / 1024 )) MB"

INFOF=$(dirname "$FILE")/$INFO
[ -f "$INFOF" ] || INFOF=${FILE%.tar.zst}.json
height=""; hash=""; made=""
if [ -f "$INFOF" ]; then
    height=$(sed -n 's/.*"height": *\([0-9]*\).*/\1/p' "$INFOF" | head -1)
    hash=$(sed -n 's/.*"hash": *"\([0-9a-f]*\)".*/\1/p' "$INFOF" | head -1)
    made=$(sed -n 's/.*"created_utc": *"\([^"]*\)".*/\1/p' "$INFOF" | head -1)
    say "snapshot: height ${height:-?}, block ${hash:-?}, made ${made:-?}"
fi
if [ -d "$TARGET/state" ] || [ -d "$TARGET/non_finalized_state" ]; then
    say "your current chain data in $TARGET gets moved aside (not deleted)"
    other=$(ls "$TARGET/state" 2>/dev/null | grep -E '^v[0-9]+$' | grep -v -x "$DBV" | head -1 || true)
    [ -z "$other" ] || say "note: you also have state/$other (another zebrad version?). This snapshot is for zebrad v15 (state/$DBV)"
fi
if [ "$YES" != 1 ]; then
    [ -t 0 ] || die "not a terminal, run again with --yes"
    printf "> restore into %s? [y/N] " "$CACHE"; read -r a
    case "$a" in y|Y|yes) ;; *) die "stopped, nothing changed" ;; esac
fi

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$TARGET"
for d in state non_finalized_state; do
    if [ -e "$TARGET/$d" ]; then mv "$TARGET/$d" "$TARGET/$d.bak-$STAMP"; say "moved $d to $d.bak-$STAMP"; fi
done
say "unpacking"
zstd -dc "$FILE" | tar -xf - --no-same-owner -C "$CACHE" || die "unpack failed, your old data is in $TARGET/*.bak-$STAMP"
[ -f "$TARGET/state/$DBV/unknowntestnet/CURRENT" ] || die "unpack incomplete, your old data is in $TARGET/*.bak-$STAMP"
case "$FILE" in "$WORK"/*) rm -rf "$WORK" ;; esac

echo
say "done. Start your node again, it catches up from the snapshot height."
[ -z "$height" ] || say "check: block $height should be $hash (compare on https://crosslink.staker.space or a node you trust)"
ls -d "$TARGET"/*.bak-"$STAMP" >/dev/null 2>&1 && say "old data: $TARGET/*.bak-$STAMP (delete it once your node runs fine)"
exit 0
