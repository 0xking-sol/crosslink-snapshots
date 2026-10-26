#!/usr/bin/env bash
# Restore a Crosslink feature-net node (zebrad v15) from a chain snapshot instead of syncing from genesis.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: bash restore.sh [--cache-dir DIR] [--file SNAPSHOT.tar.zst] [--yes] [--new] [--force]

  --cache-dir  the [state] cache_dir from your zebrad.toml (the folder that contains
               crosslink_featurenet_20260929_staking3d). Default is zebrad's own default:
               ~/.cache/zebra on Linux, ~/Library/Caches/zebra on macOS.
  --file       use a snapshot you already downloaded (its .sha256 file has to be next to it).
  --yes        don't ask before replacing the chain data.
  --new        this node has never run yet, so there's no node data in the folder.
  --force      go ahead even if another zebrad process is running (one that isn't using this
               folder), if this machine can't check for one, or if your node uses another database version.

Stop your node first. Your current chain data is moved aside (state.bak-<time>), not deleted.
secret.seed (your node identity) is never touched.
EOF
}

REPO=0xking-sol/crosslink-snapshots
ASSET=crosslink-v15-state.tar.zst
INFO=crosslink-v15-state.json
NET=crosslink_featurenet_20260929_staking3d
DBV=v31
DBDIR=state/$DBV/unknowntestnet

die() { echo "error: $*" >&2; exit 1; }
say() { echo "> $*"; }

CACHE="" FILE="" YES=0 NEW=0 FORCE=0 EXPLICIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cache-dir) [ $# -ge 2 ] && [ -n "$2" ] || die "--cache-dir needs a path"; CACHE=$2; EXPLICIT=1; shift 2 ;;
        --file) [ $# -ge 2 ] || die "--file needs a path"; FILE=$2; shift 2 ;;
        --yes|-y) YES=1; shift ;;
        --new) NEW=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done
[ "$YES" = 1 ] || [ -t 0 ] || die "not a terminal, run again with --yes"

if [ -z "$CACHE" ]; then
    case "$(uname -s)" in
        Darwin) CACHE=$HOME/Library/Caches/zebra ;;
        *) case "${XDG_CACHE_HOME:-}" in /*) CACHE=$XDG_CACHE_HOME/zebra ;; *) CACHE=$HOME/.cache/zebra ;; esac ;;
    esac
fi
case "$CACHE" in /*) ;; *) CACHE=$(pwd)/$CACHE ;; esac
CACHE=${CACHE%/}
[ "$(basename "$CACHE")" != "$NET" ] || die "pass the folder that contains $NET, not $NET itself: --cache-dir $(dirname "$CACHE")"
if [ "$EXPLICIT" = 1 ]; then
    [ -d "$CACHE" ] || die "no such folder: $CACHE (use the cache_dir from your zebrad.toml)"
fi
TARGET=$CACHE/$NET

# Under sudo the default folder is root's, not the node's. And if the node's files belong to someone else, root
# would leave them files the node can't write.
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$EXPLICIT" = 0 ]; then
    die "under sudo the default folder is root's. Run it as the user that runs zebrad, or pass --cache-dir"
fi
if [ "$(id -u)" = 0 ] && [ -e "$CACHE" ]; then
    owner=$(ls -nd "$CACHE" | awk '{print $3}')
    [ "$owner" = 0 ] || die "you're root but $CACHE belongs to user id $owner. Run it as that user, eg: sudo -u '#$owner' bash restore.sh --cache-dir $CACHE"
fi

for c in tar zstd; do command -v "$c" >/dev/null || die "$c isn't installed (eg apt install zstd, or brew install zstd)"; done
if command -v sha256sum >/dev/null; then SHA256="sha256sum"
elif command -v shasum >/dev/null; then SHA256="shasum -a 256"
else die "need sha256sum or shasum"; fi
[ -n "$FILE" ] || command -v curl >/dev/null || die "curl isn't installed"

# A running node would keep writing into the folders that get swapped. zebrad holds its database's LOCK file
# open the whole time; lsof sees that (for your own processes), pgrep sees any zebrad.
node_check() {
    local lockf=$TARGET/$DBDIR/LOCK
    if command -v lsof >/dev/null && [ -e "$lockf" ] && lsof "$lockf" >/dev/null 2>&1; then
        die "your node is running (it has the database open), stop it first"
    fi
    if command -v pgrep >/dev/null; then
        if pgrep zebrad >/dev/null 2>&1 && [ "$FORCE" != 1 ]; then
            die "a zebrad process is running. Stop your node first (or use --force if that process is a different node)"
        fi
    elif ! command -v lsof >/dev/null && [ "$FORCE" != 1 ]; then
        die "can't check for a running node here (no pgrep or lsof). Make sure it's stopped, then use --force"
    fi
}
node_check

# Which database version does this node use? Another version means another zebrad release: this one won't fit.
if [ -d "$TARGET/state" ]; then
    other=$(ls "$TARGET/state" 2>/dev/null | grep -E '^v[0-9]+$' | grep -v -x "$DBV" | head -1 || true)
    if [ -n "$other" ] && [ ! -d "$TARGET/state/$DBV" ] && [ "$FORCE" != 1 ]; then
        die "your node uses state/$other, this snapshot is for zebrad v15 (state/$DBV). Use --force to restore anyway"
    fi
fi
if [ ! -e "$TARGET/secret.seed" ] && [ ! -d "$TARGET/state" ] && [ "$NEW" != 1 ]; then
    die "no node data in $TARGET. Pass your node's --cache-dir, or add --new if this node has never run yet"
fi

mkdir -p "$CACHE" "$TARGET"
rm -rf "$TARGET"/.restore-* "$CACHE"/.restore-*   # left by a run that was killed while unpacking
avail_kb() { df -Pk "$1" | awk 'NR==2{print $4}'; }
size_of() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
jfield() { sed -n 's/.*"'"$2"'": *"\{0,1\}\([0-9a-zA-Z:.T-]*\)"\{0,1\}.*/\1/p' "$1" | head -1; }

