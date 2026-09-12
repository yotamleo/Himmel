#!/usr/bin/env bash
# scripts/guardrails/leak-classes.sh — commit-time + CI leak-class gate
# (HIMMEL-2561 / HIMMEL-2705 step 2).
#
# WHY: propagate-public.sh's scan_sensitive() only ran at propagation time,
# the moment a private branch was carved out for the public mirror. HIMMEL-2705
# moves development onto the public repo directly, so a leak has to be caught
# BEFORE it lands — at commit time (pre-commit, --staged) and again on the
# whole tree in public CI (--tree, a backstop for anything that slipped past
# pre-commit: a --no-verify commit, a merge, a stale clone). This script is
# the ONE implementation both callers share.
#
# Platform guard (gitbash-only): both callers (the pre-commit hook and the
# public CI job) invoke this as `bash scripts/guardrails/leak-classes.sh`,
# Git Bash on Windows / any POSIX bash 3.2+ — no .ps1 twin (project
# convention, matches the other shell guardrails).
#
# Five classes, each ANCHORED so a documentation-range value stays usable
# (mirrors the existing gitleaks convention of anchored regexes to avoid
# false positives on fixture/example data):
#   home-path            /home/<name>/, /Users/<name>/, C:\Users\<name>\,
#                         C:/Users/<name>/, /c/Users/<name>/ — flagged only
#                         when <name> is not a known placeholder (see
#                         ALLOW_HOME_NAMES below), is longer than one
#                         character, and does not start with '.' (a dotdir
#                         segment, e.g. /home/.himmel/, is never a username).
#                         <name> may contain an embedded space (a real
#                         Windows profile name, e.g. "Jane Smith") but never
#                         a leading/trailing one; the match still stops at
#                         the next '/' or '\', so a space only ever extends
#                         within the same path segment. The name-char class is
#                         negated ([^/\space]-style, not an ASCII whitelist —
#                         HIMMEL-2828), so a non-ASCII username like
#                         /home/élodie/ is matched too. # leak-allow: home-path doc example
#                         Only '/', '\' and whitespace end a segment/word.
#   mac-address           six hex pairs joined by a SINGLE consistent
#                         separator (all ':' or all '-' — never mixed). The
#                         mixed-separator form used to false-positive on
#                         timestamp ranges like "19:20:28-19:35:52"
#                         (scripts/ci/run-shell-tests.sh); requiring one
#                         consistent separator throughout fixes that at the
#                         anchor instead of allowlisting the file. RFC 7042
#                         doc MACs (00:00:5E:00:53:xx) and the all-zero /
#                         broadcast (ff:ff:ff:ff:ff:ff) forms are allowed.
#   private-lan-ip         RFC 1918 (10/8, 172.16/12, 192.168/16), word-
#                         anchored. RFC 5737 doc ranges (192.0.2.0/24,
#                         198.51.100.0/24, 203.0.113.0/24) and 127.0.0.0/8
#                         never match this pattern in the first place (none
#                         of them starts with 10., 172.16-31., or 192.168.),
#                         so no runtime exception is needed for them — noted
#                         here so a future reader doesn't go looking for one.
#   hostname               reads the LIVE, gitignored $HIMMEL_LEAK_DENYLIST
#                         (default ~/.claude/himmel-leak-denylist.txt) as a
#                         plain-text, one-token-per-line, exact-substring
#                         denylist — the same format seed-leak-denylist.sh
#                         writes. Station-local by construction: when the
#                         denylist file is absent this class is SKIPPED (not
#                         an error) and the script says so on stdout.
#   telegram-bot-token     [0-9]{8,10}:[A-Za-z0-9_-]{35}, copied verbatim
#                         from scan_sensitive() in propagate-public.sh (that
#                         file is being retired under HIMMEL-2705 — copying
#                         the regex text, not sourcing it).
#
# Same-line allow convention (mirrors gitleaks:allow): a trailing
#   # leak-allow: <class> <reason>          (shell/python/yaml/etc.)
#   // leak-allow: <class> <reason>          (js/ts)
#   <!-- leak-allow: <class> <reason> -->    (markdown/html)
# exempts THAT LINE for THAT CLASS only — the marker text itself is matched
# regardless of comment-prefix style, so any of the three works anywhere.
#
# ALLOW_HOME_NAMES (HIMMEL-2561 tree survey, 2026-09-08): the handover's base
# list (you, user, <user>, $USER, ${USER}, me, example, <you>, %USERNAME%,
# $env:USERNAME) -- adopter, operator, runner, vagrant, ubuntu and documents
# were confirmed unused against the tracked tree and removed from it --
# plus <me>, <name>, %s — placeholder/format-specifier spellings the same
# docs and printf-built fixtures use for the identical "a name goes here"
# meaning — extended with every placeholder name a repo-wide `/home/<name>/` /
# `/Users/<name>/` survey actually found in tracked test fixtures (confirmed
# NOT the real operator identity — a separate grep for the live station's
# actual $HOME basename came back clean):
#   ada, jarrod, alice, bob, diane, jose, somebody, claude, yotamleo
#                        - human-shaped placeholder names used across
#                         fixture/example data (marketplace/plugins test
#                         suites, propagate-public.sh's own leak-detection
#                         tests, a console-dispatch fixture). None resolves
#                         to this station's real identity.
#   leaktestuser, leaker, testop, testuser, test, osboxes, nulleak, name,
#   yourname, wineonlyuser, shouldnotleak, realop, quarantoken, priorleak,
#   posixuser, profileonlyuser, unixonlyuser, fakeuser, myvault, op, ops,
#   otheruser, fakeop
#                        - synthetic names purpose-built by existing test
#                         suites to exercise leak-detection code paths
#                         (several literally spell out what they test, e.g.
#                         "shouldnotleak", "leaktestuser") — allowlisting
#                         them does not weaken this scanner since none is a
#                         real identity, and reads as intended once you see
#                         the name.
#   runneradmin          - the generic account name GitHub Actions' own
#                         windows-latest runner uses, named in a Windows
#                         8.3-short-name-aliasing comment (fixture-repo.ts).
#   fake-sensitive-scriptpath-marker
#                        - a deliberately fake profile-capture test value
#                         (test-capture-operator-profile.sh) whose own name
#                         states it is not a real path segment.
#   ...                  - a literal ellipsis used in docs as an elided
#                         placeholder (docs/setup/new-machine.md,
#                         scripts/codex/reap-mcp-fleet.ps1).
#   parity, mismatched, plainhome, whoever, msysuser, fixture, jane, john,
#   runner, other, current-user
#                        - added post-HIMMEL-2835 (the first real --tree run
#                         against this tree's content, HIMMEL-2705's public
#                         CI job): fixture/placeholder names in
#                         ledger-path-parity.test.ts, test-resolve-user-home.sh,
#                         test-pipeline-cadence.sh, test-host-detectors.ps1,
#                         flow-run-ledger.test.ts, test-propagate-public.sh's
#                         RED-control fail-message strings, and doc-comment
#                         examples (environment-gotchas.md, test-leak-classes.sh,
#                         install-engine.js, fixture-repo.ts's "RUNNER~1"
#                         Windows 8.3-short-name reference). None resolves to
#                         this station's real identity.
# A name exactly one character long, or starting with '.', is excluded
# structurally (see above) rather than enumerated — bash 3.2-safe, no
# associative arrays.
#
# Skips: binary files (grep -I), graphify-out/, and any path prefix listed in
# .leak-classes-ignore at the repo root (absent/empty by default — an escape
# hatch for paths a PARALLEL leg is mid-removal on, not the design). --staged
# reads that file's STAGED content (git index), not the working tree, so an
# unstaged local edit can never suppress a leak in the commit being made.
# --tree reads it off disk, matching what --tree itself scans.
set -euo pipefail

