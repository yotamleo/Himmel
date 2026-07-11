#!/usr/bin/env bash
# test-tier-coupling.sh -- the REFINED tier-coupling assertion (WS5 Task 3,
# HIMMEL-654 / T9). Config-fixture only: NO live gateway, NO real config, NO
# model call. Encodes D3b: full control (write / git / PR) is paired ONLY with a
# TRUSTED main-tier engine (codex-5.5 or GLM-5.2 1M workhorse); the untrusted free
# tier (qwen3-coder-plus / nemotron) is NEVER a write-capable fallback under the
# default profile.
#
# The rule (runbook "Tier coupling -- capability follows the model"):
#   * full control    = a profile wired with `parity_guard` (the write/git/PR
#                       main-tier guard), NOT the read-only `luna_vault_guard`.
#   * trusted engine  = codex / gpt-5.5 / glm-5.2[1m] (the affirmed write engines).
#   * safe pairing    = full control REQUIRES every model in its chain (the
#                       `model.default` AND every `fallback_providers` model) to
#                       be trusted. A free / untrusted / unknown model anywhere
#                       in a full-control chain is UNSAFE (fail-closed).
#   * read-only tier  = any engine is safe (free-on-read-only is the intended
#                       parallel-junior config).
#
# Config shape follows docs/hermes-runbook.md and scripts/hermes/wire_parity_guard.py
# (a top-level `model:` with `default:`, a `fallback_providers:` list, and a
# `hooks:` block whose matcher+command identifies the guard).
#
# Platform: Git Bash on Windows (gitbash) / any POSIX bash 3.2+. Pure shell +
# awk + grep over fixture files; NOT ported to native PowerShell. A test harness
# needs no .ps1 twin (project convention: a documented platform guard suffices).
set -uo pipefail

# --- the tier-coupling rule ---------------------------------------------------
# Trusted write engines (D3b: codex-5.5 / GLM-5.2 1M workhorse; gpt-5.5 is the
# codex provider's model id per the runbook). EXACT allowlist anchored on the
# whole slug (optional provider prefix) — a substring match would let an
# unaffirmed variant (e.g. bare glm-5.2 or a hypothetical glm-5.2-air free tier)
# ride a trusted token into full control. Variants NOT listed stay UNTRUSTED
# (fail-closed). Z.ai's Claude Code docs require the explicit `[1m]` suffix for
# the largest context window, so bare `glm-5.2` is NOT the affirmed write lane.
TRUSTED_RE='^([a-z0-9._-]+/)?(codex|codex-5\.5|gpt-5\.5|gpt-5\.5-codex|glm-5\.2\[1m\])$'

is_trusted_model() {
    # arg 1 = model slug (already lower-cased). return 0 if a trusted write engine.
    printf '%s' "$1" | grep -qE "$TRUSTED_RE"
}

# full control = the profile is wired with parity_guard (write/git/PR allowed),
# not the read-only luna_vault_guard. Keys on the documented tier signal.
is_full_control() {
    grep -q 'parity_guard' "$1"
}

