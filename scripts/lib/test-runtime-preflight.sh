#!/usr/bin/env bash
# Verdict-table suite for scripts/lib/runtime-preflight.sh (HIMMEL-1991).
#
# One canned runtime tuple per case, assembled as a stub PATH: node/npm/bun and
# the Windows PATH-order probe are all stubs, so every verdict is decided by the
# policy under test and not by whatever this host happens to have installed.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/runtime-preflight.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=hermetic-path.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/hermetic-path.sh"

# A PATH with the tools the lib needs but with node/npm/bun scrubbed out, so a
# case only sees the runtimes it stubs in.
STUB="$work/bin"; mkdir -p "$STUB"
for _t in bash sh sed tr head cut uname dirname cd git; do
    link_hermetic_tool "$_t" "$STUB" 2>/dev/null || true
done
# nvm/volta/fnm are scrubbed too (panel r4 codex-3): the nvm-absent guidance is
# a verdict about the host, so a developer box with volta installed would
# otherwise flip that case and make the suite host-dependent.
BASE_PATH="$STUB:$(scrub_path "$PATH" node npm bun nvm volta fnm)"

NVMRC="$work/nvmrc"; printf '24\n' > "$NVMRC"

# stub <name> <stdout-line> — a runtime that reports one fixed version string.
stub() { local d="$work/rt"; mkdir -p "$d"; printf '#!/bin/sh\necho %s\n' "$2" > "$d/$1"; chmod +x "$d/$1"; }
rt_reset() { rm -rf "$work/rt"; mkdir -p "$work/rt"; }
# scan <extra-env...> — run the scan with the stub runtimes first on PATH.
scan() { env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=Linux \
    "$@" bash -c ". '$LIB'; runtime_preflight_scan"; }

echo "== aligned runtime -> no findings, rc 0 =="
rt_reset; stub node v24.9.0; stub npm 10.0.0; stub bun 1.4.0
out="$(scan)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "aligned tuple is silent"
else
    fail "aligned -> rc=$rc out='$out'"
fi

echo "== node major != pin -> RUNTIME-DRIFT node-major, rc 1 =="
rt_reset; stub node v26.7.0; stub npm 10.0.0; stub bun 1.4.0
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT node-major v26.7.0 24$'; then
    pass "node-major drift names both versions"
else
    fail "node drift -> rc=$rc out='$out'"
fi

echo "== node drift + no version manager -> RUNTIME-GUIDANCE nvm-absent =="
if grepq "$(scan NVM_DIR="$work/no-nvm")" '^RUNTIME-GUIDANCE nvm-absent$'; then
    pass "nvm-absent guidance rides along with the drift"
else
    fail "nvm-absent guidance missing"
fi

echo "== guidance alone never refuses (it is not a DRIFT line) =="
rt_reset; stub node v24.9.0; stub npm 10.0.0
out="$(scan NVM_DIR="$work/no-nvm")"; rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'nvm-absent'; then
    pass "aligned node emits no guidance and no refusal"
else
    fail "guidance-alone -> rc=$rc out='$out'"
fi

echo "== node absent -> RUNTIME-DRIFT node-missing =="
rt_reset; stub npm 10.0.0
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT node-missing$'; then
    pass "node-missing is a finding, not a silent skip"
else
    fail "node-missing -> rc=$rc out='$out'"
fi

echo "== node that will not say what it is -> RUNTIME-DRIFT node-unreadable =="
# A gate that shrugs at an unreadable runtime is not a gate (panel r1 codex-1).
rt_reset; stub npm 10.0.0
printf '#!/bin/sh\nexit 3\n' > "$work/rt/node"; chmod +x "$work/rt/node"
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT node-unreadable '; then
    pass "an unparseable node --version is a finding, not a pass"
else
    fail "node-unreadable -> rc=$rc out='$out'"
fi

echo "== a pin that is not a version -> never coerced into a comparison =="
# `24foo` must not read as major 24 (panel r1 codex-3). Since r6 the file it
# came from is also reported rather than skipped, so the assertion is that the
# scan says pin-unreadable — never that it compared against 24.
rt_reset; stub node v26.7.0; stub npm 10.0.0
BADPIN="$work/nvmrc-bad"; printf '24foo\n' > "$BADPIN"
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$BADPIN" RUNTIME_PREFLIGHT_OS=Linux \
    bash -c ". '$LIB'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT pin-unreadable ' && ! grepq "$out" 'node-major'; then
    pass "a malformed pin is reported, never compared"
else
    fail "malformed pin -> rc=$rc out='$out'"
fi
printf '24.9.0\n' > "$BADPIN"
if [ "$(env RUNTIME_PREFLIGHT_NVMRC="$BADPIN" bash -c ". '$LIB'; runtime_preflight_pin")" = "24" ]; then
    pass "a full semver pin still reads as its major"
else
    fail "semver pin misread"
