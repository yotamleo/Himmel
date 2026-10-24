#!/usr/bin/env bash
# test-himmel-update-clis.sh — himmel-update.sh reports and upgrades the agent
# CLIs and says so in the chain-status table:
#   --only clis       codex (upgraded through its install method) + claude (report only)
#   --only toolchain  bun is report-only: an off-pin bun names its owner and the pinned-install remedy
#   --only plugins    a missing @himmel plugin gets a table row + its install line
#
# Every binary is a STUB on a private PATH, and the npm stub is the only thing
# that "installs": no real upgrade, no network. Bash 3.2 compatible.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-clis.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
unset HIMMEL_UPDATE_CHANNEL CODEX_BIN HIMMEL_UPDATE_VM_ACK

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib" || exit 1
src_scripts="$(dirname "$SCRIPT")"
if ! { cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh" \
    && cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh" \
    && cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh" \
    && cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh" \
    && cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh" \
    && cp "$src_scripts/lib/resolve-bun.sh"        "$CLONE/scripts/lib/resolve-bun.sh" \
    && cp "$src_scripts/lib/vm-mode.sh"           "$CLONE/scripts/lib/vm-mode.sh" \
    && cp "$src_scripts/lib/claude-version.sh"    "$CLONE/scripts/lib/claude-version.sh" \
    && git init --quiet "$CLONE"; }; then
    echo "FAIL: mock clone setup" >&2
    exit 1
fi
printf '20\n' > "$CLONE/.nvmrc"
printf '1.4.4\n' > "$CLONE/.bun-version"

# vm.mode=local so the VM-first gate lets a roll through; a separate case holds it.
export HIMMEL_VM_MODE_CONFIG="$TMP/config.json"
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"

STUBS="$TMP/stubs"
NPMROOT="$TMP/npmroot/lib/node_modules/@openai/codex/bin"
mkdir -p "$STUBS" "$NPMROOT" || exit 1
STATE="$TMP/state"
mkdir -p "$STATE" || exit 1

# codex lives under an npm node_modules tree, as on a real npm-global install.
cat > "$NPMROOT/codex.js" <<'EOF'
#!/bin/sh
printf 'codex-cli %s\n' "$(cat "$STUB_STATE/codex.ver")"
EOF
ln -s "$NPMROOT/codex.js" "$STUBS/codex"
# Output shape copied from this station's real `claude --version`:
# "2.1.296 (Claude Code)"; `update` is the native self-updater.
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
case "$1" in
    update)
        echo "claude update" >> "$STUB_STATE/claude.update.log"
        [ -f "$STUB_STATE/claude.update.fail" ] && { echo "update failed: EACCES" >&2; exit 1; }
        [ -f "$STUB_STATE/claude.update.partial" ] && { cat "$STUB_STATE/claude.update.partial" > "$STUB_STATE/claude.ver"; echo "update failed: half written" >&2; exit 1; }
        if [ -f "$STUB_STATE/claude.update.stuck" ]; then cat "$STUB_STATE/claude.update.stuck" > "$STUB_STATE/claude.ver"
        else cp "$STUB_STATE/claude.latest" "$STUB_STATE/claude.ver"; fi ;;
    *) printf '%s (Claude Code)\n' "$(cat "$STUB_STATE/claude.ver")" ;;
esac
EOF
cat > "$STUBS/npm" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "view @openai/codex")           cat "$STUB_STATE/codex.latest" ;;
    "view @anthropic-ai/claude-code") cat "$STUB_STATE/claude.latest" ;;
    "root -g") cat "$STUB_STATE/npm.root" ;;
    "install -g")
        echo "npm $*" >> "$STUB_STATE/npm.log"
        [ -f "$STUB_STATE/npm.fail" ] && { echo "npm ERR! EACCES" >&2; exit 243; }
        [ "$3" = "@openai/codex@latest" ] && cp "$STUB_STATE/codex.latest" "$STUB_STATE/codex.ver" ;;
    *) echo 1.0.0 ;;
