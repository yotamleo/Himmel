#!/usr/bin/env bash
# Hermetic test suite for scripts/guardrails/leak-classes.sh (HIMMEL-2561 /
# HIMMEL-2705 step 2 / HIMMEL-2518 RED-control contract). Every case runs
# against a scratch git repo under mktemp — never this repo's own tree —
# so a scanner regression here can never be masked by real-tree noise, and
# a real-tree false positive elsewhere can never fail this suite.
#
# Covers: one positive-detection case per class, the same-line allow-comment
# convention, the absent-denylist skip line, the --staged/--tree split, the
# redaction format, and one RED control per class (HIMMEL-2518): a scratch
# mutant with that class's call site in scan_line() disabled, proving the
# real script's detection — not the fixture or the harness — is what makes
# the positive-detection case go red.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+,
# same as the script under test — no .ps1 twin (project convention).
# shellcheck disable=SC2015  # A && B && pass || fail is intentional ternary-like
# shorthand throughout this file (pass()/fail() always return 0), as in
# scripts/test-context-fill.sh.
# shellcheck disable=SC2016  # single-quoted bash -c bodies below intentionally
# defer "$1"/"$class" expansion into the mutant's own subshell/positional args.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/guardrails/leak-classes.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

. "$REPO_ROOT/scripts/lib/red-control.sh"

failures=0
skips=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
skip() { printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }
# T9j/T9k-T9m build filenames containing ", newline, TAB, CR -- all rejected
# by NTFS. Skip those fixture blocks LOUDLY under Windows Git-Bash (MINGW/
# MSYS/CYGWIN) rather than let mkdir/git add fail silently into a false
# green (HIMMEL-2864 finding 2).
is_windows_ntfs() { case "$(uname -s 2>/dev/null || echo x)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }

if ! WS="$(mktemp -d "${TMPDIR:-/tmp}/leak-classes-test.XXXXXX")"; then
    echo "test-leak-classes: mktemp -d failed" >&2
    exit 2
fi
# Consumed by the sourced red-control.sh below (shellcheck cannot follow
# the runtime-computed source path to see the read).
# shellcheck disable=SC2034
RED_CONTROL_TMPDIR="$WS"
trap 'rm -rf "$WS"' EXIT

# new_repo -- an empty, isolated git repo under $WS. Each independent
# assertion gets its own so --tree (whole-tree) and --staged (whole-index)
# scans never see another case's fixture.
new_repo() {
    local d
    if ! d="$(mktemp -d "$WS/repo.XXXXXX")"; then
        echo "test-leak-classes: mktemp -d under \$WS failed" >&2
        exit 2
    fi
    git -C "$d" init -q
    printf '%s\n' "$d"
}

# scan <repo> <mode-args...> -- runs the real script, returns via globals.
# HIMMEL_LEAK_DENYLIST is pinned to a path that never exists so this suite's
# hostname-agnostic assertions stay hermetic regardless of whether the
# station running it happens to have a live denylist file at
# ~/.claude/himmel-leak-denylist.txt -- callers that specifically exercise the
# denylist build their own scan command with HIMMEL_LEAK_DENYLIST="$dl" set
# instead of using this helper.
SCAN_OUT="" SCAN_RC=0
scan() {
    local repo="$1"; shift
    SCAN_OUT="$(cd "$repo" && HIMMEL_LEAK_DENYLIST="$WS/no-such-denylist.txt" bash "$SCRIPT" "$@" 2>&1)"
    SCAN_RC=$?
}

# strip_hostname_skip <text> -- scan()'s always-absent HIMMEL_LEAK_DENYLIST
# means every call prints leak-classes.sh's own "hostname class skipped"
# diagnostic (T8 covers that line itself); "no genuine hit" assertions below
# test for that, not literal output emptiness.
strip_hostname_skip() {
    grep -v '^leak-classes: hostname class skipped' <<< "$1"
}

# mutate_call_site <anchor> <replacement> <outfile> -- builds a scratch copy
# of leak-classes.sh with exactly one literal substring replaced (the
# scan_line() call site for one class), asserting the anchor matched exactly
# once so a later edit to leak-classes.sh can't leave a stale anchor and a
# byte-identical, vacuously-passing "mutant" (same discipline test-propagate-
# public.sh's RED-D/RED-E controls use).
mutate_call_site() {
    local anchor="$1" replacement="$2" outfile="$3" before after
    before=$(grep -cF "$anchor" "$SCRIPT")
    MUT_O="$anchor" MUT_N="$replacement" awk '
        { line = $0
          p = index(line, ENVIRON["MUT_O"])
          if (p > 0) line = substr(line,1,p-1) ENVIRON["MUT_N"] substr(line, p+length(ENVIRON["MUT_O"]))
          print line }
    ' "$SCRIPT" > "$outfile"
    after=$(grep -cF "$anchor" "$outfile" || true)
    if [ "$before" != "1" ] || [ "$after" != "0" ]; then
        fail "mutation anchor '$anchor' did not match exactly once (before=$before after=$after) -- a stale anchor would leave the mutant unmutated and its RED control would pass vacuously"
        return 1
    fi
    if cmp -s "$SCRIPT" "$outfile"; then
        fail "mutant for '$anchor' is byte-identical to the original -- broken control"
        return 1
    fi
    return 0
}

echo "== positive detection, one per class =="

# T1: home-path
r=$(new_repo)
printf 'See /home/alexphantom/data for details.\n' > "$r/home.txt"  # leak-allow: home-path test fixture
git -C "$r" add home.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "home.txt:1"; then
    pass "T1 home-path: /home/alexphantom/ flagged"  # leak-allow: home-path test fixture
else
    fail "T1 home-path (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T2: mac-address
r=$(new_repo)
printf 'Device MAC 3a:9f:2c:1e:88:04 registered.\n' > "$r/mac.txt"  # leak-allow: mac-address test fixture
git -C "$r" add mac.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "mac-address" && grepq "$SCAN_OUT" -F "mac.txt:1"; then
    pass "T2 mac-address: 3a:9f:2c:1e:88:04 flagged"  # leak-allow: mac-address test fixture
else
    fail "T2 mac-address (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T2b: mac-address doc/broadcast exceptions stay unflagged (RFC 7042 +
# all-zero + broadcast forms are explicitly allowed by check_mac).
r=$(new_repo)
printf 'doc mac 00:00:5e:00:53:01, broadcast ff:ff:ff:ff:ff:ff, zero 00:00:00:00:00:00\n' > "$r/mac-doc.txt"
git -C "$r" add mac-doc.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T2b mac-address doc/broadcast/zero exceptions stay unflagged"
else
    fail "T2b mac-address doc exceptions (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T3: private-lan-ip
r=$(new_repo)
printf 'Server at 10.55.23.7 is down.\n' > "$r/lan.txt"  # leak-allow: private-lan-ip test fixture
git -C "$r" add lan.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "private-lan-ip" && grepq "$SCAN_OUT" -F "lan.txt:1"; then
    pass "T3 private-lan-ip: 10.55.23.7 flagged"  # leak-allow: private-lan-ip test fixture
else
    fail "T3 private-lan-ip (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T4: telegram-bot-token
r=$(new_repo)
printf 'token=123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi end\n' > "$r/tg.txt"  # leak-allow: telegram-bot-token test fixture, gitleaks:allow
git -C "$r" add tg.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "telegram-bot-token" && grepq "$SCAN_OUT" -F "tg.txt:1"; then
    pass "T4 telegram-bot-token flagged"
else
    fail "T4 telegram-bot-token (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T5: hostname (station-local denylist)
r=$(new_repo)
dl="$WS/denylist-t5.txt"
printf 'leaktest-host-xyz123\n' > "$dl"
printf 'connecting to leaktest-host-xyz123 now\n' > "$r/host.txt"
git -C "$r" add host.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "hostname" && grepq "$SCAN_OUT" -F "host.txt:1"; then
    pass "T5 hostname: denylisted token flagged"
else
    fail "T5 hostname (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1b: home-path, Windows profile name with an embedded space -- the
# username segment must still match up to the next '/' or '\' rather than
# stopping at the first space (HIMMEL-2561 round-4 finding).
r=$(new_repo)
printf 'path is C:\\Users\\Jane Smith\\Documents\\file.txt\n' > "$r/winspace.txt"  # leak-allow: home-path test fixture
git -C "$r" add winspace.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "winspace.txt:1"; then
    pass "T1b home-path: C:\\Users\\Jane Smith\\ (embedded space) flagged"  # leak-allow: home-path test fixture
else
    fail "T1b home-path embedded-space (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1c: home-path, JSON/log-escaped Windows profile path -- a literal DOUBLE
# backslash in the file (as a JSON string like "C:\\Users\\NAME
# HERE\\Documents" serializes it), not the single-backslash form T1b covers
# (CR round-5 codex-2 finding).
r=$(new_repo)
printf 'path is C:\\\\Users\\\\Jane Smith\\\\Documents\\\\file.txt\n' > "$r/winjson.txt"  # leak-allow: home-path test fixture
git -C "$r" add winjson.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "winjson.txt:1"; then
    pass "T1c home-path: JSON-escaped C:\\\\Users\\\\Jane Smith\\\\ (doubled backslash) flagged"  # leak-allow: home-path test fixture
else
    fail "T1c home-path doubled-backslash (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1d: home-path, tracked SYMLINK -- --tree must scan the link's committed
# TARGET STRING, never dereference it to read whatever the link resolves to
# on disk outside the repo (CR round-5 codex-3 finding).
r=$(new_repo)
if ! MSYS=winsymlinks:nativestrict ln -s "/home/alexphantom/outside-repo-secret" "$r/link-to-home" 2>/dev/null || [ ! -L "$r/link-to-home" ]; then  # leak-allow: home-path test fixture
    echo "  SKIP T1d: this host cannot create symlinks"
else
git -C "$r" add link-to-home
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "link-to-home:1"; then
    pass "T1d home-path: tracked symlink's target string flagged without dereferencing it"  # leak-allow: home-path test fixture
else
    fail "T1d home-path symlink (rc=$SCAN_RC) out=$SCAN_OUT"
fi
fi

# T1e (HIMMEL-2825): ALLOW_HOME_NAMES no longer globally exempts real-looking
# human names (alice, bob, diane, jose, claude, jane, john) -- a real
# adopter's own username commonly collides with one of these, which used to
# make their genuine home-path leak a false negative. The fixture files that
# used to rely on the global exemption now carry their own same-line
# `# leak-allow: home-path <reason>` marker instead. Confirm the removal
# actually took effect: an unmarked use of a formerly-allowlisted name is
# flagged like any other real name.
r=$(new_repo)
printf 'HOME=/home/bob\n' > "$r/removed-allowlist.txt"  # leak-allow: home-path test fixture
git -C "$r" add removed-allowlist.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "removed-allowlist.txt:1"; then
    pass "T1e home-path: formerly-allowlisted human name (bob) is now flagged unless marked"
else
    fail "T1e home-path removed-allowlist-name control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1e2: ...and the same formerly-allowlisted name stays clean when its own
# fixture line carries the leak-allow marker -- proving the per-line
# convention is a working replacement, not just a removal.
r=$(new_repo)
printf 'HOME=/home/bob  # leak-allow: home-path test fixture\n' > "$r/marked.txt"
git -C "$r" add marked.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1e2 home-path: same formerly-allowlisted name stays clean with its own leak-allow marker"
else
    fail "T1e2 home-path marked-fixture control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1f: same drift as T1e, for the two placeholders a repo-wide --tree run
# turned up as real tracked-fixture false positives beyond ada --
# scripts/telegram/fixture-repo.ts's runneradmin comment and
# scripts/install/test-capture-operator-profile.sh's marker value.
r=$(new_repo)
printf 'C:\\Users\\runneradmin\\ and C:\\Users\\FAKE-SENSITIVE-SCRIPTPATH-MARKER\\\n' > "$r/allowlisted2.txt"  # leak-allow: home-path test fixture
git -C "$r" add allowlisted2.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && ! grepq "$SCAN_OUT" -F "home-path"; then
    pass "T1f home-path: documented placeholder names (runneradmin, fake-sensitive-scriptpath-marker) stay allowlisted"
else
    fail "T1f home-path allowlisted placeholders (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1g: home-path with no trailing separator at all -- the match must still be
# caught at end-of-string or a non-name character, not just '/' or '\'
# (CodeRabbit finding: separator-less occurrences like a HOME= assignment or
# a bare `cd` target were previously missed because the regex required a
# trailing separator).
r=$(new_repo)
printf 'HOME=/home/realname\n' > "$r/noslash.txt"  # leak-allow: home-path test fixture
git -C "$r" add noslash.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "noslash.txt:1"; then
    pass "T1g home-path: separator-less HOME=/home/realname flagged"  # leak-allow: home-path test fixture
else
    fail "T1g home-path no-trailing-separator (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1h: home-path, a single-word name followed by unrelated trailing prose on
# the same line, no path separator ever closing the match before EOL (HIMMEL-
# 2835: check_home_path()'s name-capture used to allow an embedded space with
# the SAME end-of-line terminator a single-word name used, so it greedily
# swallowed every following word into "the name" -- e.g. a real --tree run
# against this tree's own content reported bogus multi-word "names" like
# 'current-user path should be flagged'). A multi-word name may now only
# terminate at a real '/' or '\'; the flagged name here must be exactly the
# first word, not the whole tail.
r=$(new_repo)
printf 'HOME=/home/notlisted foo /tmp/y other stuff\n' > "$r/swallow.txt"  # leak-allow: home-path test fixture
git -C "$r" add swallow.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" \
   && grepq "$SCAN_OUT" -F "swallow.txt:1" \
   && ! grepq "$SCAN_OUT" -F "notlisted foo"; then
    pass "T1h home-path: /home/notlisted flags exactly 'notlisted', not the trailing prose on the line"  # leak-allow: home-path test fixture
else
    fail "T1h home-path greedy-swallow regression (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1i: same shape as T1h but the single word IS an allowlisted placeholder --
# must stay clean, proving the fix didn't just start flagging every
# single-word home-path unconditionally.
r=$(new_repo)
printf 'HOME=/home/testuser foo bar baz\n' > "$r/swallow-allowed.txt"  # leak-allow: home-path test fixture
git -C "$r" add swallow-allowed.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && ! grepq "$SCAN_OUT" -F "home-path"; then
    pass "T1i home-path: allowlisted /home/testuser followed by prose stays clean"
else
    fail "T1i home-path allowlisted-with-trailing-prose (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1j/T1j2: home-path, WSL /mnt/<drive>/Users/ form and case-insensitive
# drive-letter + "Users" segment -- CodeRabbit finding on public #581: the
# prefix alternation was case-sensitive and had no /mnt/ form, so real WSL
# and lowercase Git Bash logs (e.g. /mnt/c/Users/<name>, /c/users/<name>)
# passed the gate unflagged. Split into two INDEPENDENT fixtures/assertions
# (CodeRabbit round-2: a single fixture combining both forms would let either
# alternative silently fail to match while the other still flags the file,
# masking a regression in either one).
r=$(new_repo)
printf 'see /mnt/c/Users/realname/project\n' > "$r/wsl.txt"  # leak-allow: home-path test fixture
git -C "$r" add wsl.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" \
   && grepq "$SCAN_OUT" -F "wsl.txt:1"; then
    pass "T1j home-path: /mnt/c/Users/ (WSL) flagged"  # leak-allow: home-path test fixture
else
    fail "T1j home-path WSL form (rc=$SCAN_RC) out=$SCAN_OUT"
fi

r=$(new_repo)
printf 'see /c/users/realname2/other\n' > "$r/gitbash.txt"  # leak-allow: home-path test fixture
git -C "$r" add gitbash.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" \
   && grepq "$SCAN_OUT" -F "gitbash.txt:1"; then
    pass "T1j2 home-path: /c/users/ (lowercase Git Bash) flagged"  # leak-allow: home-path test fixture
else
    fail "T1j2 home-path lowercase Git Bash form (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1k: a bare-root "/users/..." with no drive prefix is NOT a home-dir leak
# -- it's how GitHub/REST API paths are documented in comments (e.g.
# "/users/{user}/settings/billing/actions"). Public #581 round-2 regression:
# T1j's case-insensitivity fix over-widened to match this too. Only the
# drive-prefixed WSL/Git-Bash forms (T1j) should go case-insensitive.
r=$(new_repo)
printf '// the GitHub billing API (/users/{user}/settings/billing/actions)\n' > "$r/api.txt"  # leak-allow: home-path test fixture
git -C "$r" add api.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ]; then
    pass "T1k home-path: bare-root /users/{user}/... API path NOT flagged"
