#!/usr/bin/env bash
# mirror.sh — backup discipline (ENV requirement): mirror work -> backup, then git-snapshot both.
set -euo pipefail
SRC="$ARENA_WORKSPACE"/for_ctf-collect-to-file
DST="$ARENA_WORKSPACE"/backup/for_ctf-collect-to-file
mkdir -p "$DST"
# delete-then-copy keeps the mirror exact (no stale files), except VCS dirs
find "$DST" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
cp -a "$SRC"/. "$DST"/
# keep the backup's own .git so snapshot history ACCUMULATES there too
rm -rf "$DST/.git/refs/remotes" 2>/dev/null || true
for d in "$SRC" "$DST"; do
  cd "$d"
  [ -d .git ] || git init -q -b snapshot
  git add -A
  git -c user.name=wiki-agent -c user.email=agent@localhost \
      commit -qm "snapshot: ${1:-$(date -u +%FT%TZ)}" || echo "  ($d: nothing to snapshot)"
done
echo "mirror + snapshots OK: $SRC <-> $DST"
