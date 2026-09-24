#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/dead-parts.sh - HIMMEL-3513 EXPANSION 2: static
# entry-point audit. Classifies every himmel entry point (tracked scripts/**,
# slash commands, skills, agents - hooks fold into scripts/** via the WIRED
# git-grep pass, see below) into USED / WIRED / TEST-ONLY / DOC-ONLY / DEAD.
# Report only - it never deletes or suggests deleting anything.
#
# USED: a direct transcript tool_use/typed-command call in the --since/--until
# window - its own minimal scan (independent of tool-usage.sh, per the
# HIMMEL-3513 EXPANSION 2 brief: "do your own scan, don't share code").
# WIRED / TEST-ONLY / DOC-ONLY / DEAD: static, via `git grep` at --repo-root,
# window-independent - a change on disk changes these, not the passage of time.
#
# Precedence when an entry matches more than one static class: USED beats all;
# else WIRED beats TEST-ONLY/DOC-ONLY/DEAD; else TEST-ONLY beats DOC-ONLY/DEAD;
# else DOC-ONLY beats DEAD.
#
# Hooks: every hook script's path appears as a literal substring inside the
# tracked .claude/settings.json / .codex/hooks.json (the `command` strings
# quote it in full), so the general script git-grep pass finds them there with
# no special-case parsing - they land WIRED, never USED (hooks are not called
# via a transcript tool_use).
#
# ponytail: a hook's WIRED row never gets a denial-count annotation - the
# HIMMEL-3513 EXPANSION 2 brief allows skipping this "if not cheap", and
# joining this script's static pass against the hook-denial log the way
# tool-usage.sh does is exactly the shared code this script is told not to
# have. WIRED count=0 is reported instead; the real denial counts belong to
# tool-usage.sh's own table.
#
# ponytail: a test file discovered only by a runner's directory glob (e.g. a
# hypothetical `for f in test-*.sh`) carries no textual reference to its own
# filename anywhere in tracked content, so it shows DEAD here even though it
# runs in CI/pre-commit. Accepted given "report only, no deletions" - a human
# reviews every DEAD row before acting.
#
# HIMMEL-3513 follow-up (PR #1170's caveat): `.ts` was missing from the
# discovery extension filter entirely, so a `.ts` source file was never even
# added as an entry point - it silently never appeared in the report at all,
# neither WIRED nor DEAD. Fixed: `.ts` is now discovered like `.sh`/`.js`.
# Separately, a TS-ESM import specifier names the compiled `.js` extension
# (`from "../foo.js"`) while the tracked source is `foo.ts`, so a plain
# basename-literal grep on the `.ts` name still misses real references. Fixed:
# a `.ts` entry's reference search also unions a basename search on its
# `.js`-suffixed name (see the classification loop below).
#
# HIMMEL-3550 follow-up: a `.ts` entry can ALSO be imported via an
# extensionless specifier (`from "./foo"`), which the `.js`-suffixed union
# above still misses. The reference search also unions a quote-terminated
# `/<basename>"` / `/<basename>'` search for `.ts` entries only, over-matching
# a same-named directory or unrelated string ending the same way, kept narrow
# on purpose (see the classification loop).
#
# Usage: dead-parts.sh --since <ISO8601> [--until <ISO8601>] [--repo-root <path>]
#
# --repo-root scopes the STATIC git-grep audit to a repo other than the one
# this script lives in (test-dead-parts.sh points it at a throwaway fixture
# repo, built fresh per run - never a nested .git committed into this repo).
# The USED transcript scan is always scoped by SCORECARD_PROJECTS_DIR /
# sc_transcript_roots(), same as every sibling metric; the two scopes are
# independent by design; a fixture repo has no matching real transcripts.
#
# Platform guard: no .ps1 twin, by design.
set -u

usage() { echo "usage: dead-parts.sh --since <ISO8601> [--until <ISO8601>] [--repo-root <path>]" >&2; }