else
    fail "T1k home-path: bare-root /users/ false-positived (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1l: a drive-prefixed form must fold EVERY letter of "users", not just the
# first -- /pr-check critic panel round 1 (HIMMEL-2850): the prior
# [Uu]sers fix only case-folded the leading letter, so a fully-uppercase
# Windows path like C:/USERS/realname/project still evaded detection.  # leak-allow: home-path doc example
r=$(new_repo)
printf 'see C:/USERS/realname3/project\n' > "$r/allcaps.txt"  # leak-allow: home-path test fixture
git -C "$r" add allcaps.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" \
   && grepq "$SCAN_OUT" -F "allcaps.txt:1"; then
    pass "T1l home-path: C:/USERS/ (all-caps drive-prefixed) flagged"  # leak-allow: home-path test fixture
else
    fail "T1l home-path all-caps drive-prefixed form (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1m: a file:// URI's extra slash (file:///home/...) sits right where the
# leading-context alternative needs to match "/" itself -- which the negated
# class always excludes -- so the home-path detector used to miss it entirely
# (CodeRabbit public #585 thread, HIMMEL-2854 item 6).
r=$(new_repo)
printf 'see file:///home/alexphantom/x for details\n' > "$r/fileuri.txt"  # leak-allow: home-path test fixture
git -C "$r" add fileuri.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "fileuri.txt:1"; then
    pass "T1m home-path: file:///home/... URI flagged"
else
    fail "T1m home-path file:// URI (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1n: control for T1m -- "home" here is an ordinary hostname label (no
# file:// scheme), not a /home/ path; the file://-aware widening above must
# not start matching this too (that is why simply dropping "/" from the
# leading-context negated class would have been the wrong fix).
r=$(new_repo)
printf 'see http://home/alexphantom/x for details\n' > "$r/httphome.txt"  # leak-allow: home-path test fixture
git -C "$r" add httphome.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1n home-path: http://home/... control stays clean (not a file:// URI)"
else
    fail "T1n home-path http control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1o: home-path, non-ASCII username (HIMMEL-2828) -- the username segment
