#!/usr/bin/env bash
# file-deferred-issues — auto-file low-severity CR findings as GitHub issues.
#
# Reads CR review output from --input (file or `-` for stdin), extracts
# lines tagged with deferred-class severities (NIT, LOW, SUGGESTION,
# IMPROVEMENT, DEFERRED), and files each as a GitHub issue on the
# current repo. Dedupe is content-hash based: re-running on the same
# review output is a no-op (closed/won't-fix issues count too — a
# closed nit stays closed).
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
# Output: one line per finding —
#     filed <url> <hash>
#     skipped (duplicate, issue #N) <hash>
#     skipped (dry-run) <hash> — would file: <title>
#     skipped (gh-dedupe-check-failed) <hash> — fail-closed: <reason>
#
# Exit codes:
#     0 — completed (including all-duplicates / all-dry-run)
#     1 — usage / input error
#     2 — required tool missing or environment unusable (gh / git / sha)
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

# Tool detection. sha1sum is present on Linux + gitbash; macOS only
# ships `shasum` by default. Feature-detect rather than hard-require.
for tool in gh git; do
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

# Resolve repo nameWithOwner for issue search/create. One gh call;
# capture stdout (REPO) + stderr (error message on failure) separately
# so auth-expired vs no-remote vs network failures are distinguishable
# in the operator error message. (HIMMEL-131: previously called gh twice.)
gh_repo_err_file=$(mktemp -t fdi-gh-repo.err.XXXXXX)
if ! REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$gh_repo_err_file"); then
    echo "ERR file-deferred-issues: gh repo view failed:" >&2
    sed 's/^/    /' "$gh_repo_err_file" >&2
    rm -f "$gh_repo_err_file"
    exit 2
fi
rm -f "$gh_repo_err_file"

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

# Ensure the label exists. gh emits "already exists" stderr on a
# duplicate, which is expected — swallow that case silently. For any
# OTHER failure (network down, auth expired) emit a single up-front
# warning so the per-finding "label not found" errors aren't a mystery.
if [ "$DRY_RUN" -eq 0 ]; then
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

    # Dedupe — fail-closed. If `gh issue list` errors (rate-limit, auth
    # expired, network down) we MUST NOT file, otherwise transient gh
    # failures produce duplicate issues.
    #
    # HIMMEL-131: previously `2>&1` merged stderr into stdout. On rc=0
    # with a non-empty stderr (deprecation banner, auth-refresh notice),
    # `existing` then held the stderr text instead of the issue number,
    # and the finding was silently skipped as a "duplicate". Now capture
    # stdout (issue number) and stderr (error text) into separate
    # streams.
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

    # `gh issue create` prints the URL on success (stdout). Stderr is
    # redirected to a per-iteration tmp file so failures don't get
    # mistaken for the URL line. (No --json/--jq needed — bare stdout
    # is the URL.) (HIMMEL-131: comment used to claim --json+--jq was
    # in use, but the call didn't pass those flags — drift cleared.)
    create_err=""
    if issue_url=$(gh issue create \
            --repo "$REPO" \
            --title "$title" \
            --body "$body" \
            --label "$LABEL" 2>/tmp/file-deferred-issues.err.$$); then
        echo "filed ${issue_url} ${short_hash}"
        filed=$((filed + 1))
    else
        create_err=$(cat /tmp/file-deferred-issues.err.$$ 2>/dev/null || true)
        echo "FAILED ${short_hash}: ${create_err}" >&2
        failed=$((failed + 1))
    fi
    rm -f /tmp/file-deferred-issues.err.$$
done <<< "$candidates"

echo "file-deferred-issues: summary — ${filed} filed, ${duplicates} duplicates, ${dryrun_count} dry-run, ${failed} failed, ${dedupe_failed} dedupe-check-failed"
if [ "$failed" -gt 0 ]; then
    exit 3
fi
if [ "$dedupe_failed" -gt 0 ]; then
    exit 4
fi
exit 0
