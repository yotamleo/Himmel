#!/usr/bin/env bash
# test-vault-status.sh — HIMMEL-4911. vault-status.sh classifies the luna vault's
# commit health for the console tick (ok | STALL:<age>,<n> | PUSH-LAG:<age> |
# skip | unknown); bucket-gitleaks.sh is the leg-side pre-check of a bucket
# file. Fixture git repos under a scratch dir only: the real vault is never read.
# PLATFORM GUARD: no .ps1 twin, by design (the console kit is Linux-only).
# Run: bash scripts/handover/console-kit/test-vault-status.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VS="$HERE/vault-status.sh"
BG="$HERE/bucket-gitleaks.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/vault-status-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }

export HOME="$W/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
GA=(-c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
unset TICK_VAULT_DIR TICK_VAULT_STALL_MIN TICK_VAULT_PUSHLAG_MIN HANDOVER_DIR

# mkvault <name>: a vault with one commit, tracked upstream bare repo.
mkvault() {
    git init -q --bare "$W/$1.git"
    git init -q -b main "$W/$1"
    git -C "$W/$1" remote add origin "$W/$1.git"
    echo seed > "$W/$1/seed.md"
    git -C "$W/$1" add seed.md
    git -C "$W/$1" "${GA[@]}" commit -q -m seed
    git -C "$W/$1" push -q -u origin main
}
vs() { TICK_VAULT_DIR="$W/$1" bash "$VS" ; }

mkvault v
check 'clean vault reads ok' 'ok' "$(vs v)"

echo staged > "$W/v/a.md"; echo staged2 > "$W/v/b.md"
git -C "$W/v" add a.md b.md
check 'fresh staged files are not a stall' 'ok' "$(vs v)"
touch -d '50 minutes ago' "$W/v/a.md" "$W/v/b.md"  # gnu-ok: console kit is Linux-only
check 'staged files older than the threshold read STALL:<age>,<n>' 'STALL:50m,2' "$(vs v)"
check 'the threshold is env-configurable' 'ok' "$(TICK_VAULT_STALL_MIN=90 TICK_VAULT_DIR="$W/v" bash "$VS")"
echo more >> "$W/v/seed.md"; touch -d '3 hours ago' "$W/v/seed.md"  # gnu-ok: console kit is Linux-only
check 'dirty tracked files count and the oldest sets the age' 'STALL:3h,3' "$(vs v)"
check '--path prints the resolved vault' "$W/v" "$(TICK_VAULT_DIR="$W/v" bash "$VS" --path)"

mkvault p
echo lag > "$W/p/lag.md"; git -C "$W/p" add lag.md
GIT_COMMITTER_DATE="$(date -d '3 hours ago' +%s) +0000" git -C "$W/p" "${GA[@]}" commit -q -m lag   # gnu-ok
check 'a local commit unpushed past the threshold reads PUSH-LAG:<age>' 'PUSH-LAG:3h' "$(vs p)"
check 'the push-lag threshold is env-configurable' 'ok' "$(TICK_VAULT_PUSHLAG_MIN=600 TICK_VAULT_DIR="$W/p" bash "$VS")"
echo s > "$W/p/s.md"; git -C "$W/p" add s.md; touch -d '40 minutes ago' "$W/p/s.md"  # gnu-ok
check 'STALL wins over PUSH-LAG' 'STALL:40m,1' "$(vs p)"

check 'TICK_VAULT_DIR=none reads skip' 'skip' "$(TICK_VAULT_DIR=none bash "$VS")"
check 'no vault configured or resolvable reads skip' 'skip' "$(bash "$VS")"
check 'a vault path that is not a repo reads skip' 'skip' "$(TICK_VAULT_DIR="$W/nope" bash "$VS")"
mkdir -p "$W/plain"
check 'a directory that is not a git repo reads skip' 'skip' "$(TICK_VAULT_DIR="$W/plain" bash "$VS")"
# default from the handover root: <vault>/handovers
mkdir -p "$W/v/handovers"
check 'the default vault is the parent of the handover root' 'STALL:3h,3' "$(HANDOVER_DIR="$W/v/handovers" bash "$VS")"
# fail-soft: a corrupt repo is unknown, rc 0
mkdir -p "$W/bad/.git"; echo garbage > "$W/bad/.git/HEAD"
check 'a corrupt repo reads unknown, not a failure' 'unknown' "$(TICK_VAULT_DIR="$W/bad" bash "$VS")"
TICK_VAULT_DIR="$W/bad" bash "$VS" >/dev/null 2>&1; check 'unknown exits 0' '0' "$?"

# --- bucket-gitleaks.sh -------------------------------------------------------
cp /dev/null "$W/cfg.toml"
printf '[extend]\nuseDefault = true\n' > "$W/cfg.toml"
printf 'plain prose, nothing here\n' > "$W/clean.md"
printf 'the api_key = "%s" is used here\n' "Zk3Qp9Xw7Lm2Vb8Nc4Rt6Yh1Ds5Fg0JaQ" > "$W/fp.md"
out="$(bash "$BG" --config "$W/cfg.toml" "$W/clean.md")"; rc=$?
check 'a clean file prints GITLEAKS ok' 'GITLEAKS ok' "$out"
check 'a clean file exits 0' '0' "$rc"
out="$(bash "$BG" --config "$W/cfg.toml" "$W/fp.md")"; rc=$?
check 'an FP-shaped file prints GITLEAKS FINDING <rule>' 'GITLEAKS FINDING generic-api-key' "$out"
check 'a finding exits 1' '1' "$rc"
case "$out" in *Zk3Qp9*) fail 'the finding line leaks the secret' ;; *) pass 'the finding line does not echo the secret' ;; esac
out="$(bash "$BG" --config "$W/cfg.toml" "$W/missing.md" 2>&1)"; rc=$?
check 'a missing file exits 2' '2' "$rc"
# default config: the resolved vault's .gitleaks.toml
cp "$W/cfg.toml" "$W/v/.gitleaks.toml"
check 'the vault .gitleaks.toml is the default config' 'GITLEAKS FINDING generic-api-key' "$(TICK_VAULT_DIR="$W/v" bash "$BG" "$W/fp.md")"

