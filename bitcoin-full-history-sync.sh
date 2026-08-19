#!/usr/bin/env bash
#
# bitcoin-full-history-sync — "leveling" of a fork with a rewritten-base history.
#
# Puts the NEW commits of an upstream (e.g. bitcoin/bitcoin) ON TOP of a
# reconstructed history whose old era has different SHAs (rewritten identities:
# the SVN era with real author names instead of "user@<UUID>").
#
# Method: git replace (graft) + git-filter-repo. It does NOT merge anything, it
# only rewrites parent pointers -> 0 conflicts; it preserves author, committer
# and the EXACT merge topology of upstream. It is deterministic: already-published
# SHAs do not change, so the push is a fast-forward (only new commits are added).
# Determinism relies on --preserve-commit-hashes (see step 4) and is enforced by
# an ancestry preflight before the push (step 5a).
#
# User/home-agnostic: no absolute paths; everything resolves via $HOME and via
# environment variables with sane defaults. The fork URL is derived from the
# 'origin' remote of the base repo (PUB) if not provided.
#
# ---------------------------------------------------------------------------
# Variables (all optional; defaults in brackets):
#
#   MIRROR     Pristine mirror of the upstream (git clone --mirror).
#              Auto-created from UPSTREAM if missing. [$HOME/git/bitcoin-mirror]
#   UPSTREAM   URL to mirror-clone when MIRROR is missing.
#              [https://github.com/bitcoin/bitcoin]
#   PUB        Local repo holding the real-id base on branch BASE_REF.
#              The only thing that must already exist.
#              [$HOME/git/bitcoin-full-history]
#   MAP        File mapping "RAW_SHA REALID_SHA" (one pair per line): each raw
#              commit of the upstream's old era -> its real-id equivalent in
#              BASE_REF. Auto-generated via gen-splice-map.sh if missing.
#              [$HOME/git/.bitcoin-splice-map.txt]
#   BASE_REF   Branch in PUB with the real-id base up to the link point. [svn]
#   BRANCH     Branch to level and publish. [master]
#   ORIGIN     Push URL of the fork. [git -C "$PUB" remote get-url origin]
#   LOG        Log file, or '-' / /dev/stdout to log to the console (CI).
#              [$HOME/git/bitcoin-full-history-sync.log]
#   LOCK       Lock file. [$HOME/.cache/bitcoin-full-history-sync.lock]
# ---------------------------------------------------------------------------
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

MIRROR="${MIRROR:-$HOME/git/bitcoin-mirror}"
UPSTREAM="${UPSTREAM:-https://github.com/bitcoin/bitcoin}"
PUB="${PUB:-$HOME/git/bitcoin-full-history}"
MAP="${MAP:-$HOME/git/.bitcoin-splice-map.txt}"
BASE_REF="${BASE_REF:-svn}"
BRANCH="${BRANCH:-master}"
ORIGIN="${ORIGIN:-$(git -C "$PUB" remote get-url origin 2>/dev/null || true)}"
LOG="${LOG:-$HOME/git/bitcoin-full-history-sync.log}"
LOCK="${LOCK:-$HOME/.cache/bitcoin-full-history-sync.lock}"

# Log to a file by default; set LOG to '-' (or /dev/stdout) to log to the
# console instead — handy for CI, where output belongs in the job log.
mkdir -p "$(dirname "$LOCK")"
case "$LOG" in
  ""|-|/dev/stdout|/dev/stderr) : ;;
  *) mkdir -p "$(dirname "$LOG")"; exec >>"$LOG" 2>&1 ;;
esac
echo "===== $(date -Is) ====="

exec 9>"$LOCK"
flock -n 9 || { echo "another run in progress; exiting"; exit 0; }

# PUB is the only prerequisite that must already exist.
[ -e "$PUB" ] || { echo "ERROR: missing PUB '$PUB'"; exit 1; }
[ -n "$ORIGIN" ] || { echo "ERROR: empty ORIGIN (set ORIGIN or add an 'origin' remote in $PUB)"; exit 1; }
command -v git-filter-repo >/dev/null 2>&1 || git filter-repo --version >/dev/null 2>&1 || {
  echo "ERROR: git-filter-repo is not installed (pip install --user git-filter-repo)"; exit 1; }

# 0) bootstrap MIRROR and MAP if they don't exist yet (idempotent)
if [ ! -e "$MIRROR" ]; then
  echo "MIRROR missing -> git clone --mirror $UPSTREAM"
  mkdir -p "$(dirname "$MIRROR")"
  git clone --mirror "$UPSTREAM" "$MIRROR"
fi
if [ ! -e "$MAP" ]; then
  echo "MAP missing -> generating via gen-splice-map.sh"
  MIRROR="$MIRROR" UPSTREAM="$UPSTREAM" PUB="$PUB" BASE_REF="$BASE_REF" MAP="$MAP" \
    "$SELF_DIR/gen-splice-map.sh"
fi

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
#
# --preserve-commit-hashes is what keeps the bake reproducible. Without it,
# filter-repo rewrites commit-hash references found in commit MESSAGES in a
# single streaming pass, so whether a given reference resolves depends on the
# order in which `git fast-export` emits commits with no ancestry relation --
# an order that is unspecified and shifts BOTH across git versions AND as the
# exported repo gains commits/refs. A single flipped reference changes the bytes
# of an already-published commit and cascades into every descendant, turning the
# push into a non-fast-forward. Preserving messages verbatim makes the bake a
# pure function of (DAG + MAP). See NOTES.md.
git filter-repo --quiet --force --replace-refs delete-no-add --preserve-commit-hashes

NEWTIP="$(git rev-parse "$BRANCH")"
echo "leveled tip = ${NEWTIP:0:12}  (published: ${PUBTIP:0:12})"

# 5) publish if changed (fast-forward thanks to determinism)
if [ "$NEWTIP" = "$PUBTIP" ]; then
  echo "no changes: already published"
  exit 0
fi

# 5a) preflight: the push MUST be a fast-forward. If the published tip is absent
# from the bake, or is not an ancestor of it, the leveling did not reproduce the
# published history -> stop with a clear diagnosis instead of an opaque
# non-fast-forward rejection, and never force-push behind the operator's back:
# recovering from that is a deliberate re-baseline (see NOTES.md).
if [ -n "$PUBTIP" ] && { ! git cat-file -e "${PUBTIP}^{commit}" 2>/dev/null \
                      || ! git merge-base --is-ancestor "$PUBTIP" "$NEWTIP"; }; then
  echo "ERROR: diverged bake -- published ${PUBTIP:0:12} is not an ancestor of ${NEWTIP:0:12}"
  echo "       refusing to push (it would not be a fast-forward)."
  echo "       The leveling stopped being reproducible; see NOTES.md before re-baselining."
  exit 1
fi

git push -q "$ORIGIN" "$BRANCH:$BRANCH"
echo "OK: $BRANCH published -> ${NEWTIP:0:12}"
