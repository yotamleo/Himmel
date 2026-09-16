#!/usr/bin/env bash
# Hermetic control-flow test for scripts/machine-setup/macos.sh (ALPHA installer).
# Real macOS behavior is unverified (no Mac); this asserts the script wires the
# statusline, registers the auto-arm hook, verifies crontab, is idempotent, and
# (HIMMEL-3068) installs uv/bun via Homebrew when brew is present, and fails
# LOUD (never a silent skip) when it is not.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
M="$REPO_ROOT/scripts/machine-setup/macos.sh"
[ -f "$M" ] || { echo "FAIL: $M not found"; exit 1; }
failures=0; pass() { printf '  PASS  %s\n' "$1"; }; fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

t="$(mktemp -d)"; bin="$t/bin"; mkdir -p "$bin"
# crontab present (macOS backend), jq real, plus coreutils. Deliberately NO
# brew/uv/bun stub here — this is the "Homebrew absent" scenario (this box is
# Linux CI, so there genuinely is no brew on the real inherited PATH either).
printf '#!/bin/sh\nexit 0\n' > "$bin/crontab"; chmod +x "$bin/crontab"
for x in jq git bash sh sed grep tr head sort uname cat mkdir dirname chmod mv rm; do
    p="$(command -v "$x" 2>/dev/null)" && ln -sf "$p" "$bin/$x"
done

run() { env -i HOME="$t/home" PATH="$bin:$PATH" HIMMEL_PATH="$REPO_ROOT" \
            CLAUDE_DIR="$t/home/.claude" MACOS_ASSUME_YES=1 bash "$M" 2>&1; }

out="$(run)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "macos.sh rc0"; else fail "macos.sh rc=$rc: $out"; fi
if [ -f "$t/home/.claude/settings.json" ]; then pass "settings.json created"; else fail "no settings.json"; fi
if grep -q 'statusLine' "$t/home/.claude/settings.json"; then pass "statusline wired"; else fail "no statusLine"; fi
if grep -q 'auto-arm-on-cap' "$t/home/.claude/settings.json"; then pass "auto-arm hook registered"; else fail "no auto-arm hook"; fi
if grepq "$out" -i 'alpha'; then pass "alpha notice printed"; else fail "no alpha notice"; fi

# HIMMEL-3068: Homebrew absent — must fail LOUD (a WARNING naming brew, plus
# an explicit skip line for both uv and bun), never a silent no-op. rc stays 0
# (this file's own fail_nonfatal contract: non-fatal but never silent).
if grepq "$out" -i 'Homebrew not found'; then pass "brew-absent: Homebrew-missing message printed"; else fail "brew-absent: no Homebrew-missing message"; fi
if grepq "$out" -F 'WARNING: install uv failed'; then pass "brew-absent: install uv recorded as a non-fatal failure"; else fail "brew-absent: install uv not flagged"; fi
if grepq "$out" -F 'WARNING: install bun failed'; then pass "brew-absent: install bun recorded as a non-fatal failure"; else fail "brew-absent: install bun not flagged"; fi

# idempotency: 2nd run, hook still registered exactly once
run >/dev/null 2>&1
n="$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("auto-arm-on-cap"))] | length' "$t/home/.claude/settings.json")"
if [ "$n" -eq 1 ]; then pass "auto-arm hook registered once (idempotent)"; else fail "auto-arm hook count=$n"; fi
rm -rf "$t"

# ---- HIMMEL-3068: Homebrew PRESENT — the happy path -------------------------
# A hermetic stand-in for "macOS with brew installed": stub `brew` LOGS its
# invocations and exits 0 (it never really installs anything here), and stub
# `uv`/`bun` binaries exist for the post-install `--version` assertions the
# real script runs — this is what a macOS-shaped dry run looks like from this
# Linux box; a REAL macOS run was not performed (no Mac available).
t2="$(mktemp -d "${TMPDIR:-/tmp}/test-macos-brew.XXXXXX")"; bin2="$t2/bin"; brewlog="$t2/brew.log"; mkdir -p "$bin2"
printf '#!/bin/sh\nexit 0\n' > "$bin2/crontab"; chmod +x "$bin2/crontab"
for x in jq git bash sh sed grep tr head sort uname cat mkdir dirname chmod mv rm; do
    p="$(command -v "$x" 2>/dev/null)" && ln -sf "$p" "$bin2/$x"
done
cat > "$bin2/brew" <<EOF
#!/bin/sh
echo "\$*" >> "$brewlog"
case "\$1" in
  --version) echo "Homebrew 4.0.0" ;;
esac
exit 0
EOF
chmod +x "$bin2/brew"
printf '#!/bin/sh\necho "uv 0.9.99"\n' > "$bin2/uv"; chmod +x "$bin2/uv"
printf '#!/bin/sh\necho "1.4.2"\n' > "$bin2/bun"; chmod +x "$bin2/bun"

run2() { env -i HOME="$t2/home" PATH="$bin2:$PATH" HIMMEL_PATH="$REPO_ROOT" \
             CLAUDE_DIR="$t2/home/.claude" MACOS_ASSUME_YES=1 bash "$M" 2>&1; }

out2="$(run2)"; rc2=$?
if [ "$rc2" -eq 0 ]; then pass "brew-present: macos.sh rc0"; else fail "brew-present: macos.sh rc=$rc2: $out2"; fi
if grepq "$out2" -i 'Homebrew not found'; then fail "brew-present: Homebrew-missing message printed even though brew is present"; else pass "brew-present: no Homebrew-missing message"; fi
if [ -f "$brewlog" ] && grep -qF 'install uv' "$brewlog"; then pass "brew-present: brew install uv invoked"; else fail "brew-present: brew install uv not invoked"; fi
if [ -f "$brewlog" ] && grep -qF 'tap oven-sh/bun' "$brewlog"; then pass "brew-present: brew tap oven-sh/bun invoked"; else fail "brew-present: brew tap oven-sh/bun not invoked"; fi
if [ -f "$brewlog" ] && grep -qF 'install oven-sh/bun/bun' "$brewlog"; then pass "brew-present: brew install oven-sh/bun/bun invoked"; else fail "brew-present: brew install oven-sh/bun/bun not invoked"; fi
if grepq "$out2" -F 'uv 0.9.99'; then pass "brew-present: uv --version assertion ran"; else fail "brew-present: uv --version assertion did not run"; fi
if grepq "$out2" -F '1.4.2'; then pass "brew-present: bun --version assertion ran"; else fail "brew-present: bun --version assertion did not run"; fi
rm -rf "$t2"

echo; if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
