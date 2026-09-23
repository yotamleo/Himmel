#!/usr/bin/env bash
# HIMMEL-3312 S12: uninstall.sh running from a standalone BUNDLE (REPO_ROOT
# with no clone behind it, no scripts/telegram) instead of a clone. The
# sibling test-uninstall*.sh suites all run the real repo's uninstall.sh in
# place, where REPO_ROOT == the clone and scripts/telegram always exists —
# none of them exercise the bundle branches this suite targets.
#
# The bundle is built by copying the 15-file POSIX closure (design doc
# HIMMEL-3312-standalone-undo.md §3.2) from THIS checkout into a scratch dir,
# mirroring the real relative layout, so the bundle's own uninstall.sh can
# source its own scripts/lib/*.sh exactly as it does in the real clone.
#
# Never sets HIMMEL_UNINSTALL_REAL_HOME. Every invocation runs under a
# scratch HOME; the fake supervisor is a harmless `sleep` started under
# `exec -a`, and this suite kills whatever it starts.
set -uo pipefail

FAILED=0
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}
assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

SRC_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$SRC_SCRIPTS/.." && pwd)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-standalone.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || exit 1
trap 'kill "${FAKE_SUP_PID:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT

REAL_HOME="$HOME"
unset HIMMEL_UNINSTALL_REAL_HOME
SUITE_HOME="$TMP/home"
mkdir -p "$SUITE_HOME"
export HOME="$SUITE_HOME"
mkdir -p "$TMP/cwd"
cd "$TMP/cwd" || exit 1
case "$REAL_HOME" in
    "$TMP"|"$TMP"/*)
        echo "FAIL the operator's real \$HOME resolved under this suite's \$TMP — refusing to proceed"
        FAILED=$((FAILED + 1))
        ;;
    *) echo "PASS the operator's real \$HOME is not under this suite's \$TMP" ;;
esac

# --- Build the bundle: the 15-file POSIX closure, mirrored relative layout --
BUNDLE="$TMP/prov/uninstall"

build_bundle() {
    mkdir -p "$BUNDLE/scripts/lib" "$BUNDLE/scripts/install" "$BUNDLE/scripts/machine-setup" "$BUNDLE/docs/setup"
    cp "$SRC_SCRIPTS/uninstall.sh" "$BUNDLE/scripts/uninstall.sh"
    cp "$SRC_SCRIPTS/install/uninstall-manifest.tsv" "$BUNDLE/scripts/install/uninstall-manifest.tsv"
    for f in provenance-read.sh provenance.sh canon-path.sh qmd-bin.sh \
             unwire-statusline.sh unwire-himmel-repo.sh unwire-luna-vault.sh \
             unwire-handover-dir.sh unwire-pretooluse-hooks.sh unwire-hud-config.sh \
             unwire-user-claude-md.sh; do
        cp "$SRC_SCRIPTS/lib/$f" "$BUNDLE/scripts/lib/$f"
    done
    cp "$SRC_SCRIPTS/machine-setup/uninstall-plugins.sh" "$BUNDLE/scripts/machine-setup/uninstall-plugins.sh"
    cp "$SRC_ROOT/docs/setup/settings-template.json" "$BUNDLE/docs/setup/settings-template.json"
    chmod +x "$BUNDLE/scripts/uninstall.sh"
    cat > "$BUNDLE/bundle.json" <<'JSON'
{"marker":"himmel-standalone-uninstaller/1","himmel_root":"/nonexistent/himmel-bundlejson-fallback"}
JSON
}

build_bundle
if [ -x "$BUNDLE/scripts/uninstall.sh" ] && [ -f "$BUNDLE/scripts/lib/provenance.sh" ]; then
    echo "PASS bundle fixture built ($BUNDLE)"
else
    echo "FAIL bundle fixture incomplete"; FAILED=$((FAILED + 1))
fi

PROV_DIR="$TMP/prov"
export HIMMEL_PROVENANCE_DIR="$PROV_DIR"
HOME_CANON="$(cd "$SUITE_HOME" && pwd -P)"
mkdir -p "$PROV_DIR"
jq -nc --arg home "$HOME_CANON" \
    '{t:"2026-01-01T00:00:00Z",iid:"test-iid-1",op:"install-begin",himmel_root:"/nonexistent/himmel",himmel_head:"",version:"",argv:[],home:$home,claude_config_dir:"",target:"",platform:"",writer:"test"}' \
    > "$PROV_DIR/provenance.jsonl"

run_bundle() {
    ( unset HIMMEL_UNINSTALL_REPO_ROOT
      bash "$BUNDLE/scripts/uninstall.sh" "$@" </dev/null 2>&1 )
}

# --- (a) footprint line for himmel-clone names the ledger's himmel_root, ---
# --- annotated "(not present)", not the bundle dir --------------------------
out=$(run_bundle --dry-run --skip-plugins --skip-hooks --skip-tasks)
assert_has "(a) footprint names the clone from the ledger" "/nonexistent/himmel (not present)" "$out"
assert_not_has "(a) footprint does not name the bundle dir" "$BUNDLE — the himmel clone" "$out"

# --- (b) fake supervisor is stopped directly (no scripts/telegram in the ---
# --- bundle): --yes run exits 0 and the process is gone --------------------
BRIDGE_ROOT="$TMP/bridge"
mkdir -p "$BRIDGE_ROOT"
bash -c 'exec -a "bun supervisor.ts" sleep 300' &
FAKE_SUP_PID=$!
# give exec -a a moment to land before we read it back via /proc
for _i in 1 2 3 4 5; do
    [ -r "/proc/$FAKE_SUP_PID/cmdline" ] && break
    sleep 0.2
done
printf '%s\n' "$FAKE_SUP_PID" > "$BRIDGE_ROOT/supervisor.pid"
out=$(BRIDGE_ROOT="$BRIDGE_ROOT" run_bundle --yes --skip-plugins --skip-hooks --skip-tasks --skip-settings)
rc=$?
assert_rc "(b) direct-stop run exits 0" 0 "$rc"
if kill -0 "$FAKE_SUP_PID" 2>/dev/null; then
    echo "FAIL (b) fake supervisor still running after the run"
    FAILED=$((FAILED + 1))
    kill "$FAKE_SUP_PID" 2>/dev/null
else
    echo "PASS (b) fake supervisor process is gone"
fi
assert_has "(b) reports stopping the supervisor directly" "no bundled scripts/telegram" "$out"

# --- (c) a pidfile naming an unrelated process is refused, never signalled -
bash -c 'sleep 300' &
UNRELATED_PID=$!
for _i in 1 2 3 4 5; do
    [ -r "/proc/$UNRELATED_PID/cmdline" ] && break
    sleep 0.2
done
BRIDGE_ROOT2="$TMP/bridge2"
mkdir -p "$BRIDGE_ROOT2"
printf '%s\n' "$UNRELATED_PID" > "$BRIDGE_ROOT2/supervisor.pid"
out=$(BRIDGE_ROOT="$BRIDGE_ROOT2" run_bundle --yes --skip-plugins --skip-hooks --skip-tasks --skip-settings)
rc=$?
assert_rc "(c) unrelated-pid run halts" 2 "$rc"
assert_has "(c) refuses to signal a recycled pid" "refusing to signal a recycled pid" "$out"
if kill -0 "$UNRELATED_PID" 2>/dev/null; then
    echo "PASS (c) unrelated process was not killed"
else
    echo "FAIL (c) unrelated process was killed"; FAILED=$((FAILED + 1))
fi
kill "$UNRELATED_PID" 2>/dev/null

# --- (d)/(e) purge removes the bundle LAST, only when it carries the marker
rm -f "$BRIDGE_ROOT2/supervisor.pid" "$BRIDGE_ROOT/supervisor.pid"

out=$(run_bundle --yes --skip-plugins --skip-hooks --skip-tasks --skip-settings)
rc=$?
assert_rc "(d) plain --yes run exits 0" 0 "$rc"
if [ -d "$BUNDLE" ]; then
    echo "PASS (d) --yes alone keeps the bundle"
else
    echo "FAIL (d) --yes alone removed the bundle"; FAILED=$((FAILED + 1))
fi

out=$(run_bundle --yes --purge-state --skip-plugins --skip-hooks --skip-tasks --skip-settings)
rc=$?
assert_rc "(d) --purge-state run exits 0" 0 "$rc"
if [ -d "$BUNDLE" ]; then
    echo "FAIL (d) --purge-state left the bundle behind"; FAILED=$((FAILED + 1))
else
    echo "PASS (d) --purge-state removed the bundle"
fi

# (e): a marker-less directory at the same path survives --purge-state
build_bundle
echo '{}' > "$BUNDLE/bundle.json"
if [ -d "$BUNDLE" ]; then
    echo "PASS (e) marker-less fixture in place before purge"
else
    echo "FAIL (e) could not recreate a marker-less fixture"; FAILED=$((FAILED + 1))
fi
# the marker-less bundle.json above still has scripts/uninstall.sh sitting
# beside it, so run that same self-referential entrypoint: it must find its
# own bundle.json marker-less and leave itself alone.
out=$(run_bundle --yes --purge-state --skip-plugins --skip-hooks --skip-tasks --skip-settings)
rc=$?
assert_rc "(e) purge run against a marker-less bundle exits 0" 0 "$rc"
if [ -d "$BUNDLE" ]; then
    echo "PASS (e) marker-less directory survives --purge-state"
else
    echo "FAIL (e) marker-less directory was removed"; FAILED=$((FAILED + 1))
fi
assert_has "(e) reports it as kept, not himmel's" "kept: not himmel's" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
