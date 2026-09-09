#!/usr/bin/env bash
# Generate CHANGELOG.md from conventional-commit history (newest first), grouped
# by version tag: `## [Unreleased]` for commits after the newest version tag,
# then one `## [<tag>] - <date>` section per release, newest release first.
# With NO version tags (the pre-first-release state) the output is a single
# `## [Unreleased]` over all history — byte-identical to the pre-HIMMEL-2250
# generator, so a tagless repo sees no churn.
# Non-conventional/merge/revert → ### Other.
# Fully generated; do not hand-edit. Idempotent on immediate re-run.
#
# Usage:
#   gen-changelog.sh            regenerate CHANGELOG.md in place
#   gen-changelog.sh --check    write nothing; exit 1 if the committed file is
#                               stale (prints the missing-entry count). This is
#                               the staleness primitive the morning report and
#                               the release step read — HIMMEL-2250.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/CHANGELOG.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every temp file this script creates is removed from ONE place. Bash EXIT traps
# are GLOBAL, not per-function: a second `trap ... EXIT` anywhere in the script
# would silently REPLACE this one, so the merge-base sentinel created inside
# generate() is cleaned here rather than at its own creation site (HIMMEL-2376,
# private #2077). The INT/TERM traps exist only to reach EXIT at all -- an
# untrapped signal terminates the shell WITHOUT running the EXIT trap, which is
# how an interrupted run used to leave `gen-changelog-mb-err.*` behind.
# `rm -f ""` is a silent no-op, so an unset slot costs nothing. The `--`
# terminator matters: a relative TMPDIR beginning with `-` would otherwise
# make `rm` parse the generated path as an option and leak both files --
# a cleanup that silently fails to clean is the defect this ticket fixes
# (codex-1, CR round 1).
tmp=""
mb_err_file=""
trap 'rm -f -- "$tmp" "$mb_err_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/commit-class.sh"

# Version tags only. The repo also carries non-version tags (recovery stashes
# etc.); matching them would invent phantom release sections, so the glob is
# `v` + digit — the scheme proposed in HIMMEL-2250 (`vMAJOR.MINOR.PATCH`, with
# `-rc.N` pre-releases sorting inside the same glob).
# KEEP IN SYNC with scripts/gen-changelog.ps1 $versionTagGlob.
VERSION_TAG_GLOB='v[0-9]*'
# The glob above is a cheap pre-filter and also matches non-version tags like
# `v1-backup` or a bare `v1.2` (too few components) — this anchored regex is
# the real gate: `vMAJOR.MINOR.PATCH` with an optional `-rc.1`-style suffix.
# KEEP IN SYNC with scripts/gen-changelog.ps1 $versionTagRe.
VERSION_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# render <heading> [<git-log-range>] — emit one version section. An empty range
# means "all history" (the tagless case). Always emits a leading blank line so
# the file ends with exactly one trailing newline (see the trailing-newline note
# below); `return 0` is load-bearing under `set -e` — the last `[ -n … ] && { … }`
# returns 1 when that section is empty, which would otherwise abort the script
# mid-file the moment a repo has no ### Other commits.
render() {
    local heading="$1" range="${2:-}"
    local added="" fixed="" changed="" other="" subj
    # Added/Fixed are single-type sections (the heading conveys feat/fix), so
    # strip the whole `type(scope): ` prefix → just the description (keeps the
    # `[HIMMEL-N]` + message). `${subj#*: }` removes up to & incl the first
    # `: ` (colon-space); a malformed no-space subject keeps its prefix.
    # Changed is mixed-type (chore/refactor/docs/test) so the type stays
    # informative — keep the full subject; Other keeps the raw subject.
    while IFS= read -r subj; do
        case "$(cc_classify "$subj")" in
            feat)    added="${added}- ${subj#*: }"$'\n';;
            fix)     fixed="${fixed}- ${subj#*: }"$'\n';;
            changed) changed="${changed}- ${subj}"$'\n';;
            *)       other="${other}- ${subj}"$'\n';;
        esac
    done < <(git log --no-merges --format='%s' ${range:+"$range"})
    echo
    echo "$heading"
    [ -n "$added" ]   && { echo; echo "### Added";   printf '%s' "$added"; }
    [ -n "$fixed" ]   && { echo; echo "### Fixed";   printf '%s' "$fixed"; }
    [ -n "$changed" ] && { echo; echo "### Changed"; printf '%s' "$changed"; }
    [ -n "$other" ]   && { echo; echo "### Other";   printf '%s' "$other"; }
    return 0
}