usage() {
    echo "usage: $0 --staged | --tree [PATH...]" >&2
    exit 2
}

MODE=""
TREE_PATHS=()
case "${1:-}" in
    --staged)
        shift
        [ "$#" -eq 0 ] || usage
        MODE=staged
        ;;
    --tree)
        shift
        MODE=tree
        TREE_PATHS=("$@")
        ;;
    *)
        usage
        ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "leak-classes: not inside a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

HITS=0
# Populated by each check_* detector below with EVERY non-allowlisted match on
# the line (not just the first — a line can carry more than one distinct
# secret of the same class), and by check_hostname_hits(). Declared here (not
# just inside those functions) so `${#MATCHES[@]}` / `${#HOSTNAME_HITS[@]}` in
# scan_line() never hits `set -u`'s "unbound variable" before a detector has
# run once (e.g. a RED-control mutant with that call site disabled).
MATCHES=()
HOSTNAME_HITS=()

# ---- home-path allowlist (see header for rationale) ----
# shellcheck disable=SC2016 # single-quoted on purpose: $user/${user}/$env:username
# are literal placeholder tokens this list matches against, not expansions.
ALLOW_HOME_NAMES=' you user <user> $user ${user} me <me> example <you> %username% $env:username %s ada jarrod alice bob diane jose somebody claude yotamleo leaktestuser leaker testop testuser test osboxes nulleak name <name> yourname wineonlyuser shouldnotleak realop quarantoken priorleak posixuser profileonlyuser unixonlyuser fakeuser myvault op ops otheruser fakeop runneradmin fake-sensitive-scriptpath-marker ... parity mismatched plainhome whoever msysuser fixture jane john runner other current-user '

home_name_allowed() {
    local name="$1"
    [ "${#name}" -le 1 ] && return 0
    case "$name" in .*) return 0 ;; esac
    local lower
    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    case "$ALLOW_HOME_NAMES" in
        *" $lower "*) return 0 ;;
    esac
    return 1
}

