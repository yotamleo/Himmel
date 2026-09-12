# Changelog — luna-second-brain template

Version history for the luna-second-brain vault template (published as
**luna-brain**). The version is `marketplace/.claude-plugin/marketplace.json`
`metadata.version`, read by `scripts/upgrade.sh` (the engine behind
`/luna-upgrade`). When the version here is newer than a vault's
`.vault-template.json` stamp, `/luna-upgrade` offers the changes below.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.4.29] — 2026-09-12

### Fixed
- The upgrade suite's structural bash-3.2 heredoc checker now honours a
  `<<-` opener's tab-indented terminator instead of silently skipping it
  (HIMMEL-2956, follow-up to HIMMEL-2952).

## [0.4.28] — 2026-09-12

### Fixed
- `upgrade.sh` now parses under macOS bash 3.2 (GitHub #627 / HIMMEL-2952).

## [0.4.27] — 2026-09-10

### Fixed
- **The HIMMEL-2903 snapshot now fails closed on load, and on a failed digest
  capture, too (HIMMEL-2918).** Two gaps left from that ticket's round-3 CR
  findings: (1) the stamp's `files` map reader treated a JSON/read error, a
  non-dict top level, and a `files` value that wasn't a dict all the same as
  the one legitimate empty case — a legacy stamp with no `files` key at all —
  silently reverting every file to the poisonable git fallback. It now
  withholds instead, the same way a failing `git log` already does. (2)
  `record_snapshot` checked the digest only against the literal `MISSING`; a
  failing `sha256sum` still leaves an empty string, which was appended
  successfully and then dropped without warning by the stamp writer,
  producing an incomplete map under a clean exit code. It now validates the
  digest and counts the failure, so the partial-upgrade guard refuses the
  stamp. The loader also tests `files` key *presence* before reading its
  value, so an explicit `"files": null` is rejected as unusable rather than
  conflated with the legitimate "no `files` key at all" legacy case.

## [0.4.25] — 2026-09-10

### Fixed
- **The local-edit baseline is a per-file content snapshot in the stamp; the
  vault's git history is now only the fallback (HIMMEL-2903).**
  `.vault-template.json` gained a `files: {"<rel>": "sha256:<hex>"}` map,
  written at the end of every successful upgrade, recording what the template
  put in each "overwrite"-class file. `scripts/upgrade.sh` compares against
  that map first. The git baseline it replaces was poisonable: a vault-local
  edit committed in the SAME commit that advances the stamp — what a batching
  autosync does — became the baseline itself, so the next upgrade saw no
  divergence and silently overwrote the edit. Vaults stamped before this
  version have no map and keep the git behaviour until their next upgrade
  writes one.
- **A failing `git log` no longer fails open (HIMMEL-2903).** An operational
  failure resolving the stamp commit (shallow clone, corrupt index, permission
  error) used to be indistinguishable from "no stamp commit", which meant no
  baseline, which meant the pre-HIMMEL-2886 silent overwrite. It now withholds
  the write and says so, matching the `cat-file`/`show` steps. The HEAD gate
  in front of it reads the exact return code: `rev-parse --verify -q HEAD`
  exits 1 for "HEAD names no commit" (a legitimately absent baseline — the
  first upgrade of a freshly `git init`-ed vault proceeds as before) and
  otherwise for an operational refs failure, which withholds like any other.
- **Snapshot persistence fails closed at every step (HIMMEL-2903).** The stamp
  is rewritten wholesale, so any run that proceeds without a complete snapshot
  strips the `files` map a vault already has and silently demotes it to the
  poisonable git baseline. A scratch file that cannot be CREATED aborts before
  the first write (nothing is modified, a re-run is clean); a row that cannot
  be APPENDED, or a scratch file that cannot be READ BACK at stamp time, leaves
  the existing stamp untouched and exits non-zero rather than writing a weaker
  one.
- **The withheld-file line names which baseline spoke.** Every "local edits
  withheld" line ends in `[baseline: snapshot]` or `[baseline: git]`, and the
  snapshot form prints the recorded and on-disk shas.

## [0.4.22] — 2026-09-10

### Fixed
- **`test-vault-git.sh`'s D11e near-miss assertion avoids a pipefail SIGPIPE
  risk (HIMMEL-2910 follow-up).** `grep -q` under `set -o pipefail` can
  SIGPIPE its producer on an early match, flipping a real gitleaks-blocked
  finding to read as a test failure; captures the pipeline into a variable
  first instead of piping into `grep -q` directly.

## [0.4.21] — 2026-09-10

### Fixed
- **`.gitleaks.toml`'s release-token allowlist tolerates trailing sentence
  punctuation (HIMMEL-2910).** The anchored regex added in HIMMEL-2886
  (`^[a-z0-9]+-[a-z0-9]+-pid[0-9]+$`) missed a token followed by punctuation
  — a leg writing `release-token=<token>.` (no backticks) into its LIVE
  bullet let gitleaks' generic-api-key rule capture the trailing `.` into
  the secret, stalling a real autosync commit for 30 min. Widened to allow
  one optional trailing `[.,;:)]` character; a suffixed real credential is
  still caught.

## [0.4.16] — 2026-09-10

### Fixed
- **`scripts/upgrade.sh` no longer silently overwrites a vault-local edit to a
  template-owned config file (HIMMEL-2886).** See the luna-upgrade-all commit
  for the full mechanism (STAMP_COMMIT-based local-edit detection); this bump
  ships the fix in `scripts/upgrade.sh` itself, which is template-owned and
  self-refreshes on every vault's next upgrade.

## [0.4.15] — 2026-09-10

### Added
- **`.gitleaks.toml` carries the queue-lock release-token allowlist (HIMMEL-2886).**
  Every leg writes a release token shaped `<host>-<arch>-pid<N>` into its handover
  doc's LIVE bullet by design (HIMMEL-2813); without this anchored regex, gitleaks'
  generic-api-key rule flags the line on entropy and blocks the vault's github-sync
  autosync commit. Previously a vault-local fix only — `/luna-upgrade` silently
  reverted it (pure overwrite, nothing printed) because the template didn't carry it.
- **`.pre-commit-config.yaml` carries the console-kit shellcheck exclude (HIMMEL-2886).**
  Archived console-kit scripts under `handovers/**/specs/console-kit-*/` are scratchpad
  copies, not shipped code; linting them stalled the same autosync sweep. Same silent-
  revert history as above.

### Fixed
- **`luna-upgrade-all apply` no longer silently overwrites a vault-local edit to a
  template-owned config file (HIMMEL-2886).** For an "overwrite"-class file the vault
  has committed a local edit to since its last stamped upgrade, the run now withholds
  that one write, prints `local edits withheld (not overwritten): <file> (backup: <path>)` with the
  lost hunk's diff, and does not classify the run `clean-upgrade` (or write the version
  stamp) until the edit is reconciled by hand.

