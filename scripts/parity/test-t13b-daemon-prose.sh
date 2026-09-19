#!/usr/bin/env bash
# Control for T13(b)'s daemon class in scripts/parity/test-ws5-invariants.sh
# (HIMMEL-3233).
#
# T13(b) used to match the bare word `daemon` on every added line of shipped
# source, prose included, so a README sentence, a shell comment or a doctor
# message naming an EXISTING daemon failed CI (PR #932). The narrowed rule:
#   - `while true` / `setInterval` are unchanged (every shipped line);
#   - the daemon class does not apply to *.md (prose);
#   - in any other file, full-line comments are skipped, the word `daemon`
#     counts outside prose strings (a quoted string holding whitespace is a
#     message; a single-token string such as "--daemon" is an argv element
#     and still counts; a string that RUNS -- backticks, "$(...)", or any
#     string on a `sh -c` / eval / exec / system / subprocess line -- is
#     never prose), and service-creation shapes (backgrounded
#     `nohup ... &`, systemctl ... enable, launchctl load|bootstrap) count
#     anywhere on the line, quoted or not. Bare nohup/setsid/disown do not
#     (hook case lists and bounded detach helpers use them routinely).
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

echo "== T13(b): prose and diagnostics naming an existing daemon PASS =="
# shellcheck disable=SC2016  # the backticks are literal markdown, not expansion
run_case md-prose PASS docs/qmd.md \
    'Restart the qmd daemon with `qmd mcp --http --daemon` if vec search hangs.'
run_case sh-comment PASS scripts/doctor.sh \
    "# Keep unrelated cases from probing the operator's real qmd daemon."
run_case sh-diagnostic PASS scripts/doctor.sh \
    'emit WARN C40 "the qmd daemon is wedged; restart it: qmd mcp --http --daemon"'
run_case js-comment PASS src/probe.ts \
    '// the daemon frames every reply as an SSE event'

echo "== T13(b): real new always-on surface still FAILS =="
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
# shellcheck disable=SC2016  # the backticks are fixture text, not expansion
run_case sh-backtick-daemon FAIL scripts/start.sh \
    'out=`qmd mcp --http --daemon`'
# shellcheck disable=SC2016  # "$(...)" is fixture text, not expansion
run_case sh-cmdsubst-in-string FAIL scripts/start.sh \
    'echo "started: $(qmd mcp --http --daemon)"'
run_case py-os-system-daemon FAIL src/start.py \
    'os.system("qmd mcp --http --daemon")'
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

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures of $cases case(s) failed"
    exit 1
fi
echo "PASS: T13(b) daemon-class control ($cases cases)"
exit 0
