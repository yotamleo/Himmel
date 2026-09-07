#!/usr/bin/env bash
# shellcheck disable=SC2094  # false positive: report() only echoes to stderr,
# it never writes to a scanned file — shellcheck can't see that across the call.
# Pre-commit gate (himmel-dev only): adopter-facing display strings never
# carry a raw HIMMEL-\d+ ticket ID (HIMMEL-2371).
#
# Adopters see hook display names, hook deny messages, and slash-command
# descriptions — a bare himmel-internal ticket number in one of those is
# meaningless to them and leaks project-tracker internals into the UI. The
# ticket ID still belongs in the codebase; it moves to a code comment /
# `.pre-commit-config.yaml` YAML comment beside the string instead of living
# inside it.
#
# Scope (matches the surfaces scripts/hooks/check-push-target.sh's own
# HIMMEL-2371 ticket-ID scan covers, minus the fenced-off subtrees no leg may
# edit): the STAGED `.pre-commit-config.yaml`'s `name:` fields, the STAGED
# `.claude/commands/*.md` frontmatter `description:` line, and a STAGED
# `scripts/hooks/*.sh`'s adopter-facing `echo`/`printf … >&2` deny messages
# (single physical line only — a message built across multiple lines/printf
# calls is a known, documented gap; not the shape any of the 14 real messages
# this ticket fixed used). README.md / docs/setup/** / docs/commands-catalog.md
# are deliberately NOT scanned here: their HIMMEL-\d+ mentions are narrative
# citations (traceability notes, doc-section anchors an edit would break), not
# display strings a tool renders — same class as docs/internals/**, which this
# gate always allowlists.
#
# Known gaps, not fixed — CR round 4 (codex, paid tier) surfaced all three;
# converging here rather than chasing hypotheticals with zero real instance in
# this codebase (every one of the 25/14/10 strings this ticket actually fixed
# uses the plain, unquoted style below — see the scan report):
#   - Direct-file mode's surface routing compares the caller-provided path
#     against exact repo-relative glob patterns, so a `./`-prefixed or
#     absolute path silently matches nothing. Gate mode is unaffected —
#     `git diff --cached --name-only` always returns clean repo-relative
#     paths — and direct-file mode is documented as ad hoc/tests, where
#     callers control the path they pass.
#   - The `name:` trailing-comment strip (`${line%%#*}`) is not YAML-quote
#     aware: a QUOTED value containing a literal `#`, e.g.
#     `name: "Block # HIMMEL-123"`, would have the quoted `#` misread as a
#     comment start and the ticket ID inside the quotes missed. No `name:`
#     value in this repo is quoted or contains a `#` at all.
#   - The hook-deny-message scan reads the whole `echo`/`printf … >&2` line,
#     so a ticket ID placed in a TRAILING shell comment on that same line
#     (`echo "refused" >&2 # HIMMEL-123`) is flagged even though it is not
#     part of the adopter-facing message. This repo's own convention is a
#     separate comment line above the echo (every fix in this ticket used
#     that shape), never a trailing same-line comment.
# Each is a FALSE result in the SAFE direction for its own class — the first
# and third are false positives (over-blocking a compliant string), never a
# missed real violation; the second is a false negative only for a quoting
# style this repo has never used. Revisit if a real instance appears.
#
# Usage:
#   check-no-ticket-id-in-user-strings.sh          # gate mode: STAGED files
#   check-no-ticket-id-in-user-strings.sh <file>...  # check files directly (tests)
# Exit: 0 clean · 1 a scanned string carries a ticket ID · 2 cannot evaluate (fail-closed).
set -euo pipefail

TICKET_RE='HIMMEL-[0-9]+'

fail=0
hard_fail=0
report() {
    # display path, line number, the offending line
    echo "→ check-no-ticket-id-in-user-strings: $1:$2 carries a raw ticket ID in an adopter-facing string:" >&2
    echo "    $3" >&2
    fail=1
}

# scannable PATH — true (rc 0) iff PATH exists and can be scanned. An
# EXISTING-but-unreadable path (permissions corruption, not a normal state) is
# a "cannot evaluate" case, not "no findings" — silently reading it as empty
# would be the wrong (permissive) direction, so this fails CLOSED (hard_fail,
# mapped to exit 2) instead.
scannable() {
    local p="$1"
    [ -e "$p" ] || return 1
    if [ ! -r "$p" ]; then
        echo "→ check-no-ticket-id-in-user-strings: $p exists but is not readable — fail-closed" >&2
        hard_fail=1
        return 1
    fi
    return 0
}

