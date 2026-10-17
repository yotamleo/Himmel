#!/usr/bin/env bash
# file-deferred-issues — file low-severity CR findings on the repo's tracker.
#
# Reads CR review output from --input (file or `-` for stdin) and extracts
# lines tagged with deferred-class severities (NIT, LOW, SUGGESTION,
# IMPROVEMENT, DEFERRED). Where they go is decided by an EXPLICIT, printed
# tracker mode (`tracker=jira|forge|none`) built on the one resolver,
# scripts/lib/project-mode.sh (TRACKER / himmel.tracker / JIRA_PROJECT_KEY):
#   tracker=jira   Jira is configured: ONE ticket per run (label cr-deferred,
#                  all findings as a numbered list). Never a GitHub issue: a
#                  failed lookup or create exits non-zero, with no fallback.
#   tracker=forge  No Jira, but the repo's forge is github|bitbucket: one issue
#                  per finding via the forge seam (scripts/lib/forge.sh). A
#                  forge whose tracker is disabled (Bitbucket default → 404,
#                  spec §5.2) degrades: nothing filed, findings warned.
#   tracker=none   Local tickets / no remote tracker: nothing is filed; the
#                  numbered batch is printed for the PR's Ticket coverage and
#                  the console.
# Dedupe is content-hash based: re-running on the same review output is a
# no-op (closed tickets/issues count too). On a Bitbucket repo whose tracker
# is *enabled* there is no dedupe, so re-runs would duplicate.
#
# Source format expected (matches our heavy-CR pattern):
#     path/to/file.ext:LINE: <SEVERITY>: <problem>. <fix>.
#
# Bullets (`- ` / `* `) and backtick fences/spans wrapping the finding
# line are stripped before matching. The critic panel's own shape
# (`## Suggestions (N found)` heading + `- [id]: text [path:line]` findings)
# is rewritten into the canonical shape above by a
# normalisation pass before matching — see normalize_panel_input() below.
#
# Why MEDIUM is NOT auto-filed: MEDIUM findings warrant attention before
# merge — auto-filing would let them slip into a backlog. NIT / LOW /
# SUGGESTION / IMPROVEMENT / DEFERRED are the "non-blocking but worth
# tracking" tier. CRITICAL / HIGH / IMPORTANT block the PR via the
# existing /pr-check marker flow.
#
# Output: `tracker=<mode>` first, then one line per finding (forge) or per
# batch (jira), stdout unless noted —
#     filed <url|JIRA-KEY> <hash>
#     skipped (duplicate, issue #N | JIRA-KEY) <hash>
#     skipped (dry-run) <hash> — would file: <title>
#     skipped (gh-dedupe-check-failed | jira-dedupe-check-failed) <hash> — fail-closed: <reason>   (stderr)
#     FAILED <hash>: <reason>                                           (stderr)
#
# Exit codes:
#     0 — completed (including all-duplicates / all-dry-run, AND the
#         issues-disabled graceful degrade — nothing filed, findings warned)
#     1 — usage / input error
#     2 — required tool missing or environment unusable (git always; gh on
#         the GitHub path; sha1sum/shasum), the tracker setting is invalid
#         (e.g. TRACKER=jira without JIRA_PROJECT_KEY) or the forge could not
#         be detected
#     3 — ticket/issue creation failed for at least one finding
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
  --label <name>        Label to apply (default: cr-deferred). On the forge
                        path it is auto-created on first non-dry-run invocation.
  --dry-run             Parse + show plan, don't create tickets, issues or labels.

Tracker (printed as tracker=jira|forge|none): jira when Jira is configured
(one ticket per run), else forge issues on a github/bitbucket forge, else
nothing is filed (the batch is printed for the PR's Ticket coverage).

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

# Resolve the tracker explicitly: jira | forge | none. The resolver owns the
# Jira-vs-local answer (TRACKER, git config himmel.tracker, JIRA_PROJECT_KEY);
# JIRA_PROJECT_KEY is read from the primary checkout's .env the way the Jira CLI
# does. There is deliberately NO fallback from jira to forge: a Jira repo
# files to Jira or fails.
FDI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=scripts/lib/project-mode.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$FDI_LIB_DIR/project-mode.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$FDI_LIB_DIR/load-dotenv.sh"
load_dotenv JIRA_PROJECT_KEY >/dev/null 2>&1 || true
if ! PM_TRACKER=$(project_mode_tracker); then
    echo "ERR file-deferred-issues: invalid tracker setting (see above); nothing filed." >&2
    exit 2
fi
# An EXPLICIT tracker choice (TRACKER env or git config himmel.tracker) of
# none|local means "file nothing remote", even on a GitHub origin; forge issue
# filing is only the fallback for a repo that never chose a tracker.
tracker_explicit="${TRACKER:-$(git config --get himmel.tracker 2>/dev/null || true)}"
if [ "$PM_TRACKER" = jira ]; then
    TRACKER_MODE=jira
elif [ -n "$tracker_explicit" ]; then
    TRACKER_MODE=none
else
    if ! PM_FORGE=$(project_mode_forge --quiet); then
        echo "ERR file-deferred-issues: invalid forge setting (see above); nothing filed." >&2
        exit 2
    fi
    case "$PM_FORGE" in
        github|bitbucket) TRACKER_MODE=forge ;;
        *)                TRACKER_MODE=none ;;
    esac