# Blank line goes BEFORE each heading (not after each section) so the file
# ends with exactly one trailing newline — otherwise end-of-file-fixer rewrites
# it on every commit and a freshly regenerated file never matches the committed
# one (breaking the idempotence promise). $added/$fixed/… already end in \n, so
# the section body is emitted with `printf '%s'` (no extra trailing newline).
generate() {
    local tags=() t prev date
    # Sentinel for a real `git merge-base` error (see below): the tag filter
    # runs inside a process-substitution pipeline, so a plain `exit` there
    # only kills that subshell, not this script -- the sentinel file is how
    # the failure is carried back out to fail generation for real.
    mb_err_file="$(mktemp "${TMPDIR:-/tmp}/gen-changelog-mb-err.XXXXXX")" || {
        echo "gen-changelog: mktemp failed" >&2
        exit 1
    }
    # Order by ANCESTRY (commit count via `git rev-list --count`), newest
    # first — NOT creatordate: a backfilled annotated tag on an older commit
    # can carry a newer creatordate than a tag on a later commit, which would
    # sort it first and compute `<prev>..<tag>` ranges against the wrong
    # predecessor. Assumes a linear release history (this repo's `main`,
    # squash merges) — a tag on a side branch is not orderable this way, so
    # such tags are filtered out below (with a stderr warning) before the
    # count sort even runs (HIMMEL-2363).
    # KEEP IN SYNC with scripts/gen-changelog.ps1 tag ordering.
    while IFS= read -r t; do
        [ -n "$t" ] && tags+=("$t")
    done < <(
        while IFS= read -r vt; do
            [ -n "$vt" ] || continue
            # Reachable-commit-count ordering is only valid for tags that are
            # ancestors of HEAD — a tag on a side branch has no topological
            # relationship to HEAD's history, so its count is meaningless and
            # sorting by it corrupts every release range (HIMMEL-2363: a
            # side-branch tag with a higher count than the real latest
            # release outranks it, and commits already released reappear
            # under both `## [Unreleased]` and their real release section).
            # Drop it, but never silently: a dropped release tag is a trap
            # for the next operator wondering where a release went.
            # `--is-ancestor` exits 1 for "not an ancestor" but >1 for a real
            # git error (bad object, corrupt ref) -- conflating the two would
            # silently drop a release tag on an operational error instead of
            # failing generation (HIMMEL-2363 CR). The error is recorded to
            # $mb_err_file (see above) so it fails the whole script, not just
            # this pipeline subshell.
            # KEEP IN SYNC with scripts/gen-changelog.ps1 ancestry filter.
            mb_rc=0
            git merge-base --is-ancestor "$vt" HEAD 2>/dev/null || mb_rc=$?
            if [ "$mb_rc" -gt 1 ]; then
                echo "gen-changelog: ERROR: git merge-base --is-ancestor failed for tag '$vt' (exit $mb_rc)" >&2
                echo "$mb_rc" > "$mb_err_file"
                exit 1
            elif [ "$mb_rc" -eq 1 ]; then
                echo "gen-changelog: WARNING: version tag '$vt' is not an ancestor of HEAD (side branch) — excluded from CHANGELOG.md" >&2
                continue
            fi
            # Tie-break for equal ancestry counts (two tags on the SAME
            # commit, e.g. an rc promoted to its release): a release sorts
            # before a pre-release of the same version (semver precedence --
            # `v0.1.0` outranks `v0.1.0-rc.1`), then tag name descending, so
            # the order is total. rank=1 (no `-` suffix) sorts ahead of
            # rank=0 (has one) under the `nr` (numeric reverse) sort below.
            # KEEP IN SYNC with scripts/gen-changelog.ps1 $rank.
            case "$vt" in
                *-*) rank=0 ;;
                *)   rank=1 ;;
            esac
            printf '%s\t%s\t%s\n' "$(git rev-list --count "$vt")" "$rank" "$vt"
        done < <(git tag --list "$VERSION_TAG_GLOB" | grep -E "$VERSION_TAG_RE") \
          | sort -t $'\t' -k1,1nr -k2,2nr -k3,3r | cut -f3
    )
    if [ -s "$mb_err_file" ]; then
        rm -f -- "$mb_err_file"
        exit 1
    fi
    rm -f -- "$mb_err_file"

    echo "<!-- generated by scripts/gen-changelog.sh; do not hand-edit -->"
    echo "# Changelog"
    if [ "${#tags[@]}" -eq 0 ]; then
        render "## [Unreleased]"
        return 0
    fi
    # Newest tag first: unreleased = everything after it, then each tag's own
    # range down to its predecessor; the oldest tag takes the open-ended range
    # (all history up to that tag).
    render "## [Unreleased]" "${tags[0]}..HEAD"
    local i=0
    while [ "$i" -lt "${#tags[@]}" ]; do
        t="${tags[$i]}"
        prev=""
        [ $((i + 1)) -lt "${#tags[@]}" ] && prev="${tags[$((i + 1))]}"
        date="$(git log -1 --format=%ad --date=short "$t")"
        render "## [$t] - $date" "${prev:+$prev..}$t"
        i=$((i + 1))
    done
    return 0
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f "$OUT" ]; then
        echo "STALE gen-changelog: CHANGELOG.md is missing — run scripts/gen-changelog.sh"
        exit 1
    fi
    # Explicit template (BSD/macOS portability); capture failure before
    # generate builds paths on an unset $tmp. The EXIT trap that removes this
    # file is installed once at the top of the script (HIMMEL-2376), not here.
    tmp="$(mktemp "${TMPDIR:-/tmp}/gen-changelog.XXXXXX")" || {
        echo "gen-changelog: mktemp failed" >&2
        exit 1
    }
    generate > "$tmp"
    if cmp -s "$tmp" "$OUT"; then
        echo "OK gen-changelog: CHANGELOG.md is current"
        exit 0
    fi
    # Count only entry lines (`- ...`), not section headings/blank lines a new
    # section introduces — `diff` marks an added line `> `, so an entry line
    # shows as `> - `.
    # `|| true` rescues the pipeline: diff exits 1 on a difference and pipefail
    # would propagate that into the command substitution under `set -e`.
    missing="$(diff "$OUT" "$tmp" 2>/dev/null | grep -c '^> - ' || true)"
    if [ "$missing" -eq 0 ]; then
        # A tag-only restructure (a release tag added with no new commits)
        # moves existing entries between sections without adding any --
        # "0 entr(ies) behind" reads as a bug in the checker, not staleness.
        # Report the true shape instead; morning-report.sh's counted-line
        # regex only matches "is <digits> entr(ies) behind", so this line
        # correctly falls through to its verbatim fallback.
        echo "STALE gen-changelog: CHANGELOG.md structure changed with no new entries — run scripts/gen-changelog.sh"
    else
        echo "STALE gen-changelog: CHANGELOG.md is $missing entr(ies) behind — run scripts/gen-changelog.sh"
    fi
    exit 1
fi

generate > "$OUT"