SINCE=""; UNTIL=""; REPO_ROOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --repo-root) REPO_ROOT="${2:?--repo-root needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "dead-parts: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check dead-parts || exit 2

if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$REPO_ROOT" ] || { echo "dead-parts: could not determine default --repo-root (not inside a git repo?)" >&2; exit 2; }
fi
[ -e "$REPO_ROOT/.git" ] || { echo "dead-parts: not a git repo root: $REPO_ROOT" >&2; exit 2; }

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# extra-metrics.sh's to_epoch()).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "dead-parts: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "dead-parts: bad --until: $UNTIL" >&2; exit 2; }
fi
UNTIL_EPOCH_ARG="${UNTIL_EPOCH:-9999999999}"

RUN=""
trap 'rm -rf "$RUN" "$SC_COV"' EXIT
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dead-parts.XXXXXX") || { echo "dead-parts: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

# --- discover entry points at --repo-root -----------------------------------
ENTRIES="$RUN/entries.tsv"   # kind<TAB>name<TAB>path
: > "$ENTRIES"

# codex-3: a broken repo lookup at --repo-root (corrupt .git, detached
# gitdir, etc.) must abort loudly rather than fall through to an empty file
# and a "successful" report claiming every entry point is missing.
ls_files_or_die() {
    local out="$1" err="$RUN/ls-files-err.txt"; shift
    if ! git -C "$REPO_ROOT" ls-files -- "$@" > "$out" 2>"$err"; then
        echo "dead-parts: git ls-files failed for --repo-root '$REPO_ROOT' (path: $*): $(cat "$err")" >&2
        exit 1
    fi
}

