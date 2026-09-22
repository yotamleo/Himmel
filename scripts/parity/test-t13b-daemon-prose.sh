#!/usr/bin/env bash
# Control for T13(b)'s daemon class in scripts/parity/test-ws5-invariants.sh
# (HIMMEL-3233).
#
# T13(b) used to match the bare word `daemon` on every added line of shipped
# source, prose included, so a README sentence, a shell comment or a doctor
# message naming an EXISTING daemon failed CI (PR #932). The narrowed rule:
#   - `while true` / `setInterval` are unchanged (every shipped line);
#   - the daemon class does not apply to *.md (prose);
#   - in any other file, full-line comments are skipped (a leading inline
#     /* ... */ is stripped first, so the code after it is still checked);
#     every other line still counts the bare word `daemon`, quoted or not.
#     Known limit: a message string naming a daemon still fails (pinned by
#     sh-diagnostic-known-limit below);
#   - service-creation shapes (backgrounded `nohup ... &`, systemctl ...
#     enable, launchctl load|bootstrap) count too. Bare nohup/setsid/disown
#     do not (hook case lists and bounded detach helpers use them routinely);
#   - the exact command `systemctl [--user] daemon-reload` is carved out
#     (HIMMEL-3414): it reloads unit files and starts nothing. Nothing else
#     named daemon is exempt, and a spawn beside it still fails.
#
# End-to-end against real fixture repos: each case commits a base and a feature
# commit into a throwaway git repo carrying a COPY of the real ws5 script, then
# runs it with --base main, and asserts the exit status too, so a fixture that
# breaks some OTHER section cannot fake a T13(b) verdict.
#
# Assertions use `case` glob matching, not `printf | grep -q` (HIMMEL-1430).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + shell against a temp repo; no .ps1 twin needed -- the only
# consumer is this shell test suite, which is itself gitbash-only.
#
# Usage: bash scripts/parity/test-t13b-daemon-prose.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/t13b-daemon.XXXXXX")" || { echo "FAIL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
cases=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# run_case <name> <expect PASS|FAIL> <path> <added line>
# The feature commit appends <added line> to <path> (created empty in base).
run_case() {
    local name="$1" expect="$2" path="$3" line="$4"
    local dir="$TMP_ROOT/$name"
    cases=$((cases+1))
    mkdir -p "$dir/scripts/parity" "$dir/scripts/lib" "$dir/docs/internals" "$dir/$(dirname "$path")"
    cp "$REPO/scripts/parity/test-ws5-invariants.sh" "$REPO/scripts/parity/t12-no-bloat-lib.sh" "$dir/scripts/parity/"
    cp "$REPO/scripts/lib/platform-guard.sh" "$dir/scripts/lib/"
    printf '| gemini | deferred |\n' > "$dir/docs/internals/lane-parity.md"
    printf '# fixture\n' > "$dir/CLAUDE.md"
    printf 'x\n' > "$dir/$path"
    local g=(git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
    "${g[@]}" init -q -b main >/dev/null 2>&1 || { fail "$name: fixture git init failed"; return; }
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m base >/dev/null 2>&1 || { fail "$name: fixture base commit failed"; return; }
    "${g[@]}" checkout -q -b feat >/dev/null 2>&1
    printf '%s\n' "$line" >> "$dir/$path"
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m feat >/dev/null 2>&1 || { fail "$name: fixture feat commit failed"; return; }

    local out rc
    out="$(bash "$dir/scripts/parity/test-ws5-invariants.sh" --base main 2>&1)"; rc=$?
    local ok=0
    if [ "$expect" = "PASS" ]; then
        case "$out" in *"PASS T13 no-always-on"*) [ "$rc" -eq 0 ] && ok=1 ;; esac
    else
        case "$out" in *"FAIL T13(b)"*) [ "$rc" -eq 1 ] && ok=1 ;; esac
    fi
    if [ "$ok" -eq 1 ]; then
        pass "$name -> $expect (rc=$rc)"
    else
        fail "$name -> expected $expect, got rc=$rc: $(printf '%s' "$out" | grep -E 'T13|FAIL' | tr '\n' '|')"
    fi
}