# check_pre_commit_config DISPLAY READPATH — every `name:` line. Anchored to
# "leading whitespace then literally name:". A bare glob star does NOT act as
# a quantifier the way a regex `*` would (codex-1 CR round 2): `[[:space:]]*`
# in a `case` pattern is "one space char, then ANYTHING" — NOT "a run of
# space chars" — so `[[:space:]]*name:*` matched `othername:` too (the `*`
# swallows "other" as "anything" before the literal "name:"). Strip leading
# whitespace with pure parameter expansion first (same fork-free idiom
# check_hook_deny_messages uses), then anchor the trimmed line to `name:*`.
#
# The ticket-ID grep runs on the value with any trailing YAML comment
# stripped (codex-1 CR round 3): `name: Block push # HIMMEL-123` displays as
# just "Block push" — pre-commit strips everything from an UNQUOTED `#` — so
# a ticket ID placed in a trailing inline comment is already compliant
# ("moved to a comment"), not a violation. None of this repo's `name:` values
# contain a literal `#`, so a simple strip-from-first-`#` is exact here; a
# full YAML-quoting-aware comment stripper would be scope this repo's own
# hook names never need.
check_pre_commit_config() {
    local display="$1" readpath="$2" ln trimmed value
    scannable "$readpath" || return 0
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            name:*)
                value="${line%%#*}"
                if printf '%s' "$value" | grep -qE "$TICKET_RE"; then
                    report "$display" "$ln" "$line"
                fi
                ;;
        esac
    done < "$readpath"
}

# check_command_description DISPLAY READPATH — the frontmatter `description:`
# line only (the first line matching `^description:` before the closing `---`).
check_command_description() {
    local display="$1" readpath="$2" ln in_frontmatter=0
    scannable "$readpath" || return 0
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        if [ "$ln" -eq 1 ]; then
            [ "$line" = "---" ] && in_frontmatter=1
            continue
        fi
        [ "$in_frontmatter" -eq 1 ] || break
        if [ "$line" = "---" ]; then
            break
        fi
        case "$line" in
            description:*)
                if printf '%s' "$line" | grep -qE "$TICKET_RE"; then
                    report "$display" "$ln" "$line"
                fi
                ;;
        esac
    done < "$readpath"
}

# check_hook_deny_messages DISPLAY READPATH — adopter-facing echo/printf ...
# >&2 lines (not code comments, not internal logging). Single physical line
# only — see the file header's documented multi-line gap (codex-2 CR round).
check_hook_deny_messages() {
    local display="$1" readpath="$2" ln trimmed
    scannable "$readpath" || return 0
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        # Strip leading whitespace with pure parameter expansion (no fork) —
        # a per-line subshell here made this check O(minutes) on a large hook
        # file under MSYS's slow fork(), the environment this repo targets.
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            '#'*) continue ;;  # a comment line — IDs stay allowed there
        esac
        case "$line" in
            *echo*'>&2'*|*printf*'>&2'*)
                case "$line" in
                    *HIMMEL-[0-9]*) report "$display" "$ln" "$line" ;;
                esac
                ;;
        esac
    done < "$readpath"
}

