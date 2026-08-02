#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-destructive-commands.sh.
#
# Usage: bash scripts/hooks/test-block-destructive-commands.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-destructive-commands.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# --- BLOCK cases (expect rc=2) ---
assert_rc "rm -rf /tmp/x"              2 "$(run_case "$(j_bash 'rm -rf /tmp/x')")"
assert_rc "rm -fr x"                   2 "$(run_case "$(j_bash 'rm -fr x')")"
assert_rc "rm.exe -rf x"               2 "$(run_case "$(j_bash 'rm.exe -rf x')")"
assert_rc "git reset --hard"           2 "$(run_case "$(j_bash 'git reset --hard')")"
assert_rc "git.exe reset --hard"       2 "$(run_case "$(j_bash 'git.exe reset --hard')")"
assert_rc "git clean -fx"              2 "$(run_case "$(j_bash 'git clean -fx')")"
assert_rc "git filter-branch"          2 "$(run_case "$(j_bash 'git filter-branch --tree-filter true')")"
assert_rc "curl pipe sh"               2 "$(run_case "$(j_bash 'curl http://x | sh')")"
assert_rc "curl.exe pipe bash"         2 "$(run_case "$(j_bash 'curl.exe http://x | bash')")"
assert_rc "wget pipe bash"             2 "$(run_case "$(j_bash 'wget -qO- x | bash')")"
assert_rc "wget.exe pipe sh"           2 "$(run_case "$(j_bash 'wget.exe -qO- x | sh')")"
assert_rc "schtasks create"            2 "$(run_case "$(j_bash 'schtasks /create /tn x /tr y')")"
assert_rc "schtasks.exe create"        2 "$(run_case "$(j_bash 'schtasks.exe /create /tn x /tr y')")"
# HIMMEL-1141: mutating verbs stay refused.
assert_rc "schtasks /change"           2 "$(run_case "$(j_bash 'schtasks /change /tn x /disable')")"
assert_rc "schtasks /end"              2 "$(run_case "$(j_bash 'schtasks /end /tn x')")"
assert_rc "schtasks /run"              2 "$(run_case "$(j_bash 'schtasks /run /tn x')")"
# HIMMEL-1141 security lock: UPPERCASE / mixed-case mutating verbs are STILL
# refused — cmd_lc lowercases before matching, so the lowercase verb pattern
# catches the capitalized form MS docs use. No case-bypass of the guard.
assert_rc "schtasks /CREATE upper"     2 "$(run_case "$(j_bash 'schtasks /CREATE /tn x /tr y')")"
assert_rc "schtasks /Delete mixed"     2 "$(run_case "$(j_bash 'schtasks /Delete /tn x /f')")"
assert_rc "del /s /q x"                2 "$(run_case "$(j_bash 'del /s /q x')")"
assert_rc "PowerShell shutdown.exe"    2 "$(run_case "$(j_pwsh 'shutdown.exe /s /t 0')")"
assert_rc "format c:"                  2 "$(run_case "$(j_bash 'format c:')")"
assert_rc "shutdown /s now"            2 "$(run_case "$(j_bash 'shutdown /s now')")"
assert_rc "x; shutdown -r"             2 "$(run_case "$(j_bash 'x; shutdown -r')")"
assert_rc "foo && reboot"              2 "$(run_case "$(j_bash 'foo && reboot')")"
assert_rc "mkfs.ext4 /dev/sda"         2 "$(run_case "$(j_bash 'mkfs.ext4 /dev/sda')")"
assert_rc "FOO=1 shutdown -r"          2 "$(run_case "$(j_bash 'FOO=1 shutdown -r')")"
# shellcheck disable=SC2016  # literal backtick payload is the point of this case
assert_rc "backtick format subst"      2 "$(run_case "$(j_bash 'echo `format c:`')")"
assert_rc "rm quoted -rf flag"          2 "$(run_case "$(j_bash 'rm "-rf" file')")"
# shellcheck disable=SC2016  # literal ${IFS} payload is the point of this case
assert_rc 'rm ${IFS}-separated -rf'     2 "$(run_case "$(j_bash 'rm${IFS}-rf${IFS}x')")"
# Backslash-newline continuation (HIMMEL-851 U3): real multi-line single-quoted
# string so the literal backslash + newline reach the hook exactly as a shell
# line-continuation would produce them.
cont_cmd='rm \
-rf x'
assert_rc "rm backslash-continuation -rf" 2 "$(run_case "$(j_bash "$cont_cmd")")"
# CR r1 (HIMMEL-851): bounded launcher-wrapper tolerance in command position.
assert_rc "sudo shutdown"               2 "$(run_case "$(j_bash 'sudo shutdown -h now')")"
assert_rc "x=1 shutdown"                2 "$(run_case "$(j_bash 'x=1 shutdown -h now')")"
# CR r5 (HIMMEL-851): assignment VALUE is quote-aware.
assert_rc "single-quoted assign shutdown" 2 "$(run_case "$(j_bash "foo='a b' shutdown -h now")")"
assert_rc "double-quoted assign schtasks" 2 "$(run_case "$(j_bash 'foo="a b" schtasks /delete /f')")"
assert_rc "cmd /c shutdown"             2 "$(run_case "$(j_bash 'cmd /c shutdown /s /t 0')")"
assert_rc "cmd /d /c shutdown"          2 "$(run_case "$(j_bash 'cmd /d /c shutdown /s /t 0')")"
assert_rc "cmd.exe /d /s /c shutdown"   2 "$(run_case "$(j_bash 'cmd.exe /d /s /c shutdown /s /t 0')")"
assert_rc "powershell -command stop-process" 2 "$(run_case "$(j_bash 'powershell -command stop-process -name foo')")"
# CR r2 (HIMMEL-851): path-qualified destructive executables.
assert_rc "/sbin/shutdown"              2 "$(run_case "$(j_bash '/sbin/shutdown -h now')")"
assert_rc "./shutdown relative"         2 "$(run_case "$(j_bash './shutdown -h now')")"
assert_rc "drive-path shutdown.exe"     2 "$(run_case "$(j_bash 'c:/windows/system32/shutdown.exe /s /t 0')")"
assert_rc "quoted drive-path shutdown"  2 "$(run_case "$(j_bash '"C:/Windows/System32/shutdown.exe" /s /t 0')")"
assert_rc "backslash drive-path shutdown" 2 "$(run_case "$(j_bash 'C:\Windows\System32\shutdown.exe /s /t 0')")"
# CR r4 (HIMMEL-851): path-qualified launcher wrappers.
assert_rc "/usr/bin/env shutdown"       2 "$(run_case "$(j_bash '/usr/bin/env shutdown -h now')")"
assert_rc "/usr/bin/sudo shutdown"      2 "$(run_case "$(j_bash '/usr/bin/sudo shutdown -h now')")"
assert_rc "path-qualified cmd.exe /c shutdown" 2 "$(run_case "$(j_bash 'c:/windows/system32/cmd.exe /c shutdown /s /t 0')")"
# CR r6 (HIMMEL-851): sudo/env tolerate their own flag runs (+ env assignments).
assert_rc "sudo -n shutdown"            2 "$(run_case "$(j_bash 'sudo -n shutdown -h now')")"
assert_rc "env -i shutdown"             2 "$(run_case "$(j_bash 'env -i shutdown -h now')")"
assert_rc "env -i foo=bar shutdown"     2 "$(run_case "$(j_bash 'env -i foo=bar shutdown -h now')")"
# CR r7 (HIMMEL-851): wrapper flags may each consume one following value token.
assert_rc "sudo -u root shutdown"       2 "$(run_case "$(j_bash 'sudo -u root shutdown -h now')")"
assert_rc "env -u path shutdown"        2 "$(run_case "$(j_bash 'env -u path shutdown -h now')")"
assert_rc "sudo -u root -g wheel taskkill" 2 "$(run_case "$(j_bash 'sudo -u root -g wheel taskkill /f')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "rmtemp.sh -r foo"           0 "$(run_case "$(j_bash 'rmtemp.sh -r foo')")"
assert_rc "rmdir -r foo"               0 "$(run_case "$(j_bash 'rmdir -r foo')")"
assert_rc "rm x.txt"                   0 "$(run_case "$(j_bash 'rm x.txt')")"
assert_rc "git status"                 0 "$(run_case "$(j_bash 'git status')")"
assert_rc "git commit -m x"            0 "$(run_case "$(j_bash 'git commit -m x')")"
assert_rc "git push"                   0 "$(run_case "$(j_bash 'git push')")"
assert_rc "mv a b"                     0 "$(run_case "$(j_bash 'mv a b')")"
assert_rc "cp a b"                     0 "$(run_case "$(j_bash 'cp a b')")"
assert_rc "gh pr view 1"               0 "$(run_case "$(j_bash 'gh pr view 1')")"
assert_rc "curl without pipe"          0 "$(run_case "$(j_bash 'curl http://x -o f')")"
assert_rc "git log --pretty=format:"   0 "$(run_case "$(j_bash 'git log --pretty=format:%H -n 5')")"
assert_rc "git log quoted format"      0 "$(run_case "$(j_bash 'git log --pretty="format:%h %s"')")"
assert_rc "grep -rn format src/"       0 "$(run_case "$(j_bash 'grep -rn format src/')")"
assert_rc "rg format scripts/"         0 "$(run_case "$(j_bash 'rg "format" scripts/')")"
# HIMMEL-1141: schtasks /query is read-only — the cadence diagnostic that was
# over-blocked. /query (and help/no-verb) is allowed; only mutating verbs trip.
assert_rc "schtasks /query"            0 "$(run_case "$(j_bash 'schtasks /query')")"
assert_rc "schtasks /query /fo LIST"   0 "$(run_case "$(j_bash 'schtasks /query /fo LIST /v')")"
assert_rc "schtasks.exe /query"        0 "$(run_case "$(j_bash 'schtasks.exe /query')")"
assert_rc "schtasks /Query mixed case" 0 "$(run_case "$(j_bash 'schtasks /Query /fo LIST')")"
assert_rc "grep -n schtasks string"    0 "$(run_case "$(j_bash 'grep -n schtasks scripts/hooks/block-destructive-commands.sh')")"
assert_rc "commit msg mentions reboot" 0 "$(run_case "$(j_bash 'git commit -m "fix reboot loop"')")"
assert_rc "rd /scripts (path, not switch)" 0 "$(run_case "$(j_bash 'rd /scripts foo')")"
assert_rc "echo shutdown mid-argument"  0 "$(run_case "$(j_bash 'echo shutdown')")"
assert_rc "format-data path basename"   0 "$(run_case "$(j_bash 'x; foo/format-data bar')")"
assert_rc "/usr/bin/env python3 benign" 0 "$(run_case "$(j_bash '/usr/bin/env python3 build.py')")"
assert_rc "echo'd quoted assign+verb"   0 "$(run_case "$(j_bash "echo \"FOO='a b' shutdown\"")")"
assert_rc "sudo -n apt benign"          0 "$(run_case "$(j_bash 'sudo -n apt update')")"
assert_rc "env -i printenv benign"      0 "$(run_case "$(j_bash 'env -i printenv')")"
assert_rc "sudo -u root ls benign"      0 "$(run_case "$(j_bash 'sudo -u root ls')")"
assert_rc "sudo -u root apt benign"     0 "$(run_case "$(j_bash 'sudo -u root apt update')")"
assert_rc "env -u path printenv benign" 0 "$(run_case "$(j_bash 'env -u path printenv')")"
assert_rc "non-terminal tool"          0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}')"
assert_rc "empty payload"              0 "$(run_case '{}')"

