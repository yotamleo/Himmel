#!/usr/bin/env bash
# Migrate handovers/<user>/ from v1 (#N-slug/) to v2 (<JIRA-KEY>-slug/).
#
# Idempotent — re-runs are safe; already-migrated items are skipped.
#
# Usage:
#   migrate-v1-to-v2.sh [--root <path>] [--user <name>] [--no-jira-create] [--dry-run] [--quiet]
#
# Flags:
#   --root <path>       repo root (default: git rev-parse --show-toplevel)
#   --user <name>       user slug (default: derive from handovers/ subdir)
#   --no-jira-create    do NOT call jira create for unkeyed items; mark pending_jira_link: true
#   --dry-run           print what would change; do not modify filesystem
#   --quiet             suppress progress output
#
# Exit codes:
#   0 — success (or dry-run with no errors)
#   1 — fatal error (e.g. root not a git repo, no handovers/ dir)
#   2 — partial success (some items renamed, some failed; see stderr)
set -uo pipefail

ROOT=""
USER_SLUG=""
NO_JIRA_CREATE=0
DRY_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --user) USER_SLUG="$2"; shift 2 ;;
    --no-jira-create) NO_JIRA_CREATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[ -z "$ROOT" ] && ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -d "$ROOT/handovers" ] || { echo "ERR: no handovers/ under $ROOT" >&2; exit 1; }

if [ -z "$USER_SLUG" ]; then
  USER_SLUG="$(for d in "$ROOT/handovers"/*/; do [ -d "$d" ] && basename "$d" && break; done 2>/dev/null)"
fi
STATE="$ROOT/handovers/$USER_SLUG"
[ -d "$STATE" ] || { echo "ERR: state-root $STATE not found" >&2; exit 1; }

log() {
  [ "$QUIET" -eq 0 ] && echo "$@"
}

extract_jira() {
  local f="$1"
  local key
  # 1. Prefer YAML frontmatter `jira:` field (set by v2 upgrade_frontmatter)
  #    -- read only the frontmatter block (between leading --- markers).
  key="$(awk 'NR==1 && /^---$/ {in_fm=1; next} in_fm && /^---$/ {exit} in_fm && /^jira:[[:space:]]/ {print; exit}' "$f" 2>/dev/null \
         | sed -E 's/^jira:[[:space:]]*//' \
         | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' \
         | head -1)"

  # 2. Fall back to the body `**Jira:**` line; extract the first KEY-N token.
  if [ -z "$key" ]; then
    key="$(grep -m1 -E '^\*\*Jira:\*\*' "$f" 2>/dev/null \
           | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' \
           | head -1)"
  fi

  if [ -z "$key" ]; then
    echo "—"
  else
    echo "$key"
  fi
}