echo "== T13(b): prose (*.md, comment lines) naming an existing daemon PASS =="
# shellcheck disable=SC2016  # the backticks are literal markdown, not expansion
run_case md-prose PASS docs/qmd.md \
    'Restart the qmd daemon with `qmd mcp --http --daemon` if vec search hangs.'
run_case sh-comment PASS scripts/doctor.sh \
    "# Keep unrelated cases from probing the operator's real qmd daemon."
run_case js-comment PASS src/probe.ts \
    '// the daemon frames every reply as an SSE event'

echo "== T13(b): real new always-on surface still FAILS =="
# Known limit (console ruling, HIMMEL-3233): a message naming a daemon still
# fails -- the bare word counts on every code line, quoted or not.
run_case sh-diagnostic-known-limit FAIL scripts/doctor.sh \
    'emit WARN C40 "the qmd daemon is wedged; restart it: qmd mcp --http --daemon"'
run_case sh-nohup FAIL scripts/start.sh \
    'nohup qmd mcp >/dev/null 2>&1 &'
run_case sh-nohup-in-string FAIL scripts/start.sh \
    'bash -c "nohup qmd mcp >/dev/null 2>&1 &"'
run_case sh-daemon-flag FAIL scripts/start.sh \
    'qmd mcp --http --daemon'
run_case sh-daemon-script FAIL scripts/start.sh \
    'bash scripts/ensure-qmd-daemon.sh'
run_case py-argv-daemon FAIL src/start.py \
    'subprocess.Popen(["qmd", "mcp", "--daemon"])'
run_case py-thread-daemon FAIL src/start.py \
    'threading.Thread(target=poll, daemon=True).start()'
run_case sh-bash-c-daemon FAIL scripts/start.sh \
    'bash -c "qmd mcp --http --daemon"'
run_case sh-assign-daemon FAIL scripts/start.sh \
    'cmd="qmd mcp --http --daemon"'
run_case js-inline-comment-code FAIL src/probe.ts \
    '/* start worker */ daemon.start()'
run_case js-two-inline-comments-code FAIL src/probe.ts \
    '/* start */ /* worker */ daemon.start()'
run_case html-comment-then-code FAIL src/page.html \
    '<!-- a --> /* b */ <script>daemon.start()</script>'
run_case sh-systemctl-enable FAIL scripts/start.sh \
    'systemctl --user enable --now qmd.service'
run_case sh-launchctl FAIL scripts/start.sh \
    'launchctl bootstrap gui/501 ~/Library/LaunchAgents/qmd.plist'
# shellcheck disable=SC2016  # "$arm" is fixture text, not expansion
run_case sh-setsid-nohup-bg FAIL scripts/start.sh \
    'setsid nohup bash "$arm" >/dev/null 2>&1 &'

echo "== T13(b): nohup/setsid/disown without the backgrounding shape PASS =="
run_case sh-nohup-case-list PASS scripts/hook.sh \
    '            command|exec|builtin|nohup|time|nice)'
run_case sh-nohup-and-and PASS scripts/start.sh \
    'nohup true 2>&1 && echo ok'
run_case sh-disown PASS scripts/start.sh \
    'disown 2>/dev/null || true'
run_case sh-setsid-probe PASS scripts/start.sh \
    'if command -v setsid >/dev/null 2>&1; then'

echo "== T13(b): while true / setInterval unchanged (prose too) =="
run_case md-setinterval FAIL docs/qmd.md \
    'The page polls with setInterval(tick, 1000).'
run_case sh-comment-while-true FAIL scripts/start.sh \
    '# while true; do probe; done'

echo "== T13(b): exact systemctl [--user] daemon-reload PASSES (HIMMEL-3414) =="
# The verb reloads systemd's unit files and starts nothing. The carve-out is the
# exact token only: the word `daemon` in general still counts (controls below).
run_case sh-systemctl-user-daemon-reload PASS scripts/uninstall.sh \
    'systemctl --user daemon-reload'