fi
# A dot with nothing behind it is malformed too (panel r2 codex-2).
for _bad in '24.' '24...' '24.1.2.3' 'lts/iron'; do
    printf '%s\n' "$_bad" > "$BADPIN"
    if [ -z "$(env RUNTIME_PREFLIGHT_NVMRC="$BADPIN" bash -c ". '$LIB'; runtime_preflight_pin")" ]; then
        pass "pin '$_bad' is refused, not coerced"
    else
        fail "pin '$_bad' parsed to '$(env RUNTIME_PREFLIGHT_NVMRC="$BADPIN" bash -c ". '$LIB'; runtime_preflight_pin")'"
    fi
done

echo "== a present-but-unusable pin -> RUNTIME-DRIFT pin-unreadable =="
# An alias pin leaves the mandatory node rule unenforceable; skipping it would
# let strict mode pass without checking node at all (panel r6 codex-1).
rt_reset; stub node v26.7.0; stub npm 10.0.0
printf 'lts/iron\n' > "$BADPIN"
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$BADPIN" RUNTIME_PREFLIGHT_OS=Linux \
    bash -c ". '$LIB'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT pin-unreadable '; then
    pass "a pin that cannot be compared fails closed"
else
    fail "pin-unreadable -> rc=$rc out='$out'"
fi

echo "== NO .nvmrc at all -> clean skip (nothing was ever pinned) =="
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$work/no-such-nvmrc" RUNTIME_PREFLIGHT_OS=Linux \
    bash -c ". '$LIB'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "an unpinned repo is not a drifted one"
else
    fail "no-nvmrc -> rc=$rc out='$out'"
fi

echo "== the npm detector unreachable -> RUNTIME-DRIFT npm-uncheckable =="
# A mandatory rule that cannot be evaluated must not pass silently (codex-2).
LIBCOPY="$work/isolated/runtime-preflight.sh"; mkdir -p "$work/isolated"
cp "$LIB" "$LIBCOPY"
rt_reset; stub node v24.9.0; stub npm 10.0.0
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=Linux \
    bash -c ". '$LIBCOPY'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT npm-uncheckable '; then
    pass "an unreachable npm detector fails closed"
else
    fail "npm-uncheckable -> rc=$rc out='$out'"
fi

echo "== node present, npm absent -> RUNTIME-DRIFT npm-missing =="
rt_reset; stub node v24.9.0
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT npm-missing$'; then
    pass "npm-missing (detection reused from preflight-adopter.sh)"
else
    fail "npm-missing -> rc=$rc out='$out'"
fi

echo "== bun canary -> RUNTIME-DRIFT bun-canary =="
rt_reset; stub node v24.9.0; stub npm 10.0.0; stub bun 1.4.0-canary.1+01c4e2fd6
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT bun-canary 1.4.0-canary'; then
    pass "bun canary build is refused by policy"
else
    fail "bun-canary -> rc=$rc out='$out'"
fi

echo "== bun release -> no finding (negative control) =="
rt_reset; stub node v24.9.0; stub npm 10.0.0; stub bun 1.4.0
if [ -z "$(scan)" ]; then
    pass "a release bun is clean"
else
    fail "release bun flagged: $(scan)"
fi

echo "== bun release WITH a build hash -> still clean (--revision shape) =="
rt_reset; stub node v24.9.0; stub npm 10.0.0; stub bun 1.4.0+01c4e2fd6
if [ -z "$(scan)" ]; then
    pass "the +<hash> --revision suffix is not mistaken for a non-release"
else
    fail "release+hash flagged: $(scan)"
fi

echo "== bun that will not report a version -> RUNTIME-DRIFT bun-unreadable =="
# "Release only" is asserted positively, so an unreadable answer is not a pass
# (panel r4 codex-2).
rt_reset; stub node v24.9.0; stub npm 10.0.0
printf '#!/bin/sh\nexit 4\n' > "$work/rt/bun"; chmod +x "$work/rt/bun"
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT bun-unreadable '; then
    pass "an unreadable bun version is a finding"
else
    fail "bun-unreadable -> rc=$rc out='$out'"
fi

echo "== bun 1..4 -> RUNTIME-DRIFT bun-unreadable (digits and dots is not enough) =="
# panel r5 codex-1: the release rule runs through the shared version parser, so
# a digits-and-dots string that is not a version is still refused.
rt_reset; stub node v24.9.0; stub npm 10.0.0; stub bun 1..4
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT bun-unreadable 1..4$'; then
    pass "a malformed bun version is refused, not coerced"
else
    fail "bun 1..4 -> rc=$rc out='$out'"
fi

echo "== a node --version that only STARTS with digits -> node-unreadable =="
# `v24-corrupt` must not be read as major 24 and silently match the pin
# (panel r4 codex-1).
rt_reset; stub node v24-corrupt; stub npm 10.0.0
out="$(scan)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT node-unreadable v24-corrupt$'; then
    pass "a version-shaped-but-not-a-version answer never matches the pin"
else
    fail "node v24-corrupt -> rc=$rc out='$out'"
fi

