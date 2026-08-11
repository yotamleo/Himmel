#!/usr/bin/env bash
# graph-refresh.sh — operator-invoked ONE-SHOT graphify refresh for the luna
# and/or himmel corpora (HIMMEL-1644).
#
# WHY: refresh-graph-map.sh (HIMMEL-825) is the fence-safe incremental refresh
# runner for ONE corpus, and graphmap-cadence.sh (HIMMEL-829) arms a DAILY
# scheduler that fires it per corpus. But an operator refreshing BOTH graphs on
# demand (off the cadence, ad hoc) had to reconstruct the canonical per-corpus
# argument sets by reading the cadence script — the title/slug/tag literals, the
# luna-vs-himmel corpus-root asymmetry (luna extracts the VAULT, himmel extracts
# the HIMMEL REPO, BOTH publish their curated MOC into the vault's 60-Maps/), and
# the fixed claude-cli backend. This wrapper is that missing one-shot: it encodes
# the per-corpus argument sets ONCE (identical literals to the cadence's
# bat_payload/cron_payload) and fires refresh-graph-map.sh per corpus serially.
#
# This is a LEAN-INVOKE operator command (a slash command the operator runs on
# demand), NOT a hook and NOT a cadence. It owns NO safety itself — the runner
# (refresh-graph-map.sh) owns the fence (scratchpad copy, never a live vault),
# the per-out-dir promote lock (HIMMEL-910), the freshness manifest (HIMMEL-907),
# and the host-path guard (HIMMEL-1134). This wrapper just resolves the vault,
# builds the per-corpus argv, and fires.
#
# SERIAL, never concurrent: luna then himmel, mirroring the cadence's stagger
# rationale. The two corpora use different out-dirs, so no shared lock serializes
# them — a deliberate serial run here is the operator-side guard against two
# back-to-back extractions piling onto the claude-cli backend at once.
#
# TIMEOUT CALIBRATION lives in refresh-graph-map.sh (HIMMEL-1645, a parallel
# branch): this wrapper does NOT set GRAPHIFY_API_TIMEOUT itself — it forwards the
# caller's environment verbatim, so a sane default landed in the runner applies
# without a competing override here.
#
# Usage:
#   bash scripts/graphify/graph-refresh.sh [luna|himmel|both] [--vault <path>]
#                                          [--dry-run] [-h|--help]
#
# Args/flags:
#   luna|himmel|both   Which corpus(corpora) to refresh. Default: both.
#   --vault <path>     Luna vault root (default: $LUNA_VAULT_PATH if set, else
#                      <user-profile>/Documents/luna). The vault's 60-Maps/ is
#                      where BOTH curated MOCs are published; luna also extracts
#                      the vault as its corpus.
#   --dry-run          Print the exact refresh-graph-map.sh invocations (and the
#                      cadence status probe plan) without running them.
#   -h, --help         Show this help.
#
# Test seams (used by test-graph-refresh.sh):
#   GRAPH_REFRESH_RUNNER          refresh-graph-map.sh path (default: this
#                                 repo's scripts/graphify/refresh-graph-map.sh).
#   GRAPH_REFRESH_CADENCE_SCRIPT  graphmap-cadence.sh path (default: this
#                                 repo's scripts/luna/graphmap-cadence.sh),
#                                 whose `status` output is appended after the
#                                 refresh legs so cadence drift is visible.
#
# Exit codes:
#   0  all selected corpora refreshed successfully
#   1  usage error (unknown corpus / unknown flag)
#   2  environment error (refresh-graph-map.sh not found, or --vault is not a
#      directory)
#   3  one or more corpus refresh legs failed (runner exited non-zero)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../.." && pwd)"
REFRESH_SCRIPT="${GRAPH_REFRESH_RUNNER:-$HIMMEL_ROOT/scripts/graphify/refresh-graph-map.sh}"
CADENCE_SCRIPT="${GRAPH_REFRESH_CADENCE_SCRIPT:-$HIMMEL_ROOT/scripts/luna/graphmap-cadence.sh}"
# PHI/denylist config dir (mirrors graphify-fence.sh): the vault preflight below
# reads phi-roots / egress-denylist list files under here. CLAUDE_GLM_CONFIG_DIR
# is the test seam (point it at a temp tree); default matches the fence.
PHI_CONFIG_DIR="${CLAUDE_GLM_CONFIG_DIR:-$HOME/.config/claude-glm}"

