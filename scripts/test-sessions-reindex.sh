#!/usr/bin/env bash
# Smoke test for scripts/sessions-reindex.sh.
# Usage: bash scripts/test-sessions-reindex.sh
# shellcheck disable=SC2015  # `cond && pass || fail` is the intended idiom here; pass never fails
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/sessions-reindex.sh"
[ -r "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

VAULT="$(mktemp -d)"
trap 'rm -rf "$VAULT"' EXIT
mkdir -p "$VAULT/sessions/2026/05" "$VAULT/sessions/2026/06"

note() {  # note <relpath> <type> <repo> <date>
    cat > "$VAULT/sessions/$1" <<EOF
---
date: $4
type: $2
repo: $3
---
body
EOF
}
note "2026/05/2026-05-10-1200-himmel-private-main.md" session himmel-private 2026-05-10T12:00:00Z
note "2026/06/2026-06-02-0900-himmel-private-main.md" session himmel-private 2026-06-02T09:00:00Z
note "2026/06/2026-06-03-1000-luna-medic-master.md"   session luna-medic     2026-06-03T10:00:00Z
# A non-session note + an index-style note that MUST be ignored:
note "2026/06/some-concept.md" note himmel-private 2026-06-04T10:00:00Z
printf -- '---\ntype: backfill-index\n---\n' > "$VAULT/sessions/_backfill-old.md"
# A pre-existing hub that MUST NOT be clobbered:
printf -- '---\ntype: repo-hub\n---\n\n# himmel-private\n\nCURATED PROSE KEEP ME\n' > "$VAULT/sessions/himmel-private.md"
# A note named like a repo but living OUTSIDE sessions/ — [[ext-repo]] already
# resolves there, so NO sessions/ext-repo.md hub should be created.
mkdir -p "$VAULT/30-Resources"
printf -- '---\ntype: note\n---\n# ext-repo\n' > "$VAULT/30-Resources/ext-repo.md"
note "2026/06/2026-06-05-1100-ext-repo-main.md" session ext-repo 2026-06-05T11:00:00Z
# A session note whose BODY contains decoy `repo:`/`type:` lines — the parser
# must read ONLY frontmatter, so repo stays himmel-private (no `evil` hub).
cat > "$VAULT/sessions/2026/06/2026-06-06-1200-himmel-private-main.md" <<'NOTE'
---
date: 2026-06-06T12:00:00Z
type: session
repo: himmel-private
---
Quoted transcript discussing frontmatter:
repo: evil
type: decoy
NOTE

bash "$SCRIPT" --vault "$VAULT" >/dev/null 2>&1

IDX="$VAULT/sessions/_index.md"
[ -f "$IDX" ] && pass "_index.md created" || fail "_index.md not created"

# All three session notes linked; the non-session + index notes not linked.
for b in 2026-05-10-1200-himmel-private-main 2026-06-02-0900-himmel-private-main 2026-06-03-1000-luna-medic-master; do
    grep -q "\[\[$b\]\]" "$IDX" && pass "indexed $b" || fail "missing $b in index"
done
grep -q '\[\[some-concept\]\]' "$IDX" && fail "non-session note wrongly indexed" || pass "non-session note skipped"
grep -q '\[\[_backfill-old\]\]' "$IDX" && fail "index-note wrongly indexed" || pass "index note skipped"

# Count == 5 session notes (3 himmel-private/luna-medic + ext-repo + decoy-body).
grep -q '^count: 5' "$IDX" && pass "count is 5" || fail "count wrong ($(grep '^count:' "$IDX"))"

# Newest month first (2026-06 section appears before 2026-05).
if [ "$(grep -n '^## 2026-06' "$IDX" | cut -d: -f1)" -lt "$(grep -n '^## 2026-05' "$IDX" | cut -d: -f1)" ]; then
    pass "months sorted newest-first"
else
    fail "months not newest-first"
fi
# Within a month, newest-first too (2026-06-06 link precedes 2026-06-02 link).
if [ "$(grep -n '\[\[2026-06-06-1200-himmel-private-main\]\]' "$IDX" | cut -d: -f1)" -lt "$(grep -n '\[\[2026-06-02-0900-himmel-private-main\]\]' "$IDX" | cut -d: -f1)" ]; then
    pass "within-month newest-first"
else
    fail "within-month not newest-first"
fi
# The "Repo hubs:" line links each repo, and the no-hub ext-repo note is still indexed.
grep -q 'Repo hubs:.*\[\[himmel-private\]\]' "$IDX" && pass "index links repo hubs" || fail "index missing repo-hub links"
grep -q '\[\[2026-06-05-1100-ext-repo-main\]\]' "$IDX" && pass "ext-repo note indexed despite no hub" || fail "ext-repo note dropped"

# Missing hub auto-created; existing hub NOT clobbered.
[ -f "$VAULT/sessions/luna-medic.md" ] && pass "luna-medic hub created" || fail "luna-medic hub missing"
grep -q 'CURATED PROSE KEEP ME' "$VAULT/sessions/himmel-private.md" && pass "existing hub not clobbered" || fail "existing hub was clobbered"
# No duplicate hub when a note named <repo>.md already exists elsewhere.
[ -f "$VAULT/sessions/ext-repo.md" ] && fail "duplicate hub created despite vault-wide ext-repo.md" || pass "no dup hub when <repo>.md exists elsewhere"
# Frontmatter-scoped parsing: body `repo: evil` must NOT create an evil hub.
[ -f "$VAULT/sessions/evil.md" ] && fail "body repo: line leaked into parsing (evil hub created)" || pass "body repo:/type: lines ignored (frontmatter-scoped)"

# Idempotent: second run leaves the curated hub intact and still count 4.
bash "$SCRIPT" --vault "$VAULT" >/dev/null 2>&1
grep -q 'CURATED PROSE KEEP ME' "$VAULT/sessions/himmel-private.md" && pass "idempotent: hub still intact" || fail "second run clobbered hub"
grep -q '^count: 5' "$IDX" && pass "idempotent: count stable" || fail "second run changed count"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