# HIMMEL-4911 CR round 1: deleted and non-ASCII paths, leading-zero thresholds
mkvault q
echo u > "$W/q/ünï.md"; git -C "$W/q" "${GA[@]}" add 'ünï.md'; git -C "$W/q" "${GA[@]}" commit -q -m u; git -C "$W/q" push -q 2>/dev/null
echo v2 >> "$W/q/ünï.md"; touch -d '50 minutes ago' "$W/q/ünï.md"  # gnu-ok
check 'a non-ASCII dirty path is counted, not skipped' 'STALL:50m,1' "$(vs q)"
git -C "$W/q" checkout -q -- 'ünï.md' 2>/dev/null; git -C "$W/q" rm -q --cached 'ünï.md'; rm -f "$W/q/ünï.md"; touch -d '50 minutes ago' "$W/q/.git/index"  # gnu-ok
check 'a deleted staged path still reads STALL via the index mtime' 'STALL:50m,1' "$(vs q)"
check 'a leading-zero threshold is read as decimal' 'STALL:50m,1' "$(TICK_VAULT_STALL_MIN=08 TICK_VAULT_DIR="$W/q" bash "$VS")"
mkvault r
tabf="$(printf 'a\tb.md')"; echo t > "$W/r/$tabf"; git -C "$W/r" "${GA[@]}" add -- "$tabf"; git -C "$W/r" "${GA[@]}" commit -q -m t; echo t2 >> "$W/r/$tabf"; touch -d '50 minutes ago' "$W/r/$tabf"  # gnu-ok
check 'a tab in a path is counted with its real mtime' 'STALL:50m,1' "$(vs r)"

if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%s FAILED\n' "$fails"; exit 1