# character class used to be ASCII-only, so a real username that STARTS with
# an accented character (e.g. "élodie") never matched at all: the name-chars
# `+` quantifier requires at least one ASCII whitelist char right after the
# prefix, and the very first character here isn't one. Forced to the C
# locale: under this station's own en_US.UTF-8 default, glibc's
# collation-based bracket-range matching lets [A-Za-z] incidentally match
# some accented letters anyway, which would mask the bug (and any fix) here.
r=$(new_repo)
printf 'See /home/\xc3\xa9lodie/Documents/notes.txt for details.\n' > "$r/nonascii.txt"  # leak-allow: home-path test fixture
git -C "$r" add nonascii.txt
LC_ALL=C LANG=C scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "nonascii.txt:1"; then
    pass "T1o home-path: non-ASCII username /home/élodie/ flagged"  # leak-allow: home-path test fixture
else
    fail "T1o home-path non-ASCII username (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1r (HIMMEL-2828 follow-up, console-flagged): the same widened, non-ASCII-
# admitting single-word terminator that fixed T1o also swallows trailing
# prose/doc-markup punctuation into the captured name -- a quote, comma, or
# closing paren right after an allowlisted placeholder used to stop the old
# ASCII-whitelist match before it, so the exact ALLOW_HOME_NAMES comparison
# still saw the bare name. Confirm an allowlisted name stays allowlisted
# when immediately followed by each of those shapes.
r=$(new_repo)
printf '"/home/ada", (/home/ada) and `/home/ada`\n' > "$r/quoted-allowed.txt"  # leak-allow: home-path test fixture
git -C "$r" add quoted-allowed.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1r home-path: allowlisted name quoted/comma'd/parenthesized stays allowlisted"
else
    fail "T1r home-path punctuation-adjacent allowlisted name (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1s: RED-preserving control for T1r -- the same punctuation shapes around a
# NON-allowlisted name must still be flagged, proving the stripped
# comparison in T1r doesn't accidentally allowlist everything.
r=$(new_repo)
printf '"/home/mallory", (/home/mallory) and `/home/mallory`\n' > "$r/quoted-leak.txt"  # leak-allow: home-path test fixture
git -C "$r" add quoted-leak.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "quoted-leak.txt:1"; then
    pass "T1s home-path: non-allowlisted name still flagged despite quote/comma/paren punctuation"
else
    fail "T1s home-path punctuation-adjacent leak control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1p: home-path, Windows file:// URI with a drive letter (HIMMEL-2856) --
# file:///C:/users/<name>/... (lowercase "users") was missed: after the
# file:// boundary's extra leading slash, the path continues /C:/users/...
# and neither existing alternative matches it (the case-insensitive
# [A-Za-z]:/[Uu]sers/ alternative needs no leading slash before the drive
# letter, and the bare, case-SENSITIVE /Users/ alternative requires a
# capital U -- lowercase falls through both). A capitalized
# file:///C:/Users/... already happened to match via that bare /Users/
# alternative (preceded by the ":" boundary char) even pre-fix, which is why
# the RED case here uses lowercase to prove the real gap.
r=$(new_repo)
printf 'see file:///C:/users/alexphantom/x for details\n' > "$r/filedrive.txt"  # leak-allow: home-path test fixture
git -C "$r" add filedrive.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "filedrive.txt:1"; then
    pass "T1p home-path: file:///C:/users/... URI (lowercase) flagged"
else
    fail "T1p home-path file:// drive-letter URI (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1q: control for T1p -- a leading-slash drive-letter segment NOT followed
# by "Users" must stay clean, proving the new alternative is scoped to the
# literal "Users" segment and doesn't start matching any "/<drive>:/.../ "
# shape.
r=$(new_repo)
printf 'see /C:/other/path here\n' > "$r/notusers.txt"  # leak-allow: home-path test fixture
git -C "$r" add notusers.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1q home-path: /C:/other/... control (not a Users segment) stays clean"
else
    fail "T1q home-path non-Users drive-letter control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1t: HIMMEL-2828 regression fix (console-flagged, public #664) -- a line
# that itself DEFINES a home-path regex (in a guardrail script or its test)
# used to be misread as a real leaked path, because ERE syntax like
# "|[A-Za-z]:" or "[A-Za-z0-9._-]+" was just as word-char-admissible to the
# old name-char class as a genuine username. Six shapes drawn from the real
# false positives this regression produced on PR #664 (none of the six real
# files are touched by this fixture or by the fix -- these are synthetic
# stand-ins).
r=$(new_repo)
cat > "$r/regex-defs.txt" <<'FIXTURE_EOF'
leak_pattern='(/Users/|[A-Za-z]:\Users\|[A-Za-z]:/Users/|\Users\|/home/[^/]+/|(^|[/\])AppData([/\]|$))'
grep -qiE '\Users\|/Users/|AppData' "$OUT/report.md" 2>/dev/null \
ABS_PATTERN='([A-Za-z]:[/\]+Users[/\]|/Users/|/root/|/home/[A-Za-z0-9._-]+/)'
if LC_ALL=C grep -qE 'C:/Users/[A-Za-z0-9._-]+/' "$SCRIPT"; then
if grep -qE 'C:\Users\[A-Za-z0-9_]+|/c/Users/[A-Za-z0-9_]+|/home/[A-Za-z0-9_]+/Documents' "$f"; then
FIXTURE_EOF
git -C "$r" add regex-defs.txt  # leak-allow: home-path test fixture
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1t home-path: six regex-literal/prose shapes (own name-capture, char classes, alternation) stay clean"
else
    fail "T1t home-path regex-definition false-positive control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1t2: the sixth false-positive shape is different in kind -- a doc-style
# Windows 8.3 short-name placeholder immediately followed by a truncating
# ellipsis (e.g. "RUNNER~1\...", or the Unicode ellipsis "…"), which is
# suppressed by a separate check in the match loop (not the name-char class
# T1t exercises above).
r=$(new_repo)
printf '// (C:\\Users\\RUNNER~1\\..., because "runneradmin" is over 8 characters) while\n' > "$r/ellipsis.ts"  # leak-allow: home-path test fixture
git -C "$r" add ellipsis.ts
scan "$r" --tree
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T1t2 home-path: RUNNER~1\\... doc-placeholder ellipsis stays clean"
else
    fail "T1t2 home-path ellipsis-placeholder control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T1u: RED-preserving control for T1t/T1t2 -- a genuine, non-allowlisted home
# path sitting on its own line in the same file as the regex-literal shapes
# must still be flagged, proving the metachar exclusion doesn't blind the
# scanner to a real leak just because regex syntax appears elsewhere nearby.
r=$(new_repo)
printf 'leak_pattern=(/Users/|[A-Za-z]:\\Users\\|/home/[^/]+/)\n' > "$r/mixed.txt"
printf 'See /home/mallory/data for the real leak.\n' >> "$r/mixed.txt"  # leak-allow: home-path test fixture
git -C "$r" add mixed.txt
scan "$r" --tree
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "mixed.txt:2"; then
    pass "T1u home-path: a genuine home path still flagged alongside a regex-literal line"
else
    fail "T1u home-path RED-preserving control (rc=$SCAN_RC) out=$SCAN_OUT"
fi

echo "== redaction =="

# T6: the reported line carries only the first 4 chars of the match + an
# ellipsis, never the full leaked value (T1's output, re-checked here).
r=$(new_repo)
printf 'See /home/alexphantom/data for details.\n' > "$r/home.txt"  # leak-allow: home-path test fixture
git -C "$r" add home.txt
scan "$r" --tree
if grepq "$SCAN_OUT" -F "/hom…" && ! grepq "$SCAN_OUT" -F "/home/alexphantom/"; then  # leak-allow: home-path test fixture
    pass "T6 redaction: full value withheld, only /hom… printed"
else
    fail "T6 redaction (out=$SCAN_OUT)"
fi

# T6b: overlapping denylist tokens -- a shorter token ("srv") that is also a
# literal substring of a longer one ("srv-secret-prod") must not be redacted
# first, which would break the longer match apart and print its remaining
# sensitive suffix unredacted (CR round-6 codex-2 finding).
r=$(new_repo)
dl="$WS/denylist-t6b.txt"
printf 'srv\nsrv-secret-prod\n' > "$dl"
printf 'connect to srv-secret-prod now\n' > "$r/host.txt"
git -C "$r" add host.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 1 ] && ! grepq "$SCAN_OUT" -F "secret-prod"; then
    pass "T6b redaction: overlapping denylist tokens both stay redacted, no unredacted 'secret-prod' suffix"
else
    fail "T6b redaction overlapping tokens (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T6c: a standalone denylist token at or under 4 characters must not have its
# entire value fall inside redact_line's reveal window -- a bare "srv…" would
# be the full secret, not a redaction (CR round-8 codex-4 finding).
r=$(new_repo)
dl="$WS/denylist-t6c.txt"
printf 'srv\n' > "$dl"
printf 'connect to srv now\n' > "$r/host.txt"
git -C "$r" add host.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 1 ] && ! grepq "$SCAN_OUT" -F "srv…"; then
    pass "T6c redaction: short (<=4 char) denylist token is not fully revealed"
else
    fail "T6c redaction short token (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T6d: two denylist tokens that PARTIALLY overlap (neither is a substring of
