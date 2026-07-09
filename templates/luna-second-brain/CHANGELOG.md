# Changelog — luna-second-brain template

Version history for the luna-second-brain vault template (published as
**luna-brain**). The version is `marketplace/.claude-plugin/marketplace.json`
`metadata.version`, read by `scripts/upgrade.sh` (the engine behind
`/luna-upgrade`). When the version here is newer than a vault's
`.vault-template.json` stamp, `/luna-upgrade` offers the changes below.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.2] — 2026-07-09

### Fixed
- **pre-commit auto-fixers no longer rewrite machine-generated `.manifest.json`**
  (HIMMEL-834). The ingest pipeline (single writer) emits the manifest without
  a trailing newline; `end-of-file-fixer` rewriting it at commit time fought
  the generator and — with unstaged changes present (e.g. another session's
  `.obsidian` state) — entered pre-commit's stash-rollback path, which can
  crash mid-apply and **silently drop the unstaged changes** (observed: lost
  Obsidian plugin updates, recovered from the retained
  `~/.cache/pre-commit/patch<id>` file). Both fixers now carry
  `exclude: '^\.manifest\.json$'`; `check-json` still validates the file.
  Vaults without a manifest (non-medical profiles) are unaffected.

## [0.2.1] — 2026-06-29

### Fixed
- **Windows pre-commit crash on non-ASCII (Hebrew/CJK/accented) filenames**
  (HIMMEL-615). `trailing-whitespace` / `end-of-file-fixer` print each fixed
  path to a cp1252 stdout, so a non-ASCII source-note name raised
  `UnicodeEncodeError` — and the fixer rewrote the file *before* crashing,
  leaving a silent whitespace-only diff. Both fixers are now constrained to an
  ASCII-named code/config **allowlist** (`.sh/.ps1/.yaml/.yml/.json/.toml`)
  instead of the `.md`-only denylist, so they never touch notes or ingested
  sources — no crash, no mangling, regardless of vault directory layout. Vault
  content is still scanned by gitleaks / check-yaml / check-json.

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
