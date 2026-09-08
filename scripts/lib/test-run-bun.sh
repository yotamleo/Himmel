#!/usr/bin/env bash
# Smoke test for the per-plugin MCP bun launchers (marketplace/plugins/*/run-bun.sh,
# HIMMEL-639). Mirrors scripts/lib/test-run-node.sh. Runs every assertion against
# BOTH shipped copies so the two stay byte-identical and neither regresses.
# Usage: bash scripts/lib/test-run-bun.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
W1="$REPO_ROOT/marketplace/plugins/luna-correlate/run-bun.sh"
W2="$REPO_ROOT/marketplace/plugins/telegram-himmel/run-bun.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# Minimal utils PATH for the hermetic cases (HIMMEL-2524).
#
# This used to be `dirname "$(command -v sort)"` — adopting a whole system
# directory as the allowlist. On Arch/CachyOS that resolves to /usr/bin, which
# also ships bun, so the "minimal utils PATH" handed the launcher a REAL bun:
# _resolve_bun's step 1 (`command -v bun`) won immediately, the fake bun in
# RESOLVE_BUN_PROBE_DIRS never ran, and the no-bun case had a bun. The tell was
# bun's own message, `error: Script not found "start"`, in the case that is
# supposed to prove no bun is reachable.
#
# Build the allowlist PER TOOL instead, resolved individually from the live
# PATH, so it cannot re-admit bun no matter which directory a distro ships it
# in. Same family as HIMMEL-2470 (node) and HIMMEL-2520 (bun via PATH scrub);
# the inverse mistake to those, and the reason "build an allowlist" is not
# sufficient advice on its own — the allowlist must never be a directory.
#
# Tool set derived empirically, not guessed: a logging-shim dir over the whole
# suite recorded `cat date mkdir` (mkdir + date from run-bun.sh's fail-closed
# breadcrumb; cat from the fake bun's own echo-stdin branch). Re-derive the
# same way if the launcher gains a dependency.
#
# Shims are WRAPPER SCRIPTS, not copies or symlinks: on MSYS/Cygwin a copied or
# symlinked binary no longer resolves its sibling DLLs, so it would break the
# Windows station while looking correct here.
UTILS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/himmel-run-bun-utils.XXXXXX")" || {
    printf 'FATAL: could not create the utils allowlist dir\n' >&2; exit 1; }
# Refuse an empty UTILS_DIR before anything builds a path on it. Unchecked, a
# failed mktemp leaves it empty and every "$UTILS_DIR/<tool>" below collapses to
# an absolute /<tool> — the shim writes would target root paths and the EXIT trap
# would rm -rf a path that is not the scratch dir. Templated, too: a bare
# `mktemp -d` is not portable to BSD/macOS.
case "$UTILS_DIR" in
    /tmp/himmel-run-bun-utils.*|"${TMPDIR:-/tmp}"/himmel-run-bun-utils.*) ;;
    *) printf 'FATAL: refusing an unexpected utils allowlist dir: %s\n' "$UTILS_DIR" >&2; exit 1 ;;
esac
trap 'rm -rf "$UTILS_DIR"' EXIT
_bash_abs="$(command -v bash)"
for _t in bash cat date mkdir; do
    _src="$(command -v "$_t")" || { printf 'FATAL: required test tool not found: %s\n' "$_t" >&2; exit 1; }
    printf '#!%s\nexec "%s" "$@"\n' "$_bash_abs" "$_src" > "$UTILS_DIR/$_t"
    chmod +x "$UTILS_DIR/$_t"
done
# The whole point of the allowlist: a real bun must NOT be reachable through it.
if [ -e "$UTILS_DIR/bun" ]; then printf 'FATAL: utils allowlist admitted a bun\n' >&2; exit 1; fi

# A fake bun: route on the first arg so we can exercise args/stdin/exit.
make_fake_bun() {
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/bun" <<'EOF'
#!/bin/sh
case "$1" in
  echo-args) shift; printf 'args:%s\n' "$*" ;;
  echo-stdin) cat ;;
  exit42) exit 42 ;;
  *) printf 'ran:%s\n' "$1" ;;
esac
EOF
    chmod +x "$dir/bun"
}