# the other) -- "abcdefgh" and "defghijk" share "defgh" in the middle of
# "abcdefghijk". Sequential redact-then-search breaks here: redacting
# "abcdefgh" first destroys "defghijk" as a literal substring, so the second
# pass never finds it and its "ijk" tail prints unredacted (CR round-13
# codex-2 finding).
r=$(new_repo)
dl="$WS/denylist-t6d.txt"
printf 'abcdefgh\ndefghijk\n' > "$dl"
printf 'token abcdefghijk here\n' > "$r/host.txt"
git -C "$r" add host.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 1 ] && ! grepq "$SCAN_OUT" -F "ijk" && ! grepq "$SCAN_OUT" -F "abcdefghijk"; then
    pass "T6d redaction: partially overlapping denylist tokens leave no unredacted tail"
else
    fail "T6d redaction partial overlap (rc=$SCAN_RC) out=$SCAN_OUT"
fi

echo "== allow-comment convention (one per class) =="

# T7: home-path
r=$(new_repo)
printf 'See /home/alexphantom/data for details. # leak-allow: home-path test fixture\n' > "$r/f.txt"
git -C "$r" add f.txt
scan "$r" --tree
[ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ] && pass "T7a home-path allow-comment exempts the line" \
    || fail "T7a home-path allow-comment (rc=$SCAN_RC) out=$SCAN_OUT"

# T7b: mac-address
r=$(new_repo)
printf 'MAC 3a:9f:2c:1e:88:04 // leak-allow: mac-address test fixture\n' > "$r/f.txt"
git -C "$r" add f.txt
scan "$r" --tree
[ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ] && pass "T7b mac-address allow-comment exempts the line" \
    || fail "T7b mac-address allow-comment (rc=$SCAN_RC) out=$SCAN_OUT"

# T7c: private-lan-ip
r=$(new_repo)
printf 'IP 10.55.23.7 <!-- leak-allow: private-lan-ip test fixture -->\n' > "$r/f.txt"
git -C "$r" add f.txt
scan "$r" --tree
[ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ] && pass "T7c private-lan-ip allow-comment exempts the line" \
    || fail "T7c private-lan-ip allow-comment (rc=$SCAN_RC) out=$SCAN_OUT"

# T7d: telegram-bot-token
r=$(new_repo)
printf 'token=123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi # leak-allow: telegram-bot-token test fixture\n' > "$r/f.txt"  # gitleaks:allow
git -C "$r" add f.txt
scan "$r" --tree
[ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ] && pass "T7d telegram-bot-token allow-comment exempts the line" \
    || fail "T7d telegram-bot-token allow-comment (rc=$SCAN_RC) out=$SCAN_OUT"

# T7e: hostname
r=$(new_repo)
dl="$WS/denylist-t7e.txt"
printf 'leaktest-host-xyz123\n' > "$dl"
printf 'connecting to leaktest-host-xyz123 now # leak-allow: hostname test fixture\n' > "$r/f.txt"
git -C "$r" add f.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
[ "$SCAN_RC" -eq 0 ] && [ -z "$SCAN_OUT" ] && pass "T7e hostname allow-comment exempts the line" \
    || fail "T7e hostname allow-comment (rc=$SCAN_RC) out=$SCAN_OUT"

echo "== absent denylist -> hostname class self-skips, others still run =="

# T8: with no denylist file, hostname is SKIPPED (not an error) and says so;
# a repo with only a hostname-shaped line and nothing else leak-shaped stays
# rc=0, but a home-path leak alongside it still gets caught -- proving the
# skip is scoped to the hostname class alone.
r=$(new_repo)
printf 'connecting to leaktest-host-xyz123 now\n' > "$r/f.txt"
printf 'See /home/alexphantom/data too.\n' >> "$r/f.txt"  # leak-allow: home-path test fixture
git -C "$r" add f.txt
SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$WS/no-such-denylist.txt" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "hostname class skipped" && grepq "$SCAN_OUT" -F "no-such-denylist.txt" \
   && grepq "$SCAN_OUT" -F "home-path" && ! grepq "$SCAN_OUT" -F "leaktest-host-xyz123"; then
    pass "T8 absent denylist: hostname class skips with its own line, home-path still catches"
else
    fail "T8 absent denylist (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T8b: with the DEFAULT denylist path (HIMMEL_LEAK_DENYLIST unset/empty), the
# diagnostic must show "~", never the literal home directory -- this script's
# whole job is to redact home paths, so printing $HOME raw in its own
# diagnostic would leak the operator's home directory in every scan log (CR
# round-13 codex-3 finding).
r=$(new_repo)
printf 'nothing leak-shaped here\n' > "$r/f.txt"
git -C "$r" add f.txt
fake_home="$WS/fake-home-t8b"
mkdir -p "$fake_home"
SCAN_OUT="$(cd "$r" && HOME="$fake_home" HIMMEL_LEAK_DENYLIST='' bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
# shellcheck disable=SC2088 # literal leading "~" expected in the diagnostic text, not a shell tilde-expansion
if [ "$SCAN_RC" -eq 0 ] && grepq "$SCAN_OUT" -F "~/.claude/himmel-leak-denylist.txt" \
   && ! grepq "$SCAN_OUT" -F "$fake_home"; then
    pass "T8b default denylist path: diagnostic shows ~ not the literal home directory"
else
    fail "T8b default denylist path display (rc=$SCAN_RC) out=$SCAN_OUT"
fi

echo "== --staged vs --tree split =="

# T9: a leak line present in the WORKING TREE but never staged is caught by
# --tree (reads the file off disk) but not by --staged (reads only the
# staged diff).
r=$(new_repo)
printf 'nothing sensitive here\n' > "$r/f.txt"
git -C "$r" add f.txt
printf 'See /home/alexphantom/data too.\n' >> "$r/f.txt"   # appended AFTER staging, unstaged; leak-allow: home-path test fixture
scan "$r" --staged
staged_rc=$SCAN_RC; staged_out="$SCAN_OUT"
scan "$r" --tree
tree_rc=$SCAN_RC; tree_out="$SCAN_OUT"
if [ "$staged_rc" -eq 0 ] && [ -z "$(strip_hostname_skip "$staged_out")" ] && [ "$tree_rc" -eq 1 ] && grepq "$tree_out" -F "home-path"; then
    pass "T9 --staged/--tree split: unstaged addition caught by --tree only"
else
    fail "T9 --staged/--tree split (staged_rc=$staged_rc staged_out=$staged_out tree_rc=$tree_rc tree_out=$tree_out)"
fi

# T9b: the SAME line, once actually staged, is caught by --staged too.
r=$(new_repo)
printf 'See /home/alexphantom/data too.\n' > "$r/f.txt"  # leak-allow: home-path test fixture
git -C "$r" add f.txt
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9b --staged catches a genuinely staged addition"
else
    fail "T9b --staged staged-addition (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9c: --staged must read .leak-classes-ignore from the git INDEX, not the
# working tree -- an unstaged local edit to the ignore file must never
# suppress a leak in the commit actually being made (HIMMEL-2561 round-4
# finding). Stage the leak WITHOUT the ignore entry, then edit the ignore
# file on disk (unstaged) to exempt it: --staged must still catch the leak;
# --tree, which reads the ignore file off disk, must not.
r=$(new_repo)
printf 'See /home/alexphantom/data too.\n' > "$r/f.txt"  # leak-allow: home-path test fixture
printf '' > "$r/.leak-classes-ignore"
git -C "$r" add f.txt .leak-classes-ignore
printf 'f.txt\n' > "$r/.leak-classes-ignore"   # unstaged edit exempting f.txt
scan "$r" --staged
staged_rc=$SCAN_RC; staged_out="$SCAN_OUT"
scan "$r" --tree
tree_rc=$SCAN_RC; tree_out="$SCAN_OUT"
if [ "$staged_rc" -eq 1 ] && grepq "$staged_out" -F "home-path" \
   && [ "$tree_rc" -eq 0 ] && [ -z "$(strip_hostname_skip "$tree_out")" ]; then
    pass "T9c --staged reads .leak-classes-ignore from the index: an unstaged exemption can't suppress a staged leak"
else
    fail "T9c staged-ignore-from-index (staged_rc=$staged_rc staged_out=$staged_out tree_rc=$tree_rc tree_out=$tree_out)"
fi

# T9d: a file renamed (git mv, content unchanged) from an exempt directory
# into a scanned one must still be caught by --staged (round-9 CR finding,
# codex-2). With git's default rename detection, `git diff --cached -U0`
# emits only "rename from"/"rename to" header lines and NO "@@"/"+" hunk at
# all for a same-content rename, so the destination's leaking content would
# never appear as an added line under the previous invocation.
r=$(new_repo)
mkdir -p "$r/exempt" "$r/public"
printf 'exempt/\n' > "$r/.leak-classes-ignore"
printf 'See /home/alexphantom/data too.\n' > "$r/exempt/f.txt"  # leak-allow: home-path test fixture
git -C "$r" config user.email t@t
git -C "$r" config user.name t
git -C "$r" add .leak-classes-ignore exempt/f.txt
git -C "$r" commit -q -m init
git -C "$r" mv exempt/f.txt public/f.txt
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9d --staged catches a leak renamed from an exempt dir into a scanned one"
else
    fail "T9d --staged rename-into-scanned (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9e: removing a file's exemption from .leak-classes-ignore, WITHOUT staging