# Extract the model chain (model.default + every fallback_providers model) from
# a hermes config fixture -- one lower-cased slug per line. awk (not PyYAML) so
# this runs under any bash; it tracks the `model:` and `fallback_providers:`
# top-level blocks and reads the first-colon value of `default:` / `model:`.
config_models() {
    awk '
        function slug(s) {
            sub(/^[^:]*:[[:space:]]*/, "", s)   # drop up to first ":" + spaces
            sub(/[[:space:]]*#.*/, "", s)        # drop a trailing comment
            sub(/[[:space:]]+$/, "", s)          # drop trailing spaces
            return tolower(s)
        }
        /^model:/             { inm=1; infb=0; next }
        /^fallback_providers:/ { inm=0; infb=1; next }
        /^[A-Za-z0-9_-]+:/    { inm=0; infb=0 }   # any other top-level key resets
        inm  && /default:/    { print slug($0) }
        infb && /model:/      { print slug($0) }
    ' "$1"
}

# tier_check <config.yaml>: 0 = safe pairing, 1 = unsafe. Prints a reason to
# stderr (so a caller can surface it). Read-only tiers are always safe; a
# full-control tier is safe ONLY if every model in its chain is trusted.
tier_check() {
    local cfg="$1" unsafe="" m nmodels=0
    if ! is_full_control "$cfg"; then
        echo "safe: read-only tier (no parity_guard) -- engine unconstrained" >&2
        return 0
    fi
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        nmodels=$((nmodels + 1))
        if ! is_trusted_model "$m"; then
            unsafe="${unsafe:+$unsafe, }$m"
        fi
    done < <(config_models "$cfg")
    # Fail-closed: a full-control profile whose model chain cannot be extracted
    # (malformed / unrecognized config) must never be reported safe.
    if [ "$nmodels" -eq 0 ]; then
        echo "unsafe: full-control profile (parity_guard) with no extractable" \
             "model chain (fail-closed)" >&2
        return 1
    fi
    if [ -n "$unsafe" ]; then
        echo "unsafe: full-control profile (parity_guard) with untrusted/free" \
             "model(s): $unsafe" >&2
        return 1
    fi
    echo "safe: full-control profile on trusted engine(s) only" >&2
    return 0
}

# --- test harness: build a fixture, assert tier_check's verdict ----------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
# FIXTURE BUILDER. Args: name, guard (parity|luna), default-model, fallback-model
# (fallback "" = empty fallback_providers: []). Writes a runbook-shaped config.
fixture() {
    local f="$TMP/$1.yaml" guard="$2" default="$3" fb="$4" cmd
    if [ "$guard" = "parity" ]; then
        cmd='    command: ''"PY" "ASSETS/parity_guard.py"'
    else
        cmd='    command: ''"PY" "AGENT_HOOKS/luna_vault_guard.py"'
    fi
    {
        printf 'model:\n  default: %s\n  provider: p\n' "$default"
        if [ -z "$fb" ]; then
            printf 'fallback_providers: []\n'
        else
            printf 'fallback_providers:\n- provider: fb\n  model: %s\n' "$fb"
        fi
        printf 'hooks:\n  pre_tool_call:\n  - matcher: write_file|terminal\n'
        printf '%s\n    timeout: 10\n' "$cmd"
    } > "$f"
    printf '%s' "$f"
}

# expect_<verdict> <label> <fixture-path>: run tier_check and assert.
expect_safe() {
    local label="$1" cfg="$2" why rc
    why="$(tier_check "$cfg" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ok: $label -- $why"
    else
        echo "  FAIL: $label -- expected SAFE, got UNSAFE: $why" >&2
        fails=$((fails + 1))
    fi
}
expect_unsafe() {
    local label="$1" cfg="$2" why rc
    why="$(tier_check "$cfg" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ok: $label -- correctly UNSAFE: $why"
    else
        echo "  FAIL: $label -- expected UNSAFE, got SAFE" >&2
        fails=$((fails + 1))
    fi
}
# expect_unsafe_named <label> <fixture-path> <model>: expect_unsafe PLUS a
# reason pin -- stderr must name <model> as the untrusted one, so an UNSAFE
# from a different cause (e.g. the fail-closed empty-chain path) cannot
# masquerade as the trust-classification verdict (HIMMEL-916 CR, coderabbit).
# The pin is an EXACT match against the comma-separated unsafe-model list
# (not a substring grep), so a pinned model that is a prefix of another
# entry (deepseek-chat vs deepseek-chat-v2) can never false-pass.
expect_unsafe_named() {
    local label="$1" cfg="$2" model="$3" why rc hit="" list entry old_ifs
    why="$(tier_check "$cfg" 2>&1 >/dev/null)"; rc=$?
    case "$why" in
        *"untrusted/free model(s): "*)
            list="${why##*untrusted/free model(s): }"
            old_ifs="$IFS"; IFS=','
            for entry in $list; do
                entry="${entry# }"
                [ "$entry" = "$model" ] && hit=1
            done
            IFS="$old_ifs"
            ;;
    esac
    if [ "$rc" -ne 0 ] && [ -n "$hit" ]; then
        echo "  ok: $label -- correctly UNSAFE: $why"
    elif [ "$rc" -ne 0 ]; then
        echo "  FAIL: $label -- UNSAFE for the wrong reason (expected untrusted $model): $why" >&2
        fails=$((fails + 1))
    else
        echo "  FAIL: $label -- expected UNSAFE, got SAFE" >&2
        fails=$((fails + 1))
    fi
}