# Fixed per-corpus map identity — IDENTICAL literals to graphmap-cadence.sh's
# LUNA_*/HIMMEL_* + BACKEND. Both encode the canonical per-corpus argument set;
# kept in sync by hand (this wrapper and the cadence are the two places it lives,
# by design — the cadence is the scheduled path, this is the on-demand path).
BACKEND="claude-cli"
LUNA_TITLE="Graphify Luna Map"
LUNA_SLUG="graphify-luna-map"
LUNA_TAG="luna"
HIMMEL_TITLE="Graphify Himmel Map"
HIMMEL_SLUG="graphify-himmel-map"
HIMMEL_TAG="himmel"

# Cross-platform user-home resolution (mirrors graphmap-cadence.sh /
# pipeline-cadence, HIMMEL-645). On Windows Git-Bash $HOME can be the MSYS home
# while the vault lives under the Windows user profile, so prefer USERPROFILE via
# cygpath BEFORE $HOME. POSIX hosts have USERPROFILE unset and fall straight
# through to $HOME. /tmp is the last-resort floor when both are unset.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Default vault resolution (mirrors graphmap-cadence's default_vault). Honors
# LUNA_VAULT_PATH first, else <home>/Documents/luna. Explicit --vault overrides.
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}

# --- vault preflight helpers (HIMMEL-1644 codex-adv-1) -----------------------
# The graphify-fence PreToolUse hook only matches `graphify` in COMMAND
# POSITION, so it cannot see through this wrapper to classify the vault the
# luna leg extracts (the wrapper shells refresh-graph-map.sh, not graphify
# directly). A mistyped or hostile --vault (the salus PHI vault, a denylisted
# root, a broad filesystem root) would therefore be copied + extracted to the
# backend despite the egress matrix's salus hard-deny. The preflight_vault
# gate below is the wrapper-side guard against that.
#
# These helpers are a SCOPED REIMPLEMENTATION of graphify-fence.sh's
# PHI-classification primitives (_lc / _abs / _normalize / _under_root /
# _salus_marked / _under_any_list), kept byte-for-byte aligned with the fence.
# DRIFT RISK: the fence is the load-bearing PHI guard; if its classification
# changes (new list file, renamed marker, different normalization), this copy
# must change in lockstep or the wrapper's preflight diverges from the fence's
# verdict. The fence cannot simply be sourced here — it self-executes (it
# parses its $1 command string, runs the clause loop, and `exit 0`s under a
# fail-closed EXIT trap), so sourcing it would run the fence and exit.
# Refactoring the production guardrail into a shared lib both consume is a
# larger, riskier change deliberately out of scope for this wrapper hardening.
# The DURABLE fix is the in-runner-preflight design surface tracked as
# HIMMEL-1084 (refresh-graph-map.sh already notes that residual: ANTHROPIC_*
# still pass through on the scheduled path with no matrix eval); until that
# lands, keep these helpers in sync with graphify-fence.sh by hand.

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _abs <path> -> absolute path (anchor a relative path to $PWD). Mirrors
# graphify-fence.sh's _abs for a clean value (this wrapper's $VAULT is a shell
# variable, not a tokenized command string, so it needs no quote-stripping and
# no TOOL_CWD threading — $PWD is the wrapper's own cwd). Backslashes -> forward
# slashes before the absolute/relative split, like the fence.
_abs() {
    local p="$1"
    p="${p//\\//}"
    # shellcheck disable=SC2088 # the "~/" is a literal case-pattern, not an expansion
    case "$p" in
        "~")   p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*)          ;;             # POSIX absolute
        [A-Za-z]:/*) ;;             # Windows drive-ROOTED absolute (C:/...)
        [A-Za-z]:*)  p="$PWD/${p#?:}" ;;  # Windows drive-RELATIVE -> anchor to cwd
        *)           p="$PWD/$p" ;;      # relative -> anchor to cwd
    esac
    printf '%s' "$p"
}

# _normalize <abs-path> -> lexically normalized, forward-slashed, MSYS
# drive-path-translated (collapse `.` / `..` so a `Clippings/../../salus`
# traversal cannot mis-match). Lexical only — no symlink resolution. Identical
# to graphify-fence.sh's _normalize. Globbing is disabled across the split (the
# fence runs under a global `set -f`; this wrapper does not, so toggle it locally).
_normalize() {
    local p="$1" prefix="" seg result="" oldIFS="$IFS" was_noglob=0
    p="${p//\\//}"
    case "$p" in
        /[A-Za-z]/*) p="${p:1:1}:/${p:3}" ;;
        /[A-Za-z])   p="${p:1:1}:/" ;;
    esac
    case "$p" in
        [A-Za-z]:/*) prefix="${p%%:*}:"; p="${p#[A-Za-z]:}" ;;
    esac
    case "$-" in *f*) was_noglob=1 ;; esac
    set -f
    IFS='/'
    # shellcheck disable=SC2086 # intentional split on '/'
    set -- $p
    IFS="$oldIFS"
    [ "$was_noglob" -eq 0 ] && set +f
    for seg in "$@"; do
        case "$seg" in
            ''|.) : ;;
            ..)   result="${result%/*}" ;;
            *)    result="$result/$seg" ;;
        esac
    done
    printf '%s%s' "$prefix" "${result:-/}"
}

# _under_root <path> <root> -> 0 if path == root or a descendant of root
# (case-insensitive, both sides normalized). Mirrors graphify-fence.sh.
_under_root() {
    local p r
    p="$(_lc "$(_normalize "$1")")"
    r="$(_lc "$(_normalize "$2")")"
    [ -n "$r" ] || return 1
    r="${r%/}"
    case "$p/" in "$r/"*) return 0 ;; esac
    return 1
}

# _salus_marked <abs-path> -> 0 if a `.salus` marker sits at the path or any
# ancestor directory (a path anywhere inside a PHI vault is PHI). Mirrors
# graphify-fence.sh. Walks the REAL filesystem path (the marker is a stat, not
# a string compare), so the caller passes the absolute form that exists on disk.
_salus_marked() {
    local d="$1" prev=""
    [ -d "$d" ] || d="${d%/*}"
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
        if [ -e "$d/.salus" ]; then return 0; fi
        prev="$d"
        d="${d%/*}"
    done
    return 1
}

# _under_any_list <abs-path> <listfile> -> echoes hit | miss | unreadable.
# Mirrors graphify-fence.sh: a missing list file is a miss; an UNREADABLE one is
# "unreadable" so the caller can fail CLOSED (like the fence).
_under_any_list() {
    local p="$1" listfile="$2" root
    [ -e "$listfile" ] || { echo miss; return; }
    { [ -f "$listfile" ] && [ -r "$listfile" ]; } || { echo unreadable; return; }
    while IFS= read -r root || [ -n "$root" ]; do
        root="${root%$'\r'}"
        root="${root%/}"; root="${root%\\}"
        [ -n "$root" ] || continue
        if _under_root "$p" "$root"; then echo hit; return; fi
    done < "$listfile"
    echo miss
}

# _resolve_symlinks <abs-path> -> canonical, symlink-resolved path on stdout;
# returns 1 if no resolver could canonicalize (caller degrades gracefully).
#
# Resolver chain (most-canonical first), mirroring the repo's realpath idiom
# (auto-commit.sh / arm-resume.sh / test-arm-resume-identity.sh's symlink
# identity check): plain `realpath` (the vault exists -- the `-d` check already
# ran, so the path is resolvable), then `realpath -m` (lenient), then a POSIX
# `cd "$p" && pwd -P` fallback (resolves the symlink chain via the shell's
# physical pwd -- the vault is a directory, so the cd lands). The RESULT is
# checked, not just the exit status (auto-action.sh idiom): a resolver that
# exits 0 on an empty output is not a resolution. HIMMEL-1644 codex-1 r2: the
# lexical _abs/_normalize mirror the fence and deliberately do NOT follow
# symlinks, so a vault path that is -- or traverses -- a symlink into a
# .salus/denylisted tree is classified on the LINK's ancestors, not the
# target's, and slips past the hard-refuse (the same gap hermes's parity guard
# closes with realpath at test-parity-guard.sh:319).
_resolve_symlinks() {
    local p="$1" r
    if command -v realpath >/dev/null 2>&1; then
        r="$(realpath "$p" 2>/dev/null)" && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
        r="$(realpath -m "$p" 2>/dev/null)" && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    fi
    r="$(cd "$p" 2>/dev/null && pwd -P)" && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    return 1
}

# _fs_id <path> -> "device:inode" of the path on stdout; returns 1 if no stat
# variant could read it (the caller FAILS CLOSED). This is the filesystem-
# IDENTITY primitive (HIMMEL-1670): the same directory reached via different
# case, a trailing slash, a `.`/`..` segment, an 8.3 short path, or a symlink
# all collapse to ONE id, and two genuinely-different directories -- even two
# that differ only by case on a case-SENSITIVE FS -- keep distinct ids.
#
# -L IS LOAD-BEARING, NOT DECORATION (HIMMEL-1670 CR, codex-adv-1). Both GNU
# and BSD stat default to LSTAT: without -L a symlink reports the LINK's own
# inode, not its target's. That is a guard BYPASS, not a cosmetic difference --
# a vault symlinked at HOME would produce a link inode that never equals HOME's
# directory inode, the identity comparison would pass, and the run would
# proceed on the operator HOME. The earlier version of this comment asserted
# the opposite ("stat follows symlinks for the final component by default");
# that was FALSE and is what allowed the bypass. Do not drop -L, and do not
# restore that claim. Callers additionally pass the already symlink-RESOLVED
# path where one is available, so intermediate components are covered too (-L
# only dereferences the final component).
#
# GNU stat (-c) first (Linux, MSYS2/Git-Bash -- busybox mimics it), BSD stat
# (-f) second (macOS); the RESULT is checked, not just the exit (a stat that
# exits 0 on empty output is not an identity).
_fs_id() {
    local p="$1" id
    id=$(stat -L -c '%d:%i' "$p" 2>/dev/null) || id=""
    case "$id" in *:*) printf '%s' "$id"; return 0 ;; esac
    id=$(stat -L -f '%d:%i' "$p" 2>/dev/null) || id=""
    case "$id" in *:*) printf '%s' "$id"; return 0 ;; esac
    return 1
}

# preflight_refuse <reason> — uniform refusal: stderr message naming the
# override, exit 2 (same "vault not usable" code as the not-a-directory check).
preflight_refuse() {
    echo "ERR graph-refresh: vault preflight refused: $1 (override with --vault or LUNA_VAULT_PATH)" >&2
    exit 2
}

# preflight_vault — run AFTER the [ -d "$VAULT" ] check (the sentinel + .salus
# walk need the vault to exist) and BEFORE any leg fires (dry-run included).
# (a) canonicalize, (b) refuse roots + HOME, (c) hard-refuse PHI/denylisted,
# (d) luna-vault sentinel (luna leg only).
preflight_vault() {
    local canon ap home_canon name rc resolved class_path configured_root resolved_root vault_id home_id
    canon="$(_abs "$VAULT")"
    # Resolve symlinks so EVERY check below classifies the tree the extraction
    # will ACTUALLY read (the canonical target), not the symlink's lexical
    # ancestors (HIMMEL-1644 codex-1 r2). _abs/_normalize are deliberately
    # lexical (they mirror the fence); without this resolution a vault path
    # that is -- or traverses -- a symlink into a .salus/denylisted tree is
    # classified on the LINK's ancestors and slips past the hard-refuse.
    #
    # The RESOLVED form (class_path/ap) is used for PREFLIGHT CLASSIFICATION
    # ONLY. The runner invocations (resolve_corpus_args / RUNNER_ARGV further
    # down) keep reading the operator's ORIGINAL $VAULT -- the runner copy must
    # still see the chosen path (its scratchpad-copy messaging names what the
    # operator passed); the preflight has already proved that path resolves to
    # a safe tree, so the runner reads the same bytes either way.
    if resolved="$(_resolve_symlinks "$canon")"; then
        class_path="$resolved"
    else
        # No resolver (realpath missing AND the cd/pwd -P fallback failed):
        # degrade to the lexical path and WARN so the operator knows symlink
        # coverage is best-effort here, not canonical -- a symlinked vault into
        # a salus/PHI/denylisted tree may not be refused. Graceful-degrade: the
        # run is not blocked, only the symlink guarantee drops to lexical.
        echo "WARN graph-refresh: no symlink resolver available (realpath missing and cd/pwd -P fallback failed) -- preflight classifies the LEXICAL vault path; a symlinked vault into a salus/PHI/denylisted tree may not be refused" >&2
        class_path="$canon"
    fi
    ap="$(_normalize "$class_path")"
    # (b) refuse filesystem roots + the operator HOME (a near-root the operator
    # never means to extract wholesale).
    case "$ap" in
        "/"|[A-Za-z]:/) preflight_refuse "vault is a filesystem root ($ap)" ;;
    esac
    # --- HOME identity guard (HIMMEL-1670) -----------------------------------
    # Refuse when the vault IS the operator HOME by FILESYSTEM IDENTITY
    # (device+inode via _fs_id), not case-folded path text. The previous text
    # compare (a lowercase-fold of both sides) was a defect in BOTH directions:
    # on a case-SENSITIVE FS (Linux, case-sensitive macOS) it folded two
    # genuinely-different dirs that differ only by case into a match (a false
    # refusal); and a text compare cannot see a symlink / trailing slash / `.`
    # / `..` / 8.3 short path that names the SAME dir with DIFFERENT text.
    # device+inode is case-AGNOSTIC, so it is correct on a case-insensitive FS
    # (Windows NTFS: the same dir via any case spelling is one id -- realpath
    # and pwd -P do NOT normalize case on MSYS/Git-Bash, so the old fold was
    # load-bearing there; inode replaces it correctly) AND on a case-sensitive
    # FS (two case-distinct dirs keep distinct ids -> the false refusal is
    # gone). Both sides are probed as their REAL TARGET, and that takes two
    # things, not one (CR codex-adv-1): _fs_id passes stat -L (stat defaults to
    # LSTAT -- see _fs_id), AND the vault is probed via the symlink-RESOLVED
    # $class_path rather than the lexical $canon, with HOME resolved the same
    # way. Probing $canon alone was the bypass: a vault symlinked at HOME
    # yielded the LINK's inode, which never equals HOME's, so the guard passed.
    # Fail CLOSED: if either identity cannot be probed (stat absent or path
    # missing), REFUSE -- an unresolvable comparison is not permission for a
    # safety control (replaces the old graceful-degrade, which allowed on a
    # failed resolve).
    home_canon="$(_abs "$(resolve_user_home)")"
    home_canon="$(_resolve_symlinks "$home_canon")" || \
        preflight_refuse "operator HOME could not be symlink-resolved ($(_abs "$(resolve_user_home)")) -- fail-closed, cannot prove vault is not HOME (HIMMEL-1670)"
    vault_id="$(_fs_id "$class_path")" || \
        preflight_refuse "vault identity could not be probed via stat ($VAULT -> $class_path) -- fail-closed (HIMMEL-1670)"
    home_id="$(_fs_id "$home_canon")" || \
        preflight_refuse "operator HOME identity could not be probed via stat ($home_canon) -- fail-closed, cannot prove vault is not HOME (HIMMEL-1670)"
    if [ "$vault_id" = "$home_id" ]; then
        preflight_refuse "vault is the operator HOME ($VAULT -> $class_path)"
    fi
    # (c) HARD-refuse PHI/denylisted paths, mirroring graphify-fence.sh's
    # classify() PHI branch: a `.salus` marker on any ancestor, OR the vault
    # falling under a phi-roots / egress-denylist entry. Fail-CLOSED: an
    # unreadable PHI list refuses, like the fence. Run against the RESOLVED
    # path so a symlinked vault is classified by its TARGET's real ancestry,
    # not the link's.
    if _salus_marked "$class_path"; then
        preflight_refuse "vault ($VAULT -> $class_path) is inside a salus/PHI tree (a .salus marker sits on an ancestor)"
    fi
    for name in phi-roots egress-denylist; do
        rc="$(_under_any_list "$ap" "$PHI_CONFIG_DIR/$name")"
        if [ "$rc" = unreadable ]; then
            preflight_refuse "$PHI_CONFIG_DIR/$name exists but is unreadable (fail-closed)"
        fi
        if [ "$rc" = hit ]; then
            preflight_refuse "vault ($VAULT -> $class_path) is under a $name entry (PHI/denylisted)"
        fi
    done
    # (d) luna-vault sentinel (luna leg only): the wrapper publishes into
    # 60-Maps and only a real luna vault carries BOTH a 60-Maps/ directory (the
    # publish target) AND an .obsidian/ directory. The himmel leg extracts the
    # REPO (not the vault), so it skips this — mirror the cadence, which never
    # requires the sentinel either. Check the RESOLVED path's sentinels (same
    # tree the extraction reads; $VAULT and $class_path are the same dir on
    # disk, so this matches what the runner copy will stat).
    case "$CORPUS" in
        luna|both)
            if [ ! -d "$class_path/60-Maps" ] || [ ! -d "$class_path/.obsidian" ]; then
                preflight_refuse "vault is not a plausible luna vault (needs both a 60-Maps/ and an .obsidian/ directory): $VAULT"
            fi
            # (e) configured-identity containment (codex-adv-1 r3): a corpus
            # class is EARNED by configured identity, never by directory shape
            # -- the sentinels above prove "an Obsidian vault", not "THE luna
            # vault", and the luna leg labels the extraction luna-personal. So
            # the resolved vault must sit at/under the resolved CONFIGURED luna
            # root: LUNA_VAULT_PATH (the machine-config channel), else the
            # conventional <home>/Documents/luna. A mistyped --vault pointing
            # at some OTHER Obsidian vault therefore refuses instead of
            # uploading that vault's markdown under a classification it never
            # earned; the operator ratifies a genuinely different location by
            # setting LUNA_VAULT_PATH.
            configured_root="$(_abs "$(default_vault)")"
            if resolved_root="$(_resolve_symlinks "$configured_root")"; then
                configured_root="$resolved_root"
            fi
            if ! _under_root "$ap" "$configured_root"; then
                preflight_refuse "vault ($VAULT -> $class_path) is not at/under the configured luna root ($configured_root); set LUNA_VAULT_PATH to ratify a different vault location"
            fi
            ;;
    esac
    # Publish the validated canonical path (codex-adv-2 r3): the caller
    # REASSIGNS VAULT to this, so the runner's --corpus-root/--maps-dir consume
    # EXACTLY the tree the preflight classified -- no window in which a symlink
    # retarget (or a divergent lexical form) makes the runner read a tree the
    # checks never saw. On the degraded no-resolver path this is the lexical
    # canon (already WARNed above).
    PREFLIGHT_CANONICAL_VAULT="$class_path"
}

CORPUS="both"
VAULT="$(default_vault)"
DRY_RUN=0

usage() {
    cat <<EOF
usage: graph-refresh.sh [luna|himmel|both] [--vault <path>] [--dry-run] [-h|--help]

Operator one-shot graphify refresh for the luna and/or himmel corpora
(HIMMEL-1644). Fires refresh-graph-map.sh per corpus SERIALLY (luna then
himmel), with the SAME per-corpus argument sets the daily cadence uses. The
runner owns all safety (fence, promote lock, manifest, host-path guard).

Args/flags:
  luna|himmel|both   Which corpus(corpora) to refresh. Default: both.
  --vault <path>     Luna vault root (default: \$LUNA_VAULT_PATH if set, else
                     <user-profile>/Documents/luna). The vault's 60-Maps/ is
                     where BOTH curated MOCs are published.
  --dry-run          Print the exact refresh-graph-map.sh invocations without
                     running them.
  -h, --help         Show this help.

Test seams:
  GRAPH_REFRESH_RUNNER          refresh-graph-map.sh path
  GRAPH_REFRESH_CADENCE_SCRIPT  graphmap-cadence.sh path (status appended)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        luna|himmel|both) CORPUS="$1"; shift ;;
        --vault)          VAULT="${2:?--vault requires a value}"; shift 2 ;;
        --vault=*)        VAULT="${1#--vault=}"; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "ERR graph-refresh: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Select corpora in serial order (luna, then himmel) — mirrors the cadence's
# stagger; luna and himmel never run concurrently.
case "$CORPUS" in
    luna)   CORPORA=(luna) ;;
    himmel) CORPORA=(himmel) ;;
    both)   CORPORA=(luna himmel) ;;
esac

# Validate environment up front (before firing anything).
if [ ! -f "$REFRESH_SCRIPT" ]; then
    echo "ERR graph-refresh: refresh-graph-map.sh not found at $REFRESH_SCRIPT" >&2
    exit 2
fi
# Drive-RELATIVE input (X:tail) is refused outright, BEFORE the -d existence
# check or _abs anchoring (codex-adv-2 r3, mirroring the fence's HIMMEL-845
# fail-closed rule): such a path resolves against Windows' per-drive current
# directory, so the form _abs would synthesize under $PWD is NOT provably the
# tree another layer reads -- classification and consumption could diverge.
# String-shape check, so it must run before the existence check (as typed, a
# drive-relative path usually cannot even exist on Windows).
case "$VAULT" in
    [A-Za-z]:|[A-Za-z]:[!/\\]*)
        preflight_refuse "drive-relative vault path '$VAULT' resolves against Windows' per-drive current directory and cannot be classified safely (HIMMEL-845 fail-closed) -- use an absolute path"
        ;;
esac
if [ ! -d "$VAULT" ]; then
    echo "ERR graph-refresh: vault is not a directory: $VAULT (override with --vault or LUNA_VAULT_PATH)" >&2
    exit 2
fi

# Vault preflight (HIMMEL-1644 codex-adv-1): refuse PHI/root/non-vault paths
# before ANY leg fires (dry-run included). See preflight_vault above.
preflight_vault
# Consume the validated canonical path everywhere downstream (codex-adv-2 r3):
# the runner's --corpus-root and --maps-dir, the dry-run preview, and the
# per-leg messages all read $VAULT, so this single reassignment guarantees the
# extraction reads EXACTLY the tree the preflight classified (same bytes, no
# symlink-retarget window at the wrapper layer, no lexical-form divergence).
VAULT="${PREFLIGHT_CANONICAL_VAULT:-$VAULT}"

# Set the per-corpus argv fields (R_NAME/R_CORPUS_ROOT/R_TITLE/R_SLUG/R_TAG) for
# one corpus. maps-dir is always $VAULT/60-Maps for BOTH (both publish into the
# luna vault). The corpus-root is asymmetric: luna extracts the VAULT; himmel
# extracts the HIMMEL REPO (so its derived graphify-out/ stays repo-local). This
# asymmetry is intentional, not a copy-paste bug — same wiring as the cadence.
resolve_corpus_args() {
    case "$1" in
        luna)
            R_NAME="luna"
            R_CORPUS_ROOT="$VAULT"
            R_TITLE="$LUNA_TITLE"
            R_SLUG="$LUNA_SLUG"
            R_TAG="$LUNA_TAG"
            ;;
        himmel)
            R_NAME="himmel"
            R_CORPUS_ROOT="$HIMMEL_ROOT"
            R_TITLE="$HIMMEL_TITLE"
            R_SLUG="$HIMMEL_SLUG"
            R_TAG="$HIMMEL_TAG"
            ;;
    esac
}

# Render an argv as a single shell-safe, copy-pasteable command line (each
# element printf %q-quoted). The --dry-run preview prints this so an operator can
# copy-paste any leg verbatim.
print_argv() {
    local first=1
    for a in "$@"; do
        if [ "$first" -eq 1 ]; then first=0; else printf ' '; fi
        printf '%q' "$a"
    done
}

# --- --dry-run: print the exact invocations, run nothing ----------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY graph-refresh: would refresh ${#CORPORA[@]} corpus(corpora) serially (${CORPORA[*]// / -> }) on backend $BACKEND"
    for c in "${CORPORA[@]}"; do
        resolve_corpus_args "$c"
        # corpus-class is luna-leg-only: the luna leg extracts the vault, so
        # pass --corpus-class luna-personal EXPLICITLY (the runner's default is
        # luna-personal, but the fence never sees this wrapper's invocation, so
        # the explicit class is defense-in-depth for corpus classification).
        # The himmel leg extracts the repo and passes NO class — mirroring
        # graphmap-cadence.sh exactly (the cadence passes no class for either).
        RUNNER_ARGV=(bash "$REFRESH_SCRIPT" \
            --name "$R_NAME" --corpus-root "$R_CORPUS_ROOT" --maps-dir "$VAULT/60-Maps" \
            --title "$R_TITLE" --slug "$R_SLUG" --backend "$BACKEND" --corpus-tag "$R_TAG")
        if [ "$c" = "luna" ]; then RUNNER_ARGV+=(--corpus-class luna-personal); fi
        printf 'DRY graph-refresh: [%s] ' "$c"
        print_argv "${RUNNER_ARGV[@]}"
        printf '\n'
    done
    echo "DRY graph-refresh: would then print \`$(basename "$CADENCE_SCRIPT") status\` for cadence-drift visibility (advisory)."
    echo "DRY graph-refresh: no refreshes run, nothing published."
    exit 0
fi

# --- real run: fire refresh-graph-map.sh per corpus, serially -----------------
echo "graph-refresh: refreshing $CORPUS serially on backend $BACKEND (vault: $VAULT)" >&2
FAILURES=0
for c in "${CORPORA[@]}"; do
    resolve_corpus_args "$c"
    # corpus-class is luna-leg-only (see the dry-run loop for the rationale);
    # the himmel leg passes no class, mirroring graphmap-cadence.sh.
    RUNNER_ARGV=(bash "$REFRESH_SCRIPT" \
            --name "$R_NAME" \
            --corpus-root "$R_CORPUS_ROOT" \
            --maps-dir "$VAULT/60-Maps" \
            --title "$R_TITLE" \
            --slug "$R_SLUG" \
            --backend "$BACKEND" \
            --corpus-tag "$R_TAG")
    if [ "$c" = "luna" ]; then RUNNER_ARGV+=(--corpus-class luna-personal); fi
    echo "graph-refresh: [$c] refreshing (corpus-root $R_CORPUS_ROOT -> $VAULT/60-Maps/$R_SLUG.md)" >&2
    # The `if` guards the runner call from set -e so a failed leg is REPORTED and
    # the remaining legs still run (the operator wants the per-corpus summary for
    # BOTH, not a hard stop after the first failure).
    if "${RUNNER_ARGV[@]}"; then
        echo "graph-refresh: [$c] OK -- published $VAULT/60-Maps/$R_SLUG.md"
        # Himmel's graphify-out/ is TRACKED (HIMMEL-1123); the refresh regenerates
        # it on disk but does NOT ship it. The operator must publish it separately
        # via /graph-publish so win2/weak stations pull the new graph instead of an
        # arbitrarily stale one. Do NOT auto-run it (HIMMEL-1129 stays its own
        # operator action — a commit + push + PR the operator should opt into).
        if [ "$c" = "himmel" ]; then
            echo "graph-refresh: [$c] NEXT -- run /graph-publish to ship the refreshed graphify-out/ (HIMMEL-1129)"
        fi
    else
        leg_rc=$?
        echo "graph-refresh: [$c] FAIL -- refresh-graph-map.sh exited $leg_rc" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

# --- cadence status: surface drift, advisory only ----------------------------
# After the refresh legs, print `graphmap-cadence.sh status` so the operator sees
# whether the daily cadence is armed (and how stale its last fire was) next to a
# just-run ad-hoc refresh. Best-effort + advisory: the cadence status runs
# against the OS scheduler (schtasks/crontab) and may exit non-zero (unsupported
# platform, query error); that NEVER fails this wrapper — the refreshes above
# already completed. `|| true` masks the cadence rc; the captured stdout is what
# matters. Both streams are merged so a scheduler warning is not lost.
echo
echo "graph-refresh: cadence status (HIMMEL-829) -- advisory:"
if [ -f "$CADENCE_SCRIPT" ]; then
    cadence_out=$(bash "$CADENCE_SCRIPT" status 2>&1) || true
    if [ -n "$cadence_out" ]; then
        printf '%s\n' "$cadence_out" | sed 's/^/  /'
    else
        echo "  (cadence status produced no output)"
    fi
else
    echo "  (cadence script not found at $CADENCE_SCRIPT)"
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$FAILURES" -gt 0 ]; then
    echo "graph-refresh: $FAILURES of ${#CORPORA[@]} corpus(corpora) FAILED" >&2
    exit 3
fi
echo "graph-refresh: refreshed ${#CORPORA[@]} corpus(corpora) OK"
exit 0
