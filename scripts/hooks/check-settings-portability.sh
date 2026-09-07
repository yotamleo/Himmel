#!/usr/bin/env bash
# Pre-commit gate (pre-commit framework, not Claude PreToolUse).
#
# Refuses to commit a version-controlled Claude/Codex hook-settings file that
# carries a MACHINE-ABSOLUTE path or a Windows `.exe` in a hook command
# (HIMMEL-2156). Both break every adopter who is not the machine the file was
# written on, and an absolute home path leaks the maintainer's username into
# the public mirror.
#
# The shape this exists to catch is written by a TOOL, not by hand:
# `graphify install` rewrites its own hook block in .claude/settings.json and
# .codex/hooks.json with `C:/Users/<me>/.local/bin/graphify.EXE …` every time
# it runs (baf8dbaa), so a one-off cleanup does not hold — this gate is what
# catches the re-add on the next commit that stages the file. See
# docs/internals/environment-gotchas.md.
#
# Portable replacements: `$CLAUDE_PROJECT_DIR/...` for a repo-relative path,
# `$HOME/...` for a home-relative one, and a bare PATH-resolved binary name
# behind a fail-open guard for an optional tool.
#
# Platform guard (gitbash-only): a pre-commit gate — pre-commit runs its
# hooks under Git Bash on Windows and any POSIX bash elsewhere, so no .ps1
# twin is needed.
#
# Exit codes:
#   0 — clean
#   1 — a violation in a scanned file
set -uo pipefail

# Machine-absolute user paths. `$HOME/x` and `$CLAUDE_PROJECT_DIR/x` are the
# portable forms and deliberately do NOT match.
# `[/\]` is the two-member set {slash, backslash}: inside an ERE bracket
# expression a backslash is a LITERAL member, not an escape, so the `]` that
# follows it closes the set (POSIX ERE). Both separators are covered — the
# backslash case has its own self-test below, because this reads like a
# malformed `\]` escape to anyone expecting PCRE semantics.
#
# ANY drive letter, not just C: — a home directory on D:/ leaks a username
# exactly as hard, and the original C:-only form matched the one instance in
# front of it rather than the class. `/root/` is the same class on Linux.
ABS_PATTERN='([A-Za-z]:[/\]+Users[/\]|/Users/|/root/|/home/[A-Za-z0-9._-]+/)'

# A Windows executable suffix inside a hook COMMAND. Scoped to command lines
# on purpose: `"Bash(curl.exe:*)"` in a permissions array is a legitimate
# matcher for a Windows binary, not a command this repo has to run.
# Anchored INSIDE the "command" value (`"(...)*"`), not `"command".*`: minified
# JSON puts the whole object on one line, so a trailing `.*` would let a
# sibling key's `"Bash(curl.exe:*)"` satisfy the match and falsely reject a file
# whose command is perfectly portable. Same anchoring as the flattened scan
# below, so the two agree by construction.
#
# The value class is escape-aware: `([^"\]|\\.)*`, not the simpler `[^"]*`.
# A JSON-escaped quote (`\"`) is the DOMINANT shape in a real hook command
# (`"if [ -f \"$CLAUDE_PROJECT_DIR/scripts/lib/run-node.sh\" ]; then …"`), and
# `[^"]*` cannot cross one — it reads the escaped `\"` as the closing quote and
# stops scanning right there, so a `.exe` written after it is invisible to the
# gate. `\\.` consumes an escaped pair (backslash + whatever it escapes) as one
# unit so scanning continues past it; `[^"\]` (single backslash — a bracket
# expression member, not an escape, same convention as `[/\]` above) still
# excludes a bare `"`, so a minified single-line JSON still cannot let a
# sibling key's `"Bash(curl.exe:*)"` satisfy the match.
EXE_PATTERN='"command"[[:space:]]*:[[:space:]]*"([^"\]|\\.)*\.[Ee][Xx][Ee]'