fi
echo "tracker=${TRACKER_MODE}"

# Forge path only: resolve the forge (github|bitbucket) through the seam.
# forge_detect prints an actionable message + returns non-zero when no forge
# can be determined; `if !` guards set -e.
if [ "$TRACKER_MODE" = forge ]; then
    # shellcheck source=scripts/lib/forge.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$FDI_LIB_DIR/forge.sh"
    if ! FORGE=$(forge_detect); then
        echo "ERR file-deferred-issues: could not determine the forge (see above)." >&2
        exit 2
    fi
fi

# Tool detection. `git` is always needed; `gh` only on the GitHub path (the
# Bitbucket path shells out to the himmel `bitbucket` CLI via the forge seam,
# which runs under node — guaranteed present). sha1sum is present on Linux +
# gitbash; macOS only ships `shasum`. Feature-detect rather than hard-require.
req_tools="git"
[ "$TRACKER_MODE" = forge ] && [ "$FORGE" = "github" ] && req_tools="git gh"
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

# Normalisation pass: the critic panel (scripts/cr/critic-panel.sh)
# emits a different shape than the canonical `path:LINE: SEV: text` line the
# extractor below parses — severity lives in the enclosing `## <section>`
# HEADING, not on the finding line itself:
#     ## Suggestions (3 found)
#     - [glm-3]: some finding text. [path/to/file.py:74]
# Rewrite that into `path:74: SUGGESTION: [glm-3] some finding text.` so the
# existing extractor (hashing, dedupe, titles, forge routing — everything
# below stays byte-identical) handles it exactly like a native finding.
# `Important Issues` / `Critical Issues` map to IMPORTANT / CRITICAL, which
# are deliberately absent from $SEVERITIES_REGEX above — those must keep
# BLOCKING the PR through the existing /pr-check marker flow and must never
# be auto-filed here.
#
# Lines already in the canonical shape (and any other line that isn't a panel
# finding) pass through completely unchanged — this pass is additive, never
# destructive to the existing input format. A line that looks like a panel
# finding (`- [id]: ...` / `[id]: ...`) but can't be normalised — no bracketed
# `[path]`/`[path:line]` suffix, or an unknown/absent section — is never
# silently dropped: it's reported on stderr as
# `skipped (unparsable) <id>: <first 100 chars of the line>` and counted, plus
# a one-line per-section recognised/skipped summary. Implemented with bash's
# own `[[ =~ ]]` (BASH_REMATCH) rather than awk capture groups (not POSIX,
# and mawk/busybox awk on some platforms lack them) or associative arrays
# (bash 3.2 on macOS has none) — stays portable git-bash/linux/macos.
normalize_panel_input() {
    local section="" line id rest sev path lnum
    local suggestion_n=0 important_n=0 critical_n=0 skipped_n=0

    while IFS= read -r line; do
        # Section heading: "## Suggestions (3 found)" -> section="Suggestions"
        if [[ "$line" =~ ^##[[:space:]]+(.+)[[:space:]]+\([0-9]+[[:space:]]+found\)[[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        # Any OTHER "##" heading (a different producer's section, e.g. a
        # /pr-review-toolkit:review-pr heading combined into the same input)
        # clears section state instead of leaving it stale — without this a later `[id]: ... [path:line]` bullet under
        # an unrelated heading would inherit the PRIOR panel section and be
        # auto-filed (or blocked) as though it still belonged there.
        if [[ "$line" =~ ^##[[:space:]] ]]; then
            section=""
            continue
        fi

        # Panel finding line: `- [id]: text [path:line]` — bullet optional
        # (`-`/`*`), no-bullet tolerated too.
        if [[ "$line" =~ ^[[:space:]]*([-*][[:space:]]+)?\[([^]]+)\]:[[:space:]]*(.*)$ ]]; then
            id="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[3]}"

            case "$section" in
                Suggestions)         sev="SUGGESTION" ;;
                "Important Issues")  sev="IMPORTANT" ;;
                "Critical Issues")   sev="CRITICAL" ;;
                *)                   sev="" ;;
            esac

            if [ -n "$sev" ] && [[ "$rest" =~ ^(.*[^[:space:]])[[:space:]]+\[([^][:space:]]+)(:([0-9]+))?\][[:space:]]*$ ]]; then
                path="${BASH_REMATCH[2]}"
                lnum="${BASH_REMATCH[4]}"
                if [ -n "$lnum" ]; then
                    printf '%s\n' "${path}:${lnum}: ${sev}: [${id}] ${BASH_REMATCH[1]}"
                else
                    printf '%s\n' "${path}: ${sev}: [${id}] ${BASH_REMATCH[1]}"
                fi
                case "$sev" in
                    SUGGESTION) suggestion_n=$((suggestion_n + 1)) ;;
                    IMPORTANT)  important_n=$((important_n + 1)) ;;
                    CRITICAL)   critical_n=$((critical_n + 1)) ;;
                esac
            else
                echo "skipped (unparsable) ${id}: ${line:0:100}" >&2
                skipped_n=$((skipped_n + 1))
            fi
            continue
        fi

        printf '%s\n' "$line"
    done <<< "$1"

    if [ "$((suggestion_n + important_n + critical_n + skipped_n))" -gt 0 ]; then
        echo "file-deferred-issues: panel findings recognised — Suggestions=${suggestion_n}, Important Issues=${important_n}, Critical Issues=${critical_n}; ${skipped_n} skipped (unparsable)" >&2
    fi
}
NORMALIZED_CONTENT=$(normalize_panel_input "$INPUT_CONTENT")