# ---- .leak-classes-ignore path prefixes ----
IGNORE_FILE="$REPO_ROOT/.leak-classes-ignore"
IGNORE_PATTERNS=()
if [ "$MODE" = staged ]; then
    # --staged must read the exemption list AS IT WILL BE COMMITTED, from the
    # git index, not the working tree. Cat'ing the on-disk file would let a
    # locally-edited-but-UNSTAGED exemption suppress a staged leak whose own
    # justification never actually enters history alongside it. `git show
    # :<path>` reads the index's blob for that path; it fails (no output) the
    # same way an absent file does when the path was never staged, which
    # matches the existing "absent/empty by default" contract.
    if ignore_staged="$(git show ':.leak-classes-ignore' 2>/dev/null)"; then
        while IFS= read -r pat || [ -n "$pat" ]; do
            pat="${pat%$'\r'}"
            case "$pat" in ""|"#"*) continue ;; esac
            IGNORE_PATTERNS+=("$pat")
        done <<< "$ignore_staged"
    fi
    # A pattern REMOVED from the staged ignore list (present at HEAD, gone
    # from the index) marks a file that just became scannable again. --staged
    # only walks `git diff --cached` hunks, so a file with no staged content
    # change of its own never appears there at all -- removing its exemption
    # alone would otherwise commit its full existing content unchecked
    # (HIMMEL-2561 round-11 finding, codex-1). PREV_IGNORE_PATTERNS is only
    # ever consulted to compute that removed set below; it plays no other
    # role in this run.
    PREV_IGNORE_PATTERNS=()
    if git rev-parse --verify -q HEAD > /dev/null; then
        if ignore_head="$(git show 'HEAD:.leak-classes-ignore' 2>/dev/null)"; then
            while IFS= read -r pat || [ -n "$pat" ]; do
                pat="${pat%$'\r'}"
                case "$pat" in ""|"#"*) continue ;; esac
                PREV_IGNORE_PATTERNS+=("$pat")
            done <<< "$ignore_head"
        fi
    fi
    REMOVED_IGNORE_PATTERNS=()
    if [ "${#PREV_IGNORE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${PREV_IGNORE_PATTERNS[@]}"; do
            still_present=0
            if [ "${#IGNORE_PATTERNS[@]}" -gt 0 ]; then
                for cur in "${IGNORE_PATTERNS[@]}"; do
                    [ "$pat" = "$cur" ] && { still_present=1; break; }
                done
            fi
            [ "$still_present" -eq 0 ] && REMOVED_IGNORE_PATTERNS+=("$pat")
        done
    fi
else
    # --tree scans the working-tree filesystem itself, so its exemption list
    # is read from the same place: the on-disk file.
    if [ -f "$IGNORE_FILE" ]; then
        if [ ! -r "$IGNORE_FILE" ]; then
            echo "leak-classes: $IGNORE_FILE exists but is not readable" >&2
            exit 2
        fi
        while IFS= read -r pat || [ -n "$pat" ]; do
            pat="${pat%$'\r'}"
            case "$pat" in ""|"#"*) continue ;; esac
            IGNORE_PATTERNS+=("$pat")
        done < "$IGNORE_FILE"
    fi
fi

skip_path() {
    local f="$1" pat
    case "$f" in graphify-out/*) return 0 ;; esac
    if [ "${#IGNORE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${IGNORE_PATTERNS[@]}"; do
            # A pattern ending in "/" is a directory prefix (matches anything
            # under it); anything else must match the whole path exactly, so
            # e.g. "docs/leak" as an entry can never also exempt a sibling
            # like "docs/leaked.md".
            case "$pat" in
                */) case "$f" in "$pat"*) return 0 ;; esac ;;
                *) [ "$f" = "$pat" ] && return 0 ;;
            esac
        done
    fi
    return 1
}

# Same prefix/exact matching rule as skip_path's IGNORE_PATTERNS loop, against
# an arbitrary pattern list (used for REMOVED_IGNORE_PATTERNS below).
path_matches_pattern_list() {
    local f="$1"; shift
    local pat
    for pat in "$@"; do
        case "$pat" in
            */) case "$f" in "$pat"*) return 0 ;; esac ;;
            *) [ "$f" = "$pat" ] && return 0 ;;
        esac
    done
    return 1
}

