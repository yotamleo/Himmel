#!/usr/bin/env bash
# file-deferred-issues — auto-file low-severity CR findings as issues.
#
# Reads CR review output from --input (file or `-` for stdin), extracts
# lines tagged with deferred-class severities (NIT, LOW, SUGGESTION,
# IMPROVEMENT, DEFERRED), and files each as an issue on the current repo,
# routed through the forge seam (scripts/lib/forge.sh): GitHub issues via
# `gh`, Bitbucket issues via the himmel `bitbucket` CLI (HIMMEL-327). On a
# forge whose issue tracker is disabled (Bitbucket default → 404, spec §5.2)
# the run degrades gracefully — it files nothing and warns, naming the
# deferred findings, rather than erroring the CR flow. Dedupe (GitHub only)
# is content-hash based: re-running on the same review output is a no-op
# (closed/won't-fix issues count too — a closed nit stays closed). On a
# Bitbucket repo whose tracker is *enabled* (not the §5.2 default-off case)
# there is no dedupe, so re-runs would duplicate — acceptable for Phase 2,
# which targets the disabled-tracker default.
#
# Source format expected (matches our heavy-CR pattern):
#     path/to/file.ext:LINE: <SEVERITY>: <problem>. <fix>.
#
# Bullets (`- ` / `* `) and backtick fences/spans wrapping the finding
# line are stripped before matching; no other formats are recognised.
#
# Why MEDIUM is NOT auto-filed: MEDIUM findings warrant attention before
# merge — auto-filing would let them slip into a backlog. NIT / LOW /
# SUGGESTION / IMPROVEMENT / DEFERRED are the "non-blocking but worth
# tracking" tier. CRITICAL / HIGH / IMPORTANT block the PR via the
# existing /pr-check marker flow.
#
# Output: one line per finding (stdout unless noted) —
#     filed <url> <hash>
#     skipped (duplicate, issue #N) <hash>
#     skipped (dry-run) <hash> — would file: <title>
#     skipped (gh-dedupe-check-failed) <hash> — fail-closed: <reason>   (stderr)
#     FAILED <hash>: <reason>                                           (stderr)
#
# Exit codes:
#     0 — completed (including all-duplicates / all-dry-run, AND the
#         issues-disabled graceful degrade — nothing filed, findings warned)
#     1 — usage / input error
#     2 — required tool missing or environment unusable (git always; gh on
#         the GitHub path; sha1sum/shasum) or the forge could not be detected
#     3 — issue creation failed for at least one finding
#     4 — at least one dedupe check failed (fail-closed, nothing filed
#         for that finding — operator should re-run after investigating)
set -euo pipefail

PR_NUMBER=""
INPUT=""
LABEL="cr-deferred"
DRY_RUN=0
SEVERITIES_REGEX='NIT|LOW|SUGGESTION|IMPROVEMENT|DEFERRED'

usage() {
    cat <<'EOF'
Usage: file-deferred-issues.sh --pr <number> --input <file|-> [--label NAME] [--dry-run]

Required:
  --pr <number>         Target PR number on the current repo. Linked in each issue body.
  --input <file|->      Review output to scan. `-` reads from stdin.

Optional:
  --label <name>        GitHub label to apply (default: cr-deferred).
                        Auto-created on first non-dry-run invocation.
  --dry-run             Parse + show plan, don't create issues or labels.

Severity tiers auto-filed: NIT, LOW, SUGGESTION, IMPROVEMENT, DEFERRED.
MEDIUM and above are NOT touched — they need to block the PR.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pr)       PR_NUMBER="${2:-}"; shift 2 ;;
        --input)    INPUT="${2:-}"; shift 2 ;;
        --label)    LABEL="${2:-}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERR file-deferred-issues: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$PR_NUMBER" ] || [ -z "$INPUT" ]; then
    echo "ERR file-deferred-issues: --pr and --input are required" >&2
    usage >&2
    exit 1
fi
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "ERR file-deferred-issues: --pr must be a positive integer, got: $PR_NUMBER" >&2
    exit 1