# any change to the file itself, must still be caught by --staged
# (round-11 CR finding, codex-1). `git diff --cached` never lists a file with
# no staged content change at all, so the diff-hunk loop alone would never
# look at it; only the full-blob rescan of newly-unignored files added for
# this finding catches it.
r=$(new_repo)
mkdir -p "$r/exempt"
printf 'exempt/\n' > "$r/.leak-classes-ignore"
printf 'See /home/alexphantom/data too.\n' > "$r/exempt/f.txt"  # leak-allow: home-path test fixture
git -C "$r" config user.email t@t
git -C "$r" config user.name t
git -C "$r" add .leak-classes-ignore exempt/f.txt
git -C "$r" commit -q -m init
printf '' > "$r/.leak-classes-ignore"   # exemption removed; exempt/f.txt itself untouched
git -C "$r" add .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9e --staged rescans a file whose ignore exemption was just removed"
else
    fail "T9e --staged unignore-rescan (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9f: a directory exemption is replaced by an exact-file exemption for ONE
# file in that directory. The other file in the directory loses its
# exemption and must still be caught; the file that keeps an (exact) new
# exemption must NOT be rescanned even though it also matches the removed
# directory pattern (round-12 CR finding, codex-1: the T9e rescan loop
# matched only the removed pattern and never re-checked the CURRENT ignore
# list, so a directory-to-exact-file exemption swap wrongly rejected the
# still-exempt file too).
r=$(new_repo)
mkdir -p "$r/exempt"
printf 'exempt/\n' > "$r/.leak-classes-ignore"
printf 'See /home/alexphantom/data too.\n' > "$r/exempt/keep.txt"  # leak-allow: home-path test fixture
printf 'See /home/alexphantom/data too.\n' > "$r/exempt/lose.txt"  # leak-allow: home-path test fixture
git -C "$r" config user.email t@t
git -C "$r" config user.name t
git -C "$r" add .leak-classes-ignore exempt/keep.txt exempt/lose.txt
git -C "$r" commit -q -m init
printf 'exempt/keep.txt\n' > "$r/.leak-classes-ignore"   # exempt/lose.txt just lost its exemption
git -C "$r" add .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "lose.txt" && ! grepq "$SCAN_OUT" -F "keep.txt"; then
    pass "T9f --staged rescans only the file that actually lost its exemption"
else
    fail "T9f --staged directory-to-exact-file exemption swap (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9g: diff.interHunkContext merges two nearby hunks into ONE, filling the
# gap between them with context (" "-prefixed) lines even under this
# script's fixed -U0. Those lines occupy a line number in the NEW file but
# carry no new content, so they must advance the parser's line counter
# without being scanned -- the old catch-all silently dropped them, skewing
# every later finding's reported line number in the same merged hunk (CR
# round-13 codex-4 finding).
r=$(new_repo)
git -C "$r" config user.email t@t
git -C "$r" config user.name t
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > "$r/f.txt"
git -C "$r" add f.txt
git -C "$r" commit -q -m init
git -C "$r" config diff.interHunkContext 10
printf 'a\nb\nNEWLINE1\nc\nd\ne\nf\nSee /home/alexphantom/data too.\ng\nh\n' > "$r/f.txt"  # leak-allow: home-path test fixture
git -C "$r" add f.txt
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "f.txt:8:"; then
    pass "T9g --staged: line number stays correct across a diff.interHunkContext-merged hunk"
else
    fail "T9g --staged interHunkContext line attribution (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9h: a staged file whose .gitattributes marks it `-diff`/binary must still
# be scanned -- git's own diff machinery would otherwise print "Binary files
# ... differ" with zero "+" lines for it under -U0, letting a leak in that
# file pass --staged (the pre-commit hook's ONLY mode) completely unscanned
# (CR round-14 codex-1 finding). --text on the diff invocation forces a
# textual diff regardless of the attribute.
r=$(new_repo)
printf '* -diff\n' > "$r/.gitattributes"
printf 'home path /home/alexphantom/binaryleak here\n' > "$r/bin.txt"  # leak-allow: home-path test fixture
git -C "$r" add .gitattributes bin.txt
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "bin.txt:1:"; then
    pass "T9h --staged: a leak in a .gitattributes -diff/binary file is still caught"
else
    fail "T9h --staged gitattributes -diff bypass (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9i: a filename containing a space gets a bare disambiguating TAB appended
# after git's own "+++ b/<path>" header, which run_staged()'s plain ${f#b/}
# strip used to take literally -- baking the tab into current_file. An
# EXACT-FILE .leak-classes-ignore exemption for that filename therefore
# stopped matching under --staged, so the exempted file was wrongly flagged
# (HIMMEL-2831 #2 repro, verbatim).
r=$(new_repo)
printf 'file with space.txt\n' > "$r/.leak-classes-ignore"
printf 'home path /home/alexphantom/leak here\n' > "$r/file with space.txt"  # leak-allow: home-path test fixture
git -C "$r" add 'file with space.txt' .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 0 ] && [ -z "$(strip_hostname_skip "$SCAN_OUT")" ]; then
    pass "T9i --staged: exact-file ignore exemption still matches a filename with an embedded space"
else
    fail "T9i --staged quoted-path space exemption (rc=$SCAN_RC) out=$SCAN_OUT"
fi

# T9j: a filename containing a literal double-quote gets fully C-quoted by
# git ("b/weird\"quote.txt"), which the same plain ${f#b/} strip does not
# match at all -- the finding used to cite the raw, still-escaped header text
# instead of the real filename. It must now cite the real, unescaped name.
if is_windows_ntfs; then
    skip "T9j (windows: NTFS filename)"
else
r=$(new_repo)
printf 'home path /home/alexphantom/leak here\n' > "$r/weird\"quote.txt"  # leak-allow: home-path test fixture
git -C "$r" add .
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F 'weird"quote.txt:1' \
   && ! grepq "$SCAN_OUT" -F '\"'; then
    pass "T9j --staged: a quote-containing filename is unquoted before being cited in a finding"
else
    fail "T9j --staged quoted-path finding attribution (rc=$SCAN_RC) out=$SCAN_OUT"
fi
fi

# T9k: a filename ending in a literal trailing newline byte must decode to
# its real, full name -- not collide with a DIFFERENT, shorter exact-file
# ignore entry that lacks that trailing newline. `$(...)` command
# substitution unconditionally strips ALL trailing newlines from its own
# captured output, so without unquote_diff_path()'s trailing sentinel (a `.`
# appended by printf, stripped by the caller) a decoded name's own real
# trailing newline byte would silently vanish right there and the file would
# wrongly inherit the shorter name's exemption (/pr-check panel round 1,
# codex-1).
if is_windows_ntfs; then
    skip "T9k (windows: NTFS filename)"
else
r=$(new_repo)
printf 'short.txt\n' > "$r/.leak-classes-ignore"
nlname=$'short.txt\n'
printf 'home path /home/alexphantom/leak here\n' > "$r/$nlname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$nlname" .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9k --staged: a decoded name's real trailing newline byte is not swallowed by \$(...) and collapsed into a shorter, unrelated exact-file ignore entry"
else
    fail "T9k --staged trailing-newline sentinel (rc=$SCAN_RC) out=$SCAN_OUT"
fi
fi

# T9l: a filename containing a literal (non-trailing) TAB byte gets fully
# C-quoted by git with a backslash-t escape ("b/weird\ttab.txt"); the escape
# must decode to a real TAB byte, not stay as the two literal characters
# `\` and `t` -- which would wrongly collide with an exact-file ignore entry
# written as that literal, undecoded text (self-discovered while verifying
# codex-1 above: ANSI-C `$'...'` quoting is only expanded as a standalone
# shell word, so inlining it directly on the replacement side of a
# double-quoted `${var//pattern/replacement}` silently fails to decode at
# all).
if is_windows_ntfs; then
    skip "T9l (windows: NTFS filename)"
else
r=$(new_repo)
printf '%s\n' 'weird\ttab.txt' > "$r/.leak-classes-ignore"
tabname=$'weird\ttab.txt'
printf 'home path /home/alexphantom/leak here\n' > "$r/$tabname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$tabname" .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9l --staged: a decoded name's embedded \\t escape becomes a real TAB byte, not a literal backslash-t collision with an unrelated exact-file ignore entry"
else
    fail "T9l --staged embedded-tab decode (rc=$SCAN_RC) out=$SCAN_OUT"
fi
fi

# T9m: a filename containing a literal carriage-return byte gets fully
# C-quoted by git with a backslash-r escape ("b/weird\rcr.txt"); the escape
# must decode to a real CR byte, not stay as the two literal characters
# `\` and `r` (/pr-check panel round 2, codex-1: unquote_diff_path decoded
# only \\ \" \t \n, leaving git's other named C escapes -- \r \a \b \v \f --
# undecoded and open to the same collision as T9l's \t case).
if is_windows_ntfs; then
    skip "T9m (windows: NTFS filename)"
else
r=$(new_repo)
printf '%s\n' 'weird\rcr.txt' > "$r/.leak-classes-ignore"
crname=$'weird\rcr.txt'
printf 'home path /home/alexphantom/leak here\n' > "$r/$crname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$crname" .leak-classes-ignore
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path"; then
    pass "T9m --staged: a decoded name's embedded \\r escape becomes a real CR byte, not a literal backslash-r collision with an unrelated exact-file ignore entry"
