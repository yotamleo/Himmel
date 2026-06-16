#!/usr/bin/env bash
# scripts/cr/gemini-first-pass.sh — gemini first-pass CR reviewer (HIMMEL-270).
#
# Reads a unified diff on stdin, reviews it via gemini-cli through the
# scripts/gemini/invoke.sh chokepoint (never calls `gemini` directly),
# validates + normalizes the findings, and prints them in the /pr-check
# heading contract.
#
# Exit codes:
#   0  findings emitted (including zero findings)
#   1  gemini invoke failed or output malformed — caller proceeds claude-only
#   2  usage error (no/empty stdin, unknown flag)
#
# Env: GEMINI_FIRST_PASS_CAP_BYTES — diff byte cap (default 204800).
# Bash 3.2 safe.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../gemini/invoke.sh"
CAP_BYTES="${GEMINI_FIRST_PASS_CAP_BYTES:-204800}"
case "$CAP_BYTES" in
    ''|*[!0-9]*) echo "gemini-first-pass.sh: invalid GEMINI_FIRST_PASS_CAP_BYTES='$CAP_BYTES' — using default 204800" >&2; CAP_BYTES=204800 ;;
esac

usage() {
    cat >&2 <<'EOF'
Usage: git diff main...HEAD | gemini-first-pass.sh [--model <name>]

Reads a unified diff on stdin, runs the gemini first-pass review, prints
findings in the /pr-check heading contract (stable [gemini-N] IDs).
Exit: 0 = findings emitted; 1 = gemini failed/malformed (fail-open);
2 = usage error. Never call on an empty diff — guard at the call site.
EOF
}

model=""
while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            [ $# -ge 2 ] || { echo "gemini-first-pass.sh: --model requires a value" >&2; exit 2; }
            model="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "gemini-first-pass.sh: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

diff_in="$(cat)"
if [ -z "$diff_in" ]; then
    echo "gemini-first-pass.sh: empty stdin — pipe a unified diff" >&2
    usage
    exit 2
fi
# Pure-bash shape guard — no pipe, no SIGPIPE hazard under pipefail.
# The second pattern matches a 'diff --git' line past the first line via
# a literal embedded newline (Bash 3.2-safe case pattern).
case "$diff_in" in
    "diff --git "*|*"
diff --git "*) : ;;
    *)
        echo "gemini-first-pass.sh: stdin is not a unified diff (no 'diff --git' line) — if a token-proxy rewrites git output, produce the diff via 'rtk proxy git diff' or equivalent" >&2
        usage
        exit 2 ;;
esac

truncated=0
diff_bytes="$(printf '%s\n' "$diff_in" | wc -c | tr -d '[:space:]')"
if [ "$diff_bytes" -gt "$CAP_BYTES" ]; then
    truncated=1
    # Cut offset: prefer the last whole-FILE boundary (byte offset of a
    # `diff --git` line, i.e. keep everything before it) that is <= cap and
    # > 0; if the first file alone exceeds the cap, fall back to the last
    # whole-HUNK boundary (offset of an `@@` line) <= cap. Never empty: the
    # first file's headers always precede the first `@@`.
    cut="$(printf '%s\n' "$diff_in" | awk -v cap="$CAP_BYTES" '
        {
            if ($0 ~ /^diff --git / && bytes > 0 && bytes <= cap) fc = bytes
            if ($0 ~ /^@@ / && bytes > 0 && bytes <= cap) hc = bytes
            bytes += length($0) + 1
        }
        END { print (fc > 0 ? fc : hc + 0) }')"
    if [ "$cut" -gt 0 ] 2>/dev/null; then
        diff_in="$(printf '%s\n' "$diff_in" | head -c "$cut")"
    else
        # Hard last-resort cap: no file/hunk boundary found at or below CAP_BYTES
        # (first hunk header already past cap). May cut mid-line; the truncation
        # note in the prompt covers it. Bounds quota burn as the spec's cap promises.
        diff_in="$(printf '%s\n' "$diff_in" | head -c "$CAP_BYTES")"
    fi
fi

