#!/usr/bin/env bash
# upgrade.sh — content-preserving vault/template upgrade (HIMMEL-389).
#
# Refreshes template-owned files in a luna-second-brain vault from a fresh
# himmel template, WITHOUT touching user content (journal, notes, clips).
# Vaults are scaffolded once and never updated; this brings later template
# fixes (e.g. a new PLUGINS-SETUP note) to existing vaults safely.
#
# Distinct from himmel harness self-update (HIMMEL-413) and marketplace
# autoUpdate (HIMMEL-365): this is VAULT CONTENT/config, not the harness.
#
# Usage:
#   bash scripts/upgrade.sh [--template-dir DIR] [--vault-dir DIR] [--check] [--dry-run] [--yes]
#
#   --template-dir DIR  fresh himmel template root (contains marketplace/ +
#                       _CLAUDE.md). Default resolution: --template-dir >
#                       $HIMMEL_DIR/templates/luna-second-brain > generic
#                       $HOME-relative candidate paths ($HOME[/Documents]/github/
#                       {himmel,Himmel}) > a sibling-dir scan for a himmel
#                       checkout carrying the template.
#   --vault-dir DIR     the vault to upgrade. Default: the parent of this
#                       script's dir (scripts/.. — i.e. run from inside a vault).
#   --check             print a one-line nudge of whether an upgrade is available
#                       (no banner, no plan, no changes), then exit 0.
#   --dry-run           print the plan, make zero filesystem changes.
#   --yes               skip the confirm prompt (used by the /luna-upgrade skill).
#   --backup-dir DIR    (optional) the pre-computed backup dest for this run,
#                       named in the local-edit-withheld message so an operator
#                       can recover the pre-upgrade file (HIMMEL-2886).
#
# Version source = the template's marketplace/.claude-plugin/marketplace.json
# metadata.version. The vault records its level in .vault-template.json; a
# missing stamp is treated as 0.0.0 (full pass). The stamp is written LAST so
# an aborted run re-runs cleanly (idempotent).
#
# Self-upgrading: this script is template-owned (scripts/** overwrite class),
# so a run also refreshes the upgrader itself.
set -uo pipefail

# ---------------------------------------------------------------------------
# Arg parsing
TEMPLATE_DIR=""
VAULT_DIR=""
DRY_RUN=0
ASSUME_YES=0
CHECK_ONLY=0
BACKUP_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --template-dir) TEMPLATE_DIR="${2:-}"; shift 2 ;;
        --vault-dir)    VAULT_DIR="${2:-}"; shift 2 ;;
        --backup-dir)   BACKUP_DIR="${2:-}"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --check)        CHECK_ONLY=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<'USAGE'
upgrade.sh — content-preserving vault/template upgrade (HIMMEL-389)

  bash scripts/upgrade.sh [--template-dir DIR] [--vault-dir DIR] [--check] [--dry-run] [--yes]

  --template-dir DIR  fresh himmel template root (default: --template-dir >
                      $HIMMEL_DIR/templates/luna-second-brain > $HOME-relative
                      candidate paths (github/{himmel,Himmel}) > sibling scan).
  --vault-dir DIR     the vault to upgrade (default: scripts/.. — run from a vault).
  --check             print a one-line nudge of whether an upgrade is available
                      (no banner, no plan, no changes), then exit 0.
  --dry-run           print the plan, make zero filesystem changes.
  --yes, -y           skip the confirm prompt.
  --backup-dir DIR    (optional) pre-computed backup dest, named in the
                      local-edit-withheld message.

Refreshes template-owned files (scripts, .obsidian config, plugin assets, docs)
WITHOUT touching user content (journal, notes, clips). Version source = the
template's marketplace.json metadata.version vs the vault's .vault-template.json.
USAGE
            exit 0 ;;
        *) echo "upgrade: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pick a template dir from a list of candidate himmel-checkout ROOTS read on
# stdin (one per line; "$rel" is appended to each). Echo the FIRST root that
# carries a real template (marketplace.json present) — a half-populated decoy
# root is skipped rather than selected-then-aborted. If more than one
# PHYSICALLY-distinct checkout matches (e.g. a stale clone beside the live one
# — the dual-clone trap), warn to stderr and use the first; the operator
# disambiguates with --template-dir / $HIMMEL_DIR. Returns 1 (echoes nothing)
# when none match. Used for BOTH the $HOME-candidate step and the sibling scan
# so the two surfaces behave identically (HIMMEL-420). Loop/input order is
# contractual: earlier roots win on a tie (tests T19/T22 pin this).
pick_template_root() {
    local rel="$1" root tdir key first_dir="" first_key=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        tdir="$root/$rel"
        [ -f "$tdir/marketplace/.claude-plugin/marketplace.json" ] || continue
        # Identity key dedupes case-spelling variants of ONE physical dir
        # (case-insensitive FS on Windows/macOS) so a single clone never looks
        # like "multiple checkouts". device:inode via GNU then BSD stat;
        # lowercased-path fallback when stat is unavailable.
        key="$(stat -c '%d:%i' "$tdir" 2>/dev/null || stat -f '%d:%i' "$tdir" 2>/dev/null)"
        [ -n "$key" ] || key="$(printf '%s' "$tdir" | tr '[:upper:]' '[:lower:]')"
        if [ -z "$first_dir" ]; then
            first_dir="$tdir"; first_key="$key"
        elif [ "$key" != "$first_key" ]; then
            echo "upgrade: WARNING — multiple himmel checkouts found; using $first_dir. Pass --template-dir or set HIMMEL_DIR to disambiguate." >&2
            break
        fi
    done
    [ -n "$first_dir" ] || return 1
    printf '%s' "$first_dir"
}

