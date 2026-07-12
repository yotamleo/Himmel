#!/usr/bin/env bash
# test-agents-reach.sh -- lock in the hermes AGENTS.md-reach verdict (WS5 Task 3,
# HIMMEL-654 / T10). SOURCE/CONFIG INSPECTION ONLY: no live gateway, no model
# call. Re-derives the verdict recorded in docs/internals/lane-parity.md by
# grepping the editable hermes-agent checkout, so a future hermes refactor that
# drops the auto-load fails LOUDLY here before the doc stays stale.
#
# Verdict (build-time, 2026-07-06): REACH CONFIRMED. hermes core
# (agent/prompt_builder.py) loads a repo AGENTS.md from the cwd (top-level only,
# priority 2 after .hermes.md) and SOUL.md independently from HERMES_HOME. The
# loader is on the live system-prompt path (agent/system_prompt.py calls
# build_context_files_prompt unconditionally) and is NOT profile-gated, so the
# himmel_agent profile auto-loads a repo AGENTS.md atop SOUL.md exactly like any
# other profile.
#
# Platform: gitbash-only (POSIX grep over a source tree). A test harness needs
# no .ps1 twin. SKIPs (exit 0) when the hermes-agent source is not installed --
# absence on a CI machine does not change a verdict recorded at build time; the
# FAIL signal is a present-but-changed source (the regression we lock against).
set -euo pipefail

# Resolve the editable hermes-agent source the same way himmel does: an explicit
# override first, then HERMES_HOME, then the Windows + XDG fallbacks. Windows
# drive-letter / backslash forms are normalized to forward slashes for bash
# (parameter expansion, bash 3.2-safe -- avoids a tr subshell).
normalize() { printf '%s' "${1//\\//}"; }

src=""
for candidate in \
    "${HERMES_AGENT_SOURCE:-UNSET}" \
    "${HERMES_HOME:-UNSET}/hermes-agent" \
    "${LOCALAPPDATA:-UNSET}/hermes/hermes-agent" \
    "$HOME/.local/share/hermes/hermes-agent"
do
    [ "$candidate" = "UNSET" ] && continue
    [ "$candidate" = "UNSET/hermes-agent" ] && continue
    cand="$(normalize "$candidate")"
    if [ -f "$cand/agent/prompt_builder.py" ] && [ -f "$cand/agent/system_prompt.py" ]; then
        src="$cand"
        break
    fi
done

if [ -z "$src" ]; then
    echo "SKIP: hermes-agent source not installed (HERMES_HOME/hermes-agent) --"
    echo "      reach verdict stands from build-time inspection; nothing to lock."
    exit 0
fi

PB="$src/agent/prompt_builder.py"
SP="$src/agent/system_prompt.py"
fails=0
ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

echo "== hermes AGENTS.md reach (source inspection: $src) =="

# 1. The AGENTS.md loader exists in core prompt-building and names AGENTS.md.
if grep -qE "def _load_agents_md\(" "$PB" && grep -qE '"AGENTS\.md"|"agents\.md"' "$PB"; then
    ok "core defines _load_agents_md referencing AGENTS.md"
else
    bad "_load_agents_md / AGENTS.md reference missing from prompt_builder.py"
fi

# 2. The loader is wired into the context-file builder (the public entry point).
#    Extract the builder's BODY (indented lines up to the next top-level def)
#    and require the call INSIDE it -- a bare existence grep would match the
#    loader's own `def` line and pass even with no call site at all.
if awk '/^def build_context_files_prompt\(/{f=1;next} /^def /{f=0} f' "$PB" \
        | grep -qE "_load_agents_md\("; then
    ok "build_context_files_prompt calls _load_agents_md"
else
    bad "build_context_files_prompt does not call _load_agents_md"
fi

# 3. The context-file builder is on the LIVE system-prompt path (not dead code).
if grep -qE "build_context_files_prompt\(" "$SP"; then
    ok "system_prompt.py calls build_context_files_prompt (live path)"
else
    bad "system_prompt.py no longer calls build_context_files_prompt"
fi

# 4. SOUL.md is the independent identity source (loaded from HERMES_HOME, not
#    the cwd) -- confirms AGENTS.md is loaded ATOP SOUL.md, not in its place.
if grep -qE "def load_soul_md\(" "$PB" && grep -qE "SOUL\.md" "$PB" \
   && grep -qE "get_hermes_home" "$PB"; then
    ok "SOUL.md loaded independently from HERMES_HOME (identity slot)"
else
    bad "SOUL.md identity-slot loader missing"
fi

echo ""
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS -- reach CONFIRMED: himmel_agent auto-loads repo AGENTS.md atop SOUL.md"
    exit 0
fi
echo "$fails FAILED -- reach verdict drifted; re-inspect + update lane-parity.md" >&2
exit 1
