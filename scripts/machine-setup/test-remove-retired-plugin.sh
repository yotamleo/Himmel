#!/usr/bin/env bash
# test-remove-retired-plugin.sh — hermetic tests for
# scripts/machine-setup/remove-retired-plugin.sh (HIMMEL-2033).
#
# One case per branch of the contract: absent -> silent; present + "y" -> both
# removal commands, in order; present + "n" -> neither; non-TTY -> advisory only.
# The `claude` CLI is a PATH-less stub addressed via HIMMEL_UPDATE_CLAUDE_BIN
# that appends every invocation to a log — the real CLI is never touched.
#
# Usage: bash scripts/machine-setup/test-remove-retired-plugin.sh
# Bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/machine-setup/remove-retired-plugin.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

# grepq <text> [grep-args...] — match with no pipeline, so a match that lands
# early can't be reported as a failed pipeline under pipefail (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# make_claude <dir> <present|absent> [uninstall-rc] — a claude stub whose
# `plugin list` prints the plugin SPEC and `plugin marketplace list` prints the
# MARKETPLACE name (the real CLI's two different shapes), and which logs every
# call to <dir>/calls.log. <uninstall-rc> (default 0) makes `plugin uninstall`
# fail, for the removal-ordering case.
make_claude() {
    local dir="$1" state="$2" un_rc="${3:-0}" specs='' markets=''
    mkdir -p "$dir"
    if [ "$state" = present ]; then specs='caveman@caveman'; markets='caveman'; fi
    cat > "$dir/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/calls.log"
case "\$1 \$2" in
  "plugin list")        printf '%s\n' "$specs" ;;
  "plugin marketplace") [ "\$3" = list ] && printf '%s\n' "$markets" ;;
  "plugin uninstall")   exit $un_rc ;;
esac
exit 0
STUB
    chmod +x "$dir/claude"
    : > "$dir/calls.log"
}

# An empty settings.json so the jq detector never fires from the real ~/.claude.
EMPTY_SETTINGS="$TMP/settings.json"
printf '{}\n' > "$EMPTY_SETTINGS"

run_case() { # <claude-dir> <stdin> [extra args...]
    local dir="$1" input="$2"; shift 2
    HIMMEL_UPDATE_CLAUDE_BIN="$dir/claude" \
    CLAUDE_USER_SETTINGS="$EMPTY_SETTINGS" \
    HIMMEL_RETIRED_PLUGIN_ASSUME_TTY="${ASSUME_TTY:-1}" \
        bash "$SCRIPT" "$@" <<< "$input" 2>&1
}

echo "== absent -> silent, rc 0, no removal calls =="
d="$TMP/absent"; make_claude "$d" absent
out="$(run_case "$d" '')"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "absent -> silent rc0"; else fail "absent -> rc=$rc, out: $out"; fi
if grepq "$(cat "$d/calls.log")" 'uninstall\|marketplace remove'; then
    fail "absent -> a removal command was invoked"
else
    pass "absent -> no removal command invoked"
fi

echo "== present + default (empty answer) -> uninstall then marketplace remove =="
d="$TMP/yes-default"; make_claude "$d" present
out="$(run_case "$d" '')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "present+default -> rc=$rc"
if grepq "$out" 'Remove now?'; then pass "present -> prompted"; else fail "present -> no prompt: $out"; fi
if grepq "$calls" 'plugin uninstall caveman@caveman'; then pass "default -> uninstall invoked"; else fail "default -> no uninstall: $calls"; fi
if grepq "$calls" 'plugin marketplace remove caveman'; then pass "default -> marketplace remove invoked"; else fail "default -> no marketplace remove: $calls"; fi
_u=$(grep -n 'plugin uninstall' <<< "$calls" | head -1 | cut -d: -f1)
_m=$(grep -n 'plugin marketplace remove' <<< "$calls" | head -1 | cut -d: -f1)
if [ -n "$_u" ] && [ -n "$_m" ] && [ "$_u" -lt "$_m" ]; then pass "default -> uninstall precedes marketplace remove"; else fail "default -> wrong order ($_u before $_m)"; fi

echo "== present + explicit y -> both removal commands =="
d="$TMP/yes"; make_claude "$d" present
run_case "$d" 'y' >/dev/null
calls="$(cat "$d/calls.log")"
if grepq "$calls" 'plugin uninstall caveman@caveman' && grepq "$calls" 'plugin marketplace remove caveman'; then
    pass "y -> both removal commands invoked"
else
    fail "y -> missing a removal command: $calls"
fi

echo "== present + n -> nothing removed =="
d="$TMP/no"; make_claude "$d" present
out="$(run_case "$d" 'n')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "present+n -> rc=$rc"
if grepq "$calls" 'plugin uninstall\|plugin marketplace remove'; then
    fail "n -> a removal command was invoked: $calls"
else
    pass "n -> no removal command invoked"
fi
if grepq "$out" 'kept'; then pass "n -> one-line keep notice"; else fail "n -> no keep notice: $out"; fi

echo "== a non-affirmative answer (typo) must NOT remove =="
d="$TMP/typo"; make_claude "$d" present
out="$(run_case "$d" 'q')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "typo answer -> rc=$rc"
if grepq "$calls" 'plugin uninstall\|plugin marketplace remove'; then
    fail "typo answer -> a removal command was invoked: $calls"
else
    pass "typo answer -> no removal command invoked"
fi
if grepq "$out" 'not y/yes'; then pass "typo answer -> explains why it kept"; else fail "typo answer -> no explanation: $out"; fi