# ---------------------------------------------------------------------------
# Resolve template dir: --template-dir > $HIMMEL_DIR > generic $HOME-relative
# candidate paths > sibling-dir scan. Explicit config (--template-dir /
# $HIMMEL_DIR) ALWAYS wins over the discovered candidates.
resolve_template() {
    local rel="templates/luna-second-brain" got
    if [ -n "$TEMPLATE_DIR" ]; then printf '%s' "$TEMPLATE_DIR"; return; fi
    if [ -n "${HIMMEL_DIR:-}" ] && [ -d "$HIMMEL_DIR/$rel" ]; then printf '%s' "$HIMMEL_DIR/$rel"; return; fi
    # Generic $HOME-relative candidate checkouts: common himmel clone conventions
    # so the skill/CLI work zero-config when the vault and himmel are NOT
    # siblings. Public-safe — derived from $HOME, never an operator-specific
    # string. Both the lowercase `himmel` and capitalized `Himmel` conventions.
    # Order is contractual: github/ before Documents/github/ (test T19 pins it).
    if [ -n "${HOME:-}" ]; then
        if got="$(printf '%s\n' \
                "$HOME/github/himmel" "$HOME/github/Himmel" \
                "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" \
                | pick_template_root "$rel")"; then
            printf '%s' "$got"; return
        fi
    fi
    # Sibling scan: look one level up from the vault for a himmel checkout. Goes
    # through pick_template_root too, so it is decoy-safe and warns on multiple
    # distinct sibling checkouts, matching the $HOME surface (HIMMEL-420).
    local base; base="$(cd "$VAULT_DIR/.." 2>/dev/null && pwd)"
    if [ -n "$base" ]; then
        local c
        if got="$( { for c in "$base"/himmel "$base"/Himmel "$base"/*/; do printf '%s\n' "${c%/}"; done; } | pick_template_root "$rel")"; then
            printf '%s' "$got"; return
        fi
    fi
    return 1
}

# Default vault = scripts/.. (run from inside the vault).
if [ -z "$VAULT_DIR" ]; then VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; fi
if [ ! -d "$VAULT_DIR" ]; then echo "upgrade: vault dir does not exist: $VAULT_DIR" >&2; exit 2; fi
VAULT_DIR="$(cd "$VAULT_DIR" && pwd)"

if ! TEMPLATE_DIR="$(resolve_template)"; then
    echo "upgrade: could not locate the himmel template. Pass --template-dir DIR or set HIMMEL_DIR." >&2
    exit 2
fi
if [ ! -d "$TEMPLATE_DIR" ]; then echo "upgrade: template dir does not exist: $TEMPLATE_DIR" >&2; exit 2; fi
TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" && pwd)"

MARKETPLACE_JSON="$TEMPLATE_DIR/marketplace/.claude-plugin/marketplace.json"
if [ ! -f "$MARKETPLACE_JSON" ]; then
    echo "upgrade: template marketplace.json not found at $MARKETPLACE_JSON — not a luna-second-brain template?" >&2
    exit 2
fi

# Resolve a WORKING python. On Windows `python3` is often the Microsoft Store
# stub: it is on PATH (so `command -v python3` succeeds) but non-functional —
# it prints "Python was not found", exits nonzero, and emits NO stdout. So probe
# actual stdout (`print(1)` -> `1`), not exit status, and pick the first that
# really runs. Order keeps python3 canonical on Linux/macOS.
_resolve_python() {
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 \
           && [ "$("$c" -c 'print(1)' 2>/dev/null)" = "1" ]; then
            printf '%s\n' "$c"; return 0
        fi
    done
    return 1
}
PYTHON="$(_resolve_python || true)"
[ -n "$PYTHON" ] || { echo "upgrade: required tool not on PATH: a working python (tried python3/python/py)" >&2; exit 2; }

for _t in git sha256sum; do
    command -v "$_t" >/dev/null 2>&1 || { echo "upgrade: required tool not on PATH: $_t" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# Versions
TEMPLATE_VERSION="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["version"])' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ -z "$TEMPLATE_VERSION" ]; then echo "upgrade: could not read metadata.version from $MARKETPLACE_JSON" >&2; exit 2; fi

STAMP="$VAULT_DIR/.vault-template.json"
if [ -f "$STAMP" ]; then
    # A present-but-unreadable stamp is distinct from no stamp: warn (so a
    # corrupt stamp doesn't silently escalate to a from-scratch full pass).
    if ! VAULT_VERSION="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$STAMP" 2>/dev/null)" || [ -z "$VAULT_VERSION" ]; then
        echo "upgrade: WARNING — $STAMP is unreadable or has no version; treating vault as un-stamped (full pass)." >&2
        VAULT_VERSION="0.0.0"
    fi
else
    VAULT_VERSION="0.0.0"
fi

# ---------------------------------------------------------------------------
# Per-file content snapshot (HIMMEL-2903). The stamp carries a
# `files: {"<rel>": "sha256:<hex>"}` map of what the template last wrote for
# every "overwrite"-class file. That is a baseline the VAULT's own git history
# cannot poison, so it is preferred over the STAMP_COMMIT baseline below.
# Read once, into newline-separated "<rel><TAB><sha256:hex>" rows (bash 3.2 —
# no associative arrays). A stamp without a `files` map (any vault last
# upgraded before this version) yields an empty map and the git baseline
# carries, exactly as before; the first upgrade under this version writes one.
# BASELINE_ERROR / BASELINE_ERROR_REASON are also set by the git-log checks
# below (HIMMEL-2886/2903); initialized here so a snapshot-load failure isn't
# clobbered back to 0 by that later block.
BASELINE_ERROR=0
BASELINE_ERROR_REASON=""
SNAPSHOT_MAP=""
if [ -f "$STAMP" ]; then
    # HIMMEL-2918: the python heredoc's rc distinguishes the one legitimate
    # empty map (no `files` key at all — a legacy stamp, rc 0) from an
    # unreadable/malformed one (rc != 0: a JSON/read error, a non-dict top
    # level, or a `files` value that isn't a dict). Collapsing those was
    # fail-OPEN: an empty SNAPSHOT_MAP is indistinguishable from "nothing to
    # withhold", reverting every file to the poisonable git fallback
    # HIMMEL-2903 exists to replace. Fail CLOSED instead, the same way a
    # failing `git log` already does below.
    if ! SNAPSHOT_MAP="$("$PYTHON" - "$STAMP" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if "files" not in d:
    sys.exit(0)  # legacy stamp, no `files` key at all — fall back to git.