esac
EOF
cat > "$STUBS/bun" <<'EOF'
#!/bin/sh
case "$1" in
    upgrade) echo "bun upgrade" >> "$STUB_STATE/bun.log"; echo "error: EACCES: permission denied, rename '/usr/bin/bun'" >&2; exit 1 ;;
    *) echo 1.2.3 ;;
esac
EOF
printf '#!/bin/sh\nprintf "v20.1.0\\n"\n' > "$STUBS/node"
chmod +x "$STUBS/claude" "$STUBS/npm" "$STUBS/bun" "$STUBS/node" "$NPMROOT/codex.js"
export STUB_STATE="$STATE"

# run_only <item> — output of `himmel-update.sh --only <item>`, rc in $RC
RC=0
run_only() {
    RC=0
    OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" bash scripts/himmel-update.sh --only "$1" 2>&1)" || RC=$?
}
has() { grep -qE -- "$1" <<< "$OUT"; }

reset_state() {
    printf '%s\n' "$TMP/npmroot/lib/node_modules" > "$STATE/npm.root"
    printf '0.100.0\n' > "$STATE/codex.ver"
    printf '0.200.0\n' > "$STATE/codex.latest"
    printf '2.1.100\n' > "$STATE/claude.ver"
    printf '2.1.296\n' > "$STATE/claude.latest"
    rm -f "$STATE/npm.log" "$STATE/npm.fail" "$STATE/claude.update.log" "$STATE/claude.update.fail" "$STATE/claude.update.stuck" "$STATE/claude.update.partial"
}

echo "codex CLI: upgraded through its install method"
reset_state
run_only clis
if [ "$RC" -eq 0 ] && has '^    codex +updated +0\.100\.0 -> 0\.200\.0' \
    && grep -q 'install -g @openai/codex@latest' "$STATE/npm.log" 2>/dev/null; then
    assert_pass "older codex is upgraded through npm and the table says updated"
else
    assert_fail "older codex → npm upgrade + 'updated' row (rc=$RC): $OUT"
fi

reset_state
printf '0.200.0\n' > "$STATE/codex.ver"
run_only clis
if [ "$RC" -eq 0 ] && has '^    codex +up-to-date' && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "already-current codex reads up-to-date and runs no install"
else
    assert_fail "current codex → up-to-date, no install (rc=$RC): $OUT"
fi

reset_state
touch "$STATE/npm.fail"
run_only clis
if has '^    codex +failed' && has 'npm install -g @openai/codex@latest'; then
    assert_pass "a failing npm install is a failed row naming the manual command"
else
    assert_fail "failed install → failed row + manual command: $OUT"
fi

reset_state
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
run_only clis
if has 'HELD' && has '^    codex +skipped' && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "vm.mode=none holds the codex upgrade (VM-first gate)"
else
    assert_fail "vm.mode=none → HELD, no install: $OUT"
fi
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"

echo "npm Codex: the active npm must own the selected installation"
reset_state
printf '%s\n' "$TMP/other-node/lib/node_modules" > "$STATE/npm.root"
run_only clis
if has 'needs you.*npm.*selected Codex' && [ ! -f "$STATE/npm.log" ] \
    && [ "$(cat "$STATE/codex.ver")" = '0.100.0' ]; then
    assert_pass "a mismatched npm root never mutates either Codex installation"
else
    assert_fail "mismatched npm root → needs-you, no installation: $OUT"
fi

reset_state
cat > "$STUBS/readlink" <<'EOF'
#!/bin/sh
[ "$1" = '-f' ] && exit 1
exec /usr/bin/readlink "$@"
EOF
chmod +x "$STUBS/readlink"
run_only clis
if has '^    codex +updated' && grep -q 'install -g' "$STATE/npm.log" 2>/dev/null; then
    assert_pass "npm Codex symlinks resolve with BSD-style readlink"
else
    assert_fail "BSD readlink → npm owner and upgrade: $OUT"
fi
rm -f "$STUBS/readlink"

echo "claude CLI: held to the console-launch floor and brought current (HIMMEL-5501)"
reset_state
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +updated +2\.1\.100 -> 2\.1\.296' \
    && [ -f "$STATE/claude.update.log" ] && [ "$(cat "$STATE/claude.ver")" = '2.1.296' ]; then
    assert_pass "below-floor claude is updated through its own updater and the table says updated"