fi

# Resolve the forge (github|bitbucket) from the origin remote (HIMMEL-327).
# Repo-context + issue-create route through the forge seam so a Bitbucket user
# degrades gracefully when their issue tracker is off (spec §5.2) instead of
# hard-erroring the CR flow. forge_detect prints an actionable message + returns
# non-zero when no forge can be determined; `if !` guards set -e.
FDI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=scripts/lib/forge.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$FDI_LIB_DIR/forge.sh"
if ! FORGE=$(forge_detect); then
    echo "ERR file-deferred-issues: could not determine the forge (see above)." >&2
    exit 2
fi

# Tool detection. `git` is always needed; `gh` only on the GitHub path (the
# Bitbucket path shells out to the himmel `bitbucket` CLI via the forge seam,
# which runs under node — guaranteed present). sha1sum is present on Linux +
# gitbash; macOS only ships `shasum`. Feature-detect rather than hard-require.
req_tools="git"
[ "$FORGE" = "github" ] && req_tools="git gh"
for tool in $req_tools; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERR file-deferred-issues: required tool '$tool' not on PATH" >&2
        exit 2
    fi
done
if command -v sha1sum >/dev/null 2>&1; then
    HASH_CMD="sha1sum"
elif command -v shasum >/dev/null 2>&1; then
    HASH_CMD="shasum -a 1"
else
    echo "ERR file-deferred-issues: neither sha1sum nor shasum found on PATH" >&2
    exit 2
fi

# Resolve input — '-' reads stdin eagerly into memory (don't use this
# on multi-MB reviews); else must be a readable file.
if [ "$INPUT" = "-" ]; then
    INPUT_CONTENT=$(cat)
elif [ -f "$INPUT" ] && [ -r "$INPUT" ]; then
    INPUT_CONTENT=$(cat "$INPUT")
else
    echo "ERR file-deferred-issues: --input file not readable: $INPUT" >&2
    exit 1
fi

if [ -z "$INPUT_CONTENT" ]; then
    echo "ERR file-deferred-issues: input is empty" >&2
    exit 1
fi

# Resolve repo identity via the forge seam — owner/repo on GitHub, workspace/repo
# on Bitbucket. Used for the GitHub dedupe/label/create calls below; the
# Bitbucket CLI derives its own ws/repo from the origin remote, so REPO is a
# GitHub-path detail. Capture stdout (REPO) + stderr (error message) separately
# so auth-expired vs no-remote vs network failures stay distinguishable.
repo_err_file=$(mktemp -t fdi-repo.err.XXXXXX)
# shellcheck disable=SC2119  # forge_repo_nwo takes no positional args
if ! REPO=$(forge_repo_nwo 2>"$repo_err_file"); then
    echo "ERR file-deferred-issues: could not resolve repo via forge ($FORGE):" >&2
    sed 's/^/    /' "$repo_err_file" >&2
    rm -f "$repo_err_file"
    exit 2
fi
rm -f "$repo_err_file"

HEAD_SHA=$(git rev-parse --short HEAD)

# Extract candidate lines. Primary pattern: `path[:line]: SEV: text`
# — LINE is OPTIONAL (`(:[0-9]+)?`). File-only findings (typo in
# README, missing doc section) are valid and would otherwise be
# rejected. (HIMMEL-131: regex was already permissive; comment used
# to imply LINE is required — drift cleared.) Use grep -E (egrep) —
# portable across gitbash + linux + macos. Strip leading bullets and
# backtick wrappers first so `- ... :NIT: ...` or `` `...:NIT:...` ``
# still match.
#
# `set +e` lets us inspect the rc without exiting; with `pipefail` on,
# the pipeline rc is the first non-zero in the chain — usually grep's
# rc=1 (no match, fine) or rc=2 (real error, fail). PIPESTATUS does
# not propagate out of a subshell ($()), so we use `$?` on the
# pipeline itself.
set +e
# shellcheck disable=SC2016  # single-quoted sed expressions are intentional (literal regex)
candidates=$(printf '%s\n' "$INPUT_CONTENT" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/^`+//; s/`+$//' \
    | grep -E "^[^[:space:]:]+(:[0-9]+)?:[[:space:]]*(${SEVERITIES_REGEX})[[:space:]]*:")
