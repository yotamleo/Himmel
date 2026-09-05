#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-settings-portability.sh (HIMMEL-2156).
#
# Usage: bash scripts/hooks/test-check-settings-portability.sh
#
# Fixtures are throwaway files under a temp dir, named with the same path
# suffixes the gate scopes itself to, so the cases are hermetic. The last case
# is the one that is NOT hermetic on purpose: it runs the gate against this
# repo's own tracked settings files, which is the regression this ticket
# exists to prevent coming back.
#
# Platform guard (gitbash-only): test fixture for the gate above; runs
# wherever the gate runs (Git Bash / POSIX bash), no .ps1 twin (project
# convention).
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-settings-portability.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0

# Templated, not bare: BSD/macOS mktemp REQUIRES a template and fails on a bare
# `mktemp -d`, so the bare form would make this suite Linux/Git-Bash-only. The
# failure is captured before anything builds a path on the result.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/himmel-settings-portability.XXXXXX") || {
    echo "test-check-settings-portability: mktemp -d failed — cannot build fixtures" >&2
    exit 1
}
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/.claude" "$TMP/.codex" "$TMP/other"

# case_rc <label> <expected-rc> <file>...
case_rc() {
    local label="$1" want="$2"; shift 2
    local out rc
    out=$(bash "$HOOK" "$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then
        echo "PASS $label (rc=$rc)"
    else
        echo "FAIL $label — expected rc=$want, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
}

# write_settings <path> <command-json-string>
write_settings() {
    cat > "$1" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": $2
          }
        ]
      }
    ]
  }
}
JSON
}

# --- RED: the three shapes the gate exists to refuse ------------------------
write_settings "$TMP/.claude/settings.json" '"C:/Users/somebody/.local/bin/graphify.EXE hook-guard search"'
case_rc "windows absolute user path refused" 1 "$TMP/.claude/settings.json"

write_settings "$TMP/.claude/settings.local.json" '"/home/osboxes/.local/bin/graphify hook-guard read"'
case_rc "linux absolute home path refused" 1 "$TMP/.claude/settings.local.json"

write_settings "$TMP/.codex/hooks.json" '"graphify.EXE hook-check"'
case_rc "bare .EXE in a hook command refused" 1 "$TMP/.codex/hooks.json"

# A `.exe` reached only by crossing a JSON-escaped quote — the dominant shape
# in a real settings file (`\"$CLAUDE_PROJECT_DIR/...\"` inside a "command"
# value). The old `[^"]*` class stopped scanning AT the escaped `\"`, letting
# this slip through; the escape-aware class must not.
# shellcheck disable=SC2016  # the literal $X text IS the fixture.
write_settings "$TMP/.claude/settings.json" '"if [ -f \"$X\" ]; then tool.exe run; fi"'
case_rc ".exe after an escaped quote refused" 1 "$TMP/.claude/settings.json"

# --- GREEN: the portable forms (negative controls) --------------------------
# shellcheck disable=SC2016  # the literal $CLAUDE_PROJECT_DIR text IS the fixture.
write_settings "$TMP/.claude/settings.json" '"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/x.sh\""'
case_rc "\$CLAUDE_PROJECT_DIR-relative command passes" 0 "$TMP/.claude/settings.json"

write_settings "$TMP/.claude/settings.json" '"command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0"'
case_rc "PATH-resolved fail-open command passes" 0 "$TMP/.claude/settings.json"

# shellcheck disable=SC2016  # the literal $HOME text IS the fixture.
write_settings "$TMP/.claude/settings.json" '"$HOME/.local/bin/tool run"'
case_rc "\$HOME-relative command passes" 0 "$TMP/.claude/settings.json"

# A permissions matcher naming a Windows binary is not a command this repo has
# to run — the .exe rule is scoped to "command" lines so it must not fire here.
cat > "$TMP/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(curl.exe:*)", "Bash(where.exe:*)"]
  }
}
JSON
case_rc "permissions entry naming curl.exe passes" 0 "$TMP/.claude/settings.json"

# ...including when MINIFIED onto one line next to a portable command, where an
# unanchored `"command".*\.exe` would let the sibling key satisfy the match.
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash x.sh"}]}]},"permissions":{"allow":["Bash(curl.exe:*)"]}}' \
    > "$TMP/.claude/settings.json"
case_rc "minified JSON: portable command beside a curl.exe permission passes" 0 "$TMP/.claude/settings.json"

# ...and the same minified shape with a genuinely non-portable command is still
# refused, so the anchoring did not simply stop matching.
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"graphify.EXE hook-check"}]}]},"permissions":{"allow":["Bash(curl.exe:*)"]}}' \
    > "$TMP/.claude/settings.json"
case_rc "minified JSON: .EXE command still refused" 1 "$TMP/.claude/settings.json"

# --- coverage the C:-only / line-only rules used to miss ---------------------
write_settings "$TMP/.claude/settings.json" '"D:/Users/somebody/.local/bin/tool run"'
case_rc "absolute path on a NON-C drive refused" 1 "$TMP/.claude/settings.json"

write_settings "$TMP/.claude/settings.json" '"/root/.local/bin/tool run"'
case_rc "/root absolute path refused" 1 "$TMP/.claude/settings.json"

# JSON may legally split the key and its value across lines; the line-oriented
# scan cannot see that, so the gate re-checks a flattened copy.
cat > "$TMP/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command":
              "graphify.EXE hook-check"
          }
        ]
      }
    ]
  }
}
JSON
case_rc "multi-line \"command\" property carrying .EXE refused" 1 "$TMP/.codex/hooks.json"

# ...and the same shape with a portable command must still pass, so the
# flattened scan is not just matching every multi-line file.
cat > "$TMP/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command":
              "command -v graphify >/dev/null 2>&1 && exec graphify hook-check; exit 0"
          }
        ]
      }
    ]
  }
}
JSON
case_rc "multi-line portable command passes" 0 "$TMP/.codex/hooks.json"

# --- scope control: a violation in a file this gate does not own ------------
write_settings "$TMP/other/notes.json" '"C:/Users/somebody/.local/bin/graphify.EXE hook-guard search"'
case_rc "violation outside the scanned filenames is ignored" 0 "$TMP/other/notes.json"

# --- the regression guard: this repo's own tracked files --------------------
case_rc "this repo's tracked settings + codex hooks are portable" 0 \
    "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/.codex/hooks.json"

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "PASS all cases"
exit 0
