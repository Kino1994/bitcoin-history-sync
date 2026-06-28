#!/usr/bin/env bash
#
# bitcoin-history-sync — "leveling" of a fork with a rewritten-base history.
#
# Puts the NEW commits of an upstream (e.g. bitcoin/bitcoin) ON TOP of a
# reconstructed history whose old era has different SHAs (rewritten identities:
# the SVN era with real author names instead of "user@<UUID>").
#
# Method: git replace (graft) + git-filter-repo. It does NOT merge anything, it
# only rewrites parent pointers -> 0 conflicts; it preserves author, committer
# and the EXACT merge topology of upstream. It is deterministic: already-published
# SHAs do not change, so the push is a fast-forward (only new commits are added).
#
# User/home-agnostic: no absolute paths; everything resolves via $HOME and via
# environment variables with sane defaults. The fork URL is derived from the
# 'origin' remote of the base repo (PUB) if not provided.
#
# ---------------------------------------------------------------------------
# Variables (all optional; defaults in brackets):
#
#   MIRROR     Pristine mirror of the upstream (git clone --mirror).
#              [$HOME/git/bitcoin-mirror]
#   PUB        Local repo holding the real-id base on branch BASE_REF.
#              [$HOME/git/bitcoin-svn-git-history]
#   MAP        File mapping "RAW_SHA REALID_SHA" (one pair per line): each raw
#              commit of the upstream's old era -> its real-id equivalent in
#              BASE_REF. [$HOME/git/.bitcoin-splice-map.txt]
#   BASE_REF   Branch in PUB with the real-id base up to the link point. [svn]
#   BRANCH     Branch to level and publish. [master]
#   ORIGIN     Push URL of the fork. [git -C "$PUB" remote get-url origin]
#   LOG        Log file. [$HOME/git/bitcoin-history-sync.log]
#   LOCK       Lock file. [$HOME/.cache/bitcoin-history-sync.lock]
# ---------------------------------------------------------------------------
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

MIRROR="${MIRROR:-$HOME/git/bitcoin-mirror}"
PUB="${PUB:-$HOME/git/bitcoin-svn-git-history}"
MAP="${MAP:-$HOME/git/.bitcoin-splice-map.txt}"
BASE_REF="${BASE_REF:-svn}"
BRANCH="${BRANCH:-master}"
ORIGIN="${ORIGIN:-$(git -C "$PUB" remote get-url origin 2>/dev/null || true)}"
LOG="${LOG:-$HOME/git/bitcoin-history-sync.log}"
LOCK="${LOCK:-$HOME/.cache/bitcoin-history-sync.lock}"

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK")"
exec >>"$LOG" 2>&1
echo "===== $(date -Is) ====="

exec 9>"$LOCK"
flock -n 9 || { echo "another run in progress; exiting"; exit 0; }

for p in "$MIRROR" "$PUB" "$MAP"; do
  [ -e "$p" ] || { echo "ERROR: missing '$p'"; exit 1; }
done
[ -n "$ORIGIN" ] || { echo "ERROR: empty ORIGIN (set ORIGIN or add an 'origin' remote in $PUB)"; exit 1; }
command -v git-filter-repo >/dev/null 2>&1 || git filter-repo --version >/dev/null 2>&1 || {
  echo "ERROR: git-filter-repo is not installed (pip install --user git-filter-repo)"; exit 1; }

# 1) update the upstream mirror (deltas only)
git -C "$MIRROR" fetch -q --prune origin
echo "upstream/$BRANCH = $(git -C "$MIRROR" rev-parse --short "refs/heads/$BRANCH")"

PUBTIP="$(git ls-remote "$ORIGIN" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)"

# 2) build the splice in a throwaway temporary repo
TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT
git clone -q "$MIRROR" "$TMP/w"
cd "$TMP/w"
git fetch -q "$PUB" "refs/heads/$BASE_REF:refs/heads/_base"

# 3) replaces: each raw commit of the old era -> its real-id equivalent
while read -r raw realid _; do
  [ -n "${raw:-}" ] && git replace -f "$raw" "$realid" >/dev/null 2>&1 || true
done < "$MAP"

# 4) bake (rewrite parent pointers; no content merge)
git filter-repo --quiet --force --replace-refs delete-no-add

NEWTIP="$(git rev-parse "$BRANCH")"
echo "leveled tip = ${NEWTIP:0:12}  (published: ${PUBTIP:0:12})"

# 5) publish if changed (fast-forward thanks to determinism)
if [ "$NEWTIP" = "$PUBTIP" ]; then
  echo "no changes: already published"
  exit 0
fi
git push -q "$ORIGIN" "$BRANCH:$BRANCH"
echo "OK: $BRANCH published -> ${NEWTIP:0:12}"