WORK=$CACHE/.snapshot-download
JSON=""
if [ -z "$FILE" ]; then
    url=$(curl -fsSIL --connect-timeout 30 --max-time 120 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
        die "can't reach github.com"
    case "$url" in */releases/tag/*) ;; *) die "no snapshot release found at https://github.com/$REPO/releases" ;; esac
    TAG=${url##*/}
    BASE=https://github.com/$REPO/releases/download/$TAG
    if [ -d "$WORK" ] && [ ! -d "$WORK/$TAG" ]; then rm -rf "$WORK"; fi   # a part download of an older snapshot
    mkdir -p "$WORK/$TAG"
    FILE=$WORK/$TAG/$ASSET
    curl -fsSL --retry 5 --connect-timeout 30 --max-time 120 -o "$FILE.sha256" "$BASE/$ASSET.sha256" ||
        die "couldn't fetch the sha256 for $TAG"
    curl -fsSL --retry 5 --connect-timeout 30 --max-time 120 -o "$WORK/$TAG/$INFO" "$BASE/$INFO" || true
    want=$(awk '{print $1; exit}' "$FILE.sha256")
    expected=""; unpacked=0
    if [ -f "$WORK/$TAG/$INFO" ]; then expected=$(jfield "$WORK/$TAG/$INFO" bytes); unpacked=$(jfield "$WORK/$TAG/$INFO" unpacked_bytes); fi
    have=$(size_of "$FILE")
    if [ "$have" -gt 0 ] && [ -n "$expected" ] && [ "$have" -ge "$expected" ] &&
       [ "$($SHA256 "$FILE" | awk '{print $1}')" != "$want" ]; then
        rm -f "$FILE"; have=0   # complete but damaged: start over
    fi
    if [ -n "$expected" ] && [ "$have" -lt "$expected" ]; then
        need=$(( (expected - have) / 1024 + 102400 ))
        [ "$(avail_kb "$CACHE")" -gt "$need" ] || die "not enough space in $CACHE: need about $(( need / 1024 )) MB to download"
    fi
    if [ -n "$expected" ] && [ "$have" -ge "$expected" ]; then
        say "snapshot $TAG already downloaded"
    else
        say "downloading snapshot $TAG"
        tries=0
        until curl -fL --connect-timeout 30 --speed-limit 10000 --speed-time 60 -C - -o "$FILE" "$BASE/$ASSET"; do
            rc=$?; tries=$((tries + 1))
            if [ -n "$expected" ] && [ "$(size_of "$FILE")" -ge "$expected" ]; then rm -f "$FILE"; fi
            [ "$tries" -lt 30 ] || die "download keeps failing (curl exit $rc), run again later to resume"
            say "download interrupted (curl exit $rc), resuming in 5 s"; sleep 5
        done
    fi
fi
[ -f "$FILE" ] || die "no such file: $FILE"
[ -f "$FILE.sha256" ] || die "missing $FILE.sha256"
want=$(awk '{print $1; exit}' "$FILE.sha256")

