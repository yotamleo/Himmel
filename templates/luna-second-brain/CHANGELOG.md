# Changelog — luna-second-brain template

Version history for the luna-second-brain vault template (published as
**luna-brain**). The version is `marketplace/.claude-plugin/marketplace.json`
`metadata.version`, read by `scripts/upgrade.sh` (the engine behind
`/luna-upgrade`). When the version here is newer than a vault's
`.vault-template.json` stamp, `/luna-upgrade` offers the changes below.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] — 2026-06-21

### Fixed
- **Version anchor was not bumped, so `/luna-upgrade` reported "already
  current" and stranded template changes** (HIMMEL-521). `upgrade.sh` reads
  `marketplace.json metadata.version`, but the prior change bumped only the
  scaffold seed (`.vault-template.json`). Bumped the authoritative anchor to
  `0.2.0` and added a regression guard (`test-upgrade` T26) asserting the two
  version sources stay in sync.
- **`vault-autosync` skipped the push whenever a pre-commit auto-fixer touched
  a staged file** (HIMMEL-501) — i.e. on nearly every save. Added a single
  re-stage-and-retry pass. A real gitleaks secret block still aborts the push;
  the egress guard is fully preserved.

### Changed
- **pre-commit no longer rewrites `.md` files** (HIMMEL-501). `trailing-whitespace`
  and `end-of-file-fixer` now exclude `.md`, so Markdown hard-line-breaks (two
  trailing spaces) in your notes are never silently stripped. `.md` is still
  scanned by gitleaks / check-yaml / check-json.
- **`.gitignore` now ignores `/.worktrees/`** (HIMMEL-460) so a vault `git add -A`
  autosync can't recapture root worktree dirs as phantom submodules.

### Added
- `scripts/test-vault-git.sh` + `.ps1` — coverage for the autosync re-stage/retry
  path and the preserved secret-block invariant (HIMMEL-501).

## [0.1.1] — 2026-06-20

### Fixed
- Route Steph Ango's bundled Obsidian skill pack to its own upstream marketplace
  (`obsidian@obsidian-skills`) instead of a bare-SHA pin, which is not
  installable (HIMMEL-449/435).

## [0.1.0] — 2026-06-19

### Added
- Initial versioned template with the content-preserving `/luna-upgrade` engine
  (`scripts/upgrade.sh` / `.ps1`) — refreshes template-owned files (config,
  bundled-plugin assets, scripts, scaffold docs) without touching user content
  (journal, notes, clips), with a 3-way `_CLAUDE.md` merge and fail-closed
  version stamping (HIMMEL-389).