## [0.3.1] — 2026-07-28

### Changed
- **`_CLAUDE.md` trimmed to directives (HIMMEL-480).** The operating manual is read
  every session in every vault instantiated from this template, so reference-shaped
  content earns its place or goes. Removed: an internal himmel process note about
  escalating a producing command, upstream-path asides pointing outside the vault,
  internal ticket identifiers in headings and prose, and rationale wording in the
  Contradiction-Resolution Policy. 9,155 → 8,731 bytes.
- **No contract changed.** Every directive stayed: the AI-First rules, auto-save
  rules, per-type frontmatter requirements, the decision-note `claim:`/`assumption:`
  quoting trap (an unquoted value containing a colon breaks the parse; a
  space-preceded `#` silently truncates), propose-only conflict handling, and the
  Do Not Touch list. This is a readability and cost change, not a behaviour change —
  a vault upgrading from 0.3.0 needs no migration.

## [0.3.0] — 2026-07-13

### Added
- **CONTRA layer (LUNA-94):** `_Templates/Decision.md` scaffold template with `claim:`/
  `assumption:` premise frontmatter (LUNA-95); `_CLAUDE.md` decision-note contract + the
  Contradiction-Resolution Policy — reconcile runbooks are propose-only, conflict proposals land
  in `00-Inbox/` with a conflict-note frontmatter contract (LUNA-98); `decision` and `conflict`
  added to the note-type list. Pairs with the himmel obsidian-triage `/contra` skill (ghost-self +
  bridge passes, LUNA-96/97).

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