extract_status() {
  grep -m1 -E '^\*\*Status:\*\*' "$1" 2>/dev/null | sed -E 's/.*Status:\*\*[[:space:]]*//' | awk '{print $1}'
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_template_version() {
  local file="$1"
  # If file already has template_version: 2, no-op.
  if head -3 "$file" | grep -q '^template_version: 2$'; then
    return 0
  fi
  # If has template_version: 1, sed it.
  if head -3 "$file" | grep -q '^template_version: 1$'; then
    if [ "$DRY_RUN" -eq 0 ]; then
      local tmp
      tmp="$(mktemp)"
      sed 's/^template_version: 1$/template_version: 2/' "$file" > "$tmp"
      mv "$tmp" "$file"
    fi
    return 0
  fi
  # If has no template_version field at all, prepend frontmatter.
  if ! head -1 "$file" | grep -q '^---$'; then
    if [ "$DRY_RUN" -eq 0 ]; then
      local tmp
      tmp="$(mktemp)"
      printf -- '---\ntemplate_version: 2\n---\n' > "$tmp"
      cat "$file" >> "$tmp"
      mv "$tmp" "$file"
    fi
  fi
  # Edge case: has frontmatter but no template_version line — leave for now (rare).
}

upgrade_frontmatter() {
  local file="$1" jira="$2" pending="$3"
  local now
  now="$(now_utc)"

  python3 - "$file" "$jira" "$pending" "$now" <<'PY'
import sys, re, pathlib
path, jira, pending, now = sys.argv[1:5]
p = pathlib.Path(path)
text = p.read_text(encoding='utf-8')

m = re.match(r'^---\n(.*?)\n---\n(.*)$', text, re.DOTALL)
if not m:
    fm = ''
    body = text
else:
    fm = m.group(1)
    body = m.group(2)

fields = {}
for line in fm.split('\n'):
    if ':' in line:
        k, v = line.split(':', 1)
        fields[k.strip()] = v.strip()

fields['template_version'] = '2'
fields['jira'] = jira if jira else '—'
fields.setdefault('bucket', 'later')
fields.setdefault('priority', 'Medium')
fields.setdefault('severity', '—')
fields.setdefault('created', now)
fields['updated'] = now
fields['pending_jira_link'] = pending

order = ['template_version', 'jira', 'bucket', 'priority', 'severity',
         'created', 'updated', 'pending_jira_link']
remaining = [k for k in fields if k not in order]
new_fm = '\n'.join(f"{k}: {fields[k]}" for k in order + remaining)
p.write_text(f"---\n{new_fm}\n---\n{body}", encoding='utf-8')
PY

  # Also update the body **Jira:** line so subsequent parent lookups
  # and human readers see the v2 key.
  if [ "$jira" != "—" ]; then
    if grep -q '^\*\*Jira:\*\*' "$file"; then
      local tmp
      tmp="$(mktemp)"
      awk -v k="$jira" '/^\*\*Jira:\*\*/ {print "**Jira:** " k; next} {print}' "$file" > "$tmp"
      mv "$tmp" "$file"
    fi
  fi
}

process_item() {
  local dir="$1" type="$2"
  local n_slug
  n_slug="$(basename "$dir")"

  # Already v2? (dir starts with project prefix, not #)
  case "$n_slug" in
    '#'*) ;;
    *) log "  skip (already v2): $dir"; return 1 ;;
  esac

  local plan
  case "$type" in
    epic) plan="$dir/master-plan.md" ;;
    task) plan="$dir/brief.md" ;;
    standalone) plan="$dir/brief.md" ;;
  esac
  [ -f "$plan" ] || { log "  skip (no plan): $dir"; return 1; }

  local jira
  jira="$(extract_jira "$plan")"
  local pending="false"
  local new_name

  if [ "$jira" = "—" ]; then
    if [ "$NO_JIRA_CREATE" -eq 1 ]; then
      pending="true"
      new_name="$n_slug"
    else
      local jtype="Story" parent=""
      case "$type" in
        epic) jtype="Epic" ;;
        task)
          jtype="Task"
          local epic_dir
          epic_dir="$(dirname "$(dirname "$dir")")"
          parent="$(extract_jira "$epic_dir/master-plan.md")"
          ;;
        standalone) jtype="Story" ;;
      esac

      local status
      status="$(extract_status "$plan")"
      local slug
      slug="${n_slug#\#*-}"

      log "  jira create --type $jtype ${parent:+--parent $parent} --title '$slug'"
      if [ "$DRY_RUN" -eq 0 ]; then
        local out
        if [ -n "$parent" ]; then
          out="$(jira create --type "$jtype" --parent "$parent" --title "$slug" --desc "retro for handover migration v2" 2>&1)" || {
            echo "ERR: jira create failed for $dir: $out" >&2
            return 2
          }
        else
          out="$(jira create --type "$jtype" --title "$slug" --desc "retro for handover migration v2" 2>&1)" || {
            echo "ERR: jira create failed for $dir: $out" >&2
            return 2
          }
        fi
        jira="$(echo "$out" | grep -oE '[A-Z]+-[0-9]+' | head -1)"
        if [ "$status" = "done" ]; then
          jira transition "$jira" Done >/dev/null 2>&1 || true
        fi
      else
        jira="HIMMEL-DRY"
      fi
      new_name="${jira}-${n_slug#\#*-}"
    fi
  else
    new_name="${jira}-${n_slug#\#*-}"
  fi

  if [ "$new_name" != "$n_slug" ]; then
    log "  rename: $n_slug → $new_name"
    if [ "$DRY_RUN" -eq 0 ]; then
      if ! git -C "$ROOT" mv "$dir" "$(dirname "$dir")/$new_name" 2>&1; then
        log "  WARN: git mv failed; falling back to plain mv (git index may be inconsistent)"
        mv "$dir" "$(dirname "$dir")/$new_name"
      fi
      dir="$(dirname "$dir")/$new_name"
      plan="$dir/$(basename "$plan")"
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    upgrade_frontmatter "$plan" "$jira" "$pending"
    # The plan file got the full v2 frontmatter; remaining .md files just need version stamp.
    for aux in "$dir"/*.md; do
      [ -f "$aux" ] || continue
      [ "$aux" = "$plan" ] && continue
      ensure_template_version "$aux"
    done
  fi
  return 0
}

errors=0
log "Migrating $STATE → v2 (dry_run=$DRY_RUN, no_jira_create=$NO_JIRA_CREATE)"

# Epics first.
for d in "$STATE"/epics/*/; do
  [ -d "$d" ] || continue
  process_item "$d" epic
  rc=$?
  [ "$rc" -eq 2 ] && errors=$((errors+1))
done

# Tasks under epics.
for d in "$STATE"/epics/*/tasks/*/; do
  [ -d "$d" ] || continue
  process_item "$d" task
  rc=$?
  [ "$rc" -eq 2 ] && errors=$((errors+1))
done

# Standalones.
for d in "$STATE"/standalones/*/; do
  [ -d "$d" ] || continue
  process_item "$d" standalone
  rc=$?
  [ "$rc" -eq 2 ] && errors=$((errors+1))
done

# One-shot aux-file stamp: already-v2 items skipped by process_item still need their
# non-plan .md files stamped (bugs.md, context.md, plan.md, extra-rules.md, etc.).
if [ "$DRY_RUN" -eq 0 ]; then
  for d in "$STATE"/epics/*/; do
    [ -d "$d" ] || continue
    for aux in "$d"*.md; do
      [ -f "$aux" ] || continue
      ensure_template_version "$aux"
    done
  done
  for d in "$STATE"/epics/*/tasks/*/; do
    [ -d "$d" ] || continue
    for aux in "$d"*.md; do
      [ -f "$aux" ] || continue
      ensure_template_version "$aux"
    done
  done
  for d in "$STATE"/standalones/*/; do
    [ -d "$d" ] || continue
    for aux in "$d"*.md; do
      [ -f "$aux" ] || continue
      ensure_template_version "$aux"
    done
  done
  log "Stamped all item aux .md files to template_version: 2"
fi

# One-shot _templates/ refresh: every template must be v2.
if [ "$DRY_RUN" -eq 0 ] && [ -d "$STATE/_templates" ]; then
  for f in "$STATE"/_templates/*.md; do
    [ -f "$f" ] || continue
    ensure_template_version "$f"
  done
  log "Refreshed _templates/ to template_version: 2"
fi

if [ "$errors" -gt 0 ]; then
  echo "Done with errors=$errors" >&2
  exit 2
fi
log "Done"
exit 0
