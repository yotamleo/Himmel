#!/usr/bin/env bash
# Pre-commit gate (pre-commit framework, not Claude PreToolUse).
#
# Validates every literal `gh <cmd> <sub> ... --json a,b,c` field list in
# staged content against the field names `gh` itself advertises. A typo'd
# field is invisible until the command runs live: `gh` exits 1 with
# "Unknown JSON field", which a caller's fail-closed guard reports as a
# generic "cannot evaluate" — indistinguishable from an auth/network
# blip. That is how HIMMEL-1288 shipped: /cr-public's HIMMEL-1202
# bounded-wait polled `--json headRefSha` (the real field is
# headRefOid), so the wait could never run a single iteration, and the
# operator-merge fallback it guards was unreachable precisely when a
# public PR needed it.
#
# Enumeration is offline: `gh <sub> --json __bogus__` prints
# "Available fields:" plus the list to stderr with no API call, so this
# gate adds no network dependency and works on a plane.
#
# Deliberately narrow — only LITERAL field lists are checked. Anything
# carrying `$`, backticks or command substitution is skipped rather than
# guessed at; this gate exists to catch typos, not to evaluate shell.
#
# Exit codes:
#   0 — clean, or gh unavailable (lint, not a security gate: skip loudly)
#   1 — at least one unknown field name in a staged file
set -uo pipefail

if ! command -v gh >/dev/null 2>&1; then
    echo "check-gh-json-fields: gh not on PATH — skipping" >&2
    exit 0
fi

# pre-commit passes staged filenames as argv (pass_filenames: true). Fall
# back to a diff so always_run / manual invocation works too.
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    # bash 3.2-safe (macOS): no mapfile.
    while IFS= read -r _line; do files+=("$_line"); done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
fi
[ "${#files[@]}" -eq 0 ] && exit 0

# Cache of resolved field lists, keyed by subcommand. bash 3.2 has no
# associative arrays (see scripts/hooks/CLAUDE.md), so this is a flat
# "\nkey\tf1 f2 f3" string searched with a literal match.
CACHE=""

# Sets FIELDS_OUT to the space-delimited valid fields for a `gh`
# subcommand, or empty if the subcommand does not support --json at all
# (then we skip it: an unsupported --json is a different bug class, and
# guessing here would emit noise on every `gh api --jq` style call).
#
# Result goes through a global rather than stdout on purpose: `$(...)`
# would run this in a subshell and throw away every CACHE write, so the
# cache would silently never hit and each matched line would respawn gh.
FIELDS_OUT=""
fields_for() {
    _sub="$1"
    FIELDS_OUT=""
    _hit=$(printf '%s' "$CACHE" | grep -F "	$_sub	" 2>/dev/null | head -1)
    if [ -n "$_hit" ]; then
        FIELDS_OUT="${_hit#*"	$_sub	"}"
        return 0
    fi
    # shellcheck disable=SC2086  # $_sub is a validated [a-z-]+ token list
    _raw=$(gh $_sub --json __himmel_probe__ 2>&1 >/dev/null)
    case "$_raw" in
        *"Available fields:"*) : ;;
        *) CACHE="$CACHE
	$_sub	"; return 0 ;;
    esac
    _list=$(printf '%s\n' "$_raw" \
        | sed -n '/Available fields:/,$p' \
        | sed '1d' \
        | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -E '^[A-Za-z][A-Za-z0-9_]*$' \
        | tr '\n' ' ')
    CACHE="$CACHE
	$_sub	$_list"
    FIELDS_OUT="$_list"
}

