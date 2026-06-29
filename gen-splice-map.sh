#!/usr/bin/env bash
#
# gen-splice-map — builds the MAP "RAW_SHA REALID_SHA" used by
# bitcoin-full-history-sync.sh, mapping each old-era commit of the upstream to its
# real-id equivalent in the base branch (BASE_REF) of PUB.
#
# Matching key: "author-ts | committer-ts | tree" (%at|%ct|%T), NOT the tree
# alone. The real-id rewrite preserved timestamps, message and tree and only
# changed the author identity, so this key is unique in both histories. A pure
# tree match is ambiguous: a real revert that restores an identical tree (e.g.
# "revert revision 56") shares its tree with an ancestor and would collapse.
#
# Scope: ALL upstream commits ('rev-list --all'), not just the linear ancestors
# of the link point. The old era has side branches that merge in later; leaving
# them out keeps their original SHAs and breaks the determinism of the rebase.
#
# It clones the MIRROR from UPSTREAM if it does not exist yet, and fetches it
# otherwise. Idempotent: re-running reproduces the same MAP.
#
# ---------------------------------------------------------------------------
# Variables (all optional; defaults in brackets):
#
#   PUB        Local repo holding the real-id base on branch BASE_REF.
#              [$HOME/git/bitcoin-full-history]
#   MIRROR     Pristine mirror of the upstream (git clone --mirror).
#              [$HOME/git/bitcoin-mirror]
#   UPSTREAM   URL to mirror-clone when MIRROR is missing.
#              [https://github.com/bitcoin/bitcoin]
#   BASE_REF   Branch in PUB with the real-id base up to the link point. [svn]
#   MAP        Output file "RAW_SHA REALID_SHA". [$HOME/git/.bitcoin-splice-map.txt]
# ---------------------------------------------------------------------------
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

PUB="${PUB:-$HOME/git/bitcoin-full-history}"
MIRROR="${MIRROR:-$HOME/git/bitcoin-mirror}"
UPSTREAM="${UPSTREAM:-https://github.com/bitcoin/bitcoin}"
BASE_REF="${BASE_REF:-svn}"
MAP="${MAP:-$HOME/git/.bitcoin-splice-map.txt}"

[ -e "$PUB" ] || { echo "ERROR: missing PUB '$PUB'"; exit 1; }
git -C "$PUB" rev-parse --verify "refs/heads/$BASE_REF" >/dev/null 2>&1 \
  || { echo "ERROR: PUB has no branch '$BASE_REF'"; exit 1; }
command -v git-filter-repo >/dev/null 2>&1 || git filter-repo --version >/dev/null 2>&1 || true

# 0) ensure the upstream mirror exists (clone if missing, else refresh)
if [ ! -e "$MIRROR" ]; then
  echo "MIRROR missing -> git clone --mirror $UPSTREAM"
  mkdir -p "$(dirname "$MIRROR")"
  git clone --mirror "$UPSTREAM" "$MIRROR"
else
  git -C "$MIRROR" fetch -q --prune origin || true
fi

# 1) key -> realid from the base branch
declare -A K2REAL
while read -r sha key; do
  [ -n "${sha:-}" ] && K2REAL["$key"]="$sha"
done < <(git -C "$PUB" rev-list "$BASE_REF" --format='%H %at|%ct|%T' | grep -v '^commit ')

# 2) emit a pair for every upstream commit whose key is in the base
mkdir -p "$(dirname "$MAP")"
: > "$MAP"
matched=0
while read -r raw key; do
  real="${K2REAL[$key]:-}"
  [ -n "$real" ] && { printf '%s %s\n' "$raw" "$real" >> "$MAP"; matched=$((matched+1)); }
done < <(git -C "$MIRROR" rev-list --all --format='%H %at|%ct|%T' | grep -v '^commit ')

echo "base($BASE_REF) keys : ${#K2REAL[@]}"
echo "matched pairs       : $matched  (-> $(cut -d' ' -f2 "$MAP" | sort -u | wc -l) distinct real-id)"
echo "MAP                 : $MAP"