# is_scanned_surface PATH — true (rc 0) iff PATH is one of the three scanned
# surfaces and not allowlisted. Split out from scan_file (codex-3 CR round 5)
# so gate mode can skip materializing a staged blob for a path that will not
# be scanned at all, instead of running `git show` on every staged file first.
is_scanned_surface() {
    local p="$1"
    case "$p" in
        docs/internals/*) return 1 ;;  # allowlisted — internal reference docs keep IDs
    esac
    case "$p" in
        .pre-commit-config.yaml|.claude/commands/*.md|scripts/hooks/*.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# scan_file DISPLAY READPATH — DISPLAY is the repo-relative path (used in
# messages and for surface routing); READPATH is what actually gets read (the
# same path in direct-file mode, a tmp copy of the STAGED git blob in gate
# mode — see the gate-mode loop below for why the two must differ there).
# Callers that already know is_scanned_surface held may skip re-checking it —
# the case dispatch below still routes correctly either way, since a
# non-matching DISPLAY simply falls through with no branch taken.
scan_file() {
    local display="$1" readpath="$2"
    case "$display" in
        .pre-commit-config.yaml) check_pre_commit_config "$display" "$readpath" ;;
        .claude/commands/*.md) check_command_description "$display" "$readpath" ;;
        scripts/hooks/*.sh) check_hook_deny_messages "$display" "$readpath" ;;
    esac
}

if [ "$#" -gt 0 ]; then
    # Direct-file mode: no git, no himmel-dev gating (ad hoc / tests). Read
    # straight off disk — there is no staged/working-tree distinction here.
    for f in "$@"; do
        is_scanned_surface "$f" && scan_file "$f" "$f"
    done
    [ "$hard_fail" -eq 1 ] && exit 2
    exit "$fail"
fi

# ── Gate mode ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# himmel-dev only: an adopter who vendored the repo did not agree to this
# lint. Use the shared resolver, not a bare marker-file test — mirrors
# check-claude-md-budget.sh / check-debrand-coverage.sh.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/guardrails/lib.sh"
rc=0
# shellcheck disable=SC2119  # deliberately called with no args to use its DIR default (.)
is_himmel_dev_repo || rc=$?
if [ "$rc" -eq 1 ]; then exit 0; fi

# --diff-filter=ACMR (codex-2 CR round 3): R (renamed) must stay IN — a
# rename that also changes content is classified as R only (never also M),
# so excluding it would have let a renamed hook/command file's newly-added
# ticket ID bypass this gate entirely. --name-only reports the destination
# path for a rename, which is exactly the path `git show ":$f"` below needs.
#
# codex-1 (CR round 1): scan the STAGED blob, not the working-tree file. A
# file staged clean and then dirtied further (unstaged) would otherwise scan
# the dirty content and block a clean commit; worse, a file staged WITH a
# violation and then fixed only in the working tree would scan the fixed
# content and silently let the violation through into the commit — the
# security-relevant direction. Same STAGED-blob discipline as
# check-claude-md-budget.sh's own `git show :CLAUDE.md` read.
#
# codex-1 (CR round 5): `-z` NUL-delimits the path LIST itself, so a
# git-quoted filename (non-ASCII / special characters, otherwise C-style
# escaped and quoted by plain `--name-only`) reaches `git show` as the real
# path instead of a literal quoted string that would fail to resolve.
#
# codex-1 (CR round 6): the `-z` list is written to a FILE (`if ! git … >
# "$pathlist"`) and read back with `while … < "$pathlist"`, not read directly
# off a process-substitution FIFO (`< <(git …)`). A process substitution's
# exit status is not the loop's — if that git invocation failed, the loop
# would just see EOF immediately and this fail-closed gate would exit 0,
# having silently reviewed zero files. Writing to a file first lets the `if !`
# check git's real exit status directly, the same way every other git call in
# this script is checked. Bash strings cannot hold embedded NUL bytes, so
# neither this file nor the earlier "is anything staged at all" check can go
# through `$(...)` capture (round 5's `--quiet` reasoning, still exactly why
# the loop below has no output-capturing analogue).
tmp="$(mktemp "${TMPDIR:-/tmp}/no-ticket-id.XXXXXX")" || {
    echo "→ check-no-ticket-id-in-user-strings: mktemp failed — fail-closed" >&2
    exit 2
}
pathlist="$(mktemp "${TMPDIR:-/tmp}/no-ticket-id-paths.XXXXXX")" || {
    echo "→ check-no-ticket-id-in-user-strings: mktemp failed — fail-closed" >&2
    exit 2
}
trap 'rm -f "$tmp" "$pathlist"' EXIT

if ! git diff --cached --name-only -z --diff-filter=ACMR > "$pathlist" 2>/dev/null; then
    echo "→ check-no-ticket-id-in-user-strings: cannot list staged paths — fail-closed" >&2
    exit 2
fi

# is_scanned_surface first (codex-3 CR round 5): skip `git show` entirely for
# a staged path that will not be scanned at all, instead of materializing
# every staged file's blob before checking whether it's one of the three
# scanned surfaces. An empty $pathlist (nothing staged, or nothing matching
# the filter) makes this loop run zero iterations and fall through to
# `exit "$fail"` (0) below — no separate "nothing staged" branch needed.
while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    is_scanned_surface "$f" || continue
    if ! git show ":$f" > "$tmp" 2>/dev/null; then
        echo "→ check-no-ticket-id-in-user-strings: cannot read staged blob for $f — fail-closed" >&2
        hard_fail=1
        continue
    fi
    scan_file "$f" "$tmp"
done < "$pathlist"

[ "$hard_fail" -eq 1 ] && exit 2
exit "$fail"