pipeline_rc=$?
set -e
if [ "$pipeline_rc" -gt 1 ]; then
    echo "ERR file-deferred-issues: input scan failed (pipeline rc=$pipeline_rc)" >&2
    exit 1
fi

if [ -z "$candidates" ]; then
    echo "file-deferred-issues: no deferred-class findings detected in input — nothing to file."
    exit 0
fi

# Ensure the label exists. GitHub-only: Bitbucket issues carry only a `kind`,
# not free-form labels, so the seam's label arg is a no-op there. gh emits
# "already exists" stderr on a duplicate, which is expected — swallow that case
# silently. For any OTHER failure (network down, auth expired) emit a single
# up-front warning so the per-finding "label not found" errors aren't a mystery.
if [ "$DRY_RUN" -eq 0 ] && [ "$FORGE" = "github" ]; then
    label_err=""
    if ! label_err=$(gh label create "$LABEL" \
            --repo "$REPO" \
            --description "Auto-filed deferred CR finding (HIMMEL-30)" \
            --color B0E0E6 \
            2>&1); then
        case "$label_err" in
            *"already exists"*) ;;  # idempotent path
            *) echo "WARN file-deferred-issues: gh label create failed (per-finding creates may fail): ${label_err}" >&2 ;;
        esac
    fi
fi

filed=0
duplicates=0
dryrun_count=0
failed=0
dedupe_failed=0
issues_disabled=0

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Hash key: stable across re-runs of the same finding. Includes
    # the full raw line (file path + line number + severity + text)
    # so editing the file (which shifts line numbers) creates a NEW
    # issue — correct, since the finding moved.
    hash=$(printf '%s' "$line" | $HASH_CMD | awk '{print $1}')
    short_hash="${hash:0:12}"
    marker="cr-deferred-id:${short_hash}"

    # Title: first 80 chars of the finding, prefixed with hash for
    # grep'ability. Note: `cut -c1-80` counts bytes, so multi-byte
    # UTF-8 chars at the boundary can split mid-codepoint. Cosmetic
    # only — titles are decorative.
    title_text=$(printf '%s' "$line" | cut -c1-80)
    title="[CR ${short_hash}] ${title_text}"

    # Dedupe — fail-closed, GitHub-only. The marker-in-body search is a `gh
    # issue list` capability; Bitbucket has no equivalent, and on Bitbucket the
    # tracker is disabled by default so the create below degrades before any
    # duplicate could be produced (spec §5.2). If `gh issue list` errors
    # (rate-limit, auth expired, network down) we MUST NOT file, otherwise
    # transient gh failures produce duplicate issues.
    #
    # HIMMEL-131: previously `2>&1` merged stderr into stdout. On rc=0
    # with a non-empty stderr (deprecation banner, auth-refresh notice),
    # `existing` then held the stderr text instead of the issue number,
    # and the finding was silently skipped as a "duplicate". Now capture
    # stdout (issue number) and stderr (error text) into separate
    # streams.
    if [ "$FORGE" = "github" ]; then
        dedupe_err_file=$(mktemp -t fdi-dedupe.err.XXXXXX)
        if ! existing=$(gh issue list \
                --repo "$REPO" \
                --state all \
                --search "$marker in:body" \
                --json number \
                --jq '.[0].number' 2>"$dedupe_err_file"); then
            dedupe_err=$(cat "$dedupe_err_file" 2>/dev/null || true)
            rm -f "$dedupe_err_file"
            echo "skipped (gh-dedupe-check-failed) ${short_hash} — fail-closed: ${dedupe_err}" >&2
            dedupe_failed=$((dedupe_failed + 1))
            continue
        fi
        rm -f "$dedupe_err_file"
        if [ -n "$existing" ] && [ "$existing" != "null" ]; then
            echo "skipped (duplicate, issue #${existing}) ${short_hash}"
            duplicates=$((duplicates + 1))
            continue
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "skipped (dry-run) ${short_hash} — would file: ${title}"
        dryrun_count=$((dryrun_count + 1))
        continue
    fi

    # Build body via printf — heredoc with unquoted EOF would expand
    # `$(...)` and backticks in `$line` (attacker-controlled review
    # text). Using printf with %s placeholders is injection-safe.
    body=$(printf '%s\n' \
        "Auto-filed deferred finding from CR review of PR #${PR_NUMBER}." \
        "" \
        "**Finding:**" \
        '```' \
        "${line}" \
        '```' \
        "" \
        "**Origin:** PR #${PR_NUMBER} (HEAD ${HEAD_SHA})" \
        "**Filed by:** \`scripts/cr/file-deferred-issues.sh\` (HIMMEL-30)" \
        "**Dedupe marker:** \`${marker}\`" \
        "" \
        "This was flagged as a low-severity / deferred finding during pre-merge" \
        "code review and was not blocking. Triage as time permits or close as" \
        "won't-fix; re-running the filer on the same review output will not" \
        "recreate this issue (dedupe by content hash; closed issues count too).")

    # Create via the forge seam — echoes the issue URL on success (stdout).
    # Stderr goes to a per-iteration tmp file so a failure isn't mistaken for
    # the URL line. The seam returns rc 3 when the forge's issue tracker is
    # disabled (Bitbucket default → verified 404, spec §5.2): degrade
    # gracefully — stop filing, then warn naming all deferred findings, and
    # exit 0 (never error the CR flow over a missing tracker). Any other
    # non-zero rc is a real per-finding failure.
    create_err_file=$(mktemp -t fdi-create.err.XXXXXX)
    create_rc=0
    issue_url=$(forge_issue_create "$REPO" "$title" "$body" "$LABEL" 2>"$create_err_file") || create_rc=$?
    create_err=$(cat "$create_err_file" 2>/dev/null || true)
    rm -f "$create_err_file"
    if [ "$create_rc" -eq 0 ]; then
        echo "filed ${issue_url} ${short_hash}"
        filed=$((filed + 1))
    elif [ "$create_rc" -eq 3 ]; then
        issues_disabled=1
        break
    else
        echo "FAILED ${short_hash}: ${create_err}" >&2
        failed=$((failed + 1))
    fi