else
    assert_fail "below floor → claude update + 'updated' row (rc=$RC): $OUT"
fi

reset_state
printf '2.1.296\n' > "$STATE/claude.ver"
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +up-to-date' && [ ! -f "$STATE/claude.update.log" ]; then
    assert_pass "current claude reads up-to-date and runs no updater"
else
    assert_fail "current claude → up-to-date, no update (rc=$RC): $OUT"
fi

reset_state
printf '2.1.290\n' > "$STATE/claude.ver"
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +updated +2\.1\.290 -> 2\.1\.296' && [ -f "$STATE/claude.update.log" ]; then
    assert_pass "claude above the floor but behind latest is still brought current"
else
    assert_fail "above floor, behind latest → updated (rc=$RC): $OUT"
fi

reset_state
printf '2.1.300\n' > "$STATE/claude.ver"
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +up-to-date' && [ ! -f "$STATE/claude.update.log" ]; then
    assert_pass "claude newer than the registry latest is never downgraded"
else
    assert_fail "newer than latest → up-to-date, no update (rc=$RC): $OUT"
fi

reset_state
printf '2.1.200\n' > "$STATE/claude.update.stuck"
run_only clis
if [ "$RC" -ne 0 ] && has 'still below the floor' && has '^    claude +failed'; then
    assert_pass "an update that leaves claude below the floor fails loudly (rc != 0)"
else
    assert_fail "stuck below floor → FAIL + failed row + rc 1 (rc=$RC): $OUT"
fi

reset_state
printf '2.1.285\n' > "$STATE/claude.update.stuck"
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +updated +2\.1\.100 -> 2\.1\.285' && has 'latest is 2\.1\.296'; then
    assert_pass "an update that lands above the floor but short of latest says so"
else
    assert_fail "above floor, short of latest → updated + latest note (rc=$RC): $OUT"
fi

reset_state
printf 'unavailable\n' > "$STATE/claude.latest"
printf '2.1.285\n' > "$STATE/claude.update.stuck"
run_only clis
if [ "$RC" -eq 0 ] && has '^    claude +updated +2\.1\.100 -> 2\.1\.285' && has 'cannot confirm current'; then
    assert_pass "an upgrade with no readable registry latest is never labelled current"
else
    assert_fail "unknown latest → updated + cannot confirm current (rc=$RC): $OUT"
fi

reset_state
printf '2.1.290\n' > "$STATE/claude.update.partial"
run_only clis
if [ "$RC" -ne 0 ] && has '^    claude +failed' && has 'updater exited 1'; then
    assert_pass "a failing updater is never reported as updated even if the version moved"
else
    assert_fail "updater rc 1 with moved version → failed row + rc 1 (rc=$RC): $OUT"
fi

reset_state
touch "$STATE/claude.update.fail"
run_only clis
if [ "$RC" -ne 0 ] && has 'still below the floor' && has 'claude update'; then
    assert_pass "a failing claude updater below the floor fails loudly and names the remedy"
else
    assert_fail "failing updater below floor → FAIL + remedy (rc=$RC): $OUT"
fi

reset_state
RC=0
# --check needs a reachable origin: a throwaway bare repo with the clone's HEAD pushed.
git -C "$CLONE" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m init >/dev/null 2>&1
git init --quiet --bare "$TMP/origin.git" >/dev/null 2>&1
git -C "$CLONE" remote add origin "$TMP/origin.git" >/dev/null 2>&1
git -C "$CLONE" push --quiet -u origin HEAD >/dev/null 2>&1
OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" bash scripts/himmel-update.sh --check 2>&1)" || RC=$?
if has '^    claude +skipped .*2\.1\.100 -> 2\.1\.296' && [ ! -f "$STATE/claude.update.log" ] \
    && [ "$(cat "$STATE/claude.ver")" = '2.1.100' ]; then
    assert_pass "--check reports a below-floor claude and never updates it"
else
    assert_fail "--check → report only (rc=$RC): $OUT"
fi