files = d.get("files")
if not isinstance(files, dict):
    sys.exit(1)  # present but unusable (e.g. explicit `"files": null`) — an error, not legacy.
for rel in sorted(files):
    sha = files[rel]
    # A rel with a tab/newline in it would corrupt the row format; such a path
    # cannot come from this script's own writer, so skip rather than trust it.
    if isinstance(sha, str) and isinstance(rel, str) and not (set("\t\n\r") & set(rel)):
        print("%s\t%s" % (rel, sha))
PY
)"; then
        SNAPSHOT_MAP=""
        BASELINE_ERROR=1
        BASELINE_ERROR_REASON="snapshot unreadable"
    fi
fi

# snapshot_sha <rel>: echo the recorded "sha256:<hex>" for <rel>, or nothing.
snapshot_sha() {
    local want="$1" rel sha
    [ -n "$SNAPSHOT_MAP" ] || return 1
    while IFS="$(printf '\t')" read -r rel sha; do
        if [ "$rel" = "$want" ] && [ -n "$sha" ]; then
            printf '%s' "$sha"
            return 0
        fi
    done <<EOF
$SNAPSHOT_MAP
EOF
    return 1
}

# semver-ish compare: return 0 iff $1 < $2.
ver_lt() {
    [ "$1" = "$2" ] && return 1
    local lo; lo="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
    [ "$lo" = "$1" ]
}

# --check: report whether an upgrade is available, then exit. No banner, no
# plan, no filesystem changes — a soft nudge for setup / SessionStart surfaces
# (HIMMEL-423). The /luna-upgrade skill's --check path surfaces this line.
if [ "$CHECK_ONLY" = 1 ]; then
    if ver_lt "$VAULT_VERSION" "$TEMPLATE_VERSION"; then
        echo "luna-second-brain: template v$TEMPLATE_VERSION available (vault is v$VAULT_VERSION). Run: bash scripts/upgrade.sh (or /luna-upgrade)."
    else
        echo "luna-second-brain: vault is current (v$VAULT_VERSION)."
    fi
    exit 0
fi

echo "==> luna-second-brain upgrade"
echo "    template : $TEMPLATE_DIR (v$TEMPLATE_VERSION)"
echo "    vault    : $VAULT_DIR (v$VAULT_VERSION)"
echo ""

if [ "$VAULT_VERSION" = "$TEMPLATE_VERSION" ] || ! ver_lt "$VAULT_VERSION" "$TEMPLATE_VERSION"; then
    echo "Vault is already current (v$VAULT_VERSION) — nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Local-edit detection (HIMMEL-2886): an "overwrite"-class file the vault
# itself has diverged on since its last stamped upgrade must not be silently
# clobbered — the template's own committed history has no view of vault-local
# edits, but the VAULT's git history does. STAMP_COMMIT is the last commit
# that wrote .vault-template.json (i.e. the vault's last upgrade); comparing
# a file's content there against its content NOW tells us whether the vault
# edited it locally after that upgrade (vs. the file only ever having been
# template-driven). A vault with no git repo, or no such commit (never
# upgraded via a git-tracked flow), has no baseline to compare against, so
# falls back to the pre-existing overwrite behavior.
#
# The git baseline is now the FALLBACK, not the primary one (HIMMEL-2903): it
# is poisonable. If a local edit to a template-owned file is committed in the
# SAME commit that also advances the stamp (e.g. a batching autosync — what the
# luna github-sync plugin does every 10 min), that commit becomes STAMP_COMMIT
# itself, so the baseline it reads back already contains the edit and a later
# run sees no divergence. The per-file content snapshot in the stamp
# (SNAPSHOT_MAP above) is independent of the vault's commit history and is
# consulted first; the git baseline only answers for files the snapshot has no
# entry for (a vault whose last upgrade predates the snapshot).
STAMP_COMMIT=""
# BASELINE_ERROR: `git log` FAILED operationally (shallow clone, corrupt index,
# permission error) — distinct from "git ran and found no such commit" (rc 0,
# empty stdout). Treating the two alike is fail-OPEN: an empty STAMP_COMMIT
# means "no baseline" means the pre-HIMMEL-2886 silent overwrite, which is the
# exact failure this detection exists to close. has_local_edit fails CLOSED on
# a cat-file/show error already; this makes the `git log` step consistent.
# (Initialized above, before the snapshot-load block, so a snapshot failure
# there isn't clobbered back to 0 here — HIMMEL-2918.)
# `git rev-parse --is-inside-work-tree`, not `[ -d "$VAULT_DIR/.git" ]`: a
# worktree or a submodule has a `.git` FILE (a `gitdir: <path>` pointer), not
# a directory, so the directory-only check silently fell back to the
# pre-existing overwrite behavior for exactly those vaults.
if git -C "$VAULT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # HEAD gate first: `git log` also exits 128 in a repo with NO commits yet
    # ("does not have any commits yet"). That is a legitimately absent
    # baseline, not an operational failure — without this gate the first
    # upgrade of a freshly `git init`-ed vault would withhold every file.
    #
    # The gate reads the EXACT rc, not merely non-zero: `rev-parse --verify -q`
    # exits 1 for "HEAD names no commit" (an unborn branch, or a HEAD ref with
    # nothing behind it — git itself cannot tell those apart, and both are a
    # genuinely absent baseline), and exits otherwise (128) for an operational
    # failure such as an unreadable refs backend. Collapsing the two would let
    # a refs-layer error masquerade as a fresh vault and fail OPEN, which is
    # the same hole this block closes one step further down.
    git -C "$VAULT_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1
    head_rc=$?
    if [ "$head_rc" -eq 1 ]; then
        : # HEAD names no commit — no baseline, like a vault with no repo
    elif [ "$head_rc" -ne 0 ]; then
        BASELINE_ERROR=1
        BASELINE_ERROR_REASON="git rev-parse failed"
    elif ! STAMP_COMMIT="$(git -C "$VAULT_DIR" log -1 --format=%H -- .vault-template.json 2>/dev/null)"; then
        STAMP_COMMIT=""
        BASELINE_ERROR=1
        BASELINE_ERROR_REASON="git log failed"
    fi
