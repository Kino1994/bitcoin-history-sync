# NOTES — why the leveling is toolchain-sensitive

This documents a non-obvious determinism hazard discovered while automating the
sync: **the rewritten commit SHAs depend on the `git` version used**, even with an
identical base, identical MAP, and the same `git-filter-repo` version. This is why
the CI job is pinned to a `ubuntu:22.04` container (git 2.34.1 + filter-repo
2.47.0) — the exact toolchain that produced the published `master`.

## Symptom

Same inputs, two git versions, two different results:

| toolchain | leveled `master` tip |
|-----------|----------------------|
| git **2.34.1** + filter-repo 2.47.0 (Ubuntu 22.04, the published baseline) | `084c3b09b714` |
| git **2.54.0** + filter-repo 2.47.0 (Alpine / GitHub `ubuntu-latest`)       | `1a39fbe8badb` |

`git-filter-repo` was identical (2.47.0) in both; the **only** variable was the git
version. A non-force push from the 2.54 environment is therefore rejected as a
non-fast-forward, because it does not reproduce the published history.

## Investigation (byte level)

Both bakes were reproduced locally (the 2.54 one via
`docker run alpine:latest`) and walked in parallel in reverse topological order.
The histories are identical for the first 965 commits (the real-id `svn` base and
the early rewritten commits) and **first diverge at commit #966**:

```
A (git 2.34): 18cf214528…  "update bitcoin core to git ce148944c776…"
B (git 2.54): df7a9d7a73…  "update bitcoin core to git 72dbccaf8681…"
```

Both have the **same tree** and the **same parent**. A raw `cat-file -p` diff shows
the *only* difference is one line of the commit message — an embedded git hash:

```
< update bitcoin core to git ce148944c776ae8e91cc058f44ddce356c7cebc9
> update bitcoin core to git 72dbccaf86813b3213352d15798e43fbc7521a7e
```

- `ce148944…` exists in the upstream mirror — it is `Merge pull request #300 from
  sipa/connecttimeout`. It is **rewritten in both bakes** (it does not survive
  verbatim in either, because its ancestry reaches the grafted root).
- `72dbccaf…` does **not** exist in the mirror — it is the **rewritten SHA** of
  `ce148944…`.

So in bake B the message reference was **updated** to the new SHA, while in bake A
it was **left stale** (pointing at a commit that no longer exists).

## Root cause

`git-filter-repo` rewrites commit-hash references found in commit **messages** by
default, but it does so in a **single streaming pass**: it can only update a
reference whose target commit has **already been processed** (is already in its
old→new rename map). Forward references — to commits not yet emitted — cannot be
resolved and are left as-is.

`git fast-export` only guarantees that **parents come before children**. The
relative order of commits with **no ancestry relationship** is unspecified, and it
**changed between git versions**. For our two commits (a textual reference, not a
parent edge):

| | mentions `ce148944` (`18cf2145`) | mentioned (`ce148944`) |
|---|---|---|
| **git 2.34** fast-export line | 27493 (**first**) | 43637 (later) |
| **git 2.54** fast-export line | 24540 (later)     | 14527 (**first**) |

- **git 2.34:** `18cf2145` is emitted *before* `ce148944`, so when filter-repo
  rewrites its message the new SHA of `ce148944` is unknown → reference left stale.
- **git 2.54:** `ce148944` is emitted *first*, so its new SHA (`72dbccaf`) is known
  → the message reference is updated.

A one-byte-region message difference changes the commit SHA, and because that
commit is an ancestor of everything after it, the divergence **cascades** through
the entire modern history.

## Is it a bug?

Not a clear-cut bug in either tool — it is an unfortunate **interaction** of two
legitimate behaviors:

- **git:** the `fast-export` ordering of unrelated commits is not specified;
  changing it across versions is allowed.
- **filter-repo:** rewriting message hashes in one streaming pass is best-effort;
  forward references are a known limitation.

The emergent effect is a real cross-version non-reproducibility hazard, born of
documented/expected behavior rather than a fault.

Notably, **git 2.54's result is the more correct one**: it points the message at a
hash that actually exists. git 2.34 leaves **stale hash references** in the
messages — meaning the *published* history already contains message hashes that no
longer resolve inside the repo. Reproducing the baseline means reproducing that
2.34 imperfection, which is exactly what the pinned container does.

## Consequences for this repo

- **CI pins the toolchain** (`container: ubuntu:22.04`, git 2.34.1,
  `git-filter-repo==2.47.0`) so it reproduces `084c3b09` and the push stays a
  fast-forward. See `.github/workflows/history-sync.yml`.
- **Running locally on Ubuntu 22.04 needs no pin** — it already matches.
- **Upgrading the toolchain** (e.g. to a modern git that fixes the stale
  references) is a deliberate, one-time **history rewrite**: re-bake locally inside
  the new pinned container, verify, `git push --force-with-lease`, then bump the
  pin in the workflow to match. Never bump the pin before re-baselining.

## How to reproduce

```sh
# A: published toolchain (Ubuntu 22.04)
git clone -q ~/git/bitcoin-mirror /tmp/bakeA && cd /tmp/bakeA
git fetch -q ~/git/bitcoin-svn-git-history refs/heads/svn:refs/heads/_base
while read -r raw real _; do git replace -f "$raw" "$real" 2>/dev/null; done < ~/git/.bitcoin-splice-map.txt
git filter-repo --quiet --force --replace-refs delete-no-add
git rev-parse master            # -> 084c3b09b714

# B: newer git, same filter-repo (inside a container)
docker run --rm -v ~/git:/g alpine:latest sh -c '
  apk add -q git python3 py3-pip
  pip install -q --break-system-packages git-filter-repo==2.47.0
  git config --global safe.directory "*"
  git clone -q /g/bitcoin-mirror /tmp/bakeB && cd /tmp/bakeB
  git fetch -q /g/bitcoin-svn-git-history refs/heads/svn:refs/heads/_base
  while read -r raw real _; do git replace -f "$raw" "$real" 2>/dev/null; done < /g/.bitcoin-splice-map.txt
  git filter-repo --quiet --force --replace-refs delete-no-add
  git rev-parse master'         # -> 1a39fbe8badb
```