HEAD_SHA=$(git rev-parse --short HEAD)

# Extract candidate lines. Primary pattern: `path[:line]: SEV: text`
# — LINE is OPTIONAL (`(:[0-9]+)?`). File-only findings (typo in
# README, missing doc section) are valid and would otherwise be
# rejected. Use grep -E (egrep) —
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
candidates=$(printf '%s\n' "$NORMALIZED_CONTENT" \
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

# Batch identity for the jira/none paths: one hash over every candidate line,
# so re-running on the same review output finds the same ticket. The marker is
# a single alphanumeric word because Jira's text search tokenises punctuation.
batch_repo=$(git config --get remote.origin.url 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || echo unknown-repo)
batch_hash=$(printf '%s\n%s\n' "$batch_repo" "$candidates" | $HASH_CMD | awk '{print $1}')
batch_short="${batch_hash:0:12}"
batch_marker="crbatch${batch_short}"
batch_list=$(printf '%s\n' "$candidates" | awk '{printf "%d. %s\n", NR, $0}')
batch_count=$(printf '%s\n' "$candidates" | grep -c .)

if [ "$TRACKER_MODE" = none ]; then
    echo "file-deferred-issues: no remote tracker is configured here — nothing filed. Put these ${batch_count} deferred finding(s) in the PR's Ticket coverage as 'deferred → <ticket>' and report them to the console (batch ${batch_short}):"
    printf '%s\n' "$batch_list"
    exit 0
fi

if [ "$TRACKER_MODE" = jira ]; then
    # The Jira CLI: JIRA_CMD (test seam, word-split on purpose) else the PRIMARY
    # checkout's dist, which a worktree lacks. The resolver already refused
    # TRACKER=jira without JIRA_PROJECT_KEY.
    jira_run() {
        local common
        if [ -n "${JIRA_CMD:-}" ]; then
            # shellcheck disable=SC2086
            $JIRA_CMD "$@"
            return $?
        fi
        # Resolved from THIS script's checkout, not the cwd repo, so a non-himmel
        # Jira repo still reaches the himmel CLI.
        common=$(git -C "$FDI_LIB_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
            echo "cannot locate the Jira CLI (set JIRA_CMD)" >&2
            return 1
        }
        node "$(dirname "$common")/scripts/jira/dist/index.js" "$@"
    }
    jira_title="[CR PR #${PR_NUMBER}] Deferred review findings (${batch_count})"

    # Dedupe — fail-closed. A lookup error must NOT file (a transient failure
    # would otherwise duplicate the ticket) and must NOT fall back to GitHub.
    # No status filter: a closed ticket counts, so a closed batch stays closed.
    jira_err_file=$(mktemp -t fdi-jira.err.XXXXXX) || exit 1
    if ! existing=$(jira_run list --project "$JIRA_PROJECT_KEY" --limit 1 \
            --jql "project = ${JIRA_PROJECT_KEY} AND labels = \"${LABEL}\" AND text ~ \"${batch_marker}\"" 2>"$jira_err_file"); then
        dedupe_err=$(cat "$jira_err_file" 2>/dev/null || true)
        rm -f "$jira_err_file"
        echo "skipped (jira-dedupe-check-failed) ${batch_short} — fail-closed: ${dedupe_err}" >&2
        echo "file-deferred-issues: summary — 0 filed, 0 duplicates, 0 dry-run, 0 failed, 1 dedupe-check-failed"
        exit 4
    fi
    rm -f "$jira_err_file"
    existing_key=$(printf '%s\n' "$existing" | awk 'NF{print $1; exit}')
    if [ -n "$existing_key" ]; then
        echo "skipped (duplicate, ${existing_key}) ${batch_short}"
        echo "file-deferred-issues: summary — 0 filed, 1 duplicates, 0 dry-run, 0 failed, 0 dedupe-check-failed"
        exit 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "skipped (dry-run) ${batch_short} — would file Jira ticket: ${jira_title}"
        printf '%s\n' "$batch_list"
        echo "file-deferred-issues: summary — 0 filed, 0 duplicates, 1 dry-run, 0 failed, 0 dedupe-check-failed"
        exit 0
    fi

    # printf, not a heredoc: the findings are review text and must not be
    # expanded. The body carries the Impact/What/Why/Plan/DoD/Agent detail shape
    # the Jira CLI's ticket-shape check requires.
    jira_body_file=$(mktemp -t fdi-jira.body.XXXXXX) || exit 1
    printf '%s\n' \
        "## Impact" \
        "Non-blocking review findings from PR #${PR_NUMBER} would otherwise be lost once it merges." \
        "" \
        "## What" \
        "Triage these ${batch_count} deferred finding(s): fix each, or close it as won't-fix." \
        "" \
        "## Why" \
        "They were flagged NIT / LOW / SUGGESTION / IMPROVEMENT / DEFERRED during pre-merge review and did not block the merge." \
        "" \
        "## Plan" \
        "1. Read the findings below and fix each one, or close it as won't-fix with a one-line reason." \
        "" \
        "## DoD" \
        "- Every finding below is fixed or closed with a reason, and this ticket is moved to Done." \
        "" \
        "## Agent detail" \
        "Origin: PR #${PR_NUMBER} (HEAD ${HEAD_SHA}) in ${batch_repo}." \
        "Filed by: scripts/cr/file-deferred-issues.sh (HIMMEL-30, HIMMEL-5921)." \
        "Dedupe marker: ${batch_marker}" \
        "" \
        "Findings:" \
        "" \
        "$batch_list" >"$jira_body_file"

    jira_err_file=$(mktemp -t fdi-jira.err.XXXXXX) || exit 1
    create_rc=0
    created=$(jira_run create --type Task --title "$jira_title" --labels "$LABEL,standalone" --sector 'Ship loop' \
        --project "$JIRA_PROJECT_KEY" --desc-file "$jira_body_file" 2>"$jira_err_file") || create_rc=$?
    create_err=$(cat "$jira_err_file" 2>/dev/null || true)
    rm -f "$jira_err_file" "$jira_body_file"
    new_key=$(printf '%s\n' "$created" | sed -n 's/^Created \([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\).*/\1/p' | head -n1)
    if [ "$create_rc" -ne 0 ] || [ -z "$new_key" ]; then
        echo "FAILED ${batch_short}: ${create_err:-no 'Created <KEY>' line in the Jira CLI output: $created}" >&2
        echo "file-deferred-issues: summary — 0 filed, 0 duplicates, 0 dry-run, 1 failed, 0 dedupe-check-failed"
        exit 3
    fi
    echo "filed ${new_key} ${batch_short}"
    echo "file-deferred-issues: summary — 1 filed, 0 duplicates, 0 dry-run, 0 failed, 0 dedupe-check-failed"
    exit 0
fi

# Resolve repo identity via the forge seam — owner/repo on GitHub, workspace/repo
# on Bitbucket. Used for the GitHub dedupe/label/create calls below; the
# Bitbucket CLI derives its own ws/repo from the origin remote, so REPO is a
# GitHub-path detail. Capture stdout (REPO) + stderr (error message) separately
# so auth-expired vs no-remote vs network failures stay distinguishable.
repo_err_file=$(mktemp -t fdi-repo.err.XXXXXX) || exit 1
# shellcheck disable=SC2119  # forge_repo_nwo takes no positional args
if ! REPO=$(forge_repo_nwo 2>"$repo_err_file"); then
    echo "ERR file-deferred-issues: could not resolve repo via forge ($FORGE):" >&2
    sed 's/^/    /' "$repo_err_file" >&2
    rm -f "$repo_err_file"
    exit 2
fi
rm -f "$repo_err_file"

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
    # previously `2>&1` merged stderr into stdout. On rc=0
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