for RUN in "$W1" "$W2"; do
    [ -f "$RUN" ] || { fail "$RUN not found"; continue; }
    label="${RUN#"$REPO_ROOT"/marketplace/plugins/}"; label="${label%/run-bun.sh}"
    echo "== $label: args pass through + stdout =="
    tmp="$(mktemp -d)"; make_fake_bun "$tmp/bin"
    out="$(PATH="$UTILS_DIR" RESOLVE_BUN_PROBE_DIRS="$tmp/bin" bash "$RUN" echo-args A B)"
    if [ "$out" = "args:A B" ]; then pass "args -> '$out'"; else fail "args -> '$out'"; fi
    rm -rf "$tmp"

    echo "== $label: exit code propagates =="
    tmp="$(mktemp -d)"; make_fake_bun "$tmp/bin"
    PATH="$UTILS_DIR" RESOLVE_BUN_PROBE_DIRS="$tmp/bin" bash "$RUN" exit42 >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 42 ]; then pass "exit -> 42"; else fail "exit -> $rc (want 42)"; fi
    rm -rf "$tmp"

    echo "== $label: stdin reaches the child (stdio MCP) =="
    tmp="$(mktemp -d)"; make_fake_bun "$tmp/bin"
    out="$(printf 'PAYLOAD-123' | PATH="$UTILS_DIR" RESOLVE_BUN_PROBE_DIRS="$tmp/bin" bash "$RUN" echo-stdin)"
    if [ "$out" = "PAYLOAD-123" ]; then pass "stdin -> '$out'"; else fail "stdin -> '$out'"; fi
    rm -rf "$tmp"

    echo "== $label: no bun -> fail-closed (exit 127, silent, one log line) =="
    tmp="$(mktemp -d)"; cdir="$tmp/claude"
    out="$(PATH="$UTILS_DIR" RESOLVE_BUN_PROBE_DIRS="" CLAUDE_DIR="$cdir" bash "$RUN" run start 2>"$tmp/err.txt")"
    rc=$?
    err="$(cat "$tmp/err.txt")"
    logc=0; [ -f "$cdir/himmel-bun.log" ] && logc="$(wc -l < "$cdir/himmel-bun.log" | tr -d ' ')"
    if [ "$rc" -eq 127 ] && [ -z "$out" ] && [ -z "$err" ] && [ "$logc" = "1" ]; then
        pass "no-bun -> rc127, silent, 1 log line"
    else
        fail "no-bun -> rc=$rc out='$out' err='$err' logc=$logc"
    fi
    rm -rf "$tmp"

    # POSITIVE CONTROL (HIMMEL-2524): prove the bun that ran is the FAKE one from
    # RESOLVE_BUN_PROBE_DIRS, not a real bun reached through the utils PATH. The
    # cases above assert on behaviour a real bun would merely FAIL differently at,
    # so a utils dir that re-admits a real bun made them red without ever saying
    # why. `ran:<token>` is emitted by nothing but the fake, and the token is
    # distinctive enough that no real bun subcommand could produce it.
    echo "== $label: POSITIVE CONTROL — the fake bun is the one that runs =="
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-run-bun-pc.XXXXXX")" || {
        printf 'FATAL: could not create the positive-control scratch dir\n' >&2; exit 1; }
    make_fake_bun "$tmp/bin"
    out="$(PATH="$UTILS_DIR" RESOLVE_BUN_PROBE_DIRS="$tmp/bin" bash "$RUN" himmel-2524-sentinel 2>&1)"
    if [ "$out" = "ran:himmel-2524-sentinel" ]; then
        pass "fake bun ran -> '$out'"
    else
        fail "fake bun did NOT run -> '$out' (a real bun is reachable through the utils PATH)"
    fi
    rm -rf "$tmp"

    # And the utils PATH alone must resolve NO bun at all.
    if PATH="$UTILS_DIR" command -v bun >/dev/null 2>&1; then
        fail "utils PATH resolves a real bun: $(PATH="$UTILS_DIR" command -v bun)"
    else
        pass "utils PATH resolves no bun"
    fi
done

echo "== both wrappers are byte-identical (no drift) =="
if cmp -s "$W1" "$W2"; then pass "luna-correlate/run-bun.sh == telegram-himmel/run-bun.sh"; else fail "wrappers diverged"; fi

echo "== each .mcp.json routes through the gate then the wrapper (no bare bun) =="
for p in luna-correlate telegram-himmel; do
    mcp="$REPO_ROOT/marketplace/plugins/$p/.mcp.json"
    cmd="$(jq -r '(.mcpServers // {}) | to_entries[0].value.command' "$mcp" 2>/dev/null)"
    a0="$(jq -r '(.mcpServers // {}) | to_entries[0].value.args[0]' "$mcp" 2>/dev/null)"
    # args[1] is the gate-var list — a per-plugin copy/paste typo here (e.g. luna
    # left on the telegram var) would make the documented opt-in var silently never
    # start the server, so pin it to the exact string each README documents.
    a1="$(jq -r '(.mcpServers // {}) | to_entries[0].value.args[1]' "$mcp" 2>/dev/null)"
    case "$p" in
        luna-correlate)  want_gv="HIMMEL_MCP_LUNA_CORRELATE" ;;
        telegram-himmel) want_gv="HIMMEL_MCP_TELEGRAM TELEGRAM_OWN_POLLER" ;;
    esac
    # run-bun.sh must still appear later in the arg vector (gate exec's it when opted in).
    has_run="$(jq -r '(.mcpServers // {}) | to_entries[0].value.args | any(. == "${CLAUDE_PLUGIN_ROOT}/run-bun.sh")' "$mcp" 2>/dev/null)"
    # shellcheck disable=SC2016  # literal ${CLAUDE_PLUGIN_ROOT} must NOT expand here
    if [ "$cmd" = "bash" ] && [ "$a0" = '${CLAUDE_PLUGIN_ROOT}/mcp-gate.sh' ] && [ "$a1" = "$want_gv" ] && [ "$has_run" = "true" ]; then
        pass "$p .mcp.json wired: gate($a1) -> run-bun.sh"
    else
        fail "$p .mcp.json command='$cmd' args[0]='$a0' args[1]='$a1' (want '$want_gv') has_run='$has_run'"
    fi
done

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
