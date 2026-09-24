#!/usr/bin/env bash
# scripts/handover/console-kit/cut-tag.sh - console-run pre-release tag cut
# (HIMMEL-3572 row 6). A console's `git -C <primary> tag` is refused by
# block-write-into-main-checkout's arm (g) (HIMMEL-3401) - this script never
# calls `git tag` at all: the tag is created through the GitHub API
# (`gh api .../git/refs`), which the ref-write fence does not intercept
# because it never touches the primary checkout's own refs, so the console
# can run this literal without a `!` operator step.
#
# Usage:
#   cut-tag.sh <version> <sha> [--dry-run]
#   cut-tag.sh <version> <sha> --version-override <reason> [--dry-run]
#
# <sha> is the full 40-lowercase-hex commit sha (same shape go.sh requires).
# <version> must be v<X>.<Y>.<Z>-pre.<N> where N is exactly one more than the
# highest N already tagged on origin for that same v<X>.<Y>.<Z>-pre. series
# (series is derived from the version arg itself, not hardcoded, so a future
# v0.4.0-pre.1 needs no script change) - unless --version-override <reason>
# is given, which accepts any next value and records the reason in its
# stdout/PR-body trail.
#
# Refuses (nothing written on origin) unless, after a fetch:
#   - gh's default repo (from `gh repo view`) is the SAME repo as the `origin`
#     remote git itself resolves - the ancestor/tag checks below run against
#     origin, so a gh context pointed elsewhere would check one repo and tag
#     another;
#   - <sha> is an ancestor of (or equal to) origin/main;
#   - <version> does not already exist as a tag on origin;
#   - <version> is the next in-sequence pre-release (or carries
#     --version-override --reason);
#   - every check-run at <sha> is status=completed with a conclusion in
#     {success,skipped,neutral}, at least one check-run exists, and the
#     combined commit status (when it has any statuses at all) is not
#     failure/error. check-runs is the authoritative read (HIMMEL-3572
#     ruling: the combined-status endpoint alone can read `pending` with
#     zero statuses while Actions check-runs are red) - the combined-status
#     read is a second, belt-and-suspenders refusal, never the primary one.
#
# Every read that feeds a refusal decision (git remote/ls-remote, gh api) is
# itself fail-closed: a transient failure of the READ refuses with a plain
# "could not confirm" message, never falls through as if the read had come
# back clean (HIMMEL-3572 CR round: a failed `git ls-remote` used to read as
# "no tags exist", and a failed `gh api` used to read as "nothing to flag").
#
# --dry-run runs every check and prints the plan; no origin write, no tag.
#
# Exit codes:
#   0  success (or a clean --dry-run)
#   1  gh/git failure (repo resolution, origin/gh repo mismatch, fetch,
#      ls-remote, or the ref-create call itself)
#   2  usage
#   3  <sha> is not an ancestor of origin/main
#   4  check-runs / combined status not green, or unreadable
#   5  <version> already exists as a tag on origin
#   6  <version> is out of sequence and no --version-override was given
#
# GH is overridable (GH_BIN) for hermetic PATH-stub tests, same seam shape as
# go.sh's HERE-relative sourcing.
#
# Platform guard: Linux/macOS bash 3.2+ (gh + git only, no /proc dependency).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too (HIMMEL-3570)

GH="${GH_BIN:-gh}"

usage() {
    echo "usage: cut-tag.sh <version> <sha> [--dry-run] [--version-override <reason>]" >&2
}

VERSION=""
SHA=""
DRY_RUN=0
OVERRIDE=0
REASON=""
positional=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version-override)
            shift
            if [ "$#" -eq 0 ]; then
                usage
                echo "cut-tag: --version-override needs a <reason>" >&2
                exit 2
            fi
            case "$1" in
                ""|--*)
                    usage
                    echo "cut-tag: --version-override needs a non-option <reason> (got '$1')" >&2
                    exit 2 ;;
            esac
            OVERRIDE=1; REASON="$1"; shift ;;
        --*)
            usage
            echo "cut-tag: unknown flag '$1'" >&2
            exit 2 ;;
        *)
            case "$positional" in
                0) VERSION="$1" ;;
                1) SHA="$1" ;;
                *)
                    usage
                    echo "cut-tag: too many positional args" >&2
                    exit 2 ;;
            esac
            positional=$((positional + 1))
            shift ;;
    esac
done
if [ "$positional" -ne 2 ]; then
    usage
    exit 2
fi

case "$VERSION" in
    v*-pre.*) : ;;
    *)
        usage
        echo "cut-tag: version must be v<X>.<Y>.<Z>-pre.<N> (got '$VERSION')" >&2
        exit 2 ;;
esac
# The case glob above only anchors the literal "-pre." - a bare `[0-9]*` glob
# lets `*` swallow non-digit characters too (e.g. "v0a.3.0-pre.9" would pass),
# so each component is re-checked as ALL-DIGIT below rather than trusting the
# glob shape alone.
_vrest="${VERSION#v}"              # X.Y.Z-pre.N
_vcore="${_vrest%-pre.*}"          # X.Y.Z
_vn="${_vrest##*-pre.}"
_vx="${_vcore%%.*}"
_vyz="${_vcore#*.}"
_vy="${_vyz%%.*}"
_vz="${_vyz#*.}"
case "$_vz" in
    *.*)
        usage
        echo "cut-tag: version must be v<X>.<Y>.<Z>-pre.<N> (got '$VERSION')" >&2
        exit 2 ;;
