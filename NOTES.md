# NOTES — why the leveling is toolchain-sensitive

This documents a non-obvious determinism hazard discovered while automating the
sync: **the rewritten commit SHAs depend on the `git` version used**, even with an
identical base, identical MAP, and the same `git-filter-repo` version. This is why
the CI job runs in a **pinned container**. The investigation below was done with
the original baseline (`084c3b09b714`, git 2.34.1); the repo was later re-baselined
to git 2.43.0 — see [Re-baseline (2026-06-29)](#re-baseline-2026-06-29) at the end.

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

Notably, the newer git's result is *more* correct here: it points these messages at
hashes that actually exist, whereas git 2.34 left them stale. Across the full
history the newer toolchain updates the embedded hash references (mostly
**abbreviated** 7–12 char hashes, plus a couple of full ones) in **54 commit
messages** — pointing them at the rewritten SHAs instead of the pre-rewrite ones.

Keep the magnitude in perspective, though: counting only **full 40-hex** tokens,
both bakes carry **~41,210 dangling references** in messages and differ by just 2;
of those ~41k, **41,173 are not even commits in bitcoin/bitcoin** — ordinary
citations (other PRs, `Revert <sha>`, external SHAs) that every git history has,
present upstream too. So the "fix" is real but cosmetic: 54 message references
resolve where they did not before, out of 49,381 commits whose SHAs all change.

## Consequences for this repo

- **CI pins the toolchain** (`container: ubuntu:24.04`, git 2.43.0,
  `git-filter-repo==2.47.0`) so it reproduces `1a39fbe8badb` and the push stays a
  fast-forward. See `.github/workflows/history-sync.yml`.
- **Running locally now requires the same toolchain.** A host with a different git
  (e.g. Ubuntu 22.04's 2.34.1) diverges, so run the bake inside the same
  `ubuntu:24.04` container.
- **Pinning is mandatory regardless of which version you choose.** `git
  fast-export` ordering can change in *any* future version, so a newer pin is not
  "more future-proof" — only the pin itself guarantees reproducibility, and it must
  cover both git and filter-repo.
- **Upgrading the toolchain again** is a deliberate, one-time **history rewrite**:
  re-bake inside the new pinned container, verify the tip is stable (two bakes →
  same SHA), `git push --force-with-lease`, then bump the pin in the workflow to
  match. Never bump the pin before re-baselining.

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

## Re-baseline (2026-06-29)

The repo was re-baselined from the original git-2.34.1 baseline (`084c3b09b714`) to
a git-2.43.0 baseline (`1a39fbe8badb`). Rationale: maintainability — pinning a
modern, frozen toolchain (`ubuntu:24.04`) rather than carrying `ubuntu:22.04`
forever. It is **not** a fix (it changes 2 of ~41k dangling references) and it does
**not** remove the need to pin.

Steps performed (low risk — nobody had cloned the fork):

1. Baked twice inside `ubuntu:24.04` (git 2.43.0 + filter-repo 2.47.0); both runs
   produced `1a39fbe8badb` → deterministic. (git 2.43 happens to match git 2.54.)
2. Verified vs the old baseline: same commit count (49,381), the **full multiset of
   all 47,638 trees is identical** (content byte-for-byte unchanged), authors /
   committers / dates identical, `svn` base still an ancestor. The only differences
   are **54 commit messages** with updated hash references (see above).
3. `git push --force-with-lease=master:084c3b09… origin master:master` →
   `084c3b09b7 → 1a39fbe8ba`.
4. Bumped the workflow pin to `ubuntu:24.04` and updated the docs.

Old SHAs (incl. `084c3b09b714`) are now obsolete; the live baseline is
`1a39fbe8badb`.