run_case sh-systemctl-daemon-reload PASS scripts/uninstall.sh \
    '  systemctl daemon-reload >/dev/null 2>&1 || true'
run_case sh-systemctl-daemon-reload-if PASS scripts/uninstall.sh \
    'if systemctl --user daemon-reload; then echo reloaded; fi'
run_case sh-systemctl-daemon-reload-twice PASS scripts/uninstall.sh \
    'systemctl daemon-reload;systemctl --user daemon-reload'

echo "== T13(b): a daemon spawn beside or near daemon-reload still FAILS =="
run_case sh-reload-then-nohup FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reload && nohup qmd mcp >/dev/null 2>&1 &'
run_case sh-reload-then-enable FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reload && systemctl --user enable --now qmd.service'
run_case sh-reload-then-daemon-flag FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reload; qmd mcp --http --daemon'
run_case sh-bare-daemon-spawn FAIL scripts/uninstall.sh \
    'bash scripts/ensure-qmd-daemon.sh'
run_case sh-daemon-reload-lookalike FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reloader'
run_case sh-daemon-reexec FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reexec'
run_case sh-other-verb-daemon-reload FAIL scripts/uninstall.sh \
    'foo --user daemon-reload'
run_case sh-daemon-reload-with-arg FAIL scripts/uninstall.sh \
    'systemctl --user daemon-reload --now qmd.service'

echo "== T13(b): a read-only process lookup naming a daemon FAILS without a marker -- the lexical carve-out is gone (HIMMEL-3432 marker-only simplification) =="
# The per-shape carve-out (pgrep/pkill/ps token anchors, chain/subst/
# backslash-continuation disqualifiers, the *.sh-only kind gate) is REMOVED:
# every fix closed one bypass shape and adversarial review kept finding the
# next, ending in a Critical (see the shadowed-call section below). A
# per-line lexical scanner cannot tell a real pgrep(1) invocation from an
# identifier spelled the same way, so every shape below -- old bypasses and
# the read-only shapes alike -- now fails exactly like main. Only the
# `t13b-ok` marker (further below) exempts a line.
# shellcheck disable=SC2016  # the brackets are a literal pgrep self-match idiom
run_case sh-pgrep-bracket-c FAIL scripts/start.sh \
    "pgrep -f '[c]laude daemon run'"
run_case sh-pgrep-af FAIL scripts/start.sh \
    "pgrep -af 'claude daemon'"
run_case sh-ps-pipe-grep FAIL scripts/start.sh \
    "ps -eo pid,args | grep '[c]laude daemon'"
run_case sh-pkill-dash-0 FAIL scripts/start.sh \
    "pkill -0 -f 'claude daemon'"
run_case sh-pgrep-redirect-fd-dup FAIL scripts/start.sh \
    "pgrep -f 'claude daemon run' >/dev/null 2>&1"
# shellcheck disable=SC2016  # command substitution is the point of the fixture
run_case sh-pgrep-cmd-subst FAIL scripts/start.sh \
    'pgrep -f "$(claude daemon run)"'
# shellcheck disable=SC2006  # backtick substitution is the point of the fixture
run_case sh-pgrep-backtick FAIL scripts/start.sh \
    "pgrep -f \`claude daemon run\`"
run_case sh-pkill-dash-0-then-9 FAIL scripts/start.sh \
    "pkill -0 -9 -f 'claude daemon'"
run_case sh-zsh-process-subst FAIL scripts/start.sh \
    'pgrep -f =(claude daemon run)'

