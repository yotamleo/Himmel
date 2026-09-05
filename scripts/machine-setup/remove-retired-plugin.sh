#!/usr/bin/env bash
# remove-retired-plugin.sh — offer to remove the response-compression plugin
# himmel retired in HIMMEL-2033 (`caveman@caveman` + its `caveman` marketplace).
#
# WHY: new installs no longer get it (it is out of full-plugin-enable.json and
# settings-template.json), but machines provisioned before HIMMEL-2033 still
# carry it — a dead upstream whose vendored skills trip Hermes's skill scanner
# on every gateway start (HIMMEL-2032). `/himmel-update` is the one thing that
# already runs on those machines, so the offer lives here and is called from it.
#
# Contract:
#   - absent            -> silent, exit 0 (idempotent: safe on every update).
#   - present + TTY     -> prompt "Remove now? [Y/n]", DEFAULT = remove.
#   - present + "n"     -> one-line notice, removes nothing.
#   - present + no TTY  -> advisory only. NEVER hangs, NEVER removes silently.
#   - --advisory-only   -> same as no-TTY (used by `/himmel-update --check`).
#   - EOF at the prompt -> keeps. A failed read is the ABSENCE of an answer,
#                          never the bare-Enter default.
#   - `plugin list` errored -> refuses to remove anything: whether the plugin
#                          is installed is UNKNOWN, and de-registering its
#                          marketplace on a guess would orphan it.
# Best-effort: always exits 0 so a caller's chain never aborts on it.
#
# Seams (tests): HIMMEL_UPDATE_CLAUDE_BIN (the claude CLI),
# CLAUDE_USER_SETTINGS (the settings.json read for detection),
# HIMMEL_RETIRED_PLUGIN_ASSUME_TTY=1 (take the interactive branch with stdin
# on a pipe, so both answers are drivable).
#
# Bash 3.2 compatible.
set -uo pipefail

SPEC='caveman@caveman'
MARKETPLACE='caveman'

ADVISORY_ONLY=0
[ "${1:-}" = "--advisory-only" ] && ADVISORY_ONLY=1

CLAUDE_BIN="${HIMMEL_UPDATE_CLAUDE_BIN:-claude}"
SETTINGS="${CLAUDE_USER_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"

# Two independent detectors — either one counts as "present". The CLI is the
# live truth; settings.json catches the case where the CLI is unavailable or
# lists nothing but the machine still carries the enabledPlugins /
# extraKnownMarketplaces entries.
# NOTE: never pipe the CLI into `grep -q` here — grep exits on first match, the
# producer takes SIGPIPE, and `pipefail` then reports a SUCCESSFUL match as a
# failed pipeline (HIMMEL-1430). Capture first, match against a here-string.
#
# Match on IDENTIFIER BOUNDARIES, not a bare substring: the CLI's list output
# shape is not a stable contract, so we scan text — but a plain `grep caveman`
# also fires on an unrelated `caveman-tools@other-market` row, and a boundary
# class that treats `@` as a separator additionally fires on `other@caveman`
# (a DIFFERENT plugin served from this marketplace). `@`, `.` and `-` are
# therefore part of an identifier here, not boundaries: `caveman@caveman` and a
# standalone `caveman` marketplace line still match, while every longer
# identifier that merely contains them does not.
# Both needles are fixed literals defined above (`caveman@caveman`, `caveman`)
# made of alphanumerics and `@` — none of which is an ERE metacharacter — so no
# escaping step is needed here. Keep it that way if the literals ever change.
ID_BOUND='[^A-Za-z0-9_@.-]'
bounded_match() { # <needle> <haystack>
    grep -Eq "(^|$ID_BOUND)$1($ID_BOUND|\$)" <<< "$2"
}

# Detection sets two INDEPENDENT flags, because the two removals are
# independent: uninstalling the plugin and de-registering its marketplace are
# separate operations with separate failure modes, and the removal block below
# must be able to skip one without skipping the other.
SPEC_PRESENT=0
MARKET_PRESENT=0
# The plugin-list probe FAILING is not the same fact as the plugin being
# absent. Swallowing the difference is how the marketplace could be removed
# out from under a still-installed plugin: list errors -> SPEC_PRESENT=0 ->
# no uninstall -> marketplace removed anyway -> orphaned install. Track the
# failure and let the removal block refuse rather than guess.
SPEC_UNKNOWN=0