echo "== tier-coupling: trusted engine + full control =="
# codex-5.5 with no free fallback -- the canonical safe main-tier pairing.
expect_safe  "codex-5.5 + full control, no fallback" \
    "$(fixture safe_codex parity codex-5.5 '')"
# GLM-5.2 1M workhorse (D3b blessed for write), no fallback.
expect_safe  "glm-5.2[1m] + full control, no fallback" \
    "$(fixture safe_glm parity 'glm-5.2[1m]' '')"
# trusted default AND a trusted fallback (codex) -- all-trusted chain is safe.
expect_safe  "gpt-5.5 + full control, codex fallback (all trusted)" \
    "$(fixture safe_gptfb parity gpt-5.5 codex-5.5)"

echo "== tier-coupling: free tier NEVER paired with full control =="
# nemotron (free) as the DEFAULT on a full-control profile -- must FAIL.
expect_unsafe "nemotron (free) + full control" \
    "$(fixture bad_nemotron parity nvidia/nemotron-3-ultra-550b-a55b '')"
# qwen3-coder-plus (free) as the DEFAULT on a full-control profile -- must FAIL.
expect_unsafe "qwen3-coder-plus (free) + full control" \
    "$(fixture bad_qwen parity qwen3-coder-plus '')"
# deepseek-chat (CN provider, GLM trust tier) on a full-control profile --
# must FAIL, and specifically as an UNTRUSTED-MODEL verdict (reason-pinned).
expect_unsafe_named "deepseek-chat (untrusted CN tier) + full control" \
    "$(fixture bad_deepseek parity deepseek-chat '')" deepseek-chat
# deepseek-reasoner -- the lane row's second advertised model, equally untrusted.
expect_unsafe_named "deepseek-reasoner (untrusted CN tier) + full control" \
    "$(fixture bad_deepseek_r parity deepseek-reasoner '')" deepseek-reasoner
# trusted default BUT a free model in fallback_providers -- a free tier must
# never be a WRITE-CAPABLE fallback, so this must FAIL too (D3b).
expect_unsafe "codex-5.5 default + nemotron free fallback (write-capable)" \
    "$(fixture bad_fbfree parity codex-5.5 nvidia/nemotron-3-ultra-550b-a55b:free)"
# unknown / unrecognized engine on a full-control profile -- fail-closed.
expect_unsafe "unknown engine + full control (fail-closed)" \
    "$(fixture bad_unknown parity some-mystery-model '')"
# bare GLM-5.2 is capped below the desired Z.ai long-context lane unless the
# explicit [1m] suffix is present -- must FAIL.
expect_unsafe "bare glm-5.2 (missing [1m]) + full control" \
    "$(fixture bad_bare_glm parity glm-5.2 '')"
# unaffirmed VARIANT of a trusted slug (substring trap): glm-5.2-air carries the
# trusted "glm-5.2" token but is NOT on the affirmed allowlist -- must FAIL.
expect_unsafe "glm-5.2-air variant (unaffirmed) + full control" \
    "$(fixture bad_variant parity glm-5.2-air '')"
# full-control config whose model chain cannot be extracted (no model: block) --
# must FAIL closed, never report safe on an empty chain.
{
    printf 'hooks:\n  pre_tool_call:\n  - matcher: write_file|terminal\n'
    printf '    command: "PY" "ASSETS/parity_guard.py"\n    timeout: 10\n'
} > "$TMP/bad_nochain.yaml"
expect_unsafe "no extractable model chain + full control (fail-closed)" \
    "$TMP/bad_nochain.yaml"

echo "== tier-coupling: free tier is fine on the READ-ONLY junior =="
# read-only tier (luna_vault_guard) on a free model -- the intended config.
expect_safe  "nemotron (free) + read-only junior" \
    "$(fixture ok_ro_nemotron luna nvidia/nemotron-3-ultra-550b-a55b '')"
expect_safe  "qwen3-coder-plus (free) + read-only junior" \
    "$(fixture ok_ro_qwen luna qwen3-coder-plus '')"
expect_safe  "deepseek-chat + read-only junior" \
    "$(fixture ok_ro_deepseek luna deepseek-chat '')"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS -- refined tier-coupling holds: full control only on a trusted engine"
    exit 0
fi
echo "$fails FAILED" >&2
exit 1