echo "== windows bash resolving to the WSL launcher first -> bash-wsl-first =="
rt_reset; stub node v24.9.0; stub npm 10.0.0
WHERE_BAD="$work/where-bad.sh"
printf '#!/bin/sh\nprintf %%s\\\\n "C:\\\\Windows\\\\System32\\\\bash.exe" "C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe"\n' > "$WHERE_BAD"
chmod +x "$WHERE_BAD"
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=MINGW64_NT \
    RUNTIME_PREFLIGHT_WHERE="$WHERE_BAD" bash -c ". '$LIB'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT bash-wsl-first '; then
    pass "WSL-first bash is a finding on Windows"
else
    fail "bash-wsl-first -> rc=$rc out='$out'"
fi

echo "== git bash first -> no bash finding (negative control) =="
WHERE_OK="$work/where-ok.sh"
printf '#!/bin/sh\nprintf %%s\\\\n "C:\\\\Program Files\\\\Git\\\\usr\\\\bin\\\\bash.exe" "C:\\\\Windows\\\\System32\\\\bash.exe"\n' > "$WHERE_OK"
chmod +x "$WHERE_OK"
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=MINGW64_NT \
    RUNTIME_PREFLIGHT_WHERE="$WHERE_OK" bash -c ". '$LIB'; runtime_preflight_scan")"
if [ -z "$out" ]; then
    pass "Git Bash ahead of the WSL launcher is clean"
else
    fail "git-bash-first flagged: $out"
fi

echo "== the windows bash probe missing -> RUNTIME-DRIFT bash-uncheckable =="
# Unknown order is not clean order (panel r3 codex-1).
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=MINGW64_NT \
    RUNTIME_PREFLIGHT_WHERE="$work/no-such-where" bash -c ". '$LIB'; runtime_preflight_scan")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^RUNTIME-DRIFT bash-uncheckable '; then
    pass "an unusable PATH-order probe fails closed"
else
    fail "bash-uncheckable -> rc=$rc out='$out'"
fi

echo "== a finding whose value contains spaces survives into the banner =="
# `C:\Program Files\...` must not be truncated at its first space (codex-2).
SPACED="$work/with space/runtime-preflight.sh"; mkdir -p "$work/with space"
cp "$LIB" "$SPACED"
rt_reset; stub node v24.9.0; stub npm 10.0.0
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=Linux \
    bash -c ". '$SPACED'; runtime_preflight spaced" 2>&1)"
if grepq "$out" -F "with space/preflight-adopter.sh is missing or unreadable"; then
    pass "the whole path reaches the operator, spaces and all"
else
    fail "spaced path truncated: $out"
fi

echo "== the same tuple is only ever a DRIFT on windows =="
out="$(env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=Linux \
    RUNTIME_PREFLIGHT_WHERE="$WHERE_BAD" bash -c ". '$LIB'; runtime_preflight_scan")"
if [ -z "$out" ]; then
    pass "the bash probe never runs off Windows"
else
    fail "bash probe fired on Linux: $out"
fi

# ── severity policy ───────────────────────────────────────────────────────────
rt_reset; stub node v26.7.0; stub npm 10.0.0
pf() { env PATH="$work/rt:$BASE_PATH" RUNTIME_PREFLIGHT_NVMRC="$NVMRC" RUNTIME_PREFLIGHT_OS=Linux \
    "$@" bash -c ". '$LIB'; runtime_preflight run-shell-tests" 2>&1; }

echo "== default: LOUD on stderr, exit 0 (advisory) =="
out="$(pf)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'runtime preflight: run-shell-tests' && grepq "$out" '\.nvmrc pins 24'; then
    pass "advisory default warns without blocking"
else
    fail "advisory -> rc=$rc out='$out'"
fi

echo "== HIMMEL_RUNTIME_PREFLIGHT=strict -> same findings, exit 1 =="
out="$(pf HIMMEL_RUNTIME_PREFLIGHT=strict)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'REFUSING to run run-shell-tests'; then
    pass "strict refuses"
else
    fail "strict -> rc=$rc out='$out'"
fi

echo "== HIMMEL_RUNTIME_PREFLIGHT=0 -> silent, exit 0 =="
out="$(pf HIMMEL_RUNTIME_PREFLIGHT=0)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "the CI/adopter escape hatch is fully silent"
else
    fail "off -> rc=$rc out='$out'"
fi

# ── canary: the known-bad bash set must not drift from the JS resolver ────────
echo "== known-bad bash set matches run-hook-with-bash.js =="
JS="$REPO_ROOT/scripts/hooks/run-hook-with-bash.js"
# Both sides are normalised to ONE PATH PER LINE before sorting — the shell
# side is a single space-separated string, so it is split explicitly here
# rather than relying on the reader (or a reviewer) to spot the word-splitting.
js_set="$(grep -o "'/[a-z0-9/.]*bash\.exe'" "$JS" | tr -d "'" | sort | tr '\n' ' ')"
sh_set="$(bash -c ". '$LIB'; printf '%s' \"\$RUNTIME_PREFLIGHT_BAD_BASH\"" | tr ' ' '\n' | sort | tr '\n' ' ')"
if [ -n "$js_set" ] && [ "$js_set" = "$sh_set" ]; then
    pass "shell and JS known-bad lists agree ($sh_set)"
else
    fail "known-bad drift — js='$js_set' shell='$sh_set'"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