reset_state
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
run_only clis
if has 'HELD' && has '^    claude +skipped' && [ ! -f "$STATE/claude.update.log" ]; then
    assert_pass "vm.mode=none holds the claude update (VM-first gate)"
else
    assert_fail "vm.mode=none → claude HELD, no update: $OUT"
fi
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"

reset_state
cat > "$STUBS/pacman" <<'EOF'
#!/bin/sh
case "$1" in
    -Qo) [ "$2" = "$STUB_CLAUDE_PATH" ] && exit 0; exit 1 ;;
    -Qoq) echo claude-code ;;
    *) echo forbidden-package-upgrade >> "$STUB_STATE/pm.log"; exit 1 ;;
esac
EOF
chmod +x "$STUBS/pacman"
STUB_CLAUDE_PATH="$(cd "$STUBS" && pwd -P)/claude" || exit 1  # the updater asks pacman about the physical path (/tmp is /private/tmp on macOS)
export STUB_CLAUDE_PATH
run_only clis
if has 'needs you.*sudo pacman -Syu claude-code' && [ ! -f "$STATE/pm.log" ] \
    && [ ! -f "$STATE/claude.update.log" ] && [ "$RC" -ne 0 ]; then
    assert_pass "package-manager claude prints the needs-you command, never updates, still fails below the floor"
else
    assert_fail "pacman claude → needs-you, no updater, rc != 0 (rc=$RC): $OUT"
fi
rm -f "$STUBS/pacman"

echo "bun: report only — a version off the .bun-version pin is never self-upgraded (HIMMEL-7092)"
reset_state
run_only toolchain
if has 'bun 1\.2\.3 differs from the \.bun-version pin \(1\.4\.4\) — NOT self-upgrading' \
    && has 'fix: bash scripts/machine-setup/ubuntu\.sh' && has '^    bun +skipped' \
    && ! has 'bun\.sh/install' && [ ! -f "$STATE/bun.log" ]; then
    assert_pass "off-pin bun is reported with the pinned-installer remedy, a skipped row and no bun upgrade"
else
    assert_fail "off-pin bun → NOT self-upgrading + remedy + skipped row, no upgrade run: $OUT"
fi

# bun owned by the system package manager: say who updates it, never the curl installer.
cat > "$STUBS/pacman" <<'EOF'
#!/bin/sh
[ "$1" = "-Qo" ] && { echo "$2 is owned by bun 1.2.3-1"; exit 0; }
exit 1
EOF
chmod +x "$STUBS/pacman"
run_only toolchain
if has 'fix: sudo pacman -Syu bun' && has 'owned by pacman' && ! has 'bun\.sh/install' && [ ! -f "$STATE/bun.log" ]; then
    assert_pass "pacman-owned bun names the exact pacman command and never self-upgrades"
else
    assert_fail "pacman-owned bun → 'fix: sudo pacman -Syu bun', no upgrade: $OUT"
fi
rm -f "$STUBS/pacman"

echo "bun: prefer the user install, warn on divergent versions, a pin match is up-to-date"
mkdir -p "$HOME/.bun/bin"
cat > "$HOME/.bun/bin/bun" <<'EOF'
#!/bin/sh
case "$1" in
    upgrade) echo user-bun >> "$STUB_STATE/bun.log" ;;
    *) echo 1.4.4 ;;
esac
EOF
chmod +x "$HOME/.bun/bin/bun"
run_only toolchain
if has 'bun 1\.4\.4 matches the \.bun-version pin' && [ ! -f "$STATE/bun.log" ] && has '^    bun +up-to-date'; then
    assert_pass "the user Bun wins over PATH; at the pin it is up-to-date and its updater never runs"
else
    assert_fail "preferred user Bun at the pin → current row, no upgrade: $OUT"
fi
if has 'WARN.*bun.*1\.4\.4.*1\.2\.3'; then
    assert_pass "different user and PATH Bun versions produce a WARN"
else
    assert_fail "dual Bun → differing-version WARN: $OUT"
fi
rm -rf "$HOME/.bun"