fi

# withhold_notice <rel> <provenance>: the shared "local edits withheld" line.
# <provenance> names WHICH baseline spoke (snapshot | git) so an operator
# reading a --dry-run plan can tell the stamp's content snapshot from the
# vault-git fallback in one word (HIMMEL-2903).
withhold_notice() {
    local rel="$1" prov="$2" backup_note="none (no --backup-dir given for this run)"
    [ -n "$BACKUP_DIR" ] && backup_note="$BACKUP_DIR/$rel"
    echo "  local edits withheld (not overwritten): $rel (backup: $backup_note) [baseline: $prov]"
}

# has_local_edit <rel> <dst> [print]: exit 0 iff <dst> differs from the
# baseline for <rel> — i.e. the vault edited it since its last upgrade.
# Baseline resolution order (HIMMEL-2903):
#   1. the stamp's per-file content snapshot, when it has an entry for <rel>
#      (authoritative: independent of the vault's commit history);
#   2. else the content committed at STAMP_COMMIT (the vault's last stamped
#      upgrade) — the pre-2903 behaviour, kept for vaults stamped before the
#      snapshot existed, and fail-CLOSED when `git log` itself failed;
#   3. no baseline at all (no repo, no stamp commit, new template-owned file)
#      => not a local edit, the pre-existing overwrite behaviour.
# A file recorded in the snapshot but absent on disk is NOT a local edit —
# deleted files stay the existing code path's business.
# With [print]=1, also emits the "local edits withheld" line (+ a unified diff
# of the withheld hunk on the git path) — called once per file (the planning
# pass only; the execute pass re-detects the same files but must not re-print).
has_local_edit() {
    local rel="$1" dst="$2" print="${3:-0}"
    [ -f "$dst" ] || return 1

    # (1) Snapshot baseline: the sha the template itself last wrote here.
    local snap dst_sha
    if snap="$(snapshot_sha "$rel")" && [ -n "$snap" ]; then
        dst_sha="sha256:$(sha_of "$dst")"
        if [ "$snap" != "$dst_sha" ]; then
            if [ "$print" = 1 ]; then
                withhold_notice "$rel" "snapshot"
                # The snapshot is a hash, not content — there is nothing to
                # diff against, so name both shas instead of printing nothing.
                echo "    recorded at the last upgrade: $snap"
                echo "    on disk now:                  $dst_sha"
            fi
            return 0
        fi
        return 1
    fi

    # (2) git baseline. A failed `git log` is not a proven absence of one.
    if [ "$BASELINE_ERROR" = 1 ]; then
        [ "$print" = 1 ] && echo "  could not determine the upgrade baseline ($BASELINE_ERROR_REASON) — withholding $rel as a precaution"
        return 0
    fi
    [ -n "$STAMP_COMMIT" ] || return 1
    # `./$rel`, not a bare `$rel`: `git show <rev>:<path>` resolves a path
    # relative to the CURRENT DIRECTORY only when it starts with `./` —
    # a bare path is repo-root-relative, which is the WRONG root whenever
    # VAULT_DIR is a subdirectory of a larger enclosing repo (verified: a
    # bare path there errors "path exists, but not <rel>" and git's own
    # hint names the `./` form).
    #
    # Existence check FIRST, and distinct from retrieval below: a file
    # genuinely absent at STAMP_COMMIT (a new template-owned file) must
    # return 1 same as always, but an OPERATIONAL failure retrieving a file
    # that does exist there (a broken git object, or mktemp below failing to
    # give us anywhere to write) must NOT be read the same way — silently
    # falling through to "no local edit" on an error is the exact silent-
    # overwrite failure mode this function exists to close, just via a
    # different path. Fail CLOSED (withhold) on an operational error instead.
    local cat_err
    if ! cat_err="$(git -C "$VAULT_DIR" cat-file -e "$STAMP_COMMIT:./$rel" 2>&1)"; then
        case "$cat_err" in
            *"does not exist"*)
                # Legitimately absent at the stamp commit (a new
                # template-owned file) — not a local edit.
                return 1
                ;;
            *)
                # Any OTHER cat-file failure (corrupt object, invalid
                # STAMP_COMMIT, etc.) is an operational error, not a proven
                # absence — fail CLOSED rather than silently allowing the
                # write through on a failure we cannot interpret.
                [ "$print" = 1 ] && echo "  could not verify local edits for $rel (git cat-file failed) — withholding the write as a precaution"
                return 0
                ;;
        esac
    fi
    local committed; committed="$(mktemp)"
    if [ -z "$committed" ] || [ ! -e "$committed" ]; then
        [ "$print" = 1 ] && echo "  could not verify local edits for $rel (mktemp failed) — withholding the write as a precaution"
        return 0
    fi
    if ! git -C "$VAULT_DIR" show "$STAMP_COMMIT:./$rel" > "$committed" 2>/dev/null; then
        rm -f "$committed"
        [ "$print" = 1 ] && echo "  could not verify local edits for $rel (git show failed) — withholding the write as a precaution"
        return 0
    fi
    local committed_sha
    committed_sha="$(sha_of "$committed")"
    dst_sha="$(sha_of "$dst")"
    if [ "$committed_sha" != "$dst_sha" ]; then
        if [ "$print" = 1 ]; then
            withhold_notice "$rel" "git"
            if command -v diff >/dev/null 2>&1; then
                diff -u "$committed" "$dst" | sed 's/^/    /'
            fi
        fi
        rm -f "$committed"
        return 0
    fi
    rm -f "$committed"
    return 1
}

