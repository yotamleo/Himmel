# v1.0.0 tag-cut checklist (HIMMEL-3603)

This is the ordered list of steps for the console to run **once every
fixVersion v1.0.0 gate ticket is closed** (HIMMEL-3604–3609 and the rest of
the v1.0.0 fixVersion). It does not itself cut anything — this ticket only
prepares the mechanics.

## 0. Preconditions

- Every fixVersion v1.0.0 issue is Done (check in Jira, not from memory).
- `main`'s tip is the commit to release. Note its full 40-char sha.

## 1. Bump `VERSION`

`VERSION` currently reads `0.3.0` and is deliberately **left unbumped** by
this PR (see the "VERSION" section below for why). Before cutting the real
tag:

1. On `main`, edit `VERSION` to `1.0.0` (bare, no `v` prefix, no trailing
   content beyond the newline).
2. Commit and land it through the normal PR flow — this is an ordinary repo
   change, not something `cut-tag.sh` does for you (`cut-tag.sh` creates a
   git tag via the GitHub API; it never touches tracked files).
3. Re-note `main`'s new tip sha — that is the sha the tag must point at.

## 2. `cut-tag.sh` — cutting the bare release

`scripts/handover/console-kit/cut-tag.sh` (console-run only; never from a
leg) accepts `<version>` as either `v<X>.<Y>.<Z>-pre.<N>` or a bare
`v<X>.<Y>.<Z>` release (HIMMEL-3701). The bare form runs through every gate
in section 4 below, plus one release-specific sequence rule: it is refused
(exit 6) unless at least one `v<X>.<Y>.<Z>-pre.<N>` tag already exists on
origin for that same `X.Y.Z`, or `--version-override <reason>` is given.

For the real `v1.0.0` cut: run a final pre-release (e.g. `v1.0.0-pre.1`) to
prove the pipeline, then run

```bash
bash scripts/handover/console-kit/cut-tag.sh v1.0.0 <full-40-char-sha> --dry-run
```

and, once the plan looks right, drop `--dry-run`. No by-hand `gh api` fallback
is needed.

## 3. Dry run first

```
bash scripts/handover/console-kit/cut-tag.sh <version> <full-40-char-sha> --dry-run
```

This runs every check below and prints the plan; it writes nothing to
origin and creates no tag. Confirm the plan looks right before dropping
`--dry-run`.

## 4. The gate list `cut-tag.sh` checks (in order)

1. `gh`'s default repo matches the `origin` git remote (so the checks below
   and the tag write target the same repo).
2. `<sha>` is an ancestor of (or equal to) `origin/main`.
3. `<version>` does not already exist as a tag on origin.
4. `<version>` is the next in-sequence value for its `vX.Y.Z-pre.` series
   (current series tops out at `v0.3.0-pre.9`); for a bare `vX.Y.Z` release,
   at least one `vX.Y.Z-pre.N` tag must already exist on origin instead —
   unless `--version-override <reason>` is given.
5. Every GitHub check-run at `<sha>` is `status=completed` with a conclusion
   in `{success, skipped, neutral}`, and at least one check-run exists
   (HIMMEL-3572: check-runs is the authoritative read, not combined-status).
6. The combined commit status, when it carries any statuses at all, is not
   `failure`/`error` (belt-and-suspenders, never the primary check).
7. The commit's `CI` workflow run (read via the Actions API) exists and is
   `status=completed conclusion=success` (HIMMEL-3627: guards against a
   commit whose CI run hasn't started yet, where check-runs alone would
   pass vacuously on unrelated Pages checks).

Any transient read failure among the above refuses closed ("could not
confirm"), never falls through as clean.

## 5. Cut

Drop `--dry-run` once the plan is confirmed. The tag is created through
`gh api .../git/refs`, not `git tag` — this script never writes the primary
checkout's own refs.

## 6. After the tag

- Confirm the release-tarball build (`scripts/release/build-tarball.sh
  --version 1.0.0`) and the AUR `PKGBUILD` pin pick up the new tag/version
  per their own release runbooks (out of this ticket's scope — link here
  once those runbooks exist).
- Regenerate `CHANGELOG.md` (`bash scripts/gen-changelog.sh`) — the
  `## [Unreleased]` section becomes `## [v1.0.0] - <date>` automatically
  once the tag exists, no hand-editing.

## VERSION: why this PR does not bump it

`scripts/himmelctl/lib/provenance.js` reads the `VERSION` file directly into
every install-provenance ledger row (`beginRow()`). Bumping `VERSION` to
`1.0.0` before the tag exists would make every `himmelctl install`/`update`
run on `main` between this PR and the real tag cut log `"1.0.0"` in its
provenance ledger — a release that has not happened yet. No other script
reads `VERSION` automatically: `scripts/release/build-tarball.sh` takes an
explicit `--version` CLI argument instead, and `scripts/check-plugin-drift.sh`
compares against git tags, not this file. So `VERSION` stays `0.3.0` here;
step 1 above is the deferred bump, to be done immediately before the real
cut, on `main`, in its own small PR.
