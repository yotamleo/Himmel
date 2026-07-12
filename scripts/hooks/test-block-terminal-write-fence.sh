#!/usr/bin/env bash
# Unit test for scripts/hooks/block-terminal-write-fence.sh (HIMMEL-745) — the
# codex-lane terminal write-fence. Exit 0 = allow, exit 2 = block.
#
# Hermetic: a temp HOME + isolated git config, temp git fixtures built with
# `git init` + `symbolic-ref` (no commits / identity needed), and EXPLICIT cwd
# in every write-on-main payload so the assertion never depends on the suite's
# own process cwd (the #975 lesson). No network — the external-write cases are
# classified by command text alone.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HOOKS/block-terminal-write-fence.sh"
[ -f "$GUARD" ] || { echo "guard not found: $GUARD" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Isolate git from the real user/system config so branch reads are deterministic.
export HOME="$T"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/.gitconfig"
# The guard must never inherit the opt-in from the suite env.
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true

mkrepo() {  # mkrepo <dir> <branch-ref>
    git init -q "$1" >/dev/null 2>&1
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}
mkrepo "$T/mainrepo"  "main"
mkrepo "$T/featrepo"  "feat/x"
MAIN="$T/mainrepo"
FEAT="$T/featrepo"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# check <label> <block|allow> <json> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | env "$@" bash "$GUARD" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label — expected $expect got $got"; fi
}

echo "== external-write class (a) =="
check "git push denied"                 block '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "git push allowed with opt-in"    allow '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' CODEX_EXTERNAL_WRITES_OK=1
check "git push --force denied"          block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
check "remote set-url rewrite denied"    block '{"tool_name":"Bash","tool_input":{"command":"git remote set-url origin http://x"}}'
check "config url rewrite denied"        block '{"tool_name":"Bash","tool_input":{"command":"git config remote.origin.url http://x"}}'
check "config url READ allowed"          allow '{"tool_name":"Bash","tool_input":{"command":"git config --get remote.origin.url"}}'
check "config --file url rewrite denied"  block '{"tool_name":"Bash","tool_input":{"command":"git config --file .git/config remote.origin.url http://x"}}'
check "gh pr create denied"              block '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'
check "gh pr view allowed"               allow '{"tool_name":"Bash","tool_input":{"command":"gh pr view 12"}}'
check "gh issue list allowed"            allow '{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}'
check "curl denied"                      block '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}'
check "curl allowed with opt-in"         allow '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}' CODEX_EXTERNAL_WRITES_OK=1
# Windows lane: .exe-suffixed binaries must not bypass the fence (CR codex-1).
check "git.exe push denied"              block '{"tool_name":"Bash","tool_input":{"command":"git.exe push origin main"}}'
check "curl.exe denied"                  block '{"tool_name":"Bash","tool_input":{"command":"curl.exe http://evil/x"}}'
check "gh.exe pr create denied"          block '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr create --fill"}}'
check "gh.exe pr view allowed"           allow '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr view 12"}}'
# Attached-value long flag before push must not break the anchor (CR under-block).
check "git --git-dir=/x push denied"     block '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/x push origin main"}}'

echo "== write-on-main class (b) =="
check "Set-Content on main-checkout denied" block "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"
check "Set-Content on feature-branch allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$FEAT\"}}"
# git.exe commit on main must be caught too (CR .exe parity for class b).
check "git.exe commit on main denied"    block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git.exe commit -m x\",\"cwd\":\"$MAIN\"}}"
# A write-verb only inside quoted/logged text must NOT be flagged on main
# (CR false-positive: command-position anchor on the PS writers).
check "echo mentioning set-content on main allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo see Set-Content docs\",\"cwd\":\"$MAIN\"}}"
check "git commit on main denied"        block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$MAIN\"}}"
check "git commit on feature allowed"    allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FEAT\"}}"
check "redirect to real file on main denied" block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$MAIN\"}}"
# $TMP is a literal token in the payload the guard must treat as a temp path.
# shellcheck disable=SC2016
check "redirect into \$TMP allowed" allow '{"tool_name":"Bash","tool_input":{"command":"echo hi > $TMP/scratch.txt","cwd":"'"$MAIN"'"}}'
check "redirect to /dev/null allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > /dev/null 2>&1\",\"cwd\":\"$MAIN\"}}"
check "git status on main allowed"       allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\",\"cwd\":\"$MAIN\"}}"
check "cat read on main allowed"         allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat foo.txt\",\"cwd\":\"$MAIN\"}}"

# .single-writer opt-out: the same on-main write is now allowed.
: > "$MAIN/.single-writer"
check "Set-Content on main with .single-writer allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"

echo "== non-command payloads =="
check "no command -> allow"              allow '{"tool_name":"Bash","tool_input":{}}'
check "non-terminal tool -> allow"       allow '{"tool_name":"Read","tool_input":{"file_path":"/x/README.md"}}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