else
    fail "T9m --staged embedded-cr decode (rc=$SCAN_RC) out=$SCAN_OUT"
fi
fi

echo "== diff-prefix config independence (HIMMEL-2826) =="

# T11: run_staged()'s parser keys on the literal "+++ b/" prefix `git diff
# --cached` normally emits. A station with diff.mnemonicPrefix=true swaps
# that to "+++ i/" (index) for the new side; the parser's fallback branch
# then takes current_file verbatim AS "i/<realpath>" instead of stripping a
# recognised prefix. If the repo also carries a directory-style
# .leak-classes-ignore entry that happens to match that mnemonic letter
# (here "i/" -- a perfectly ordinary directory name, unrelated to git's
# scheme), EVERY staged file's corrupted "i/..." path now matches that
# exemption and the leak goes completely unreported, regardless of where it
# actually lives in the repo. Pinning diff.mnemonicPrefix=false (and
# diff.noprefix=false, its sibling) on the invocation removes the
# station-config dependency entirely.
r=$(new_repo)
mkdir -p "$r/i"
printf 'unrelated\n' > "$r/i/placeholder.txt"
printf 'i/\n' > "$r/.leak-classes-ignore"
printf 'See /home/alexphantom/secret.txt\n' > "$r/leak.txt"  # leak-allow: home-path test fixture
git -C "$r" config diff.mnemonicPrefix true
git -C "$r" add i/placeholder.txt .leak-classes-ignore leak.txt
scan "$r" --staged
if [ "$SCAN_RC" -eq 1 ] && grepq "$SCAN_OUT" -F "home-path" && grepq "$SCAN_OUT" -F "leak.txt:1"; then
    pass "T11 --staged: a diff.mnemonicPrefix=true station config can't corrupt the parsed file path into a spurious ignore-directory match"
else
    fail "T11 --staged diff.mnemonicPrefix independence (rc=$SCAN_RC) out=$SCAN_OUT"
fi

echo "== the real pre-commit hook fires (not just the script directly) =="

# T10: drives the ACTUAL `leak-classes` entry from this repo's own
# .pre-commit-config.yaml through a real `pre-commit run`, the same
# extract-the-real-entry pattern scripts/hooks/test-check-commit-msg-precommit.sh
# uses for conventional-commit-msg -- so the fixture's wiring IS the repo's
# wiring rather than a hand-copied restatement, and a later edit to the hook's
# id/entry/pass_filenames/always_run/stages in .pre-commit-config.yaml turns
# this red rather than silently testing a stale shape. Skips cleanly (exit 0)
# where pre-commit is not installed.
if ! command -v pre-commit >/dev/null 2>&1; then
    echo "  SKIP T10: pre-commit not installed on this host"
else
    CONFIG="$REPO_ROOT/.pre-commit-config.yaml"
    entry=$(awk '
        /^      - id: leak-classes$/ { grab = 1; print; next }
        grab && /^      - id: / { exit }
        grab { print }
    ' "$CONFIG")
    if [ -z "$entry" ]; then
        fail "T10 pre-commit: could not extract the leak-classes entry from $CONFIG"
    else
        pc_repo="$WS/pc-repo"
        mkdir -p "$pc_repo/scripts/guardrails"
        git -C "$pc_repo" init -q -b main
        git -C "$pc_repo" config user.email t@t
        git -C "$pc_repo" config user.name t
        git -C "$pc_repo" config commit.gpgsign false
        cp "$SCRIPT" "$pc_repo/scripts/guardrails/leak-classes.sh"
        {
            printf 'repos:\n'
            printf '  - repo: local\n'
            printf '    hooks:\n'
            printf '%s\n' "$entry"
        } > "$pc_repo/.pre-commit-config.yaml"

        # Neutralise the developer's global/system git config: a global
        # core.hooksPath makes `pre-commit install` refuse outright (same
        # trap test-check-commit-msg-precommit.sh works around). Empty
        # files, not /dev/null -- git must be able to stat them.
        : > "$WS/gitconfig-empty"
        pc_out=$(cd "$pc_repo" && GIT_CONFIG_GLOBAL="$WS/gitconfig-empty" GIT_CONFIG_SYSTEM="$WS/gitconfig-empty" pre-commit install 2>&1)
        pc_rc=$?
        if [ "$pc_rc" -ne 0 ] || [ ! -f "$pc_repo/.git/hooks/pre-commit" ]; then
            fail "T10 pre-commit: pre-commit install failed in the fixture (rc=$pc_rc out=$pc_out)"
        else
            # Case A: a leaking staged file -- the real hook must FAIL and its
            # own reported output must name the class.
            printf 'See /home/alexphantom/data for details.\n' > "$pc_repo/leak.txt"  # leak-allow: home-path test fixture
            git -C "$pc_repo" add leak.txt
            leak_out=$(cd "$pc_repo" && GIT_CONFIG_GLOBAL="$WS/gitconfig-empty" GIT_CONFIG_SYSTEM="$WS/gitconfig-empty" HIMMEL_LEAK_DENYLIST="$WS/no-such-denylist.txt" pre-commit run leak-classes --files leak.txt 2>&1)
            leak_rc=$?
            if [ "$leak_rc" -ne 0 ] && grepq "$leak_out" -F "home-path"; then
                pass "T10a real pre-commit hook: leak-classes FAILS through a genuine pre-commit run on a leaking file"
            else
                fail "T10a real pre-commit hook did not fail as expected (rc=$leak_rc out=$leak_out)"
            fi

            # Case B: reset to a clean staged file -- the real hook must PASS.
            git -C "$pc_repo" reset -q
            printf 'nothing sensitive here\n' > "$pc_repo/clean.txt"
            git -C "$pc_repo" add clean.txt
            clean_out=$(cd "$pc_repo" && GIT_CONFIG_GLOBAL="$WS/gitconfig-empty" GIT_CONFIG_SYSTEM="$WS/gitconfig-empty" HIMMEL_LEAK_DENYLIST="$WS/no-such-denylist.txt" pre-commit run leak-classes --files clean.txt 2>&1)
            clean_rc=$?
            if [ "$clean_rc" -eq 0 ]; then
                pass "T10b real pre-commit hook: leak-classes PASSES through a genuine pre-commit run on a clean file"
            else
                fail "T10b real pre-commit hook did not pass on a clean file (rc=$clean_rc out=$clean_out)"
            fi
        fi
    fi
fi

echo "== RED controls (HIMMEL-2518): one mutation per class, call site in scan_line() disabled =="

# run_class_red_control <label> <class> <anchor> <replacement> <fixture-file-setup>
# Builds the fixture repo, runs the REAL script (must hit=yes rc=1) as a
# sanity precondition, then runs a MUTANT with that class's scan_line() call
# site disabled and asserts the mutant misses (hit=no rc=0). The wrapper
# always echoes a non-empty "hit=..." line to stdout and exits with the
# scanner's own real exit code, so point (b) of the contract (non-empty
# output) holds even though the class miss itself is a total absence of the
# scanner's own report line.
run_class_red_control() {
    local label="$1" class="$2" anchor="$3" replacement="$4" repo="$5"
    local mutant="$WS/mutant-$class.sh"

    mutate_call_site "$anchor" "$replacement" "$mutant" || return

    # Precondition: the REAL script still hits on this fixture (else the
    # fixture, not the mutation, would be why the mutant misses).
    scan "$repo" --tree
    if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "$class"; then
        fail "$label RED-control precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
        return
    fi

    # Pin HIMMEL_LEAK_DENYLIST to a scratch, guaranteed-absent path (same
    # convention as scan()'s own hermetic default) rather than inheriting
    # whatever the calling shell has exported: a station denylist token that
    # happens to be a substring of this class's fixture text would otherwise
    # make check_hostname_hits() fire during the mutant run and flip its exit
    # code for a reason unrelated to the class under test (HIMMEL-2829).
    red_control_run --cwd "$repo" --env HIMMEL_LEAK_DENYLIST="$WS/no-such-denylist.txt" -- bash -c '
        out=$(bash "$1" --tree 2>&1); rc=$?
        case "$out" in *"'"$class"'"*) hit=yes ;; *) hit=no ;; esac
        echo "hit=$hit"
        exit "$rc"
    ' _ "$mutant"

    red_control_assert --label "$label" --expect-rc 0 \
        --observed "$RED_CONTROL_OUT" \
        --expect-wrong "hit=no" \
        --correct "hit=yes" \
        --note "with $class's call site in scan_line() disabled, the fixture that the real script flags goes completely unreported -- proving that call site, not the fixture or this suite's own grep, is what makes the positive-detection case above meaningful" \
        && pass "$label RED confirmed" \
        || fail "$label RED control did not confirm (see FAIL line above)"
}

# home-path
r=$(new_repo); printf 'See /home/alexphantom/data for details.\n' > "$r/f.txt"; git -C "$r" add f.txt  # leak-allow: home-path test fixture
run_class_red_control "RED-home-path" "home-path" \
    '    if check_home_path "$content" && ! line_allows "$content" home-path; then' \
    '    if false && check_home_path "$content" && ! line_allows "$content" home-path; then' "$r"