# ---------------------------------------------------------------------------
# Per-file classification. Returns one of:
#   overwrite | jsonmerge | skipexists | threeway | report | skip
# Extensible per-profile (HIMMEL-389 scope §8): a future wiki profile keys off
# the .vault-template.json "template" field and swaps this classifier.
classify() {
    case "$1" in
        _CLAUDE.md)                                   echo threeway ;;
        _Templates/*.md)                              echo report ;;
        .obsidian/community-plugins.json)             echo jsonmerge ;;
        .obsidian/plugins/*/data.json)                echo skipexists ;;
        .obsidian/plugins/*/main.js|.obsidian/plugins/*/manifest.json|.obsidian/plugins/*/styles.css) echo skipexists ;;
        .obsidian/PLUGINS-SETUP.md)                   echo overwrite ;;
        .obsidian/app.json|.obsidian/appearance.json|.obsidian/graph.json|.obsidian/core-plugins.json) echo overwrite ;;
        scripts/*)                                    echo overwrite ;;
        docs/*)                                       echo overwrite ;;
        .pre-commit-config.yaml)                      echo overwrite ;;
        marketplace/.claude-plugin/marketplace.json)  echo overwrite ;;
        .env.example|.gitignore|.gitattributes|.gitleaks.toml|README.md) echo overwrite ;;
        *)                                            echo skip ;;
    esac
}

# Atomic write: copy src over dst via temp + rename (handles self-overwrite of
# this running script: POSIX keeps the open inode; Windows rename-over may fail,
# which we treat as non-fatal).
write_file() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    local tmp="$dst.upgrade-tmp.$$"
    if cp "$src" "$tmp" 2>/dev/null && mv "$tmp" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    echo "  WARN: could not update $dst (left as-is)" >&2
    return 1
}

sha_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo MISSING; fi; }

# Snapshot accumulator (HIMMEL-2903): the execute pass records, for every
# "overwrite"-class file, the sha of what is in the VAULT once the pass is
# done — which is what the template just wrote, because the stamp is written
# ONLY when the run fully succeeded (no withheld edits, no write failures).
# That sha becomes the next run's baseline, immune to whatever the vault
# afterwards commits alongside the stamp. A file the template owns but that
# is absent in the vault records nothing.
SNAPSHOT_FILE=""
trap '[ -n "${SNAPSHOT_FILE:-}" ] && rm -f "$SNAPSHOT_FILE"; true' EXIT

SNAPSHOT_FAILURES=0
record_snapshot() {
    local rel="$1" dst="$2" s
    [ -n "$SNAPSHOT_FILE" ] || return 0
    s="$(sha_of "$dst")"
    [ "$s" = "MISSING" ] && return 0
    # HIMMEL-2918: a failing sha256sum still leaves `cut` exiting 0 on no
    # input, so `s` can come back "" here — checked only against MISSING
    # above, an empty (or otherwise malformed) digest slipped past silently
    # and produced an incomplete <rel><TAB> row that the stamp writer's
    # `if tab and rel and sha` later drops without warning. Reject anything
    # that isn't a 64-char lowercase hex digest before it is ever written.
    case "$s" in
        *[!0-9a-f]*|"") s="" ;;
    esac
    if [ -z "$s" ] || [ "${#s}" -ne 64 ]; then
        SNAPSHOT_FAILURES=$((SNAPSHOT_FAILURES+1))
        echo "  WARN: could not record the content snapshot for $rel (invalid digest)" >&2
        return 0
    fi
    # A dropped row is not cosmetic: the stamp is rewritten wholesale, so a
    # file whose row never lands loses its snapshot entry and silently reverts
    # to the poisonable git baseline. Count the failure and let the stamp guard
    # below refuse the write, the same way a failed file write does.
    if ! printf '%s\t%s\n' "$rel" "$s" >> "$SNAPSHOT_FILE"; then
        SNAPSHOT_FAILURES=$((SNAPSHOT_FAILURES+1))
        echo "  WARN: could not record the content snapshot for $rel" >&2
    fi
}

# Capture the vault's prior PLUGINS-SETUP.md sha BEFORE any overwrite, so the
# reprint check (step 4) can tell whether the manual-install table changed.
PLUGINS_SETUP_REL=".obsidian/PLUGINS-SETUP.md"
PLUGINS_SETUP_PRIOR_SHA="$(sha_of "$VAULT_DIR/$PLUGINS_SETUP_REL")"

# ---------------------------------------------------------------------------
# Build + print plan, then execute (unless --dry-run). One pass over the
# template-owned files; user content is never enumerated so it can't be touched.
n_write=0 n_skip_identical=0 n_skip_exists=0 n_jsonmerge=0 n_report=0 n_threeway=0 n_local_edit=0
WRITE_FAILURES=0
declare -a PLAN

CLAUDE_MERGE_RESULT=""   # set to clean|copied|conflict|error during execute

# JSON add-only merge for community-plugins.json. Prints the ids it would add
# (one per line) to stdout; with EXECUTE=1 also writes the merged file.
plugins_merge() {
    local vault_f="$1" tmpl_f="$2" execute="$3"
    EXECUTE="$execute" "$PYTHON" - "$vault_f" "$tmpl_f" <<'PY'
import json, os, sys
vault_p, tmpl_p = sys.argv[1], sys.argv[2]
execute = os.environ.get("EXECUTE") == "1"
# Safety: a present-but-unreadable or non-array vault file is left UNTOUCHED
# (never coerced to [] and overwritten — that would destroy the user's plugin
# list). Only a clean JSON array is merged into; a missing file starts as [].
if os.path.exists(vault_p):
    try:
        vault = json.load(open(vault_p, encoding="utf-8"))
    except (ValueError, OSError) as e:
        sys.stderr.write("  WARN: %s is unreadable (%s); leaving untouched\n" % (vault_p, e))
        sys.exit(0)
    if not isinstance(vault, list):
        sys.stderr.write("  WARN: %s is not a JSON array; leaving untouched\n" % vault_p)
        sys.exit(0)
else:
    vault = []
tmpl = json.load(open(tmpl_p, encoding="utf-8"))
seen = set(vault)
added = [x for x in tmpl if x not in seen]
for a in added:
    print(a)
if execute and added:
    merged = list(vault) + added
    with open(vault_p, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
PY
}

# 3-way merge _CLAUDE.md into a temp. git merge-file -p exits with the NUMBER
# OF CONFLICT HUNKS: 0 = clean, 1..127 = a conflict (exit code = hunk count, so
# a multi-hunk conflict returns 2, 3, ... and is STILL a conflict), >=128 =
# genuine error (missing/unreadable input, etc.). clean/copied => replace +
# advance the base snapshot; conflict => sidecar + alert; error => surface git's
# stderr. The base snapshot is advanced ONLY on a clean/copied result — leaving
# it on conflict/error means a future template bump re-runs the same 3-way and
# re-surfaces the unresolved change rather than silently resolving it ours-wins.
claude_threeway() {
    local execute="$1"
    local ours="$VAULT_DIR/_CLAUDE.md"
    local theirs="$TEMPLATE_DIR/_CLAUDE.md"
    local base_dir="$VAULT_DIR/.vault-template.base"
    local base="$base_dir/_CLAUDE.md"
    [ -f "$theirs" ] || return 0
    # Advance the base snapshot to theirs (best-effort; a failure here means the
    # NEXT run can't 3-way and falls back to ours-wins, so warn but don't fail).
    advance_base() {
        mkdir -p "$base_dir" && cp "$theirs" "$base" \
            || echo "  WARN: base snapshot for _CLAUDE.md not updated (next run uses ours-wins fallback)" >&2
    }
    # Vault has no _CLAUDE.md at all => copy theirs (additive).
    if [ ! -f "$ours" ]; then
        CLAUDE_MERGE_RESULT="copied"
        if [ "$execute" = 1 ]; then
            write_file "$theirs" "$ours" || { WRITE_FAILURES=$((WRITE_FAILURES+1)); return 0; }
            advance_base
        fi
        return 0
    fi
    # No recorded base => use pristine template as base (=> ours wins, safe).
    local base_use="$base"
    [ -f "$base" ] || base_use="$theirs"
    local merged mf_err rc
    # Preflight the git launcher itself: `git merge-file` exits with the
    # conflict-hunk count TRUNCATED TO 127, so 126/127 from the merge are
    # legitimate high-conflict results — indistinguishable from the shell's
    # own 126 ("found but not executable") / 127 ("command not found") for a
    # broken git install. Proving git runs HERE removes that ambiguity: any
    # later 126/127 is a real conflict count, never a launcher failure.
    if ! git --version >/dev/null 2>&1; then
        CLAUDE_MERGE_RESULT="error"
        echo "  ERROR: git is missing or not runnable — cannot 3-way merge _CLAUDE.md" >&2
        return 0
    fi
    merged="$(mktemp)"; mf_err="$(mktemp)"
    git merge-file -p "$ours" "$base_use" "$theirs" > "$merged" 2>"$mf_err"; rc=$?
    if [ "$rc" -eq 0 ]; then
        CLAUDE_MERGE_RESULT="clean"
        if [ "$execute" = 1 ]; then
            # Route the merged write through write_file so a failed write counts
            # toward WRITE_FAILURES (fail-closed) and the base only advances if
            # _CLAUDE.md was actually replaced — never a lying stamp + lost merge.
            if write_file "$merged" "$ours"; then
                advance_base
            else
                WRITE_FAILURES=$((WRITE_FAILURES+1))
            fi
        fi
    elif [ "$rc" -ge 1 ] && [ "$rc" -le 127 ]; then
        # merge-file returns the conflict HUNK COUNT, truncated to 127; the
        # launcher preflight above already proved git runs, so 126/127 here
        # are real (extreme) conflict counts, not launcher failures. >=128
        # is a genuine error.
        CLAUDE_MERGE_RESULT="conflict"
        # Leave _CLAUDE.md untouched; write the conflicted merge to a sidecar.
        # Do NOT advance the base snapshot (so the conflict re-surfaces).
        # A silent `cp` failure here would recreate the very bug this change
        # fixes one path over: the operator is told there is a conflict and
        # pointed at a sidecar that does not exist. Fail loudly instead.
        if [ "$execute" = 1 ] && ! cp "$merged" "$VAULT_DIR/_CLAUDE.md.template-merge"; then
            CLAUDE_MERGE_RESULT="error"
            echo "  ERROR: could not write the _CLAUDE.md merge sidecar to $VAULT_DIR/_CLAUDE.md.template-merge" >&2
        fi
    else
        CLAUDE_MERGE_RESULT="error"
        echo "  ERROR: git merge-file failed for _CLAUDE.md (rc=$rc)" >&2
        if [ -s "$mf_err" ]; then
            sed 's/^/    /' "$mf_err" >&2
        else
            echo "    (git produced no diagnostic output)" >&2
        fi
    fi
    rm -f "$merged" "$mf_err"
}

process() {
    local execute="$1" rel class src dst
    while IFS= read -r src; do
        rel="${src#"$TEMPLATE_DIR"/}"
        class="$(classify "$rel")"
        dst="$VAULT_DIR/$rel"
        case "$class" in
            skip) ;;
            overwrite)
                if [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
                    if has_local_edit "$rel" "$dst" "$((1 - execute))"; then
                        PLAN+=("LOCAL-EDIT   $rel (vault has local edits since last upgrade — NOT overwritten)")
                        n_local_edit=$((n_local_edit+1))
                    else
                        PLAN+=("WRITE        $rel"); n_write=$((n_write+1))
                        [ "$execute" = 1 ] && { write_file "$src" "$dst" || WRITE_FAILURES=$((WRITE_FAILURES+1)); }
                    fi
                else
                    n_skip_identical=$((n_skip_identical+1))
                fi
                # Record the post-pass content regardless of the branch taken:
                # written, identical, or withheld. A withheld file blocks the
                # stamp write entirely, so its row never reaches a stamp.
                if [ "$execute" = 1 ]; then record_snapshot "$rel" "$dst"; fi ;;
            skipexists)
                if [ -f "$dst" ]; then
                    n_skip_exists=$((n_skip_exists+1))
                else
                    PLAN+=("WRITE-NEW    $rel"); n_write=$((n_write+1))
                    [ "$execute" = 1 ] && { write_file "$src" "$dst" || WRITE_FAILURES=$((WRITE_FAILURES+1)); }
                fi ;;
            report)
                if [ ! -f "$dst" ]; then
                    PLAN+=("WRITE-NEW    $rel"); n_write=$((n_write+1))
                    [ "$execute" = 1 ] && { write_file "$src" "$dst" || WRITE_FAILURES=$((WRITE_FAILURES+1)); }
                elif [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
                    PLAN+=("REPORT       $rel (template changed; review — not overwritten)"); n_report=$((n_report+1))
                fi ;;
            jsonmerge|threeway) : ;;  # handled out-of-loop below
        esac
    done < <(find "$TEMPLATE_DIR" -type f 2>/dev/null)

    # community-plugins.json add-only merge.
    local cp_rel=".obsidian/community-plugins.json"
    if [ -f "$TEMPLATE_DIR/$cp_rel" ]; then
        local added; added="$(plugins_merge "$VAULT_DIR/$cp_rel" "$TEMPLATE_DIR/$cp_rel" "0")"
        if [ -n "$added" ]; then
            PLAN+=("MERGE-JSON   $cp_rel (+$(echo "$added" | tr '\n' ',' | sed 's/,$//'))"); n_jsonmerge=$((n_jsonmerge+1))
            [ "$execute" = 1 ] && plugins_merge "$VAULT_DIR/$cp_rel" "$TEMPLATE_DIR/$cp_rel" "1" >/dev/null
        fi
    fi

    # _CLAUDE.md 3-way.
    claude_threeway "$execute"
    case "$CLAUDE_MERGE_RESULT" in
        copied)   PLAN+=("WRITE-NEW    _CLAUDE.md"); n_threeway=$((n_threeway+1)) ;;
        clean)    PLAN+=("MERGE-3WAY   _CLAUDE.md (clean — merged)"); n_threeway=$((n_threeway+1)) ;;
        conflict) PLAN+=("MERGE-3WAY   _CLAUDE.md (CONFLICT — original kept, see _CLAUDE.md.template-merge)"); n_threeway=$((n_threeway+1)) ;;
        error)    PLAN+=("MERGE-3WAY   _CLAUDE.md (ERROR — git merge-file failed, original kept)"); n_threeway=$((n_threeway+1)) ;;
    esac
}

# --- Plan pass (no writes) ---
process 0

if [ "${#PLAN[@]}" -eq 0 ]; then
    echo "No template-owned files differ — vault content is current. Writing version stamp."
else
    echo "Plan ($((n_write)) write, $n_jsonmerge json-merge, $n_threeway _CLAUDE.md, $n_report report, $n_skip_identical identical, $n_skip_exists user-kept, $n_local_edit local-edit-withheld):"
    printf '  %s\n' "${PLAN[@]}"
fi
echo ""

if [ "$DRY_RUN" = 1 ]; then
    [ -f "$VAULT_DIR/.salus-profile" ] && echo "  (salus profile: would refresh medic skill + egress floor — operator content untouched)"
    echo "--dry-run: no changes made."
    exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
    printf 'Proceed and upgrade this vault to v%s? [y/N] ' "$TEMPLATE_VERSION"
    read -r _ans || _ans=""
    case "$_ans" in [yY]|[yY][eE][sS]) ;; *) echo "aborted — no changes made."; exit 0 ;; esac
fi

# --- Execute pass ---
# Without a scratch file there is no snapshot to record — and because the stamp
# is REWRITTEN wholesale below, a run that proceeds anyway would strip whatever
# `files` map the vault already had, silently demoting it back to the poisonable
# git baseline this change exists to replace. So refuse HERE, before the first
# write: nothing has been touched yet, so the abort leaves the vault exactly as
# it was and a re-run is clean.
SNAPSHOT_FILE="$(mktemp -t luna-upgrade-snapshot.XXXXXX 2>/dev/null)"
if [ -z "$SNAPSHOT_FILE" ] || [ ! -e "$SNAPSHOT_FILE" ]; then
    echo "upgrade: could not create a temp file for the content snapshot — aborting before any change." >&2
    echo "  Proceeding would rewrite $STAMP without its content snapshot, dropping the" >&2
    echo "  local-edit baseline the vault already has. No files were modified; free up" >&2
    echo "  temp space (or set TMPDIR to a writable directory) and re-run." >&2
    exit 2
fi
PLAN=()
n_write=0 n_skip_identical=0 n_skip_exists=0 n_jsonmerge=0 n_report=0 n_threeway=0 n_local_edit=0
WRITE_FAILURES=0
CLAUDE_MERGE_RESULT=""
process 1

# salus medical profile (HIMMEL-577): on a vault that opted into the salus profile
# (.salus-profile present), refresh the medic skill + PHI-egress floor from the
# template via the tested overlay apply. PROFILE-GATED so a non-medical luna vault
# never receives the egress floor (which HARD-blocks its MCP/web workflows).
# Content-safe: the apply re-installs only code/config — the _-root scaffolds are
# scaffold-new-only and the operator's settings.json / _skin-photo-archive.md are
# never clobbered (see lib/salus-overlay.sh).
if [ -f "$VAULT_DIR/.salus-profile" ] && [ -f "$TEMPLATE_DIR/scripts/lib/salus-overlay.sh" ]; then
    mkdir -p "$VAULT_DIR/_profiles"
    cp -R "$TEMPLATE_DIR/_profiles/salus" "$VAULT_DIR/_profiles/"
    # shellcheck source=lib/salus-overlay.sh
    # shellcheck disable=SC1091
    . "$TEMPLATE_DIR/scripts/lib/salus-overlay.sh"
    if apply_salus_overlay "$VAULT_DIR" >/dev/null; then
        echo "  salus profile: refreshed medic skill + egress floor (operator content untouched)."
    fi
fi

# Step 4: reprint the manual-install table if PLUGINS-SETUP.md changed.
if [ "$(sha_of "$TEMPLATE_DIR/$PLUGINS_SETUP_REL")" != "$PLUGINS_SETUP_PRIOR_SHA" ] && [ -f "$VAULT_DIR/$PLUGINS_SETUP_REL" ]; then
    echo ""
    echo "================= PLUGINS-SETUP.md changed — manual-install table ================="
    cat "$VAULT_DIR/$PLUGINS_SETUP_REL"
    echo "==================================================================================="
fi

# Loud alert if _CLAUDE.md merge conflicted.
if [ "$CLAUDE_MERGE_RESULT" = "conflict" ]; then
    echo "" >&2
    echo "!! _CLAUDE.md had a MERGE CONFLICT with the new template. Your _CLAUDE.md was" >&2
    echo "!! left UNTOUCHED. The conflicted 3-way merge is in: _CLAUDE.md.template-merge" >&2
    echo "!! Resolve it by hand, then delete the .template-merge sidecar, and re-run." >&2
fi

# Only stamp the vault as upgraded when the run FULLY succeeded. A conflict, a
# git merge-file error, or any failed write means the vault did not reach the
# target version — leave the stamp behind so a re-run re-processes (and
# re-alerts) instead of a "current" stamp silently masking the gap. The stamp
# is the last write, so an aborted run also re-runs cleanly (idempotent).
if [ "$WRITE_FAILURES" -gt 0 ] || [ "$n_local_edit" -gt 0 ] || [ "$SNAPSHOT_FAILURES" -gt 0 ] || [ "$CLAUDE_MERGE_RESULT" = "conflict" ] || [ "$CLAUDE_MERGE_RESULT" = "error" ]; then
    echo "" >&2
    echo "upgrade: NOT writing the version stamp — the vault is partially upgraded" >&2
    echo "  (write failures: $WRITE_FAILURES; local edits withheld: $n_local_edit;" >&2
    echo "  snapshot failures: $SNAPSHOT_FAILURES;" >&2
    echo "  _CLAUDE.md: ${CLAUDE_MERGE_RESULT:-ok}). Resolve the issues above and re-run;" >&2
    echo "  template-owned writes are idempotent." >&2
    exit 1
fi

if ! "$PYTHON" - "$STAMP" "$TEMPLATE_VERSION" "$SNAPSHOT_FILE" <<'PY'
import json, sys, datetime
stamp_p, ver, snap_p = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
stamp = {"template": "luna-second-brain", "version": ver, "upgraded_at": now}
# files: the per-file content baseline for the next run (HIMMEL-2903). Sorted
# so the stamp is byte-stable across runs that changed nothing — a vault that
# autosyncs the stamp should not see a spurious diff every upgrade.
files = {}
if snap_p:
    # An unreadable scratch file must NOT degrade to "no snapshot": the stamp
    # below is rewritten wholesale, so writing it without the map would strip
    # the baseline the vault already has. Fail instead — the caller prints the
    # re-run message and the existing stamp (with its existing map) survives.
    try:
        with open(snap_p, encoding="utf-8") as fh:
            for line in fh:
                rel, tab, sha = line.rstrip("\n").partition("\t")
                if tab and rel and sha:
                    files[rel] = "sha256:" + sha
    except OSError as e:
        sys.stderr.write("upgrade: could not read the content snapshot (%s)\n" % e)
        sys.exit(3)
if files:
    stamp["files"] = dict(sorted(files.items()))
with open(stamp_p, "w", encoding="utf-8") as fh:
    json.dump(stamp, fh, indent=2)
    fh.write("\n")
PY
then
    echo "upgrade: ERROR — files updated but the version stamp could not be written to $STAMP." >&2
    echo "  The vault content IS upgraded; re-run to record the stamp." >&2
    exit 1
fi

echo ""
echo "Upgrade complete — vault is now v$TEMPLATE_VERSION."