say "checking sha256"
got=$($SHA256 "$FILE" | awk '{print $1}')
if [ "$got" != "$want" ]; then
    case "$FILE" in "$WORK"/*) rm -f "$FILE"; die "sha256 doesn't match, deleted the download. Run again" ;; esac
    die "sha256 doesn't match ($got vs $want)"
fi

# The snapshot's description, only if it describes this exact archive.
for j in "${FILE%.tar.zst}.json" "$(dirname "$FILE")/$INFO"; do
    if [ -f "$j" ] && [ "$(jfield "$j" sha256)" = "$got" ]; then JSON=$j; break; fi
done
# Read it now: a downloaded json goes with the download folder, which is deleted after the swap.
J_HEIGHT="" J_FIN="" J_FINHASH="" J_MADE=""
if [ -n "$JSON" ]; then
    J_HEIGHT=$(jfield "$JSON" height); J_FIN=$(jfield "$JSON" finalized_height)
    J_FINHASH=$(jfield "$JSON" finalized_hash); J_MADE=$(jfield "$JSON" created_utc)
fi

# Only the two chain folders, plain files and folders, nothing that climbs out. grep exit 1 = no bad lines;
# anything else (bad lines, or grep failing) stops here.
LIST=$(mktemp); STAGING=""
cleanup() { rm -f "$LIST" "$LIST.v"; [ -z "$STAGING" ] || rm -rf "$STAGING"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
zstd -dc "$FILE" | tar -tf - > "$LIST" || die "can't read the archive"
rc=0; grep -v -E "^$NET/(state|non_finalized_state)(/[A-Za-z0-9._-]+)*/?\$" "$LIST" > /dev/null || rc=$?
[ "$rc" = 1 ] || die "unexpected path in the archive"
rc=0; grep -E '(^|/)\.\.(/|$)' "$LIST" > /dev/null || rc=$?
[ "$rc" = 1 ] || die "archive has '..' paths"
grep -q "^$NET/$DBDIR/CURRENT\$" "$LIST" || die "archive has no state/$DBV database"
grep -q "^$NET/non_finalized_state/" "$LIST" || die "archive has no non_finalized_state folder"
zstd -dc "$FILE" | tar -tvf - > "$LIST.v" || die "can't read the archive"
rc=0; grep -v -E '^[-d]' "$LIST.v" > /dev/null || rc=$?
[ "$rc" = 1 ] || die "archive has links or special files"

need_kb=$(( $(zstd -dc "$FILE" | wc -c) / 1024 + 102400 ))
[ "$(avail_kb "$TARGET")" -gt "$need_kb" ] || die "not enough space in $TARGET: need $(( need_kb / 1024 )) MB free to unpack"

if [ -n "$JSON" ]; then
    say "snapshot: height $J_HEIGHT, finalized $J_FIN, made $J_MADE"
fi
[ -d "$TARGET/state" ] || [ -d "$TARGET/non_finalized_state" ] && say "your current chain data in $TARGET gets moved aside (not deleted)"
if [ "$YES" != 1 ]; then
    printf "> restore into %s? [y/N] " "$CACHE"
    read -r a || a=""
    case "$a" in y|Y|yes) ;; *) [ -d "$WORK" ] && die "stopped, nothing changed (the download stays in $WORK for next time)"
                               die "stopped, nothing changed" ;; esac
fi

# Unpack inside the node's folder (same disk, so the swap is two renames), check it, then swap: a failed or
# interrupted unpack leaves the node's data exactly as it was.
STAMP=$(date +%Y%m%d-%H%M%S)
STAGING=$TARGET/.restore-$STAMP
mkdir -p "$STAGING"
say "unpacking"
zstd -dc "$FILE" | tar -xf - --no-same-owner -C "$STAGING" || die "unpack failed, nothing changed"
[ -f "$STAGING/$NET/$DBDIR/CURRENT" ] && [ -f "$STAGING/$NET/$DBDIR/version" ] || die "unpack incomplete, nothing changed"
node_check   # again: the download and the question can take a while

moved="" placed=""
# Undo the swap: drop whatever is in place of a moved folder (new or half-moved), then put the old one back.
rollback() {
    local x ok=1
    for x in $moved; do
        rm -rf "${TARGET:?}/$x"
        mv "$TARGET/$x.bak-$STAMP" "$TARGET/$x" || ok=0
    done
    for x in $placed; do case " $moved " in *" $x "*) ;; *) rm -rf "${TARGET:?}/$x" ;; esac; done
    [ "$ok" = 1 ] && echo "put the old data back" || echo "COULDN'T PUT IT ALL BACK, your old data is in $TARGET/*.bak-$STAMP"
}
for d in state non_finalized_state; do
    if [ -e "$TARGET/$d" ]; then
        mv "$TARGET/$d" "$TARGET/$d.bak-$STAMP" || die "couldn't move $d aside: $(rollback)"
        moved="$moved $d"
    fi
done
for d in state non_finalized_state; do
    mv "$STAGING/$NET/$d" "$TARGET/$d" || die "couldn't move the new $d in: $(rollback)"
    placed="$placed $d"
done
case "$FILE" in "$WORK"/*) rm -rf "$WORK" ;; esac

echo
say "done. Start your node again, it catches up from the snapshot height."
if [ -n "$JSON" ]; then
    say "then check you're on the right chain: ask your node for block $J_FIN (eg getblockhash $J_FIN over RPC)"
    say "and compare it with https://crosslink.staker.space. It should be $J_FINHASH"
fi
baks=$(ls -d "$TARGET"/*.bak-* 2>/dev/null || true)
[ -z "$baks" ] || { say "old data (delete once your node runs fine):"; echo "$baks" | sed 's/^/    /'; }
exit 0