detect() {
    local out list_rc=0
    if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        out="$("$CLAUDE_BIN" plugin list 2>/dev/null)" || list_rc=$?
        if [ "$list_rc" -ne 0 ]; then
            SPEC_UNKNOWN=1
        else
            bounded_match "$SPEC" "$out" && SPEC_PRESENT=1
        fi
        out="$("$CLAUDE_BIN" plugin marketplace list 2>/dev/null || true)"
        bounded_match "$MARKETPLACE" "$out" && MARKET_PRESENT=1
    fi
    # settings.json is the exact-key source — no text scanning needed.
    if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
        jq -e --arg s "$SPEC" '(.enabledPlugins // {}) | has($s)' "$SETTINGS" >/dev/null 2>&1 \
            && SPEC_PRESENT=1
        jq -e --arg m "$MARKETPLACE" '(.extraKnownMarketplaces // {}) | has($m)' "$SETTINGS" >/dev/null 2>&1 \
            && MARKET_PRESENT=1
    fi
    [ "$SPEC_PRESENT" = 1 ] || [ "$MARKET_PRESENT" = 1 ]
}

detect || exit 0

echo ""
echo "==> retired plugin still installed (HIMMEL-2033)"
echo "    $SPEC is installed but is no longer part of himmel;"
echo "    himmel recommends removing it."

interactive=0
if [ "${HIMMEL_RETIRED_PLUGIN_ASSUME_TTY:-}" = 1 ]; then
    interactive=1
elif [ -t 0 ] && [ -t 1 ]; then
    interactive=1
fi

if [ "$ADVISORY_ONLY" -eq 1 ] || [ "$interactive" -eq 0 ]; then
    echo "    non-interactive: nothing was removed. To remove it yourself:"
    echo "      claude plugin uninstall $SPEC"
    echo "      claude plugin marketplace remove $MARKETPLACE"
    exit 0
fi

# ALLOW-LIST the affirmative, don't deny-list the negative. Removal is the
# destructive branch, so anything that is not an explicit yes (or the bare
# Enter that takes the documented [Y/n] default) keeps the plugin — a typo or
# a stray line must never be read as consent to uninstall.
printf '    Remove now? [Y/n] '
ans=''
if ! IFS= read -r ans; then
    # A failed read (Ctrl-D, a closed/exhausted stdin) is the ABSENCE of an
    # answer, not the bare Enter that means "take the default". Only a real
    # empty LINE is consent-by-default; EOF keeps the plugin.
    echo ""
    echo "    kept — no answer was read (EOF); nothing was removed."
    exit 0
fi
case "$ans" in
    '' | [Yy] | [Yy][Ee][Ss]) ;;
    *)
        echo "    kept — $SPEC left installed (answer was not y/yes)."
        exit 0
        ;;
esac

if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "    warn: claude CLI not on PATH — nothing removed." >&2
    exit 0
fi

# ORDER MATTERS: de-registering the marketplace while the plugin is still
# installed orphans it — the plugin's source is gone, so a later retry or
# recovery has nothing to resolve against. So the marketplace removal is
# GATED on the uninstall having succeeded (or on the plugin not being
# installed here in the first place, which is the state left behind when an
# operator removed the plugin by hand). A failed uninstall leaves BOTH in
# place, intact and retryable.
if [ "$SPEC_UNKNOWN" = 1 ]; then
    echo "    'claude plugin list' failed, so whether $SPEC is installed is UNKNOWN." >&2
    echo "    Refusing to remove the marketplace on a guess — that would orphan the" >&2
    echo "    plugin if it is in fact installed. Fix the CLI, then re-run." >&2
    exit 0
fi
uninstall_ok=1
if [ "$SPEC_PRESENT" = 1 ]; then
    "$CLAUDE_BIN" plugin uninstall "$SPEC" \
        || { uninstall_ok=0; echo "    warn: 'claude plugin uninstall $SPEC' failed (non-fatal)." >&2; }
fi
if [ "$uninstall_ok" = 0 ]; then
    echo "    skipping the marketplace removal: $SPEC is still installed, and removing" >&2
    echo "    its marketplace now would orphan it. Fix the uninstall, then re-run." >&2
    exit 0
fi
if [ "$MARKET_PRESENT" = 1 ]; then
    "$CLAUDE_BIN" plugin marketplace remove "$MARKETPLACE" \
        || echo "    warn: 'claude plugin marketplace remove $MARKETPLACE' failed (non-fatal)." >&2
fi
exit 0