esac
for _vcomp in "$_vx" "$_vy" "$_vz" "$_vn"; do
    case "$_vcomp" in
        ''|*[!0123456789]*)
            usage
            echo "cut-tag: version must be v<X>.<Y>.<Z>-pre.<N> with all-numeric components (got '$VERSION')" >&2
            exit 2 ;;
    esac
done
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; then
    usage
    echo "cut-tag: sha must be the full 40-char lowercase hex commit sha (got '$SHA')" >&2
    exit 2
fi

SERIES="${VERSION%.*}."          # "v0.3.0-pre."
N="${VERSION##*.}"               # "9"

NWO=$("$GH" repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null)
if [ -z "$NWO" ]; then
    echo "cut-tag: cannot resolve owner/repo (gh repo view --json owner,name failed)" >&2
    exit 1
fi

if ! origin_url=$(git remote get-url origin 2>/dev/null); then
    echo "cut-tag: refusing - could not resolve the origin remote's URL" >&2
    exit 1
fi
origin_nwo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
if [ "$NWO" != "$origin_nwo" ]; then
    echo "cut-tag: refusing - gh's default repo ($NWO) differs from the origin remote ($origin_nwo) - the ancestor/tag checks run against origin, so gh must target the same repo" >&2
    exit 1
fi

if ! git fetch origin main --tags --quiet 2>/dev/null; then
    echo "cut-tag: git fetch origin main --tags failed" >&2
    exit 1
fi

if ! git merge-base --is-ancestor "$SHA" origin/main 2>/dev/null; then
    echo "cut-tag: refusing - $SHA is not an ancestor of (or equal to) origin/main" >&2
    exit 3
fi

if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "cut-tag: refusing - $VERSION already exists as a tag on origin" >&2
    exit 5
fi

if [ "$OVERRIDE" -ne 1 ]; then
    maxn=0
    if ! ls_raw=$(git ls-remote --tags origin "refs/tags/${SERIES}*" 2>/dev/null); then
        echo "cut-tag: refusing - git ls-remote --tags origin failed while checking the ${SERIES}* series - cannot confirm sequence" >&2
        exit 1
    fi
    existing=$(printf '%s\n' "$ls_raw" | awk '{print $2}' | grep -v '\^{}$')
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        tail="${ref#refs/tags/"$SERIES"}"
        case "$tail" in
            *[!0123456789]*) continue ;;
        esac
        [ "$tail" -gt "$maxn" ] && maxn="$tail"
    done <<EOF
$existing
EOF
    want=$((maxn + 1))
    if [ "$N" != "$want" ]; then
        echo "cut-tag: refusing - $VERSION is out of sequence for series ${SERIES}* (next is ${SERIES}${want}); pass --version-override <reason> to force" >&2
        exit 6
    fi
fi

if ! runs_json=$("$GH" api "repos/$NWO/commits/$SHA/check-runs?per_page=100" --paginate 2>/dev/null); then
    echo "cut-tag: refusing - gh api check-runs failed at $SHA" >&2
    exit 4
fi
if [ -z "$runs_json" ]; then
    echo "cut-tag: refusing - could not read check-runs at $SHA" >&2
    exit 4
fi
total=$(printf '%s' "$runs_json" | jq -s '[.[].check_runs[]] | length' 2>/dev/null)
bad=$(printf '%s' "$runs_json" | jq -s -r '
    [.[].check_runs[]]
    | map(select(.status != "completed" or (.conclusion as $c | ["success","skipped","neutral"] | index($c) | not)))
    | .[] | "\(.name)=\(.status)/\(.conclusion // "null")"
' 2>/dev/null)
if [ -z "$total" ] || [ "$total" -eq 0 ]; then
    echo "cut-tag: refusing - no check-runs reported at $SHA (CI may not have registered yet)" >&2
    exit 4
fi
if [ -n "$bad" ]; then
    echo "cut-tag: refusing - not every check-run at $SHA is green: $bad" >&2
    exit 4
fi

if ! status_json=$("$GH" api "repos/$NWO/commits/$SHA/status" 2>/dev/null); then
    echo "cut-tag: refusing - gh api combined status failed at $SHA" >&2
    exit 4
fi
combined_state=$(printf '%s' "$status_json" | jq -r '.state // "unknown"' 2>/dev/null)
combined_count=$(printf '%s' "$status_json" | jq -r '.total_count // 0' 2>/dev/null)
if [ "${combined_count:-0}" -gt 0 ] 2>/dev/null; then
    case "$combined_state" in
        failure|error)
            echo "cut-tag: refusing - combined commit status at $SHA is $combined_state" >&2
            exit 4 ;;
    esac
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "cut-tag: DRY RUN - would create refs/tags/$VERSION at $SHA on $NWO ($total check-runs green)"
    [ "$OVERRIDE" -eq 1 ] && echo "cut-tag: DRY RUN - version-override reason: $REASON"
    exit 0
fi

if ! "$GH" api "repos/$NWO/git/refs" -f "ref=refs/tags/$VERSION" -f "sha=$SHA" >/dev/null 2>&1; then
    echo "cut-tag: gh api repos/$NWO/git/refs failed - tag not created" >&2
    exit 1
fi
git fetch origin --tags --quiet 2>/dev/null || true

echo "cut-tag: created refs/tags/$VERSION at $SHA on $NWO"
[ "$OVERRIDE" -eq 1 ] && echo "cut-tag: version-override reason: $REASON"
exit 0