echo "== EOF at the prompt must NOT be read as the [Y/n] default =="
d="$TMP/eof"; make_claude "$d" present
out="$(HIMMEL_UPDATE_CLAUDE_BIN="$d/claude" CLAUDE_USER_SETTINGS="$EMPTY_SETTINGS" \
       HIMMEL_RETIRED_PLUGIN_ASSUME_TTY=1 bash "$SCRIPT" </dev/null 2>&1)"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "EOF -> rc=$rc"
if grepq "$calls" 'plugin uninstall\|plugin marketplace remove'; then
    fail "EOF -> a removal command was invoked: $calls"
else
    pass "EOF -> no removal command invoked"
fi
if grepq "$out" 'no answer was read'; then pass "EOF -> explains the keep"; else fail "EOF -> no explanation: $out"; fi

echo "== a FAILED 'plugin list' must not let a marketplace-only removal through =="
d="$TMP/list-fails"; mkdir -p "$d"
cat > "$d/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/calls.log"
case "\$1 \$2" in
  "plugin list")        exit 1 ;;
  "plugin marketplace") [ "\$3" = list ] && printf '%s\n' 'caveman' ;;
esac
exit 0
STUB
chmod +x "$d/claude"; : > "$d/calls.log"
out="$(run_case "$d" '')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "list-fails -> rc=$rc"
if grepq "$calls" 'plugin marketplace remove'; then
    fail "list-fails -> marketplace removed on unknown plugin state (orphan risk): $calls"
else
    pass "list-fails -> marketplace removal refused"
fi
if grepq "$out" 'UNKNOWN'; then pass "list-fails -> reports the unknown state"; else fail "list-fails -> no unknown-state message: $out"; fi

echo "== present + non-interactive -> advisory only, no prompt, no removal =="
d="$TMP/nontty"; make_claude "$d" present
out="$(ASSUME_TTY=0 run_case "$d" '')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "non-interactive -> rc=$rc"
if grepq "$out" 'non-interactive: nothing was removed'; then pass "non-interactive -> advisory printed"; else fail "non-interactive -> $out"; fi
if grepq "$out" 'Remove now?'; then fail "non-interactive -> prompted anyway"; else pass "non-interactive -> no prompt"; fi
if grepq "$calls" 'plugin uninstall\|plugin marketplace remove'; then
    fail "non-interactive -> a removal command was invoked: $calls"
else
    pass "non-interactive -> no removal command invoked"
fi

echo "== present + --advisory-only on a TTY -> advisory only =="
d="$TMP/advisory"; make_claude "$d" present
out="$(run_case "$d" '' --advisory-only)"
calls="$(cat "$d/calls.log")"
if grepq "$out" 'non-interactive: nothing was removed' && ! grepq "$calls" 'plugin uninstall'; then
    pass "--advisory-only -> advisory, nothing removed"
else
    fail "--advisory-only -> out: $out; calls: $calls"
fi

echo "== lookalike identifiers must NOT trigger the offer =="
# Both shapes: a longer name that CONTAINS the needle (caveman-tools@...), and a
# DIFFERENT plugin served from a marketplace whose name contains it
# (other@caveman) — the latter is why `@` is not a boundary character.
for _case in 'caveman-tools@other-market|caveman-tools' 'other@caveman-x|caveman-x'; do
    _specs="${_case%%|*}"; _markets="${_case##*|}"
    d="$TMP/lookalike-${_markets}"; mkdir -p "$d"
    cat > "$d/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/calls.log"
case "\$1 \$2" in
  "plugin list")        printf '%s\n' '$_specs' ;;
  "plugin marketplace") [ "\$3" = list ] && printf '%s\n' '$_markets' ;;
esac
exit 0
STUB
    chmod +x "$d/claude"; : > "$d/calls.log"
    out="$(run_case "$d" '')"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "lookalike '$_specs' -> silent (no false offer)"; else fail "lookalike '$_specs' -> rc=$rc, out: $out"; fi
done

echo "== a FAILING uninstall must NOT proceed to the marketplace removal =="
d="$TMP/uninstall-fails"; make_claude "$d" present 1
out="$(run_case "$d" '')"; rc=$?
calls="$(cat "$d/calls.log")"
[ "$rc" -eq 0 ] || fail "failing uninstall -> rc=$rc"
if grepq "$calls" 'plugin uninstall caveman@caveman'; then pass "failing uninstall -> uninstall attempted"; else fail "failing uninstall -> no uninstall attempt: $calls"; fi
if grepq "$calls" 'plugin marketplace remove'; then
    fail "failing uninstall -> marketplace removed anyway (would orphan the plugin): $calls"
else
    pass "failing uninstall -> marketplace removal skipped"
fi
if grepq "$out" 'skipping the marketplace removal'; then pass "failing uninstall -> explains the skip"; else fail "failing uninstall -> no explanation: $out"; fi

echo "== settings.json detector: extraKnownMarketplaces entry with a silent CLI =="
d="$TMP/settings-only"; make_claude "$d" absent
s2="$TMP/settings-with-entry.json"
printf '{"extraKnownMarketplaces":{"caveman":{}}}\n' > "$s2"
out="$(HIMMEL_UPDATE_CLAUDE_BIN="$d/claude" CLAUDE_USER_SETTINGS="$s2" \
       HIMMEL_RETIRED_PLUGIN_ASSUME_TTY=0 bash "$SCRIPT" </dev/null 2>&1)"
if grepq "$out" 'retired plugin still installed'; then pass "settings detector -> present"; else fail "settings detector -> $out"; fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$failures FAILURE(S)"
exit 1