violations=""
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    if [ ! -r "$f" ]; then
        echo "⛔ check-gh-json-fields: staged file '$f' is unreadable — refusing to skip the --json field scan on it (fail-closed)." >&2
        exit 1
    fi
    # Skip this gate and its own test — both embed deliberately-bogus
    # field names as fixtures. Match repo-relative paths, not basenames,
    # so a file dropped elsewhere cannot inherit the exemption.
    case "$f" in
        scripts/hooks/check-gh-json-fields.sh|scripts/hooks/test-check-gh-json-fields.sh) continue ;;
    esac

    # Match `gh <sub> … --json <fields>` on LOGICAL lines: backslash
    # continuations are joined first, so a command split across two physical
    # lines is seen whole (HIMMEL-1326). awk prints
    # "<first-physical-line>:<joined text>" — the lineno kept below is the first
    # physical line of the logical line, so the message still points somewhere
    # useful. grep then filters exactly as it did on physical lines (awk, not a
    # subshell, keeps this bash 3.2-safe).
    #
    # The join is a BARE concatenation, with no separator inserted. That is what
    # the shell itself does: `\` + newline is removed as a PAIR, so
    # `--json headRef\` + `Oid` is the single token `headRefOid`. Inserting a
    # space would split that into `headRef` and `Oid` and reject a perfectly
    # valid field — a false positive on correct code, which is worse for a lint
    # than the miss it replaces. Whitespace belonging to the source (the space
    # before the `\`, the indent on the next line) is preserved verbatim, so
    # normally-formatted continuations still tokenize correctly.
    #
    # Preprocessing failures must NOT read as "no matches". grep exiting 1 on a
    # genuine no-match is normal and stays absorbed by `|| true`; an awk error or
    # an unreadable file is not, and folding it into the same `|| true` would
    # silently pass the file unchecked — the exact fail-open this gate exists to
    # prevent. So awk runs separately and its status IS checked; only grep's is
    # forgiven.
    joined=$(mktemp -t ghjson-joined-XXXXXX) || {
        echo "⛔ check-gh-json-fields: mktemp failed — cannot preprocess $f" >&2
        exit 1
    }
    if ! awk '
        {
            line = $0
            cont = (line ~ /\\$/)
            if (cont) line = substr(line, 1, length(line) - 1)
            if (start) buf = buf line
            else { start = NR; buf = line }
            if (!cont) { print start ":" buf; start = 0; buf = "" }
        }
        END { if (start) print start ":" buf }
        ' < "$f" > "$joined" 2>/dev/null; then
        rm -f "$joined"
        echo "⛔ check-gh-json-fields: could not preprocess $f (awk error or unreadable file)." >&2
        echo "   Refusing to report it clean — an unchecked file must not pass as checked." >&2
        exit 1
    fi

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        lineno=${hit%%:*}
        text=${hit#*:}
        # Subcommand = the leading run of bare lowercase words after `gh`.
        # Stopping at the first non-word token drops flags, quoted args and
        # `"$pr"`-style expansions without having to enumerate shell syntax.
        sub=$(printf '%s' "$text" \
            | sed -E 's/.*(^|[^A-Za-z0-9_-])gh[[:space:]]+//' \
            | sed -E 's/^([a-z][a-z-]*( [a-z][a-z-]*)*).*/\1/')
        # Only well-formed subcommand words; anything else is not ours.
        printf '%s' "$sub" | grep -qE '^[a-z][a-z-]*( [a-z][a-z-]*)*$' || continue
        csv=$(printf '%s' "$text" | sed -E 's/.*--json[[:space:]]+//' | sed -E 's/[^A-Za-z0-9_,].*//')
        [ -n "$csv" ] || continue

        fields_for "$sub"
        valid="$FIELDS_OUT"
        # Empty => subcommand does not support --json; not this gate's business.
        [ -n "$valid" ] || continue

        for fld in $(printf '%s' "$csv" | tr ',' ' '); do
            [ -n "$fld" ] || continue
            case " $valid " in
                *" $fld "*) : ;;
                *) violations="$violations
  $f:$lineno: gh $sub --json … unknown field \"$fld\"" ;;
            esac
        done
    done < <(grep -E '(^|[^A-Za-z0-9_-])gh[[:space:]]+[a-z][a-z-]*([[:space:]]+[a-z][a-z-]*)*[^|;&]*--json[[:space:]]+[A-Za-z][A-Za-z0-9_,]*' "$joined" || true)
    rm -f "$joined"
done

[ -n "$violations" ] || exit 0

{
    echo "⛔ check-gh-json-fields: staged file(s) pass field names \`gh\` does not know."
    echo "$violations"
    echo
    echo "gh exits 1 on an unknown field, which callers report as a generic"
    echo "\"cannot evaluate\" — so the typo hides as a transient failure and the"
    echo "guarded path silently never runs (HIMMEL-1288)."
    echo "List the real names with:  gh <subcommand> --json __bogus__"
} >&2
exit 1