# New-file hunk ranges "file start end" per line — used by the citation guard
# (Task 5) and computed on the (possibly truncated) diff.
# shellcheck disable=SC2317,SC2329  # cleanup is invoked indirectly via trap (SC2329 = false-positive for trap-invoked functions)
cleanup() { rm -f "${ranges_file:-}"; }
trap cleanup EXIT
ranges_file="$(mktemp -t gfp-ranges.XXXXXX)" || { echo "gemini-first-pass.sh: mktemp failed — fail-open, proceed claude-only" >&2; exit 1; }
printf '%s\n' "$diff_in" | awk '
    /^\+\+\+ / {
        # $2 handles unquoted paths. Git-quoted paths (spaces / non-ASCII) are
        # emitted as "+++ \"b/path with spaces\"" — $2 then picks up only the
        # first token and the citation guard misattributes the finding as
        # hallucinated. Proper unquoting requires a dedicated parser; for now
        # we accept the limitation and document it so the drop is visible.
        f = $2
        if (substr(f, 1, 1) == "\"") {
            print "gemini-first-pass.sh: git-quoted path in +++ line — citation guard may drop findings for this file (spaces/non-ASCII in path)" > "/dev/stderr"
        }
        sub(/^b\//, "", f)
        next
    }
    /^@@ / {
        if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
            s = substr($0, RSTART + 1, RLENGTH - 1)
            n = split(s, a, ",")
            start = a[1] + 0
            len = (n > 1 ? a[2] + 0 : 1)
            if (len > 0) print f, start, start + len - 1
        }
    }' > "$ranges_file"

trunc_note=""
if [ "$truncated" -eq 1 ]; then
    trunc_note="NOTE: the diff below was TRUNCATED to fit size limits; review only what is present."
fi

role_prompt="You are the first-pass code reviewer in an automated review pipeline.
Review ONLY the unified diff below. Output EXACTLY this markdown structure
and nothing else (no preamble, no fences):

## Critical Issues (N found)
- [gemini-1]: <one-line issue> [<file>:<line>]

## Important Issues (N found)
- [gemini-2]: <one-line issue> [<file>:<line>]

## Suggestions (N found)
- [gemini-3]: <one-line suggestion> [<file>:<line>]

Rules: replace N with the exact bullet count under that heading (0 is
allowed, then put no bullets under it). Every bullet MUST end with a
[<file>:<line>] citation pointing into the diff (new-file line numbers).
Number IDs sequentially across all sections. Critical = certain
bug/security/data-loss. Important = likely bug or risky pattern.
Suggestion = style/cleanup. Do not invent findings; an empty review is
acceptable and better than a fabricated one.
$trunc_note

DIFF:
$diff_in"

if [ -n "$model" ]; then
    raw="$(printf '%s' "$role_prompt" | bash "$INVOKE" --model "$model" -)"
else
    raw="$(printf '%s' "$role_prompt" | bash "$INVOKE" -)"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
    # Raw-output log intentionally NOT cleaned up — it is the fail-open diagnostic artifact.
    log="$(mktemp -t gfp-raw.XXXXXX)" || log=""
    if [ -n "$log" ]; then
        printf '%s\n' "$raw" > "$log"
        echo "gemini-first-pass.sh: gemini invoke failed (rc=$rc) — fail-open, proceed claude-only. Raw output: $log" >&2
    else
        echo "gemini-first-pass.sh: gemini invoke failed (rc=$rc) — fail-open, proceed claude-only. mktemp failed; raw output follows on stderr:" >&2
        printf '%s\n' "$raw" >&2
    fi
    exit 1
fi