ls_files_or_die "$RUN/script-files.txt" scripts
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
        */fixtures/*) continue ;;
        # codex-1 (round 11): scripts/ also carries data and doc files
        # (backends.json, README.md, ...) - without an extension filter every
        # tracked file under it was misclassified as a script entry point.
        # HIMMEL-3513 follow-up: .ts was missing from this filter entirely, so
        # a TS source file was never even added as an entry point - it could
        # not be reported DEAD OR WIRED, it just silently never appeared.
        *.sh|*.mjs|*.js|*.py|*.ts) ;;
        *) continue ;;
    esac
    n=$(basename "$p"); n="${n%.sh}"; n="${n%.mjs}"; n="${n%.js}"; n="${n%.py}"; n="${n%.ts}"
    printf 'script\t%s\t%s\n' "$n" "$p"
done < "$RUN/script-files.txt" >> "$ENTRIES"

ls_files_or_die "$RUN/claude-files.txt" .claude
ls_files_or_die "$RUN/mp-files.txt" marketplace/plugins

{
    grep -E '^\.claude/commands/[^/]+\.md$' "$RUN/claude-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$p" .md); printf 'command\t%s\t%s\n' "$n" "$p"
    done
    grep -E '^marketplace/plugins/[^/]+/commands/[^/]+\.md$' "$RUN/mp-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$p" .md); printf 'command\t%s\t%s\n' "$n" "$p"
    done

    grep -E '^\.claude/skills/[^/]+/SKILL\.md$' "$RUN/claude-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$(dirname "$p")"); printf 'skill\t%s\t%s\n' "$n" "$p"
    done
    grep -E '^marketplace/plugins/[^/]+/skills/[^/]+/SKILL\.md$' "$RUN/mp-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$(dirname "$p")"); printf 'skill\t%s\t%s\n' "$n" "$p"
    done

    grep -E '^\.claude/agents/[^/]+\.md$' "$RUN/claude-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$p" .md); printf 'agent\t%s\t%s\n' "$n" "$p"
    done
    grep -E '^marketplace/plugins/[^/]+/agents/[^/]+\.md$' "$RUN/mp-files.txt" 2>/dev/null | while IFS= read -r p; do
        n=$(basename "$p" .md); printf 'agent\t%s\t%s\n' "$n" "$p"
    done
} >> "$ENTRIES"

# --- USED: minimal independent transcript scan, own window -------------------
FILES="$RUN/files.txt"
DISC_ERR="$RUN/disc-err.txt"
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "dead-parts: transcript discovery failed under the transcript root(s) - refusing to print a partial count:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

# round-6 codex-1: a transcript's records are not guaranteed chronological (a
# resumed/compacted session can append a record whose timestamp sorts earlier
# than one physically before it), so gating the whole file on its head/tail
# LINES' timestamps can discard a file that still has a genuinely in-window
# record somewhere in the middle. Gate on the true min/max instead - the
# per-record `inwin` filter below still does the real per-record selection;
# this is only the cheap whole-file skip.
#
# HIMMEL-3513 follow-up: the min/max used to come from a per-line bash loop
# calling `to_epoch` (a `date -d` fork) once per extracted timestamp - fine
# for a handful of records, but a real transcript file can carry thousands of
# tool_use timestamps, and a real run scans every *.jsonl under every
# transcript root (hundreds of worktree roots as legs accumulate). That is
# tens or hundreds of thousands of serial `date` forks before the FIRST byte
# of the report prints (the report is built and emitted only after this whole
# scan finishes), which is indistinguishable from a silent hang to anyone who
# doesn't wait it out. `to_epoch` is now called at most twice per file - the
# extracted timestamps are ISO8601 UTC strings of uniform width, which sort
# lexically in chronological order, so the sorted first/last line IS the
# min/max without visiting every line in a subshell.
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | cut -d'"' -f4 | sort; }

# HIMMEL-3547: a malformed timestamp (matches the extraction charset but
# fails `date -d`/`date -j`, e.g. an out-of-range month/day) can still sort
# to the lexically-first or -last line, so the sorted head/tail line's
# to_epoch can fail even though every other timestamp in the file parses
# fine. Falling back to skipping the whole file (bad-timestamp) then throws
# away real in-window usage evidence. On a head/tail parse failure, scan the
# sorted list from that end for the nearest line that DOES parse instead -
# this only runs on the rare malformed case, so the common-case "at most
# twice" fork budget above is unaffected.
nearest_valid_epoch() {
    # $1 = sorted timestamp file, $2 = order (asc for min, desc for max)
    local f="$1" order="$2" f_sorted line e
    if [ "$order" = desc ]; then f_sorted=$(sort -r "$f"); else f_sorted=$(cat "$f"); fi
    while IFS= read -r line; do
        e=$(to_epoch "$line") && { printf '%s\n' "$e"; return 0; }
    done <<EOF
$f_sorted
EOF
    return 1
}

TAGGED="$RUN/tagged.tsv"; : > "$TAGGED"
JQ_FAILS=0
BAD_EDGE_TIMESTAMPS=0
while IFS= read -r f; do
    [ -r "$f" ] || { sc_cov unreadable; continue; }
    case "$f" in */subagents/*) sc_cov subagent; continue ;; esac

    ts_of "$f" > "$RUN/cur-ts.txt"
    [ -s "$RUN/cur-ts.txt" ] || { sc_cov no-timestamp; continue; }
    file_bad_edge=0
    min_epoch=$(to_epoch "$(head -n 1 "$RUN/cur-ts.txt")") || min_epoch=""
    if [ -z "$min_epoch" ]; then
        min_epoch=$(nearest_valid_epoch "$RUN/cur-ts.txt" asc) || min_epoch=""
        [ -n "$min_epoch" ] && file_bad_edge=1
    fi
    max_epoch=$(to_epoch "$(tail -n 1 "$RUN/cur-ts.txt")") || max_epoch=""
    if [ -z "$max_epoch" ]; then
        max_epoch=$(nearest_valid_epoch "$RUN/cur-ts.txt" desc) || max_epoch=""
        [ -n "$max_epoch" ] && file_bad_edge=1
    fi
    [ "$file_bad_edge" -eq 1 ] && BAD_EDGE_TIMESTAMPS=$((BAD_EDGE_TIMESTAMPS + 1))
    if [ -z "$min_epoch" ] || [ -z "$max_epoch" ]; then sc_cov bad-timestamp; continue; fi
    [ "$max_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$min_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi

    out=$(jq -r --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" '
      def inwin: (.timestamp // null) as $t | $t != null and
        (try (($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) >= $since_epoch and
              ($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) < $until_epoch)
         catch false);
      select(inwin) |
      if .type=="assistant" then
        (.message.content[]? | select(.type=="tool_use") |
          if .name=="Skill" then "SKILL\t\(.input.skill // "")"
          elif .name=="Bash" then "BASH\t\(.input.command // "" | gsub("\n";" "))"
          elif .name=="Agent" then "AGENT\t\(.input.subagent_type // "")"
          else empty end)
      elif .type=="user" then
        (.message.content | select(type=="string") | select(test("^<command-name>")) | "CMD\t\(.)")
      else empty end
      ' "$f" 2>/dev/null) || { JQ_FAILS=$((JQ_FAILS + 1)); sc_cov jq-failed; continue; }
    sc_cov parsed
    printf '%s\n' "$out" >> "$TAGGED"
done < "$FILES"

if [ "$JQ_FAILS" -gt 0 ]; then
    echo "dead-parts: WARNING: $JQ_FAILS transcript(s) skipped due to jq failure in the USED scan" >&2
fi
if [ "$BAD_EDGE_TIMESTAMPS" -gt 0 ]; then
    echo "dead-parts: WARNING: $BAD_EDGE_TIMESTAMPS transcript(s) had a malformed head/tail timestamp - fell back to the nearest valid one instead of skipping the file" >&2
fi

# ponytail: a transcript's Skill tool_use may name a plugin-qualified skill
# (`plugin:name`) while discovery's `name` is bare, so a used skill is matched
# by taking the suffix after the last `:` - same tradeoff as tool-usage.sh's
# own USED-skill matching, same accepted collision risk.
awk -F'\t' '$1=="SKILL" && $2!=""{print $2}' "$TAGGED" | sed 's/.*://' | sort -u > "$RUN/used-skill-names.txt"
awk -F'\t' '$1=="AGENT" && $2!=""{print $2}' "$TAGGED" | sort -u > "$RUN/used-agent-names.txt"
awk -F'\t' '$1=="BASH"{print $2}' "$TAGGED" > "$RUN/bash-commands.txt"
awk -F'\t' '$1=="CMD"{print $2}' "$TAGGED" > "$RUN/command-strings.txt"
grep -o '<command-name>/\?[^<]*' "$RUN/command-strings.txt" 2>/dev/null \
    | sed -E 's#^<command-name>/?##' | sort -u > "$RUN/used-command-names.txt"
# ponytail: USED-script detection is a path-substring match against raw Bash
# command text, so a `cat`/`grep` on a script's own path also counts as USED,
# not only its execution. Accepted: the same over-counting risk already
# applies to the WIRED git-grep pass (a mention anywhere in tracked content
# also counts), and this metric's job is "does anything reference this path
# at all", not "does anything execute it" - a human reviews every DEAD row.
: > "$RUN/used-script-paths.txt"
awk -F'\t' '$1=="script"{print $3}' "$ENTRIES" | while IFS= read -r sp; do
    grep -qF -- "$sp" "$RUN/bash-commands.txt" 2>/dev/null && echo "$sp" >> "$RUN/used-script-paths.txt"
done

# --- static classification: WIRED / TEST-ONLY / DOC-ONLY / DEAD -------------
classify_hits() {
    # $1 = entry's own path (excluded as a self-match); stdin = hit file list
    _cp_code=0; _cp_test=0; _cp_doc=0
    while IFS= read -r hp; do
        [ -z "$hp" ] && continue
        [ "$hp" = "$1" ] && continue
        case "$hp" in
            test-*.sh|*/test-*.sh|*.test.*|*_test.*|*.spec.*|*_spec.*|tests/*|*/tests/*|test/*|*/test/*) _cp_test=1 ;;
            docs/*) _cp_doc=1 ;;
            *) _cp_code=1 ;;
        esac
    done
    if [ "$_cp_code" -eq 1 ]; then echo WIRED
    elif [ "$_cp_test" -eq 1 ]; then echo TEST-ONLY
    elif [ "$_cp_doc" -eq 1 ]; then echo DOC-ONLY
    else echo DEAD
    fi
}

CLASS="$RUN/classified.tsv"
: > "$CLASS"
GIT_GREP_FAILS=0
while IFS=$'\t' read -r kind name path; do
    [ -n "$kind" ] || continue
    used=0
    case "$kind" in
        script) grep -qxF -- "$path" "$RUN/used-script-paths.txt" 2>/dev/null && used=1 ;;
        skill) grep -qxF -- "$name" "$RUN/used-skill-names.txt" 2>/dev/null && used=1 ;;
        command) grep -qxF -- "$name" "$RUN/used-command-names.txt" 2>/dev/null && used=1 ;;
        agent) grep -qxF -- "$name" "$RUN/used-agent-names.txt" 2>/dev/null && used=1 ;;
    esac
    if [ "$used" -eq 1 ]; then
        printf '%s\t%s\t%s\tUSED\n' "$kind" "$name" "$path" >> "$CLASS"
        continue
    fi
    if [ "$kind" = "script" ]; then pattern="$path"; else pattern="$name"; fi
    hits=$(git -C "$REPO_ROOT" grep -lF -- "$pattern" 2>/dev/null); grc=$?
    [ "$grc" -gt 1 ] && GIT_GREP_FAILS=$((GIT_GREP_FAILS + 1))
    # codex-1 fix: entry discovery already excludes */fixtures/* (this
    # scorecard kit's own fixture trees, or any other repo's), so the
    # reference search must too - otherwise a real script's name appearing
    # inside a committed fixture (a transcript, a nested test repo) counts as
    # a real reference and masks a genuinely dead script as WIRED.
    # codex-2 fix: a root-level fixtures/ dir has no leading slash in
    # git-grep output, so the exclusion must also match a path that STARTS
    # with fixtures/, not only .../fixtures/... .
    hits=$(printf '%s\n' "$hits" | grep -vE '(^|/)fixtures/')
    # ponytail: this basename search (script entries only, always run and
    # unioned with the full-path hits rather than gated on the full-path
    # search coming up empty - a doc's full-path reference must never
    # suppress a code caller that only spells the path relatively, e.g.
    # ./foo.sh next to a docs/*.md hit on scripts/foo.sh) is a literal
    # substring search, so it also over-counts: a basename that is itself a
    # substring of another tracked file's name or prose (e.g. `caller.sh`
    # inside `test-caller.sh`, or inside a comment like "called from
    # caller.sh") counts as a hit too. Accepted for the same reason as the
    # USED-script ponytail above - the job is "does anything reference this
    # name at all", and the direction of the error (false WIRED, not false
    # DEAD) is the safe one for a report a human reviews before acting.
    if [ "$kind" = "script" ]; then
        bn_hits=$(git -C "$REPO_ROOT" grep -lF -- "$(basename "$path")" 2>/dev/null); bgrc=$?
        [ "$bgrc" -gt 1 ] && GIT_GREP_FAILS=$((GIT_GREP_FAILS + 1))
        bn_hits=$(printf '%s\n' "$bn_hits" | grep -vE '(^|/)fixtures/')
        hits=$(printf '%s\n%s\n' "$hits" "$bn_hits" | grep -v '^$' | sort -u)
    fi
    # HIMMEL-3513 follow-up (PR #1170's caveat): a TS-ESM import specifier
    # names the compiled `.js` extension (`from "../src/foo.js"`) while the
    # tracked source is `foo.ts`, so neither the full-path nor the
    # basename-literal search above ever matches a real import. Union in one
    # more basename search on the .js-suffixed name for .ts entries only.
    # HIMMEL-3550: a `.ts` entry can also be imported via an EXTENSIONLESS
    # specifier (`from "./foo"`, resolver-dependent, common with bundlers),
    # which neither the full-path nor either basename-literal search above
    # ever matches. Union in a search for the basename immediately preceded
    # by a `/` and immediately followed by a closing quote - narrow (.ts
    # entries only, quote-terminated) to keep false-positive risk low, but
    # still over-matches a same-named directory or an unrelated string that
    # happens to end in `/<basename>"` or `/<basename>'`. The basename is
    # ERE-escaped before interpolation, so a literal basename is always what
    # gets matched (CR round 1, codex-1).
    case "$path" in
        *.ts)
            js_bn="$(basename "$path" .ts).js"
            js_hits=$(git -C "$REPO_ROOT" grep -lF -- "$js_bn" 2>/dev/null); jgrc=$?
            [ "$jgrc" -gt 1 ] && GIT_GREP_FAILS=$((GIT_GREP_FAILS + 1))
            js_hits=$(printf '%s\n' "$js_hits" | grep -vE '(^|/)fixtures/')
            hits=$(printf '%s\n%s\n' "$hits" "$js_hits" | grep -v '^$' | sort -u)

            ext_bn="$(basename "$path" .ts)"
            # shellcheck disable=SC2016 # single-quoted sed script: no expansion wanted
            ext_bn_esc=$(printf '%s' "$ext_bn" | sed 's/[.[\*^$()+?{|]/\\&/g')
            extless_hits=$(git -C "$REPO_ROOT" grep -lE -- "/${ext_bn_esc}[\"']" 2>/dev/null); egrc=$?
            [ "$egrc" -gt 1 ] && GIT_GREP_FAILS=$((GIT_GREP_FAILS + 1))
            extless_hits=$(printf '%s\n' "$extless_hits" | grep -vE '(^|/)fixtures/')
            hits=$(printf '%s\n%s\n' "$hits" "$extless_hits" | grep -v '^$' | sort -u)
            ;;
    esac
    cls=$(printf '%s\n' "$hits" | classify_hits "$path")
    printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$path" "$cls" >> "$CLASS"
done < "$ENTRIES"

if [ "$GIT_GREP_FAILS" -gt 0 ]; then
    echo "dead-parts: WARNING: $GIT_GREP_FAILS git-grep call(s) failed (rc>1, not a plain no-match) during the reference search - affected entries may show a false DEAD/DOC-ONLY verdict" >&2
fi

# --- report ------------------------------------------------------------------
echo "--- entry-point classification (since=$SINCE until=${UNTIL:-now} repo-root=$REPO_ROOT)"
for k in script command skill agent; do
    line="kind=$k"
    for c in USED WIRED TEST-ONLY DOC-ONLY DEAD; do
        n=$(awk -F'\t' -v k="$k" -v c="$c" '$1==k && $4==c' "$CLASS" | wc -l | tr -d ' ')
        line="$line $c=$n"
    done
    echo "$line"
done
total="totals:"
for c in USED WIRED TEST-ONLY DOC-ONLY DEAD; do
    n=$(awk -F'\t' -v c="$c" '$4==c' "$CLASS" | wc -l | tr -d ' ')
    total="$total $c=$n"
done
echo "$total"
sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

echo "--- all entries (kind name path class)"
sort "$CLASS"

echo "--- DEAD (no reference anywhere, no transcript call)"
awk -F'\t' '$4=="DEAD"{printf "%s\t%s\t%s\n",$1,$2,$3}' "$CLASS" | sort

echo "--- DOC-ONLY (referenced only from docs/*.md)"
awk -F'\t' '$4=="DOC-ONLY"{printf "%s\t%s\t%s\n",$1,$2,$3}' "$CLASS" | sort
