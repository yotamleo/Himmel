#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-docker-privesc.sh (HIMMEL-441).
#
# Usage: bash scripts/hooks/test-block-docker-privesc.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
#
# The paired test IS the spec: every row mirrors the BLOCK/ALLOW matrix in
# specs/design/2026-06-20-block-docker-privesc-design.md.
#
# SC2016: many rows pass a LITERAL $HOME / $PWD into the JSON command on purpose
# (the hook does its own expansion), so single quotes around them are intentional.
# shellcheck disable=SC2016
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-docker-privesc.sh"
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
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}'  "$(printf '%s' "$1" | jq -Rs .)"; }

# --- BLOCK cases (expect rc=2) ---
# The motivating example: writes /etc as root via a bind mount, no sudo.
assert_rc "motivating: -v /etc:/host-etc:rw + install" 2 "$(run_case "$(j_bash 'docker run --rm --pull=never -v /etc:/host-etc:rw ubuntu:22.04 /usr/bin/install -m 0644 -o 0 -g 0 /host-etc/sddm.conf.bak /host-etc/sddm.conf')")"
assert_rc "-v /:/host (root, any mode)"        2 "$(run_case "$(j_bash 'docker run -v /:/host alpine cat /host/etc/shadow')")"
assert_rc "-v /root:/r"                         2 "$(run_case "$(j_bash 'docker run -v /root:/r img sh')")"
assert_rc "-v ~/.ssh:/k (tilde expand)"        2 "$(run_case "$(j_bash 'docker run -v ~/.ssh:/k img sh')")"
assert_rc "-v \$HOME/.ssh:/k (HOME expand)"     2 "$(run_case "$(j_bash 'docker run -v $HOME/.ssh:/k img sh')")"
assert_rc "--mount source=/etc"                2 "$(run_case "$(j_bash 'docker run --mount type=bind,source=/etc,target=/h img sh')")"
assert_rc "-v docker.sock"                      2 "$(run_case "$(j_bash 'docker run -v /var/run/docker.sock:/s img sh')")"
assert_rc "--privileged"                        2 "$(run_case "$(j_bash 'docker run --privileged img sh')")"
assert_rc "--pid=host"                          2 "$(run_case "$(j_bash 'docker run --pid=host img sh')")"
assert_rc "--pid host (space)"                  2 "$(run_case "$(j_bash 'docker run --pid host img sh')")"
assert_rc "--user 0"                            2 "$(run_case "$(j_bash 'docker run --user 0 img sh')")"
assert_rc "-u0 (glued)"                         2 "$(run_case "$(j_bash 'docker run -u0 img sh')")"
assert_rc "--user=root"                         2 "$(run_case "$(j_bash 'docker run --user=root img sh')")"
assert_rc "--cap-add=DAC_READ_SEARCH"          2 "$(run_case "$(j_bash 'docker run --cap-add=DAC_READ_SEARCH img sh')")"
assert_rc "--cap-add SYS_ADMIN (space)"        2 "$(run_case "$(j_bash 'docker run --cap-add SYS_ADMIN img sh')")"
assert_rc "--volumes-from"                      2 "$(run_case "$(j_bash 'docker run --volumes-from other img sh')")"
assert_rc "--device /dev/sda (block device)"   2 "$(run_case "$(j_bash 'docker run --device /dev/sda img sh')")"
assert_rc "-v /usr:/u:rw (sys-integrity rw)"   2 "$(run_case "$(j_bash 'docker run -v /usr:/u:rw img sh')")"
assert_rc "-v /usr:/u (no mode = writable)"    2 "$(run_case "$(j_bash 'docker run -v /usr:/u img sh')")"
assert_rc "-v /etc/../etc (normalise)"         2 "$(run_case "$(j_bash 'docker run -v /etc/../etc:/h img sh')")"
assert_rc "Windows C:\\Users\\me (drive-colon)" 2 "$(run_case "$(j_bash 'docker run -v C:\Users\me:/d img sh')")"
assert_rc "docker cp /etc/shadow (host src)"   2 "$(run_case "$(j_bash 'docker cp /etc/shadow ctr:/x')")"
assert_rc "podman run -v /etc:/h:rw"           2 "$(run_case "$(j_bash 'podman run -v /etc:/h:rw img sh')")"
assert_rc "sudo docker run --privileged"       2 "$(run_case "$(j_bash 'sudo docker run --privileged img sh')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "docker ps"                          0 "$(run_case "$(j_bash 'docker ps')")"
assert_rc "docker build ."                     0 "$(run_case "$(j_bash 'docker build .')")"
assert_rc "docker run --rm alpine echo hi"     0 "$(run_case "$(j_bash 'docker run --rm alpine echo hi')")"
assert_rc "docker logs x"                      0 "$(run_case "$(j_bash 'docker logs x')")"
assert_rc "docker compose up"                  0 "$(run_case "$(j_bash 'docker compose up')")"
assert_rc "-v ./data:/d (relative)"            0 "$(run_case "$(j_bash 'docker run -v ./data:/d img app')")"
assert_rc "-v data:/d (named volume)"          0 "$(run_case "$(j_bash 'docker run -v data:/d img app')")"
assert_rc "-v /tmp/build:/b"                   0 "$(run_case "$(j_bash 'docker run -v /tmp/build:/b img app')")"
assert_rc "-v \$HOME/Documents/proj:/p"        0 "$(run_case "$(j_bash 'docker run -v $HOME/Documents/proj:/p img app')")"
assert_rc "-v /usr/share/fonts:/f:ro (sys ro)" 0 "$(run_case "$(j_bash 'docker run -v /usr/share/fonts:/f:ro img app')")"
assert_rc "-v /etc/localtime:ro (safe ro)"     0 "$(run_case "$(j_bash 'docker run -v /etc/localtime:/etc/localtime:ro img app')")"
assert_rc "-v /etc/resolv.conf:ro (safe ro)"   0 "$(run_case "$(j_bash 'docker run -v /etc/resolv.conf:/etc/resolv.conf:ro img app')")"
assert_rc "-v /opt/data:/d (non-sensitive)"    0 "$(run_case "$(j_bash 'docker run -v /opt/data:/d img app')")"
assert_rc "--user 1000 (non-root)"             0 "$(run_case "$(j_bash 'docker run --user 1000 img app')")"
assert_rc "--cap-add NET_ADMIN (non-root cap)" 0 "$(run_case "$(j_bash 'docker run --cap-add NET_ADMIN img app')")"
assert_rc "non-docker command (git status)"    0 "$(run_case "$(j_bash 'git status')")"
assert_rc "Unknown tool passthrough"           0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"/etc/x"}}')"
assert_rc "Empty input passthrough"            0 "$(run_case '{}')"

