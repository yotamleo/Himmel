#!/usr/bin/env bash
# shellcheck disable=SC2015
# Hermetic tests for resume.sh — no git repo needed (uses --repo-root override).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/resume.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
has(){ printf '%s' "$2" | grep -q "$3" && echo "ok - $1" || { echo "FAIL - $1: missing [$3]"; fails=$((fails+1)); }; }
hasnt(){ printf '%s' "$2" | grep -q "$3" && { echo "FAIL - $1: unexpected [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# --- fixture handover tree (Mode B bucket layout) + fake registry ---
root="$tmp/handovers"; base="$root/yotamleo/himmel"
mkdir -p "$base/standalones/HIMMEL-389-vault-upgrade" \
         "$base/standalones/#77-bare-item" \
         "$base/epics/HIMMEL-414-cr-epic" \
         "$base/epics/HIMMEL-500-live-epic"

# Standalone with two session files (latest wins) + a Cold-Start block bounded by a later ## heading.
printf '**Status:** pending\n' > "$base/standalones/HIMMEL-389-vault-upgrade/brief.md"
cat > "$base/standalones/HIMMEL-389-vault-upgrade/next-session-1.md" <<'MD'
## Cold-Start Prompt

RESUME-389-V1 old body.

## Overnight Mode Trigger
ignore me
MD
cat > "$base/standalones/HIMMEL-389-vault-upgrade/next-session-2.md" <<'MD'
# Next Session
## Cold-Start Prompt

RESUME-389-V2 line one.
RESUME-389-V2 line two.

## Overnight Mode Trigger
ignore me too
MD

# #N standalone, no session file -> fallback to brief.md.
printf '**Status:** in-progress\nBRIEF-77-MARKER body.\n' > "$base/standalones/#77-bare-item/brief.md"

# Epics: one done (excluded from --list), one live (included).
printf '**Status:** done\n' > "$base/epics/HIMMEL-414-cr-epic/master-plan.md"
printf '**Status:** in-progress\n' > "$base/epics/HIMMEL-500-live-epic/master-plan.md"

# Epic-task: a task carries its OWN Jira key (HIMMEL-501), NOT epic-key+subnum —
# so the ID extractor takes the full key, no truncation. No session file -> brief fallback.
mkdir -p "$base/epics/HIMMEL-500-live-epic/tasks/HIMMEL-501-first-task"
printf '**Status:** in-progress\nTASK-501-MARKER body.\n' > "$base/epics/HIMMEL-500-live-epic/tasks/HIMMEL-501-first-task/brief.md"

# tech-debt.md with a Lingering entry -> stale nudge.
cat > "$root/yotamleo/tech-debt.md" <<'MD'
## Lingering (decompose me)

- **HIMMEL-999** lingering-example — decompose
MD

reg="$tmp/registry.json"
cat > "$reg" <<'JSON'
{ "repos": { "himmel": {
  "path": "c:/work/himmel", "user": "yotamleo", "jira_project": "HIMMEL"
} } }
JSON
RR="C:/Work/Himmel"   # mixed-case to prove case-insensitive registry match
run(){ HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root "$RR" "$@"; }

# 1. Key form -> latest session's Cold-Start block, trimmed at the next ## heading.
o="$(run HIMMEL-389)"
has "key form: latest block"     "$o" "RESUME-389-V2 line one"
hasnt "key form: excludes overnight" "$o" "Overnight Mode Trigger"
hasnt "key form: not the older v1"   "$o" "RESUME-389-V1"
has "key form: stale nudge"      "$o" "lingering-example"

# 2. Bare numeric -> dual scan finds HIMMEL-389.
has "bare numeric finds key item" "$(run 389)" "RESUME-389-V2 line one"

# 3. #N with no session file -> fallback to brief.md.
o="$(run 77)"
has "bare 77 -> #77 fallback brief" "$o" "BRIEF-77-MARKER"
has "bare 77 -> shows-brief notice" "$o" "no session file yet"
has "hash form 77 -> #77 fallback"  "$(run '#77')" "BRIEF-77-MARKER"

# 3b. Epic-task path (own KEY-N) -> resolves + falls back to brief.
o="$(run HIMMEL-501)"
has "epic-task resolves"       "$o" "TASK-501-MARKER"
has "epic-task id not truncated" "$o" "for HIMMEL-501"

# 4. --list: active only, excludes the done epic, includes the epic-task.
o="$(run --list)"
has "list: live standalone"  "$o" "HIMMEL-389"
has "list: #77 item"         "$o" "#77"
has "list: live epic"        "$o" "HIMMEL-500"
has "list: epic-task row"    "$o" "$(printf 'HIMMEL-501\tfirst-task\tin-progress\ttask')"
hasnt "list: excludes done"  "$o" "HIMMEL-414"

# 5. Error paths.
run merge >/dev/null 2>&1; check "invalid ID -> rc 2" "$?" "2"
run 999999 >/dev/null 2>&1; check "not found -> rc 3" "$?" "3"
run 1 2 >/dev/null 2>&1; check "too many args -> rc 2" "$?" "2"
HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root >/dev/null 2>&1
check "--repo-root without value -> rc 2" "$?" "2"
HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root "C:/Work/Other" 5 >/dev/null 2>&1
check "unregistered repo -> rc 3" "$?" "3"
run --list HIMMEL-389 >/dev/null 2>&1
check "--list with an ID -> rc 2" "$?" "2"

# 6. node lookup crash (rc neither 0/1/2) -> hard error, not misreported as graceful skip.
fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 5
SH
chmod +x "$fakebin/node"
PATH="$fakebin:$PATH" HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root "$RR" 389 >/dev/null 2>&1
check "node crash (rc=5) -> hard error, not graceful skip" "$?" "2"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