# Self-test both patterns at startup. A regex that silently stopped matching
# would render as a clean pass on every commit — the failure mode this gate
# cannot afford (HIMMEL-2320: a zero is not evidence without a positive
# control).
#
# Here-strings, not pipes, throughout these probes: under `set -o pipefail` a
# `producer | grep -q` exits on the first match, the producer then takes
# SIGPIPE writing the remainder, and the PIPELINE status goes non-zero — which
# would INVERT the negated guard below and refuse every commit on a pattern
# that did in fact match (HIMMEL-1430). Each probe is one short line, far under
# the Git Bash here-string limit.
selftest() {
    local pat="$1" probe="$2" name="$3"
    if ! grep -Eq "$pat" <<< "$probe"; then
        echo "check-settings-portability: $name failed its self-test — refusing" >&2
        exit 1
    fi
}
selftest "$ABS_PATTERN" '      "command": "C:/Users/somebody/.local/bin/tool run",' ABS_PATTERN
selftest "$ABS_PATTERN" '      "command": "/home/somebody/bin/tool run",' ABS_PATTERN
# The backslash member of `[/\]` specifically — a regex flavour that read that
# bracket as an escaped `]` would silently stop matching Windows-style paths
# while the forward-slash probe above kept passing.
selftest "$ABS_PATTERN" '      "command": "C:\\Users\\somebody\\bin\\tool run",' ABS_PATTERN
# A home directory on another drive leaks a username exactly as hard, and
# /root is the same class on Linux — both were missed by a C:-only pattern.
selftest "$ABS_PATTERN" '      "command": "D:/Users/somebody/bin/tool run",' ABS_PATTERN
selftest "$ABS_PATTERN" '      "command": "/root/bin/tool run",' ABS_PATTERN
selftest "$EXE_PATTERN" '      "command": "tool.EXE hook-check"' EXE_PATTERN
# A `.exe` reached only by crossing a JSON-escaped quote — the shape `[^"]*`
# alone cannot see, and the dominant shape in a real settings file.
# shellcheck disable=SC2016  # the literal $X text IS the fixture.
selftest "$EXE_PATTERN" '      "command": "if [ -f \"$X\" ]; then tool.exe run; fi"' 'EXE_PATTERN (escaped-quote crossing)'
# Negative self-tests: the portable forms, and the permissions-array entry the
# EXE rule is deliberately scoped away from, must NOT match.
# shellcheck disable=SC2016  # the literal $VAR text IS the fixture: these
# probes assert the portable forms do NOT match, so expansion would defeat them.
for _probe in '      "command": "bun \"$CLAUDE_PROJECT_DIR/scripts/x.ts\"",' \
              '      "command": "$HOME/.local/bin/tool run",' ; do
    if grep -Eq "$ABS_PATTERN" <<< "$_probe"; then
        echo "check-settings-portability: ABS_PATTERN matched a portable form — refusing" >&2
        exit 1
    fi
done
if grep -Eq "$EXE_PATTERN" <<< '      "Bash(curl.exe:*)",'; then
    echo "check-settings-portability: EXE_PATTERN matched a permissions entry — refusing" >&2
    exit 1
fi

# Which files this gate owns. Keep in sync with the `files:` regex of the
# `settings-portability` hook in .pre-commit-config.yaml.
is_scanned() {
    case "$1" in
        *.claude/settings.json|*.claude/settings.local.json|*.codex/hooks.json) return 0 ;;
        *) return 1 ;;
    esac
}

# pre-commit passes staged filenames as argv (pass_filenames: true). Fall back
# to the staged diff so a direct/always_run invocation also works.
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    # bash 3.2-safe (macOS): no mapfile.
    while IFS= read -r _line; do files+=("$_line"); done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
fi
[ "${#files[@]}" -eq 0 ] && exit 0

fail=0
for f in "${files[@]}"; do
    is_scanned "$f" || continue
    [ -f "$f" ] || continue
    if [ ! -r "$f" ]; then
        echo "⛔ check-settings-portability: '$f' is unreadable — refusing to skip the scan on it (fail-closed)." >&2
        exit 1
    fi
    hits=$(grep -nE "$ABS_PATTERN|$EXE_PATTERN" -- "$f" 2>/dev/null || true)
    # JSON may put the "command" key and its value on SEPARATE lines, which the
    # line-oriented scan above cannot see. Flatten the file to one line and
    # re-check the .exe rule so that shape cannot slip through. The flattened
    # scan has no line number to report, so it only ever ADDS a verdict — the
    # per-line hits above stay the detail the message prints.
    flat_hit=""
    if [ -z "$hits" ]; then
        flat_hit=$(tr '\n' ' ' < "$f" 2>/dev/null | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\]|\\.)*\.[Ee][Xx][Ee]' | head -1 || true)
    fi
    [ -n "$hits" ] || [ -n "$flat_hit" ] || continue
    fail=1
    {
        echo "⛔ check-settings-portability: $f carries a machine-specific hook command."
        if [ -n "$hits" ]; then
            printf '%s\n' "$hits" | sed 's/^/    /'
        else
            echo "    (multi-line \"command\" property) $flat_hit"
        fi
    } >&2
done

[ "$fail" -eq 0 ] && exit 0

{
    echo
    echo "A tracked settings/hooks file must run on every adopter's machine:"
    echo "  - no absolute user path (C:/Users/…, /Users/…, /home/<name>/…)"
    echo "  - no .exe/.EXE in a hook command"
    echo "Use \$CLAUDE_PROJECT_DIR/… or \$HOME/…, or a PATH-resolved binary name"
    echo "behind a fail-open guard:"
    echo "  command -v tool >/dev/null 2>&1 && exec tool hook-check; exit 0"
    echo
    echo "If \`graphify install\` just re-added these entries, re-apply the"
    echo "portable shape — see docs/internals/environment-gotchas.md."
} >&2
exit 1
