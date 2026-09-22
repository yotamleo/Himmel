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

echo "== T13(b): read-only process lookups naming a daemon PASS (HIMMEL-3432) =="
# shellcheck disable=SC2016  # the brackets are a literal pgrep self-match idiom
run_case sh-pgrep-bracket-c PASS scripts/start.sh \
    "pgrep -f '[c]laude daemon run'"
run_case sh-pgrep-af PASS scripts/start.sh \
    "pgrep -af 'claude daemon'"
run_case sh-ps-pipe-grep PASS scripts/start.sh \
    "ps -eo pid,args | grep '[c]laude daemon'"
run_case sh-pkill-dash-0 PASS scripts/start.sh \
    "pkill -0 -f 'claude daemon'"

echo "== T13(b): a lookup that ALSO starts a process still FAILS (HIMMEL-3432) =="
run_case sh-pgrep-or-start FAIL scripts/start.sh \
    "pgrep -f 'claude daemon run' || claude daemon run &"
run_case sh-pgrep-and-nohup FAIL scripts/start.sh \
    "pgrep -f 'claude daemon' && nohup claude daemon run &"
run_case sh-pkill-without-dash-0 FAIL scripts/start.sh \
    "pkill -f 'claude daemon'"
run_case sh-ps-grep-then-kill FAIL scripts/start.sh \
    "ps -eo pid,args | grep '[c]laude daemon' | xargs kill"

echo "== T13(b): a lookup arg that itself SPAWNS still FAILS (HIMMEL-3432 CR) =="
# shellcheck disable=SC2016  # command substitution is the point of the fixture
run_case sh-pgrep-cmd-subst FAIL scripts/start.sh \
    'pgrep -f "$(claude daemon run)"'
# shellcheck disable=SC2006  # backtick substitution is the point of the fixture
run_case sh-pgrep-backtick FAIL scripts/start.sh \
    "pgrep -f \`claude daemon run\`"
run_case sh-pkill-dash-0-then-9 FAIL scripts/start.sh \
    "pkill -0 -9 -f 'claude daemon'"
run_case sh-pgrep-process-subst FAIL scripts/start.sh \
    'pgrep -f <(claude daemon run)'
run_case sh-pgrep-process-subst-out FAIL scripts/start.sh \
    'pgrep -f >(claude daemon run)'

echo "== T13(b): # t13b-ok: <reason> exempts its own line only (HIMMEL-3432) =="
run_case sh-t13b-ok-marker PASS scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: transient self-daemon the CLI background-run flag spawns; read-only var scrape'
run_case sh-t13b-ok-empty-reason FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok:'
run_case sh-t13b-ok-empty-reason-space FAIL scripts/start.sh \
    'nohup claude daemon run &  # t13b-ok: '
run_case sh-t13b-ok-marker-above-does-not-exempt FAIL scripts/start.sh \
    $'# t13b-ok: reason lives on the wrong line\nnohup claude daemon run &'

echo "== T13(b): a redirect-only lookup line PASSES, not over-strict (HIMMEL-3432 adv-review) =="
run_case sh-pgrep-redirect-fd-dup PASS scripts/start.sh \
    "pgrep -f 'claude daemon run' >/dev/null 2>&1"

echo "== T13(b): a shell function NAMED pgrep/pkill still FAILS (HIMMEL-3432 adv-review) =="
run_case sh-pgrep-function-name FAIL scripts/start.sh \
    'pgrep () ( setsid -f claude daemon run --label x )
pgrep -f "claude daemon run"'
run_case sh-pkill-function-name FAIL scripts/start.sh \
    'pkill () ( setsid -f claude daemon run --label x )
pkill -0 -f "claude daemon run"'

echo "== T13(b): a backslash line-continuation hiding the starter still FAILS (HIMMEL-3432 adv-review) =="
run_case sh-pgrep-backslash-continuation FAIL scripts/start.sh \
    'pgrep -f "claude daemon run" >/dev/null \
    || setsid -f claude daemon run'

echo "== T13(b): the lookup carve-out is *.sh/*.bash only, not other languages (HIMMEL-3432 adv-review) =="
run_case py-pgrep-lookalike FAIL src/start.py \
    'pgrep and subprocess.Popen(["claude","daemon","run"])'
run_case ts-pgrep-lookalike FAIL src/start.ts \
    'pgrep ? spawn("claude",["daemon","run"]) : 0'

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures of $cases case(s) failed"
    exit 1
fi
echo "PASS: T13(b) daemon-class control ($cases cases)"
exit 0