# Validate the raw output, drop hallucinated citations, renumber IDs,
# recompute per-section counts. awk exits 3 on malformed structure.
final="$(printf '%s\n' "$raw" | awk -v rf="$ranges_file" -v trunc="$truncated" '
function getn(s) { match(s, /\([0-9]+ found\)/); return substr(s, RSTART + 1, RLENGTH - 8) + 0 }
BEGIN {
    nr = 0
    while ((getline line < rf) > 0) {
        split(line, a, " "); nr++; rfile[nr] = a[1]; rs[nr] = a[2] + 0; re[nr] = a[3] + 0
    }
    close(rf)
    sec = 0
    name[1] = "Critical Issues"; name[2] = "Important Issues"; name[3] = "Suggestions"
}
/^## Critical Issues \([0-9]+ found\)[[:space:]]*$/  { sec = 1; seen[1] = 1; declared[1] = getn($0); next }
/^## Important Issues \([0-9]+ found\)[[:space:]]*$/ { sec = 2; seen[2] = 1; declared[2] = getn($0); next }
/^## Suggestions \([0-9]+ found\)[[:space:]]*$/      { sec = 3; seen[3] = 1; declared[3] = getn($0); next }
/^- / { if (sec > 0) { count[sec]++; bullets[sec, count[sec]] = $0 }; next }
# Non-bullet, non-heading, non-empty lines inside a section (e.g. wrapped
# continuation text from multi-line findings) are silently discarded.
# Emit a stderr note to keep the no-silent-drops property visible.
/^[^# \t-]/ { if (sec > 0 && length($0) > 0) { print "gemini-first-pass.sh: discarded non-bullet line in section " sec " (multi-line finding continuation?): " $0 > "/dev/stderr" } }
END {
    for (i = 1; i <= 3; i++) {
        if (!seen[i]) {
            print "gemini-first-pass.sh: malformed — missing heading: " name[i] > "/dev/stderr"; exit 3
        }
        if (declared[i] != count[i] + 0) {
            print "gemini-first-pass.sh: malformed — " name[i] " declared " declared[i] " vs " count[i] + 0 " bullets" > "/dev/stderr"; exit 3
        }
    }
    # Citation guard: keep a bullet only when its trailing [file:line] names a
    # file in the diff AND a line inside one of that file new-side hunk
    # ranges. Everything else is a hallucinated citation -> drop + recount.
    for (i = 1; i <= 3; i++) {
        kept[i] = 0
        for (j = 1; j <= count[i] + 0; j++) {
            b = bullets[i, j]
            okc = 0
            if (match(b, /\[[^][]+:[0-9]+\][[:space:]]*$/)) {
                cit = substr(b, RSTART + 1, RLENGTH)
                sub(/\][[:space:]]*$/, "", cit)
                k = length(cit)
                while (k > 0 && substr(cit, k, 1) != ":") k--
                cfile = substr(cit, 1, k - 1)
                cline = substr(cit, k + 1) + 0
                for (r = 1; r <= nr; r++) {
                    if (rfile[r] == cfile && cline >= rs[r] && cline <= re[r]) { okc = 1; break }
                }
            }
            if (!okc) {
                print "gemini-first-pass.sh: dropped hallucinated/missing citation: " b > "/dev/stderr"
                continue
            }
            kept[i]++
            keep[i, kept[i]] = b
        }
    }
    print "# Gemini First-Pass Review" (trunc ? " (truncated input)" : "")
    id = 0
    for (i = 1; i <= 3; i++) {
        print ""
        print "## " name[i] " (" kept[i] + 0 " found)"
        for (j = 1; j <= kept[i] + 0; j++) {
            b = keep[i, j]
            id++
            if (b ~ /^- \[[^]]*\]:/) sub(/^- \[[^]]*\]:/, "- [gemini-" id "]:", b)
            else sub(/^- /, "- [gemini-" id "]: ", b)
            print b
        }
    }
}')"
rc=$?
if [ "$rc" -ne 0 ]; then
    # Raw-output log intentionally NOT cleaned up — it is the fail-open diagnostic artifact.
    log="$(mktemp -t gfp-raw.XXXXXX)" || log=""
    if [ -n "$log" ]; then
        printf '%s\n' "$raw" > "$log"
        echo "gemini-first-pass.sh: malformed gemini output — fail-open, proceed claude-only. Raw output: $log" >&2
    else
        echo "gemini-first-pass.sh: malformed gemini output — fail-open, proceed claude-only. mktemp failed; raw output follows on stderr:" >&2
        printf '%s\n' "$raw" >&2
    fi
    exit 1
fi

printf '%s\n' "$final"
exit 0