echo "== T13(b): a pgrep/pkill/ps/grep shadowed by a function, function-keyword, or alias still FAILS when the CALL line names a daemon (HIMMEL-3432 AC adversarial Critical) =="
# The Critical the AC adversarial review proved against the now-removed
# carve-out: a *.sh line can DEFINE a shell function or alias literally
# named pgrep/pkill/ps/grep, SHADOWING the real command, while `daemon` sits
# on the CALL line rather than the definition line a lexical anchor was
# checking. With the carve-out gone this closes by construction -- the call
# line is just a line containing the word daemon, exempt only by marker.
run_case sh-pgrep-function-shadow-call FAIL scripts/start.sh \
    'pgrep () { shift; setsid -f claude "$@"; }
pgrep -f daemon run'
run_case sh-function-keyword-pgrep-shadow-call FAIL scripts/start.sh \
    'function pgrep { shift; setsid -f claude "$@"; }
pgrep -f daemon run'
run_case sh-pkill-function-shadow-call FAIL scripts/start.sh \
    'pkill () { setsid -f claude "$@"; }
pkill -0 -f daemon run'
run_case sh-ps-function-shadow-call FAIL scripts/start.sh \
    'ps () { setsid -f claude daemon run; }
ps aux | grep x'
run_case sh-grep-function-shadow-call FAIL scripts/start.sh \
    'grep () { shift; setsid -f claude daemon run; }
ps aux | grep x'
run_case sh-alias-pgrep-shadow-call FAIL scripts/start.sh \
    'alias pgrep="setsid -f claude"
pgrep -f daemon run'
run_case sh-alias-pkill-shadow-call FAIL scripts/start.sh \
    'alias pkill="setsid -f claude"
pkill -0 -f daemon run'

echo "== T13(b): # t13b-ok: <reason> is now the ONLY exemption -- hardened after the lexical carve-out's removal (HIMMEL-3432 marker-only simplification) =="
run_case sh-t13b-ok-marker PASS scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: transient self-daemon the CLI background-run flag spawns; read-only var scrape'
run_case js-t13b-ok-marker PASS src/probe.ts \
    'daemon.start()  // t13b-ok: transient self-daemon the SDK background-run flag spawns'
run_case sh-t13b-ok-empty-reason FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok:'
run_case sh-t13b-ok-empty-reason-space FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: '
run_case sh-t13b-ok-marker-above-does-not-exempt FAIL scripts/start.sh \
    $'# t13b-ok: reason lives on the wrong line\nnohup claude daemon run &'
run_case sh-t13b-ok-reason-too-short FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: short'
run_case sh-t13b-ok-reason-no-word-char FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: --------'
run_case sh-t13b-ok-reason-digits-only FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: 12345678'
run_case sh-t13b-ok-no-space-after-hash FAIL scripts/start.sh \
    'nohup claude daemon run &  #t13b-ok: real eight char reason'
run_case sh-t13b-ok-no-space-after-colon FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok:realeightcharreason'
run_case sh-t13b-ok-double-space-after-hash FAIL scripts/start.sh \
    'nohup claude daemon run &  #  t13b-ok: real eight char reason'
run_case sh-t13b-ok-double-space-after-colon-ok PASS scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok:  real eight char reason'

# HIMMEL-3446: the marker counts only as a genuine trailing comment (a
# quote/brace-depth aware scan, not raw substring text), with a reason of
# >= 8 chars containing a run of 3+ letters. Case names below borrow the
# reviewer's adv1094b marker-attack fixture matrix.
echo "== HIMMEL-3446: marker must be a real trailing comment, not smuggled text =="

run_case sh-t13b-ok-marker-crlf-ok PASS scripts/start.sh \
    $'nohup claude daemon run &  # t13b-ok: a real eight char reason\r'

run_case smg-dq-string FAIL scripts/start.sh \
    'echo "# t13b-ok: a real eight char reason"; nohup claude daemon run &'
run_case smg-sq-string FAIL scripts/start.sh \
    "echo '# t13b-ok: a real eight char reason'; nohup claude daemon run &"
run_case smg-bash-c-arg FAIL scripts/start.sh \
    "bash -c 'nohup claude daemon run &' '# t13b-ok: a real eight char reason'"
run_case smg-herestring FAIL scripts/start.sh \
    "nohup claude daemon run <<< '# t13b-ok: a real eight char reason' &"