# --- HIMMEL-1451 cli-proxy sanctioned carve-out ---
# The proxy bounce needs process termination (taskkill / schtasks /end), all
# refused at command position below. The SAFE path is the cli-proxy-lane.ps1
# -Restart/-Stop verb, which terminates internally (never inspected here). The
# sanctioned shapes PASS; the dangerous primitives and an appended kill (proving
# the carve-out is anchored to the WHOLE command, not a prefix) still BLOCK.
assert_rc "sanctioned -Restart (pwsh5)"  0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Restart')")"
assert_rc "sanctioned -Stop (pwsh5)"     0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Stop')")"
assert_rc "sanctioned -Restart -Force"   0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Restart -Force')")"
assert_rc "sanctioned -Stop -Force (pwsh7)" 0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Stop -Force')")"
# CR r4 (HIMMEL-1451): close the 4-of-8 standalone coverage gap -- exercise the
# other shell for every verb-shape so all 8 carve-out patterns are hit, not 4.
assert_rc "sanctioned -Stop -Force (pwsh5)"    0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Stop -Force')")"
assert_rc "sanctioned -Restart (pwsh7)"        0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Restart')")"
assert_rc "sanctioned -Restart -Force (pwsh7)" 0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Restart -Force')")"
assert_rc "sanctioned -Stop (pwsh7)"           0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Stop')")"
# CR r4 (HIMMEL-1451 / glm-4): the combined -Install -Restart [-Force] one-shot
# pin-roll (.EXAMPLE) is now an enumerated sanctioned shape (rc=0 on both shells).
assert_rc "sanctioned -Install -Restart (pwsh5)"       0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Install -Restart')")"
assert_rc "sanctioned -Install -Restart -Force (pwsh7)" 0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Install -Restart -Force')")"
# HIMMEL-1470: close the remaining 2-of-4 combined coverage gap. r4 delivered
# "8 standalone + 2 combined"; the carve-out (block-destructive-commands.sh)
# enumerates all 4 combined shapes (powershell/pwsh x -Install -Restart[-Force]),
# so exercise the other two shells here too -> 4-of-4 combined, 12-of-12 total.
assert_rc "sanctioned -Install -Restart -Force (pwsh5)" 0 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Install -Restart -Force')")"
assert_rc "sanctioned -Install -Restart (pwsh7)"        0 "$(run_case "$(j_bash 'pwsh -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Install -Restart')")"
# codex-1 (CR r4): NO negative "out-of-root relative invocation -> DENIED" case
# here. The premise (that this carve-out GATES the relative path) is disproved:
# the floor INDEPENDENTLY allows `powershell/pwsh -NoProfile -File <relative>`
# (no deny rule matches -- `-File` is not the armed `-c` wrapper the CMDPOS
# grammar arms), so an impostor/escaped path returns rc=0 regardless of this
# carve-out. That residual is a floor-level gap (script-internals-unseen, the
# documented no-general-parser residual, HIMMEL-912 class), not a hole this
# carve-out opens or can close -- see the comment at the carve-out above.
# Asserting rc=0 for an impostor shape here would read as blessing it, so the
# documenting probe lives only in the r4 work note, not in the suite.
# Near-miss: the direct primitive an operator might reach for instead of the
# script still hits the deny floor (the carve-out did NOT widen it).
assert_rc "direct taskkill proxy"        2 "$(run_case "$(j_bash 'taskkill /F /IM cli-proxy-api.exe')")"
assert_rc "direct schtasks /end proxy"   2 "$(run_case "$(j_bash 'schtasks /end /tn cli-proxy-api')")"
# Near-miss: the sanctioned PREFIX does not whitelist an appended kill -- the
# case match is on the whole command, so the trailing taskkill still blocks.
assert_rc "sanctioned prefix + appended kill" 2 "$(run_case "$(j_bash 'powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Restart; taskkill /F /IM x')")"

# --- MALFORMED JSON case (expect rc=2, fail closed) ---
assert_rc "truncated JSON + rm -rf" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"')"

# --- BYPASS case ---
assert_rc "DESTRUCTIVE_OK bypass"       0 "$(run_case "$(j_bash 'rm -rf /tmp/x')" "DESTRUCTIVE_OK=1")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