reset_state
cat > "$STUBS/pacman" <<'EOF'
#!/bin/sh
case "$1" in
    -Qo) exit 0 ;;
    -Qoq) echo codex ;;
    *) echo forbidden-package-upgrade >> "$STUB_STATE/pm.log"; exit 1 ;;
esac
EOF
chmod +x "$STUBS/pacman"
run_only clis
if has 'needs you.*sudo pacman -Syu codex' && [ ! -f "$STATE/pm.log" ] && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "package-manager Codex requires the user and never invokes an updater"
else
    assert_fail "package-manager Codex → needs-you remedy, no updater: $OUT"
fi
rm -f "$STUBS/pacman"

echo "standalone Codex: use only its advertised self-updater"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/bin/sh
case "$1" in
    --version) printf 'codex-cli %s\n' "$(cat "$STUB_STATE/codex.ver")" ;;
    --help) [ -f "$STUB_STATE/self-update" ] && echo '  update  Update Codex to the latest version' ;;
    update) echo native-update >> "$STUB_STATE/native.log"; cp "$STUB_STATE/codex.latest" "$STUB_STATE/codex.ver" ;;
esac
exit 0
EOF
chmod +x "$HOME/.local/bin/codex"
export CODEX_BIN="$HOME/.local/bin/codex"
reset_state
touch "$STATE/self-update"
run_only clis
if has '^    codex +updated' && [ -f "$STATE/native.log" ] && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "standalone Codex uses its own advertised updater, not npm"
else
    assert_fail "standalone Codex → native self-update, no npm: $OUT"
fi
reset_state
rm -f "$STATE/native.log"
cat > "$STUBS/pacman" <<'EOF'
#!/bin/sh
case "$1" in -Qo) exit 0 ;; -Qoq) echo codex ;; *) exit 1 ;; esac
EOF
chmod +x "$STUBS/pacman"
run_only clis
if has 'needs you.*sudo pacman -Syu codex' && [ ! -f "$STATE/native.log" ]; then
    assert_pass "a local-bin alias to a package-owned Codex never uses its self-updater"
else
    assert_fail "package-owned Codex alias → manual remedy, no native update: $OUT"
fi
rm -f "$STUBS/pacman" "$STATE/native.log"
reset_state
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
run_only clis
if has 'HELD' && [ ! -f "$STATE/native.log" ]; then
    assert_pass "standalone Codex update is held without VM proof"
else
    assert_fail "standalone without VM proof → HELD, no self-update: $OUT"
fi
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
rm -f "$STATE/self-update"
run_only clis
if has 'needs you.*reinstall' && [ ! -f "$STATE/native.log" ] && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "standalone without an updater prints its reinstall remedy"
else
    assert_fail "standalone without updater → needs-you reinstall remedy: $OUT"
fi
unset CODEX_BIN

echo "missing @himmel plugins: install line + table row"
cat > "$TMP/market.json" <<'EOF'
{"name":"himmel","plugins":[{"name":"alpha"},{"name":"himmel-bus"}]}
EOF
cat > "$TMP/installed.json" <<'EOF'
{"plugins":{"alpha@himmel":[{"version":"1.0.0"}]}}
EOF
RC=0
OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" HIMMEL_MARKETPLACE_JSON="$TMP/market.json" \
    HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed.json" bash scripts/himmel-update.sh --only plugins 2>&1)" || RC=$?
if has '^    plugins +skipped .*claude plugin install himmel-bus@himmel'; then
    assert_pass "missing plugin gets a table row carrying its exact install command"
else
    assert_fail "missing plugin → table row with install line (rc=$RC): $OUT"
fi
printf '{"plugins":{"alpha@himmel":[{"version":"1.0.0"}],"himmel-bus@himmel":[{"version":"1.0.0"}]}}\n' > "$TMP/installed.json"
OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" HIMMEL_MARKETPLACE_JSON="$TMP/market.json" \
    HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed.json" bash scripts/himmel-update.sh --only plugins 2>&1)" || RC=$?
if has '^    plugins +up-to-date'; then
    assert_pass "all plugins installed reads up-to-date"
else
    assert_fail "all installed → up-to-date row: $OUT"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