# --- HIMMEL-441 CR-hardening: wrapper-with-flags, glob metachars, form variants ---
# Wrapper FLAGS before docker must not defeat the guard (skip-until-docker).
assert_rc "sudo -E docker run -v /etc:/h:rw"   2 "$(run_case "$(j_bash 'sudo -E docker run -v /etc:/host-etc:rw ubuntu /usr/bin/install x y')")"
assert_rc "sudo -u root docker --privileged"   2 "$(run_case "$(j_bash 'sudo -u root docker run --privileged img sh')")"
assert_rc "nice -n 5 docker run --privileged"  2 "$(run_case "$(j_bash 'nice -n 5 docker run --privileged img sh')")"
assert_rc "timeout 10 docker run --privileged" 2 "$(run_case "$(j_bash 'timeout 10 docker run --privileged img sh')")"
assert_rc "env -i docker run --privileged"     2 "$(run_case "$(j_bash 'env -i docker run --privileged img sh')")"
# Docker GLOBAL value-flag before the subcommand must not hide it.
assert_rc "docker --context foo run --priv"    2 "$(run_case "$(j_bash 'docker --context foo run --privileged img sh')")"
# Glob metachars in a host path → fail-CLOSED (shell expands them at runtime).
assert_rc "-v /etc*:/h:rw (glob)"              2 "$(run_case "$(j_bash 'docker run -v /etc*:/h:rw img sh')")"
assert_rc "-v /et[c]:/h:rw (glob class)"       2 "$(run_case "$(j_bash 'docker run -v /et[c]:/h:rw img sh')")"
assert_rc "-v ~/.ss?:/k (glob ?)"              2 "$(run_case "$(j_bash 'docker run -v ~/.ss?:/k img sh')")"
assert_rc "--mount source=/etc? (glob)"        2 "$(run_case "$(j_bash 'docker run --mount type=bind,source=/etc?,target=/h img sh')")"
assert_rc "docker cp /etc?/shadow (glob)"      2 "$(run_case "$(j_bash 'docker cp /etc?/shadow ctr:/x')")"
# Privilege-flag + mount FORM variants (each a distinct case arm).
assert_rc "--user root (space+name)"           2 "$(run_case "$(j_bash 'docker run --user root img sh')")"
assert_rc "-u 0 (space short)"                 2 "$(run_case "$(j_bash 'docker run -u 0 img sh')")"
assert_rc "--user 0:0 (uid:gid)"               2 "$(run_case "$(j_bash 'docker run --user 0:0 img sh')")"
assert_rc "--volume /etc:/h:rw (long form)"    2 "$(run_case "$(j_bash 'docker run --volume /etc:/h:rw img sh')")"
assert_rc "--volume=/etc:/h:rw (long glued)"   2 "$(run_case "$(j_bash 'docker run --volume=/etc:/h:rw img sh')")"
assert_rc "--mount src=/etc (alias)"           2 "$(run_case "$(j_bash 'docker run --mount type=bind,src=/etc,target=/h img sh')")"
assert_rc "--device=/dev/sda (glued)"          2 "$(run_case "$(j_bash 'docker run --device=/dev/sda img sh')")"
assert_rc "docker exec --privileged"           2 "$(run_case "$(j_bash 'docker exec --privileged ctr sh')")"
assert_rc "docker create -v /etc:/h"           2 "$(run_case "$(j_bash 'docker create -v /etc:/h img')")"
assert_rc "cd /tmp && docker run --priv"       2 "$(run_case "$(j_bash 'cd /tmp && docker run --privileged img sh')")"
# Quoted flag TOKEN must not dodge the case match (kimi-7).
assert_rc "quoted \"-v\" /etc:/h:rw"           2 "$(run_case "$(j_bash 'docker run "-v" /etc:/h:rw img sh')")"
assert_rc "quoted \"--privileged\""            2 "$(run_case "$(j_bash 'docker run "--privileged" img sh')")"
assert_rc "docker cp ctr:/x /etc/passwd (dst)" 2 "$(run_case "$(j_bash 'docker cp ctr:/x /etc/passwd')")"
# Negatives: non-block device + sys-integrity read-only via --mount must ALLOW.
assert_rc "--device /dev/fuse (char dev)"      0 "$(run_case "$(j_bash 'docker run --device /dev/fuse img app')")"
assert_rc "--mount source=/usr,readonly (ro)"  0 "$(run_case "$(j_bash 'docker run --mount type=bind,source=/usr,target=/u,readonly img app')")"
assert_rc "docker cp ctr:/x ./local (dst ok)"  0 "$(run_case "$(j_bash 'docker cp ctr:/x ./local')")"

# --- BYPASS case (expect rc=0 with DOCKER_PRIVESC_OK=1) ---
assert_rc "Bypass --privileged"                0 "$(run_case "$(j_bash 'docker run --privileged img sh')" "DOCKER_PRIVESC_OK=1")"
assert_rc "Bypass -v /etc:/h:rw"               0 "$(run_case "$(j_bash 'docker run -v /etc:/h:rw img sh')" "DOCKER_PRIVESC_OK=1")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