# mac-address
r=$(new_repo); printf 'Device MAC 3a:9f:2c:1e:88:04 registered.\n' > "$r/f.txt"; git -C "$r" add f.txt  # leak-allow: mac-address test fixture
run_class_red_control "RED-mac-address" "mac-address" \
    '    if check_mac "$content" && ! line_allows "$content" mac-address; then' \
    '    if false && check_mac "$content" && ! line_allows "$content" mac-address; then' "$r"

# private-lan-ip
r=$(new_repo); printf 'Server at 10.55.23.7 is down.\n' > "$r/f.txt"; git -C "$r" add f.txt  # leak-allow: private-lan-ip test fixture
run_class_red_control "RED-private-lan-ip" "private-lan-ip" \
    '    if check_lan_ip "$content" && ! line_allows "$content" private-lan-ip; then' \
    '    if false && check_lan_ip "$content" && ! line_allows "$content" private-lan-ip; then' "$r"

# telegram-bot-token
r=$(new_repo); printf 'token=123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi end\n' > "$r/f.txt"; git -C "$r" add f.txt  # leak-allow: telegram-bot-token test fixture, gitleaks:allow
run_class_red_control "RED-telegram-bot-token" "telegram-bot-token" \
    '    if check_telegram "$content" && ! line_allows "$content" telegram-bot-token; then' \
    '    if false && check_telegram "$content" && ! line_allows "$content" telegram-bot-token; then' "$r"

# hostname (needs the denylist env var threaded through the mutant's own
# subprocess, not just this suite's -- red_control_run's --env handles that).
r=$(new_repo)
dl="$WS/denylist-red-hostname.txt"
printf 'leaktest-host-xyz123\n' > "$dl"
printf 'connecting to leaktest-host-xyz123 now\n' > "$r/f.txt"
git -C "$r" add f.txt
mutant="$WS/mutant-hostname.sh"
if mutate_call_site '    check_hostname_hits "$content"' 'true # RED-control: check_hostname_hits disabled' "$mutant"; then
    SCAN_OUT="$(cd "$r" && HIMMEL_LEAK_DENYLIST="$dl" bash "$SCRIPT" --tree 2>&1)"; SCAN_RC=$?
    if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "hostname"; then
        fail "RED-hostname precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" --env HIMMEL_LEAK_DENYLIST="$dl" -- bash -c '
            out=$(bash "$1" --tree 2>&1); rc=$?
            case "$out" in *"hostname"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-hostname" --expect-rc 0 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=no" \
            --correct "hit=yes" \
            --note "with the check_hostname_hits call site in scan_line() disabled, the denylisted token goes completely unreported" \
            && pass "RED-hostname RED confirmed" \
            || fail "RED-hostname RED control did not confirm (see FAIL line above)"
    fi
fi

echo "== RED-control station-denylist independence (HIMMEL-2829) =="

# T12: run_class_red_control()'s red_control_run call (used by the four
# non-hostname classes above) passes no --env for HIMMEL_LEAK_DENYLIST, so it
# inherits whatever the calling shell has exported. A station whose real
# denylist happens to contain a token that is a literal substring of one of
# those fixtures' own wording (here: "registered", already present in the
# mac-address fixture "... registered.") makes check_hostname_hits() fire
# during the mutant run purely by coincidence, flipping the mutant's exit
# code away from the rc=0 a genuine miss produces -- so
# red_control_assert's --expect-rc 0 wrongly FAILS the control for a reason
# that has nothing to do with mac-address detection. Exported here as a
# scratch, throwaway denylist -- never this station's real one.
r=$(new_repo)
printf 'Device MAC 3a:9f:2c:1e:88:04 registered.\n' > "$r/f.txt"  # leak-allow: mac-address test fixture
git -C "$r" add f.txt
dl="$WS/t12-contaminating-denylist.txt"
printf 'registered\n' > "$dl"
HIMMEL_LEAK_DENYLIST="$dl" run_class_red_control "T12-mac-address-under-station-denylist" "mac-address" \
    '    if check_mac "$content" && ! line_allows "$content" mac-address; then' \
    '    if false && check_mac "$content" && ! line_allows "$content" mac-address; then' "$r"

echo "== RED controls: HIMMEL-2831 #2 / HIMMEL-2854 #6 follow-ups =="

# RED-home-path-file-uri (HIMMEL-2854 #6): revert check_home_path's
# leading-context regex to its pre-fix form -- the file:// URI in T1m must
# then go completely unreported.
r=$(new_repo)
printf 'see file:///home/alexphantom/x for details\n' > "$r/f.txt"  # leak-allow: home-path test fixture
git -C "$r" add f.txt
mutant="$WS/mutant-home-path-file-uri.sh"
if mutate_call_site \
    '(^file://|^|[^A-Za-z0-9_.$/\\-]file://|[^A-Za-z0-9_.$/\\-])' \
    '(^|[^A-Za-z0-9_.$/\\-])' \
    "$mutant"; then
    scan "$r" --tree
    if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "home-path"; then
        fail "RED-home-path-file-uri precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" -- bash -c '
            out=$(bash "$1" --tree 2>&1); rc=$?
            case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-home-path-file-uri" --expect-rc 0 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=no" \
            --correct "hit=yes" \
            --note "reverting the leading-context regex to drop the file:// alternatives makes the file:///home/... URI in T1m go completely unreported" \
            && pass "RED-home-path-file-uri RED confirmed" \
            || fail "RED-home-path-file-uri RED control did not confirm (see FAIL line above)"
    fi
fi

# RED-home-path-metachars (HIMMEL-2828 regression fix, console-flagged
# #664): revert the ERE-metacharacter exclusion this fix added to the
# name-char class -- unlike the RED controls above, this fix REMOVES a false
# positive rather than adding a detection, so the polarity is reversed: the
# REAL (fixed) script must stay CLEAN on this fixture, and the MUTANT
# (reverted to pre-fix) must misreport it as a leak. The exclusion appears
# four times in one regex line (three negated-class copies, one positive
# terminator copy); mutate_call_site's own single-occurrence contract can't
# express that, so this control does its own occurrence-counted, index()-based
# substring removal (same literal-substring technique mutate_call_site uses
# internally, just applied per-line instead of first-match-only) rather than
# reuse that helper.
r=$(new_repo)
printf '%s\n' "ABS_PATTERN='([A-Za-z]:[/\\]+Users[/\\]|/Users/|/root/|/home/[A-Za-z0-9._-]+/)'" > "$r/f.txt"  # leak-allow: home-path test fixture
git -C "$r" add f.txt
mutant="$WS/mutant-home-path-metachars.sh"
old_frag='(.*+?{}|^$['
before=$(grep -o -F "$old_frag" "$SCRIPT" | wc -l | tr -d ' ')
if [ "$before" != "4" ]; then
    fail "RED-home-path-metachars anchor '$old_frag' did not appear exactly 4 times (before=$before) -- a stale anchor would leave the mutant unmutated and this control would pass vacuously"
else
    MUT_O="$old_frag" awk '
        { line = $0
          o = ENVIRON["MUT_O"]
          out = ""
          while ((p = index(line, o)) > 0) {
              out = out substr(line, 1, p-1)
              line = substr(line, p + length(o))
          }
          out = out line
          print out
        }
    ' "$SCRIPT" > "$mutant"
    after=$(grep -o -F "$old_frag" "$mutant" | wc -l | tr -d ' ')
    if [ "$after" != "0" ] || cmp -s "$SCRIPT" "$mutant"; then
        fail "RED-home-path-metachars mutation did not take effect (after=$after)"
    else
        scan "$r" --tree
        if [ "$SCAN_RC" -ne 0 ] || [ -n "$(strip_hostname_skip "$SCAN_OUT")" ]; then
            fail "RED-home-path-metachars precondition failed: the REAL (fixed) script does not stay clean on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
        else
            red_control_run --cwd "$r" -- bash -c '
                out=$(bash "$1" --tree 2>&1); rc=$?
                case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
                echo "hit=$hit"
                exit "$rc"
            ' _ "$mutant"
            red_control_assert --label "RED-home-path-metachars" --expect-rc 1 \
                --observed "$RED_CONTROL_OUT" \
                --expect-wrong "hit=yes" \
                --correct "hit=no" \
                --note "reverting the ERE-metacharacter exclusion makes the regex-literal ABS_PATTERN fixture get misread as a real home path again, proving the exclusion -- not the fixture -- is what keeps T1t clean" \
                && pass "RED-home-path-metachars RED confirmed" \
                || fail "RED-home-path-metachars RED control did not confirm (see FAIL line above)"
        fi
    fi
fi

# RED-home-path-ellipsis (HIMMEL-2828 regression fix, console-flagged #664):
# revert the doc-ellipsis skip check in check_home_path's match loop -- the
# RUNNER~1\... placeholder in T1t2 must then be reported as a leak.
r=$(new_repo)
printf '// (C:\\Users\\RUNNER~1\\..., because "runneradmin" is over 8 characters) while\n' > "$r/ellipsis.ts"  # leak-allow: home-path test fixture
git -C "$r" add ellipsis.ts
mutant="$WS/mutant-home-path-ellipsis.sh"
# The anchor/replacement are derived from the live script rather than
# hand-transcribed here: the real line embeds ANSI-C $'...' quoting (the
# doc-ellipsis and Unicode-ellipsis literals), and hand-escaping that through
# this file's own single-quoted literals would be exactly the kind of fragile
# transcription mutate_call_site's own occurrence check exists to catch late,
# not avoid entirely.
ellipsis_anchor=$(grep -m1 -F '! home_name_allowed "$name"; then' "$SCRIPT")
ellipsis_indent=$(printf '%s' "$ellipsis_anchor" | sed -E 's/^([[:space:]]*).*/\1/')
ellipsis_replacement="${ellipsis_indent}if ! home_name_allowed \"\$name\"; then"
if [ -z "$ellipsis_anchor" ]; then
    fail "RED-home-path-ellipsis anchor not found in $SCRIPT (script shape changed?)"