# shellcheck disable=SC2016  # single-quoted on purpose: the fixture line is
# literal text for the target repo, never expanded here
run_case smg-param-exp FAIL scripts/start.sh \
    'echo "${x# t13b-ok: a real eight char reason}"; nohup claude daemon run &'
# shellcheck disable=SC2016  # single-quoted on purpose: literal fixture text
run_case smg-cmd-subst FAIL scripts/start.sh \
    'x=$(echo "# t13b-ok: a real eight char reason"); nohup claude daemon run &'
run_case smg-word-hash FAIL scripts/start.sh \
    'echo foo# t13b-ok: a real eight char reason; nohup claude daemon run &'
run_case smg-escaped-hash FAIL scripts/start.sh \
    'nohup claude daemon run & \# t13b-ok: a real eight char reason; claude daemon run &'
run_case smg-slashslash-sh FAIL scripts/start.sh \
    'true // t13b-ok: a real eight char reason; nohup claude daemon run &'

run_case smg-js-string FAIL src/x.ts \
    'const s = "// t13b-ok: a real eight char reason"; daemon.start()'
# shellcheck disable=SC2016  # single-quoted on purpose: literal fixture text
run_case smg-js-template FAIL src/x.ts \
    'const s = `# t13b-ok: a real eight char reason`; daemon.start()'
run_case smg-js-regex FAIL src/x.ts \
    'if (/# t13b-ok: a real eight char reason/.test(s)) daemon.start()'
run_case smg-js-leadblock FAIL src/x.ts \
    '/* // t13b-ok: a real eight char reason */ daemon.start()'

run_case sh-t13b-ok-reason-punct-run FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: .......x'
run_case sh-t13b-ok-reason-space-padded FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: x         y'
run_case sh-t13b-ok-nested-marker FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: # t13b-ok: a real reason'

# Item (d), console ruling: everything after a real "# t13b-ok: <reason>" IS
# a shell comment, so a chained daemon start past it is unreachable code on
# THIS line, not a smuggle -- this is not a bug to fix, it must keep passing.
run_case sh-t13b-ok-mid-chain-comment-eats-rest PASS scripts/start.sh \
    'nohup claude daemon run & # t13b-ok: a real eight char reason ; claude daemon run &'

run_case py-t13b-ok-marker-genuine PASS src/start.py \
    'daemon.start()  # t13b-ok: a real eight char reason'
run_case py-t13b-ok-marker-quoted FAIL src/start.py \
    "s = '# t13b-ok: a real eight char reason'; daemon.start()"

# Real markers already on main (verbatim, HIMMEL-3446 console re-verify: base
# 08de71f5 predates #1087/58733898 and #1083/a358da5d, which added these).
# Pinned so the tightened rules keep accepting the genuine shapes that shipped
# on other legs' branches, not just the synthetic fixture lines above.
run_case real-1083-test-fleet-daemon-string PASS scripts/handover/console-kit/test-fleet.sh \
    "    '- 10:27 LIVE — background leg via the daemon'  # t13b-ok: literal fixture text for a mocked leg row, not real automation"
# shellcheck disable=SC2016  # single-quoted on purpose: literal fixture text, real HIMMEL-3403 argv-match line
run_case real-1087-argv-match-marker PASS scripts/handover/headed-arm.sh \
    '        [ "${prev2##*/}" = claude ] && [ "$prev1" = daemon ] && [ "$arg" = run ] && return 0  # t13b-ok: read-only argv match of the Claude Code service, starts nothing'
run_case real-1087-pgrep-marker PASS scripts/handover/headed-arm.sh \
    "    pids=\"\$(\"\$PGREP\" -f '[c]laude daemon run' 2>/dev/null)\"  # t13b-ok: read-only pgrep lookup of the Claude Code service, starts nothing"

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures of $cases case(s) failed"
    exit 1
fi
echo "PASS: T13(b) daemon-class control ($cases cases)"
exit 0