# ---- hostname denylist (station-local, gitignored) ----
DENYLIST_PATH="${HIMMEL_LEAK_DENYLIST:-$HOME/.claude/himmel-leak-denylist.txt}"
# Diagnostics below print a path, not $DENYLIST_PATH itself: the default
# lives under $HOME, and this script's own job is to redact home paths from
# output, so printing it raw would leak the operator's home directory in
# every captured scan log (CR round-13 codex-3 finding).
DENYLIST_DISPLAY_PATH="$DENYLIST_PATH"
case "$DENYLIST_DISPLAY_PATH" in
    "$HOME"/*) DENYLIST_DISPLAY_PATH="~${DENYLIST_DISPLAY_PATH#"$HOME"}" ;;
esac
DENYLIST_TOKENS=()
if [ -f "$DENYLIST_PATH" ]; then
    if [ ! -r "$DENYLIST_PATH" ]; then
        echo "leak-classes: $DENYLIST_DISPLAY_PATH exists but is not readable" >&2
        exit 2
    fi
    while IFS= read -r tok || [ -n "$tok" ]; do
        tok="${tok%$'\r'}"
        case "$tok" in ""|"#"*) continue ;; esac
        DENYLIST_TOKENS+=("$tok")
    done < "$DENYLIST_PATH"
else
    echo "leak-classes: hostname class skipped (no denylist at $DENYLIST_DISPLAY_PATH)"
fi

# ---- allow-comment convention ----
line_allows() {
    local content="$1" class="$2"
    # Boundary after $class (end-of-line or whitespace) so "leak-allow:
    # home-path" cannot also exempt an unrelated class whose name happens to
    # start with the same prefix (e.g. a typo'd "leak-allow: home-pathology"
    # must NOT silently suppress a home-path finding). $class is always one
    # of this script's own five fixed class-name literals, never user input.
    local re="leak-allow:[[:space:]]*${class}([[:space:]]|\$)"
    [[ "$content" =~ $re ]]
}

redact_spans() {
    local content="$1"; shift
    # \x1f (unit separator) joins the match list for awk's split() -- none of
    # the five leak classes ever produce it, unlike printable delimiters.
    local sep joined
    sep=$(printf '\x1f')
    joined=$(printf '%s\x1f' "$@")
    # Marks every character of $content covered by ANY match, over the
    # ORIGINAL content, then merges adjacent covered characters into one
    # redacted span -- NOT sequential substring replacement (redact one
    # match, then search the ALREADY-redacted string for the next), which
    # breaks on a PARTIAL overlap between two matches that neither fully
    # contains the other (e.g. hostname denylist tokens "abcdef" and
    # "defghi" on "abcdefghi": redacting "abcdef" first destroys "defghi" as
    # a literal substring, so the second pass never finds it and its "ghi"
    # tail prints unredacted — CR round-13 codex-2 finding). A short token
    # that IS a full substring of a longer one (e.g. "srv" inside
    # "srv-secret-prod") still works: its span sits entirely inside the
    # merged run. Literal substring search via awk index()/substr() — NOT
    # bash's ${content/$matched/...}, which treats $matched as a glob
    # pattern and silently no-ops when $matched contains backslashes, as
    # every Windows-style home-path or colon-separated MAC match does.
    # Values cross into awk via ENVIRON, not -v, since -v assignment applies
    # its own backslash-escape processing that would mangle those same
    # backslashes before the script even runs.
    LEAK_REDACT_C="$content" LEAK_REDACT_M="$joined" LEAK_REDACT_SEP="$sep" awk '
        BEGIN {
            c = ENVIRON["LEAK_REDACT_C"]
            n = split(ENVIRON["LEAK_REDACT_M"], arr, ENVIRON["LEAK_REDACT_SEP"])
            len = length(c)
            for (mi = 1; mi <= n; mi++) {
                m = arr[mi]
                if (m == "") continue
                mlen = length(m)
                pos = 1
                while (pos <= len) {
                    p = index(substr(c, pos), m)
                    if (p == 0) break
                    s = pos + p - 1
                    e = s + mlen - 1
                    for (k = s; k <= e; k++) covered[k] = 1
                    pos = s + 1
                }
            }
            out = ""
            k = 1
            while (k <= len) {
                if (covered[k]) {
                    s = k
                    while (covered[k]) k++
                    e = k - 1
                    spanlen = e - s + 1
                    # Same reveal-window cap as before: at or under 4 chars,
                    # keep one fewer than the span length so at least one
                    # character always stays hidden (CR round-8 codex-4).
                    keep = (spanlen > 4) ? 4 : spanlen - 1
                    if (keep < 0) keep = 0
                    out = out substr(c, s, keep) "…"
                } else {
                    out = out substr(c, k, 1)
                    k++
                }
            }
            print out
        }
    '
}

# ---- class detectors: each populates $MATCHES with every non-allowlisted
# match on the line and returns 0 iff that array is non-empty ----

check_home_path() {
    local content="$1" remaining="$1" whole name
    # shellcheck disable=SC2016 # single-quoted on purpose: this is a regex
    # literal for [[ =~ ]], not a string meant to expand.
    # Username segment allows an embedded space (not a leading/trailing one --
    # the negated `[^/\space]`-style name-char class anchors both ends) so a
    # real Windows profile path like "C:\Users\Jane Smith\Documents" is still caught. # leak-allow: home-path doc example
    # The two forms are two separate alternatives, not one greedy class: a
    # multi-word name (embedded space) may ONLY terminate at a real '/' or
    # '\' -- so it can never swallow trailing prose that isn't itself a path
    # segment (HIMMEL-2835: the earlier single shared terminator, which also
    # accepted end-of-line/non-name-char for the space-carrying form, let an
    # unterminated /home/... or C:\Users\... reference run to end-of-line and
    # capture every following word as part of the "name"). A single-word name
    # keeps the permissive terminator (end-of-line, '/', '\', or whitespace --
    # a space simply ends the word, it does not extend it; HIMMEL-2828 widened
    # the name-char class itself from an ASCII whitelist to this negated form
    # so a non-ASCII username, e.g. élodie, is part of the word too).
    # Both the leading "C:\Users\" and trailing separator also match a
    # doubled backslash, so a JSON/log-escaped path like
    # "C:\\Users\\Jane Smith\\Documents" is still caught (a literal double # leak-allow: home-path doc example
    # backslash in the file, not a single one). # leak-allow: home-path doc example
    # CR (public #581): the drive-letter/WSL prefix alternatives are
    # case-insensitive on the drive letter and "Users" segment, and cover
    # /mnt/<drive>/Users/ (WSL) alongside /<drive>/Users/ (Git Bash) --
    # real Git Bash and WSL logs use both, and the repo targets Windows.
    # A bare-root "/users/" (no drive prefix) is NOT a real home-dir form on
    # any OS this repo targets -- macOS is always capitalized "/Users/", and
    # lowercase "/users/" at the root is common in unrelated text (e.g. a
    # GitHub REST API path "/users/{user}/settings/..."), so it must stay
    # case-sensitive; only the drive-prefixed WSL/Git-Bash forms go
    # case-insensitive (public #581 CodeRabbit round 2, false-positive fix) --
    # every letter of "users" is folded, not just the first, so forms like
    # C:/USERS/... are also caught (HIMMEL-2850, /pr-check panel round 1).
    # CR (public #585, HIMMEL-2854 item 6): a file:// URI's extra slash
    # (file:///home/...) sits right where the leading-context alternative
    # would need to match "/" itself -- which the negated class always
    # excludes -- so neither alternative can ever match there. Two literal
    # "file://" alternatives (anchored at start-of-string, or after a
    # non-word char) let the scheme itself stand in for that boundary
    # without loosening the negated class for anything else (so a bare
    # "http://home/..." -- "home" as an ordinary hostname label, not a
    # /home/ path -- still does not match).
    # HIMMEL-2828 follow-up (console-flagged): the word-char class also
    # excludes a small set of trailing prose/doc-markup punctuation --
    # backtick, quote, comma, semicolon, colon, or a closing paren/bracket --
    # and the single-word terminator accepts that same set, so a quoted or
    # doc-formatted name (e.g. "/home/ada", `/home/ada`) is captured as
    # exactly "ada" instead of swallowing the punctuation (and, on a line
    # with more than one occurrence, instead of the name run spilling across
    # the punctuation into the next occurrence's own "/" as if it were a
    # multi-word terminator). Non-ASCII bytes stay admitted -- only this
    # fixed ASCII punctuation set is excluded.
    local re='(^file://|^|[^A-Za-z0-9_.$/\\-]file://|[^A-Za-z0-9_.$/\\-])(/home/|/Users/|/mnt/[A-Za-z]/[Uu][Ss][Ee][Rr][Ss]/|/[A-Za-z]/[Uu][Ss][Ee][Rr][Ss]/|[A-Za-z]:/[Uu][Ss][Ee][Rr][Ss]/|[A-Za-z]:\\\\[Uu][Ss][Ee][Rr][Ss]\\\\|[A-Za-z]:\\[Uu][Ss][Ee][Rr][Ss]\\)(([^]/\\[:space:]`"'\'',;:)]+( [^]/\\[:space:]`"'\'',;:)]+)*)([/\\]|\\\\)|([^]/\\[:space:]`"'\'',;:)]+)($|[]/\\[:space:]`"'\'',;:)]))'
    MATCHES=()
    # Loop past EVERY match, allowlisted or not, so a second (or third)
    # non-allowlisted home path later on the same line is still caught.
    while [[ "$remaining" =~ $re ]]; do
        whole="${BASH_REMATCH[0]}"
        if [ -n "${BASH_REMATCH[4]}" ]; then
            name="${BASH_REMATCH[4]}"
            term="${BASH_REMATCH[6]}"
        else
            name="${BASH_REMATCH[7]}"
            term="${BASH_REMATCH[8]}"
        fi
        if ! home_name_allowed "$name"; then
            MATCHES+=("${BASH_REMATCH[2]}${name}${term}")
        fi
        remaining="${remaining#*"$whole"}"
    done
    [ "${#MATCHES[@]}" -gt 0 ]
}

check_mac() {
    local content="$1" remaining whole m lower
    MATCHES=()
    # Loop past EVERY match (allowlisted doc-range/all-zero/broadcast forms
    # included) so a second, real MAC later on the same line is still caught.
    # Colon-separated forms are scanned to exhaustion before dash-separated,
    # matching the original priority.
    remaining="$content"
    while [[ "$remaining" =~ (^|[^0-9A-Fa-f:-])(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})($|[^0-9A-Fa-f:-]) ]]; do
        whole="${BASH_REMATCH[0]}"; m="${BASH_REMATCH[2]}"
        lower=$(printf '%s' "$m" | tr 'A-F' 'a-f')
        case "$lower" in
            00:00:5e:00:53:*|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) ;;
            *) MATCHES+=("$m") ;;
        esac
        remaining="${remaining#*"$whole"}"
    done
    remaining="$content"
    while [[ "$remaining" =~ (^|[^0-9A-Fa-f:-])(([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2})($|[^0-9A-Fa-f:-]) ]]; do
        whole="${BASH_REMATCH[0]}"; m="${BASH_REMATCH[2]}"
        lower=$(printf '%s' "$m" | tr 'A-F' 'a-f')
        case "$lower" in
            00-00-5e-00-53-*|00-00-00-00-00-00|ff-ff-ff-ff-ff-ff) ;;
            *) MATCHES+=("$m") ;;
        esac
        remaining="${remaining#*"$whole"}"
    done
    [ "${#MATCHES[@]}" -gt 0 ]
}

check_lan_ip() {
    local content="$1" remaining="$1" whole
    # A single alternation (not three independent `if`s) so the loop below
    # advances past whichever range matched and keeps scanning the rest of
    # the line for every other private-IP hit, in any range, in order.
    local re='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})($|[^0-9])'
    MATCHES=()
    while [[ "$remaining" =~ $re ]]; do
        whole="${BASH_REMATCH[0]}"
        MATCHES+=("${BASH_REMATCH[2]}")
        remaining="${remaining#*"$whole"}"
    done
    [ "${#MATCHES[@]}" -gt 0 ]
}

check_telegram() {
    local content="$1" remaining="$1" whole
    MATCHES=()
    while [[ "$remaining" =~ ([0-9]{8,10}:[A-Za-z0-9_-]{35}) ]]; do
        whole="${BASH_REMATCH[0]}"
        MATCHES+=("${BASH_REMATCH[1]}")
        remaining="${remaining#*"$whole"}"
    done
    [ "${#MATCHES[@]}" -gt 0 ]
}

check_hostname_hits() {
    local content="$1" tok
    HOSTNAME_HITS=()
    [ "${#DENYLIST_TOKENS[@]}" -gt 0 ] || return 0
    for tok in "${DENYLIST_TOKENS[@]}"; do
        case "$content" in
            *"$tok"*) HOSTNAME_HITS+=("$tok") ;;
        esac
    done
    return 0
}

# scan_line collects every class hit on the line first, then redacts ALL of
# them into one shared display string before printing any report line — a
# line with, say, both a home path and a MAC must not leak the MAC while
# reporting the home path (and vice versa).
scan_line() {
    local file="$1" lineno="$2" content="$3"
    local -a hit_classes=() hit_matches=()
    local m

    if check_home_path "$content" && ! line_allows "$content" home-path; then
        for m in "${MATCHES[@]}"; do hit_classes+=("home-path"); hit_matches+=("$m"); done
    fi
    if check_mac "$content" && ! line_allows "$content" mac-address; then
        for m in "${MATCHES[@]}"; do hit_classes+=("mac-address"); hit_matches+=("$m"); done
    fi
    if check_lan_ip "$content" && ! line_allows "$content" private-lan-ip; then
        for m in "${MATCHES[@]}"; do hit_classes+=("private-lan-ip"); hit_matches+=("$m"); done
    fi
    if check_telegram "$content" && ! line_allows "$content" telegram-bot-token; then
        for m in "${MATCHES[@]}"; do hit_classes+=("telegram-bot-token"); hit_matches+=("$m"); done
    fi
    check_hostname_hits "$content"
    if [ "${#HOSTNAME_HITS[@]}" -gt 0 ] && ! line_allows "$content" hostname; then
        local tok
        for tok in "${HOSTNAME_HITS[@]}"; do
            hit_classes+=("hostname"); hit_matches+=("$tok")
        done
    fi

    [ "${#hit_classes[@]}" -eq 0 ] && return 0

    local redacted i
    redacted="$(redact_spans "$content" "${hit_matches[@]}")"
    for i in "${!hit_classes[@]}"; do
        printf '%s %s:%s: %s\n' "${hit_classes[$i]}" "$file" "$lineno" "$redacted"
    done
    HITS=1
}

# unquote_diff_path <token> -- reverses the two things git's "+++ b/<path>"
# header can do to a path that a plain ${f#b/} strip does not undo (HIMMEL-2831
# #2): a bare disambiguating TAB appended after an otherwise-unquoted path
# that contains a space, and full C-style quoting ("b/name" -> a double-quoted,
# backslash-escaped string) for a path containing a ", \, or control
# character. core.quotePath=false (set on the git diff invocation below) only
# exempts bytes >0x80 from quoting -- ", \, and control characters are ALWAYS
# quoted regardless of that setting, so this reversal is still needed for
# those. Decodes every NAMED C-style escape git's quote_c_style() can emit
# (\\ \" \t \n \r \a \b \v \f); an octal \NNN escape for a control byte with
# no named form (e.g. NUL, ESC, DEL) is not decoded -- deferred, tracked on
# HIMMEL-2831 alongside item #1, since such raw bytes are not representable
# in a POSIX filename or are otherwise vanishingly unlikely (/pr-check panel
# round 2, codex-1).
unquote_diff_path() {
    local s="$1"
    # $'...' ANSI-C quoting is only expanded as a standalone word -- inside
    # a double-quoted `${var//pattern/replacement}` (the shape every
    # substitution below needs, since the assignment itself is
    # double-quoted) a literal $'\n' etc. on the REPLACEMENT side is taken
    # as five literal characters, not a real control byte (verified against
    # bash 5.3.15; /pr-check panel round 1 follow-up). Pre-computing each
    # control byte into its own unquoted assignment first, then referencing
    # it as a plain "$var" below, sidesteps that: a plain variable
    # expansion works the same regardless of the surrounding quote context.
    local tab=$'\t' nl=$'\n' cr=$'\r' bell=$'\a' bs=$'\b' vt=$'\v' ff=$'\f' esc=$'\x01'
    case "$s" in
        *"$tab") s="${s%"$tab"}" ;;
    esac
    case "$s" in
        \"*\")
            s="${s#\"}"
            s="${s%\"}"
            # Order matters: turn literal backslashes into a placeholder
            # first so the later \" / \t / \n / ... passes don't themselves
            # get re-escaped, then restore the placeholder as a bare
            # backslash.
            s="${s//\\\\/$esc}"
            s="${s//\\\"/\"}"
            s="${s//\\t/$tab}"
            s="${s//\\n/$nl}"
            s="${s//\\r/$cr}"
            s="${s//\\a/$bell}"
            s="${s//\\b/$bs}"
            s="${s//\\v/$vt}"
            s="${s//\\f/$ff}"
            s="${s//$esc/\\}"
            ;;
    esac
    # A trailing sentinel, stripped by the caller: `$(...)` command
    # substitution unconditionally strips ALL trailing newlines from its
    # output, so a decoded `\n`-escaped path (e.g. a name ending in a
    # literal newline byte) would otherwise lose it here and could
    # wrongly inherit a different file's exact-file ignore exemption
    # (/pr-check panel round 1, codex-1).
    printf '%s.' "$s"
}

# ---- --staged: parse `git diff --cached -U0`, scan ADDED lines only ----
run_staged() {
    local diff_line current_file="" skip_current=0 newline=0 in_hunk=0
    local diff_output
    # Captured (not a process substitution) so a failing `git diff` propagates
    # its own exit code instead of silently scanning nothing under `set -e`.
    # --no-color/--no-ext-diff/--no-textconv: the line parser below matches
    # exact literal prefixes ("diff --git ", "+++ ", "@@ ", "+"); a repo or
    # global config that forces colored diff output, an external diff driver,
    # or a textconv filter could otherwise transform a hunk header or added
    # line so it no longer matches those prefixes, silently dropping it from
    # scanning instead of raising an error. The three -c overrides pin git's
    # own added/removed/context line-indicator characters to their defaults
    # ("+"/"-"/" ") for this invocation only — diff.outputIndicatorNew et al.
    # can reconfigure those characters, which would break the same literal
    # "+"-prefix parsing the same way a color/textconv transform would.
    # --no-renames: with rename detection on, a file moved verbatim (or
    # near-identically) from an exempt directory into a scanned one produces
    # only "rename from"/"rename to" header lines and NO "@@"/"+" hunk at
    # all under -U0, so its content never gets scanned as "added" — a real
    # gap for a genuinely renamed secret. Forcing --no-renames makes git
    # emit the same rename as a plain delete+add pair, so the destination's
    # full content always appears as "+" lines this parser already handles.
    # --text: a `-diff` or `binary` attribute in a staged .gitattributes
    # makes git print "Binary files ... differ" instead of a hunk, with NO
    # "+" lines at all — a leak inside a file the STAGED CHANGE ITSELF marks
    # binary would pass this gate completely unscanned (CR round-14 codex-1
    # finding). --text forces a textual diff regardless of that attribute
    # (and of genuinely binary content, which then just scans as noisy text
    # instead of being silently skipped — --tree's separate `grep -Iq`
    # binary skip is unaffected, since that check reads the actual bytes on
    # disk rather than trusting an attribute).
    # core.quotePath=false: paired with unquote_diff_path() above -- this
    # stops git from octal-escaping non-ASCII path bytes, leaving the rarer
    # ", \, and control-character case (which git quotes regardless of this
    # setting) as the only one unquote_diff_path() still has to reverse.
    # diff.mnemonicPrefix=false / diff.noprefix=false: the "+++ " parsing
    # below strips a literal "b/" prefix to recover the real path. A
    # station with diff.mnemonicPrefix=true swaps that to "i/" (index) for
    # --cached; the parser's fallback then keeps "i/<realpath>" verbatim,
    # which can spuriously match an unrelated directory-style
    # .leak-classes-ignore entry (e.g. a repo directory literally named
    # "i/") and exempt every staged file (HIMMEL-2826). Pinning both off
    # forces the plain "b/" prefix this parser is written against,
    # regardless of the running station's git config.
    if ! diff_output="$(git -c core.quotePath=false -c diff.mnemonicPrefix=false -c diff.noprefix=false -c diff.outputIndicatorNew=+ -c diff.outputIndicatorOld=- -c diff.outputIndicatorContext=' ' diff --no-color --no-ext-diff --no-textconv --no-renames --cached --text -U0 --)"; then
        echo "leak-classes: git diff --cached failed" >&2
        exit 2
    fi
    [ -z "$diff_output" ] && return 0
    while IFS= read -r diff_line; do
        case "$diff_line" in
            "diff --git "*)
                in_hunk=0
                ;;
            "+++ "*)
                # Only a real file-header line before the first hunk of this
                # file (in_hunk=0); inside a hunk (in_hunk=1) a line starting
                # with "+++ " is added CONTENT whose text itself begins with
                # "++ " (diff's own "+" marker plus a literal "++ ") -- not a
                # header, and must still be scanned.
                if [ "$in_hunk" -eq 0 ]; then
                    local f
                    f="$(unquote_diff_path "${diff_line#+++ }")"
                    f="${f%.}"
                    case "$f" in
                        "b/"*) current_file="${f#b/}" ;;
                        "/dev/null") current_file="" ;;
                        *) current_file="$f" ;;
                    esac
                    if [ -n "$current_file" ] && skip_path "$current_file"; then
                        skip_current=1
                    else
                        skip_current=0
                    fi
                else
                    if [ "$skip_current" -eq 0 ] && [ -n "$current_file" ]; then
                        scan_line "$current_file" "$newline" "${diff_line#+}"
                    fi
                    newline=$((newline + 1))
                fi
                ;;
            "@@ "*)
                in_hunk=1
                if [[ "$diff_line" =~ \+([0-9]+) ]]; then
                    newline="${BASH_REMATCH[1]}"
                fi
                ;;
            "+"*)
                if [ "$skip_current" -eq 0 ] && [ -n "$current_file" ]; then
                    scan_line "$current_file" "$newline" "${diff_line#+}"
                fi
                newline=$((newline + 1))
                ;;
            " "*)
                # A context line: -U0 normally emits none, but
                # diff.interHunkContext can merge two nearby hunks into one
                # and fill the gap with context (pinned to a leading space
                # via diff.outputIndicatorContext above) even under -U0. It
                # occupies a line in the NEW file like an added line does,
                # so newline must still advance past it — just without
                # scanning it, since its content isn't new (CR round-13
                # codex-4 finding: the old catch-all silently dropped it,
                # skewing every later finding's reported line number in the
                # same merged hunk).
                newline=$((newline + 1))
                ;;
            *) ;;
        esac
    done <<< "$diff_output"
    scan_unignored_full
}

# A file whose .leak-classes-ignore exemption was just removed (see
# REMOVED_IGNORE_PATTERNS above) may carry NO staged content change of its
# own -- it never appears in `git diff --cached` at all, so the loop above
# would never look at it. Scan such a file's full STAGED blob (the index
# content, matching the "read the ignore list from the index" contract this
# whole mode already follows), not just its added lines, the one time it
# transitions from exempt to scanned.
scan_unignored_full() {
    [ "${#REMOVED_IGNORE_PATTERNS[@]}" -eq 0 ] && return 0
    local f content lineno line
    while IFS= read -r -d '' f; do
        case "$f" in graphify-out/*) continue ;; esac
        path_matches_pattern_list "$f" "${REMOVED_IGNORE_PATTERNS[@]}" || continue
        # A file can match a removed pattern (e.g. a dropped directory
        # exemption) while STILL being covered by a different, remaining
        # pattern (e.g. an exact-file exemption for that same file) --
        # skip_path() is the current, authoritative exemption check
        # (codex-1, round 12: without this a directory-to-exact-file
        # exemption swap made --staged reject files --tree still exempts).
        skip_path "$f" && continue
        content="$(git show ":$f" 2>/dev/null)" || continue
        lineno=1
        while IFS= read -r line || [ -n "$line" ]; do
            scan_line "$f" "$lineno" "$line"
            lineno=$((lineno + 1))
        done <<< "$content"
    done < <(git ls-files -z --cached --)
}

# ---- --tree: walk tracked text files, scan every line ----
run_tree() {
    local paths=("$@") f lineno content link_target
    # Run `git ls-files` once first, discarding its stdout, purely so a
    # failure propagates its own exit code -- the streaming pass below still
    # goes through process substitution (NUL-delimited output can't survive a
    # bash command-substitution variable) but by then we already know it will
    # succeed.
    if [ "${#paths[@]}" -gt 0 ]; then
        git ls-files -z -- "${paths[@]}" > /dev/null || { echo "leak-classes: git ls-files failed" >&2; exit 2; }
    else
        git ls-files -z > /dev/null || { echo "leak-classes: git ls-files failed" >&2; exit 2; }
    fi
    while IFS= read -r -d '' f; do
        skip_path "$f" && continue
        # A tracked symlink: git only ever commits its TARGET STRING, never
        # the content at that target, so scan that string as the one line
        # this entry contributes -- opening "$f" via shell redirection below
        # would transparently follow the link and scan whatever it points
        # at, which can be outside the repo entirely.
        if [ -L "$f" ]; then
            if ! link_target="$(readlink -- "$f")"; then
                echo "leak-classes: $f: cannot read symlink target -- failing closed" >&2
                exit 2
            fi
            scan_line "$f" 1 "$link_target"
            continue
        fi
        # -e / -r first, checked separately from the -I binary-file test just
        # below: a tracked path git ls-files just returned but that is
        # missing or unreadable on disk is a scan-integrity failure, not the
        # same intentional skip a genuine binary file gets — this is a leak
        # PREVENTION gate, so a file it cannot actually inspect must fail the
        # gate rather than let the run report success having silently
        # scanned less than the whole tree.
        if [ ! -e "$f" ] || [ ! -r "$f" ]; then
            echo "leak-classes: $f: tracked but missing or unreadable on disk -- cannot verify it, failing closed" >&2
            exit 2
        fi
        grep -Iq '' -- "$f" 2>/dev/null || continue
        lineno=0
        # shellcheck disable=SC2094 # $f is only read as a string value here (the
        # file it names), never opened for writing -- false positive.
        while IFS= read -r content || [ -n "$content" ]; do
            lineno=$((lineno + 1))
            scan_line "$f" "$lineno" "$content"
        done < "$f"
    done < <(if [ "${#paths[@]}" -gt 0 ]; then git ls-files -z -- "${paths[@]}"; else git ls-files -z; fi)
}

if [ "$MODE" = staged ]; then
    run_staged
else
    # ${arr[@]+"${arr[@]}"}, not a bare "${TREE_PATHS[@]}": bash 3.2 (macOS
    # default, and this script's own stated gitbash-only/3.2+ target) raises
    # "unbound variable" under set -u expanding an EMPTY array, and the
    # common `--tree` invocation (full-repo scan, no path args) leaves
    # TREE_PATHS empty. Fixed in bash 4.4+, but this repeats the idiom used
    # in scripts/guardrails/lint-fail-open.sh for the same reason.
    run_tree ${TREE_PATHS[@]+"${TREE_PATHS[@]}"}
fi

if [ "$HITS" -eq 1 ]; then
    exit 1
fi
exit 0