elif mutate_call_site "$ellipsis_anchor" "$ellipsis_replacement" "$mutant"; then
    scan "$r" --tree
    if [ "$SCAN_RC" -ne 0 ] || [ -n "$(strip_hostname_skip "$SCAN_OUT")" ]; then
        fail "RED-home-path-ellipsis precondition failed: the REAL (fixed) script does not stay clean on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" -- bash -c '
            out=$(bash "$1" --tree 2>&1); rc=$?
            case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-home-path-ellipsis" --expect-rc 1 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=yes" \
            --correct "hit=no" \
            --note "reverting the doc-ellipsis skip check makes the RUNNER~1\\... placeholder in T1t2 get reported as a leaked home path again" \
            && pass "RED-home-path-ellipsis RED confirmed" \
            || fail "RED-home-path-ellipsis RED control did not confirm (see FAIL line above)"
    fi
fi

# RED-staged-unquote (HIMMEL-2831 #2): revert run_staged()'s "+++" header
# parse to the pre-fix plain strip (no unquote_diff_path call) -- the
# space-containing exact-file exemption in T9i must then go back to being
# wrongly flagged.
r=$(new_repo)
printf 'file with space.txt\n' > "$r/.leak-classes-ignore"
printf 'home path /home/alexphantom/leak here\n' > "$r/file with space.txt"  # leak-allow: home-path test fixture
git -C "$r" add 'file with space.txt' .leak-classes-ignore
mutant="$WS/mutant-staged-unquote.sh"
if mutate_call_site \
    'f="$(unquote_diff_path "${diff_line#+++ }")"' \
    'f="${diff_line#+++ }"' \
    "$mutant"; then
    scan "$r" --staged
    if [ "$SCAN_RC" -ne 0 ] || [ -n "$(strip_hostname_skip "$SCAN_OUT")" ]; then
        fail "RED-staged-unquote precondition failed: the REAL script did not stay clean on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" -- bash -c '
            out=$(bash "$1" --staged 2>&1); rc=$?
            case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-staged-unquote" --expect-rc 1 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=yes" \
            --correct "hit=no" \
            --note "reverting the +++ header parse to the plain \${f#b/} strip bakes git's trailing disambiguation tab into current_file, so the exact-file exemption for 'file with space.txt' stops matching and the file is wrongly flagged again" \
            && pass "RED-staged-unquote RED confirmed" \
            || fail "RED-staged-unquote RED control did not confirm (see FAIL line above)"
    fi
fi

# RED-staged-unquote-trailing-newline (codex-1, /pr-check panel round 1):
# revert unquote_diff_path()'s trailing sentinel -- both the printf that
# appends it and the caller's strip of it -- so a decoded name's real
# trailing newline byte is the last byte of the captured `$(...)` output
# again, and gets silently stripped. The T9k fixture must then wrongly
# inherit "short.txt"'s exemption.
r=$(new_repo)
printf 'short.txt\n' > "$r/.leak-classes-ignore"
nlname=$'short.txt\n'
printf 'home path /home/alexphantom/leak here\n' > "$r/$nlname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$nlname" .leak-classes-ignore
step1="$WS/mutant-staged-trailing-newline.step1.sh"
mutant="$WS/mutant-staged-trailing-newline.sh"
if mutate_call_site "printf '%s.' \"\$s\"" "printf '%s' \"\$s\"" "$step1"; then
    anchor2='f="${f%.}"'
    before2=$(grep -cF "$anchor2" "$step1")
    MUT_O="$anchor2" MUT_N='f="$f"' awk '
        { line = $0
          p = index(line, ENVIRON["MUT_O"])
          if (p > 0) line = substr(line,1,p-1) ENVIRON["MUT_N"] substr(line, p+length(ENVIRON["MUT_O"]))
          print line }
    ' "$step1" > "$mutant"
    after2=$(grep -cF "$anchor2" "$mutant" || true)
    if [ "$before2" != "1" ] || [ "$after2" != "0" ]; then
        fail "mutation anchor '$anchor2' did not match exactly once (before=$before2 after=$after2) -- a stale anchor would leave the mutant unmutated and its RED control would pass vacuously"
    elif cmp -s "$SCRIPT" "$mutant"; then
        fail "mutant for '$anchor2' is byte-identical to the original -- broken control"
    else
        scan "$r" --staged
        if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "home-path"; then
            fail "RED-staged-unquote-trailing-newline precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
        else
            red_control_run --cwd "$r" -- bash -c '
                out=$(bash "$1" --staged 2>&1); rc=$?
                case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
                echo "hit=$hit"
                exit "$rc"
            ' _ "$mutant"
            red_control_assert --label "RED-staged-unquote-trailing-newline" --expect-rc 0 \
                --observed "$RED_CONTROL_OUT" \
                --expect-wrong "hit=no" \
                --correct "hit=yes" \
                --note "removing the trailing sentinel lets \$(...) strip the decoded name's own real trailing newline byte, so it collapses onto 'short.txt' and wrongly inherits its exemption" \
                && pass "RED-staged-unquote-trailing-newline RED confirmed" \
                || fail "RED-staged-unquote-trailing-newline RED control did not confirm (see FAIL line above)"
        fi
    fi
fi

# RED-staged-unquote-ctrlchar (self-discovered while verifying codex-1
# above): revert the \t decode step in unquote_diff_path() to a no-op
# (leave the literal backslash-t pair undecoded) -- the T9l fixture must
# then wrongly inherit the literal, undecoded ignore entry's exemption.
r=$(new_repo)
printf '%s\n' 'weird\ttab.txt' > "$r/.leak-classes-ignore"
tabname=$'weird\ttab.txt'
printf 'home path /home/alexphantom/leak here\n' > "$r/$tabname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$tabname" .leak-classes-ignore
mutant="$WS/mutant-staged-ctrlchar.sh"
if mutate_call_site \
    's="${s//\\t/$tab}"' \
    's="${s//\\t/\\t}"' \
    "$mutant"; then
    scan "$r" --staged
    if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "home-path"; then
        fail "RED-staged-unquote-ctrlchar precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" -- bash -c '
            out=$(bash "$1" --staged 2>&1); rc=$?
            case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-staged-unquote-ctrlchar" --expect-rc 0 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=no" \
            --correct "hit=yes" \
            --note "leaving the \\t escape undecoded makes the real-tab fixture collide with the literal-backslash-t ignore entry, wrongly exempting it" \
            && pass "RED-staged-unquote-ctrlchar RED confirmed" \
            || fail "RED-staged-unquote-ctrlchar RED control did not confirm (see FAIL line above)"
    fi
fi

# RED-staged-unquote-cr (/pr-check panel round 2, codex-1): revert the \r
# decode step in unquote_diff_path() to a no-op (leave the literal
# backslash-r pair undecoded) -- the T9m fixture must then wrongly inherit
# the literal, undecoded ignore entry's exemption. \a \b \v \f decode is the
# byte-identical shape one line above/below this one and is not separately
# RED-tested.
r=$(new_repo)
printf '%s\n' 'weird\rcr.txt' > "$r/.leak-classes-ignore"
crname=$'weird\rcr.txt'
printf 'home path /home/alexphantom/leak here\n' > "$r/$crname"  # leak-allow: home-path test fixture
git -C "$r" add -- "$crname" .leak-classes-ignore
mutant="$WS/mutant-staged-cr.sh"
if mutate_call_site \
    's="${s//\\r/$cr}"' \
    's="${s//\\r/\\r}"' \
    "$mutant"; then
    scan "$r" --staged
    if [ "$SCAN_RC" -ne 1 ] || ! grepq "$SCAN_OUT" -F "home-path"; then
        fail "RED-staged-unquote-cr precondition failed: the REAL script did not hit on this fixture (rc=$SCAN_RC out=$SCAN_OUT)"
    else
        red_control_run --cwd "$r" -- bash -c '
            out=$(bash "$1" --staged 2>&1); rc=$?
            case "$out" in *"home-path"*) hit=yes ;; *) hit=no ;; esac
            echo "hit=$hit"
            exit "$rc"
        ' _ "$mutant"
        red_control_assert --label "RED-staged-unquote-cr" --expect-rc 0 \
            --observed "$RED_CONTROL_OUT" \
            --expect-wrong "hit=no" \
            --correct "hit=yes" \
            --note "leaving the \\r escape undecoded makes the real-cr fixture collide with the literal-backslash-r ignore entry, wrongly exempting it" \
            && pass "RED-staged-unquote-cr RED confirmed" \
            || fail "RED-staged-unquote-cr RED control did not confirm (see FAIL line above)"
    fi
fi

echo
echo "== summary =="
if [ "$failures" -eq 0 ]; then
    if [ "$skips" -gt 0 ]; then
        echo "ALL PASS ($skips skipped)"
    else
        echo "ALL PASS"
    fi
    exit 0
else
    echo "$failures FAILURE(S)"
    exit 1
fi
