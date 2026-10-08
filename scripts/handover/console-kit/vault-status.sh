#!/usr/bin/env bash
# vault-status.sh — HIMMEL-4911. One-token health of the luna vault's commit
# path, for tick.sh's vault= field and console-wait.sh's wake:
#   ok               nothing staged/dirty past the threshold, nothing unpushed past it
#   STALL:<age>,<n>  <n> staged/modified tracked files, the oldest <age> old (the
#                    auto-commit is stuck: reproduce with `git -C <vault> hook run pre-commit`)
#   PUSH-LAG:<age>   local commits ahead of upstream, the oldest <age> old
#   skip             no vault configured, or the path is not a git repo
#   unknown          a git read failed (fail-soft: always exit 0)
# --path prints the resolved vault dir instead (empty when skip).
#
# Vault: TICK_VAULT_DIR (`none` = skip), else the parent of the handover root
# (HANDOVER_DIR, e.g. <luna>/handovers). Thresholds, minutes:
# TICK_VAULT_STALL_MIN (default 20), TICK_VAULT_PUSHLAG_MIN (default 60).
# Git plumbing only, no index refresh, read-only (--no-optional-locks), bounded.
# ponytail: age is the oldest file mtime / oldest unpushed commit time, not the
# moment the hook began failing; the thresholds absorb that, a stage-time ledger is overkill.
# bash 3.2-safe; no .ps1 twin (the console kit is Linux-only).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too (HIMMEL-3570)

want_path=0
[ "${1:-}" = "--path" ] && want_path=1

vault="${TICK_VAULT_DIR:-}"
if [ -z "$vault" ] && [ -n "${HANDOVER_DIR:-}" ]; then
    vault="$(cd "$HANDOVER_DIR/.." 2>/dev/null && pwd)" || vault=""
fi
case "$vault" in ''|none) vault="" ;; esac
if [ -n "$vault" ] && [ ! -e "$vault/.git" ]; then vault=""; fi

if [ "$want_path" -eq 1 ]; then printf '%s\n' "$vault"; exit 0; fi
if [ -z "$vault" ]; then printf 'skip\n'; exit 0; fi

g() { ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 10} git --no-optional-locks -C "$vault" "$@"; }
fmt_age() { # <seconds>
    local s="$1"
    [ "$s" -ge 0 ] 2>/dev/null || s=0
    if [ "$s" -ge 172800 ]; then printf '%sd' $((s / 86400))
    elif [ "$s" -ge 3600 ]; then printf '%sh' $((s / 3600))
    else printf '%sm' $((s / 60)); fi
}

now="$(date +%s)"
stall_min="${TICK_VAULT_STALL_MIN:-20}"; lag_min="${TICK_VAULT_PUSHLAG_MIN:-60}"
case "$stall_min" in ''|*[!0-9]*) stall_min=20 ;; esac
case "$lag_min" in ''|*[!0-9]*) lag_min=60 ;; esac
stall_min=$((10#$stall_min)); lag_min=$((10#$lag_min))   # 08/09 are not octal

g rev-parse --git-dir >/dev/null 2>&1 || { printf 'unknown\n'; exit 0; }
# -z turns off path quoting; tr then makes it line-based (ponytail: a path with a
# newline in its name splits in two, parse NUL-delimited if one ever shows up)
staged="$(g diff --cached --name-only -z 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")" || { printf 'unknown\n'; exit 0; }
dirty="$(g diff --name-only -z 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")" || { printf 'unknown\n'; exit 0; }
idx="$(g rev-parse --path-format=absolute --git-path index 2>/dev/null)" || idx=""

files="$(printf '%s\n%s\n' "$staged" "$dirty" | sed '/^$/d' | sort -u)"
n=0; oldest=""
if [ -n "$files" ]; then
    while IFS= read -r f; do
        n=$((n + 1))
        # a deleted path has no mtime of its own: the index's stands in for it
        m="$(stat -c %Y "$vault/$f" 2>/dev/null)" || m="$(stat -c %Y "$idx" 2>/dev/null)" || continue  # gnu-ok: console kit is Linux-only
        if [ -z "$oldest" ] || [ "$m" -lt "$oldest" ]; then oldest="$m"; fi
    done <<EOF
$files
EOF
fi
if [ "$n" -gt 0 ] && [ -n "$oldest" ]; then
    age=$((now - oldest))
    if [ "$age" -ge $((stall_min * 60)) ]; then printf 'STALL:%s,%s\n' "$(fmt_age "$age")" "$n"; exit 0; fi
fi

g rev-parse --verify -q '@{u}' >/dev/null 2>&1; up_rc=$?
# rc 1 = no upstream configured (nothing to lag behind); any other rc is a failed read
case "$up_rc" in 0|1) : ;; *) printf 'unknown\n'; exit 0 ;; esac
if [ "$up_rc" -eq 0 ]; then
    ahead="$(g log '@{u}..HEAD' --format=%ct 2>/dev/null)" || { printf 'unknown\n'; exit 0; }
    first="$(printf '%s\n' "$ahead" | tail -n 1)"
    if [ -n "$first" ]; then
        age=$((now - first))
        if [ "$age" -ge $((lag_min * 60)) ]; then printf 'PUSH-LAG:%s\n' "$(fmt_age "$age")"; exit 0; fi
    fi
fi
printf 'ok\n'
