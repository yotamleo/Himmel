#!/usr/bin/env bash
# SessionStart hook (HIMMEL-1666). Pins every $CLAUDE_PROJECT_DIR-relative
# guard script (scripts/hooks/*.sh, scripts/guardrails/*.sh) to its
# git-committed blob hash at HEAD, keyed by this session's session_id, in a
# location outside every worker's Edit(<worktree>) grant
# ($HIMMEL_HOOK_INTEGRITY_DIR, default ~/.claude/himmel/hook-integrity).
#
# run-hook-with-bash.js's verifyProjectHookIntegrity() compares each script's
# ON-DISK content against this pin before running it — see that file's header
# comment for the full mechanism. This hook only needs to run BEFORE any tool
# call in the session, which SessionStart guarantees; it does not need to be
# fast relative to a PreToolUse hook, and it never blocks anything itself.
#
# HONEST RESIDUAL (HIMMEL-2085): the pin directory is an ordinary user-
# writable path, and a dispatched worker whose envelope grants unrestricted
# Bash (Bash(node *)/Bash(bash *), WORKER_BASH_ALLOW) runs as the SAME OS user
# this hook does — nothing at the filesystem level stops
# `bash -c 'echo ... > $out_dir/$session_id.json'` from forging a pin to match
# a tampered guard. block-glm-external-writes.sh's pin-dir write-fence class
# now denies that Bash/PowerShell shape for EVERY dispatched worker lane (GLM
# or native, keyed on the general HIMMEL_WORKER marker, not just GLM), closing
# the class of attack this comment used to warn was fully open. It remains a
# command-TEXT fence, not a filesystem permission boundary: an OS-user-level
# attacker (chmod the pin file writable first, a second process, a path built
# from characters/bytes never spelled out as the pin-dir string) is still out
# of scope — see that hook's own header for the full residual. The chmod/attrib
# read-only step below stays a cheap deterrent against ACCIDENTAL overwrite on
# top of that fence, not a substitute for it.
#
# Best-effort and ADVISORY like every SessionStart hook: every early exit below
# is `exit 0` with no pin file written. run-hook-with-bash.js reads a missing
# pin file as "cannot verify" and fails OPEN — see its header for why that
# direction is the safe rollout default. This hook writing nothing is a
# same-as-today outcome, never a new way to break a session.
set -uo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0
# session_id is used below to build a filesystem path ($out_dir/$session_id.json)
# and comes straight off stdin JSON with no shape guarantee from this hook's
# own contract. Restrict it to the token shape a real session id actually is
# (alnum/hyphen/underscore) before it ever reaches a path - anything else
# (a `/`, `..`, a leading `-` a later `mv`/`jq` could read as a flag) exits
# clean rather than resolving outside $out_dir or being reinterpreted as an
# option. This is a defensive floor, not a response to a specific payload
# shape Claude Code is known to send.
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# Only inside a real git worktree of this project — a fixture/temp dir with no
# .git (e.g. test-plugin-hook-bash-wiring.sh's sandbox) leaves no pin file,
# which is the fail-open case above, by design.
git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

out_dir="${HIMMEL_HOOK_INTEGRITY_DIR:-$HOME/.claude/himmel/hook-integrity}"
mkdir -p "$out_dir" 2>/dev/null || exit 0

tmp="$(mktemp "${TMPDIR:-/tmp}/hook-integrity.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$tmp"' EXIT

{
  printf '{"session_id":%s,"recorded_at":"%s","pins":{' \
    "$(printf '%s' "$session_id" | jq -Rs '.')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=1
  for dir in scripts/hooks scripts/guardrails; do
    [ -d "$CLAUDE_PROJECT_DIR/$dir" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      mode_type_sha="$(printf '%s' "$line" | cut -f1)"
      blob="$(printf '%s' "$mode_type_sha" | awk '{print $3}')"
      relpath="$(printf '%s' "$line" | cut -f2-)"
      if [ -z "$blob" ] || [ -z "$relpath" ]; then continue; fi
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '%s:%s' "$(printf '%s' "$relpath" | jq -Rs '.')" "$(printf '%s' "$blob" | jq -Rs '.')"
    done < <(git -C "$CLAUDE_PROJECT_DIR" ls-tree -r HEAD -- "$dir" 2>/dev/null | grep -E '\.sh$')
  done
  printf '}}\n'
} > "$tmp"

# Validate before publishing: a malformed pin file must not become a permanent
# fail-open for the whole session by being read and rejected on every hook
# call — better to leave no file, the same outcome as never having run.
jq -e . "$tmp" >/dev/null 2>&1 || exit 0
dest="$out_dir/$session_id.json"
mv -f "$tmp" "$dest" 2>/dev/null || exit 0
# Read-only best-effort (see the residual note above — deterrent, not a
# defense). chmod is the POSIX/Git-Bash path; attrib covers a native cmd.exe
# HOME on Windows where chmod may be a no-op. Failure here is not fatal — the
# pin file still exists and still protects the accidental/careless case.
chmod 400 "$dest" 2>/dev/null || true
command -v attrib >/dev/null 2>&1 && attrib +R "$dest" >/dev/null 2>&1
exit 0