done <<< "$candidates"

# Issues-disabled graceful degrade (spec §5.2): warn naming every deferred
# finding so the operator can triage them manually, and exit 0 — a forge that
# simply lacks an issue tracker must not fail the CR flow.
#
# Why a 404 here reliably means "tracker disabled" and not "bad repo / no
# access": forge_repo_nwo above already did a repo-read (a GET that 404s on a
# missing repo, 401s on bad auth) and exits 2 before this loop runs. So reaching
# a 404 at issue-create time means the repo exists and is readable but its issue
# tracker is off. (If a scope-limited token ever 404'd a readable tracker,
# degrading is still the safe call — warn, don't block the CR.) The warning says
# "appears disabled" + reports any already-filed count so a partial run is never
# misrepresented as "nothing filed".
if [ "$issues_disabled" -eq 1 ]; then
    echo "WARN file-deferred-issues: issue tracker appears disabled on this ${FORGE} repository (spec §5.2; ${filed} already filed before this point) — the following deferred CR finding(s) were NOT filed (non-blocking, triage manually):" >&2
    while IFS= read -r dline; do
        [ -z "$dline" ] && continue
        echo "    - ${dline}" >&2
    done <<< "$candidates"
    exit 0
fi

echo "file-deferred-issues: summary — ${filed} filed, ${duplicates} duplicates, ${dryrun_count} dry-run, ${failed} failed, ${dedupe_failed} dedupe-check-failed"
if [ "$failed" -gt 0 ]; then
    exit 3
fi
if [ "$dedupe_failed" -gt 0 ]; then
    exit 4
fi
exit 0
