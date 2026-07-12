#!/usr/bin/env bash
# Hermetic, git-oracle tests for the one-time clip-lifecycle migration engine
# (LUNA-86): tools/migrate-clip-lifecycle.mjs.
#
# Backfills top-level `processed: true` clips into Clippings/_evidence/, with a
# SIX-form (3 plain + 3 `.md`) literal boundary-safe inbound-link rewrite, an
# exactly-reversible `evidence_kind` frontmatter insertion, and a byte-identical
# rollback proved against a pre-migration git commit.
#
# Style mirrors test-triage-evidence-move.sh / test-archive-clips.sh: build a
# hermetic temp vault, drive the REAL engine, assert end-state. bash 3.2-safe
# (no mapfile / no associative arrays).
#
# TDD: written BEFORE tools/migrate-clip-lifecycle.mjs exists → starts RED.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$PLUGIN_DIR/tools/migrate-clip-lifecycle.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

VAULT="$tmp/vault"
MANIFEST="$tmp/manifest.json"   # OUTSIDE the vault tree (must not dirty git oracle)

mkdir -p "$VAULT/Clippings/_synthesis"
mkdir -p "$VAULT/Clippings/_done/2026-05"
mkdir -p "$VAULT/Clippings/2026-06"
mkdir -p "$VAULT/50-Journal/Daily"
mkdir -p "$VAULT/30-Resources/Tech"

# ── Clip ids — realistic metachars: en-dash, space, +, ( ) ───────────────────
ID1='@DataChaz – 2026-05-25T143753+0200'                       # tweet  → authors  (2026-05)
ID2='@karpathy – 2026-05-25T031232+0200'                       # research → concepts (2026-05)
ID2EXTRA="$ID2-extra"                                          # prefix-sibling (unprocessed, must NOT move/clobber)
ID3='LangGraph (multi-agent) +notes – 2026-06-10T101010+0200'  # github → tools   (2026-06)
ID4REL='2026-06/Subfolder Clip – 2026-06-12T080000+0200'       # subfolder (depth-2) → tools (2026-06)
ID4BASE='Subfolder Clip – 2026-06-12T080000+0200'
ID5='Lonely Clip – 2026-05-05T090000+0200'                     # misc, no inbound (2026-05)
ID6='Yt Talk – 2026-06-20T120000+0200'                         # youtube → concepts (2026-06)
ID7='Plain A – 2026-05-15T080000+0200'                         # (2026-05)
ID8='Plain B – 2026-06-15T080000+0200'                         # (2026-06)

# ── Eligible clips (top-level, processed: true) ──────────────────────────────
{
    printf -- '---\ntype: tweet\nharvested_at: 2026-05-25\nprocessed: true\n'
    printf -- 'date_clipped: 2026-05-25T143753+0200\ntags:\n  - author\n---\n'
    printf -- 'DataChaz body.\n'
} > "$VAULT/Clippings/$ID1.md"

{
    printf -- '---\ntype: research\nharvested_at: 2026-05-25\nprocessed: true\n'
    printf -- 'date_clipped: 2026-05-25T031232+0200\n---\n'
    printf -- 'karpathy body.\n\n## Promotion candidate\n'
    # shellcheck disable=SC2016  # backtick is literal markdown, not command substitution
    printf -- '- **Bi-temporal anchor:** carry `derived_from: [[Clippings/%s]]` and fresh date.\n' "$ID2"
} > "$VAULT/Clippings/$ID2.md"

{
    printf -- '---\ntype: article\nharvested_at: 2026-06-10\nprocessed: true\n'
    printf -- 'date_clipped: 2026-06-10T101010+0200\n'
    printf -- 'harvest_url_canonical: https://github.com/langchain-ai/langgraph\n---\n'
    printf -- 'langgraph body.\n'
} > "$VAULT/Clippings/$ID3.md"

{
    printf -- '---\ntype: article\nharvested_at: 2026-06-12\nprocessed: true\n'
    printf -- 'date_clipped: 2026-06-12T080000+0200\ntags: [tool, cli]\n---\n'
    printf -- 'subfolder body.\n'
} > "$VAULT/Clippings/$ID4REL.md"

{
    printf -- '---\ntype: article\nharvested_at: 2026-05-05\nprocessed: true\n'
    printf -- 'date_clipped: 2026-05-05T090000+0200\n---\n'
    # cross-dependency: this eligible clip links ANOTHER eligible clip (ID7) —
    # regression-guards the reverse-order rollback clip-interdependency property.
    printf -- 'lonely body, see [[Clippings/%s]].\n' "$ID7"
} > "$VAULT/Clippings/$ID5.md"

{
    printf -- '---\ntype: youtube\nharvested_at: 2026-06-20\nprocessed: true\n'
    printf -- 'date_clipped: 2026-06-20T120000+0200\n---\n'
    printf -- 'yt body.\n'
} > "$VAULT/Clippings/$ID6.md"

{
    printf -- '---\ntype: article\nharvested_at: 2026-05-15\nprocessed: true\n'
    printf -- 'date_clipped: 2026-05-15T080000+0200\n---\n'
    # cross-dependency (mutual): ID7 links back to ID5 — both are eligible and
    # both migrate, so reverse-order rollback must restore the mutual link too.
    printf -- 'plain A body, see [[Clippings/%s]].\n' "$ID5"
} > "$VAULT/Clippings/$ID7.md"

{
    printf -- '---\ntype: article\nharvested_at: 2026-06-15\nprocessed: true\n'
    printf -- 'date_clipped: 2026-06-15T080000+0200\n---\n'
    printf -- 'plain B body.\n'
} > "$VAULT/Clippings/$ID8.md"

# ── Ineligible clips (must stay top-level) ───────────────────────────────────
# Prefix-sibling: UNPROCESSED → stays put; pure boundary guard.
{
    printf -- '---\ntype: research\nharvested_at: 2026-05-25\nprocessed: false\n'
    printf -- 'date_clipped: 2026-05-25T031232+0200\n---\n'
    printf -- 'sibling body.\n'
} > "$VAULT/Clippings/$ID2EXTRA.md"

# Unharvested clip (no processed: key)
{
    printf -- '---\ntype: article\nharvested_at: 2026-05-01\n---\n'
    printf -- 'unharvested body.\n'
} > "$VAULT/Clippings/Unharvested – 2026-05-01T000000+0200.md"

# ── Folders the migration MUST ignore ────────────────────────────────────────
{
    printf -- '---\ntype: article\nprocessed: true\n---\n'
    printf -- 'already graduated.\n'
} > "$VAULT/Clippings/_done/2026-05/Done Clip – 2026-04-01.md"

printf -- '---\ntype: pipeline-deferred\n---\n# Deferred\n' > "$VAULT/Clippings/_deferred.md"

# ── Inbound citations ────────────────────────────────────────────────────────
# Synthesis page — the silent-dangle regression surface (.md-suffixed forms).
{
    printf -- '---\ntype: synthesis\n---\n# Synthesis\n\n'
    printf -- '- plain .md cite: [[Clippings/%s.md]]\n'              "$ID1"   # .md]]  (mandatory #1)
    printf -- '- aliased .md cite: [[Clippings/%s.md|DataChaz thread]]\n' "$ID1"   # .md|alias
    printf -- '- heading .md cite: [[Clippings/%s.md#Key Ideas]]\n'  "$ID2"   # .md#heading (mandatory #2)
    printf -- '- sibling plain: [[Clippings/%s]]\n'                  "$ID2EXTRA"  # boundary guard
    printf -- '- sibling .md: [[Clippings/%s.md]]\n'                 "$ID2EXTRA"  # boundary guard (.md)
} > "$VAULT/Clippings/_synthesis/synth.md"

# Daily note — non-.md plain backref to ID3.
{
    printf -- '---\ndate: 2026-06-10\ntype: daily\n---\n\n## Actions\n'
    printf -- '- [ ] try it (from [[Clippings/%s]])\n' "$ID3"
} > "$VAULT/50-Journal/Daily/2026-06-10.md"

# External note — non-.md aliased link to subfolder clip + non-.md # form to ID2.
{
    printf -- '- sub: [[Clippings/%s|Sub alias]]\n' "$ID4REL"
    printf -- '- kar: [[Clippings/%s#Key Ideas]]\n' "$ID2"
} > "$VAULT/30-Resources/Tech/notes.md"

# Engine state files (manifest default / ledger / lock) must never dirty git.
printf -- '.migrate-clip-lifecycle.*\n' > "$VAULT/.gitignore"

# ── git oracle ───────────────────────────────────────────────────────────────
git -C "$VAULT" init -q
git -C "$VAULT" add -A
git -C "$VAULT" -c user.email=t@t.dev -c user.name=test commit -qm "pre-migration oracle"

porcelain_count() { git -C "$VAULT" status --porcelain | wc -l | tr -d ' '; }

# Count vault files still referencing an OLD id via any of the SIX literal forms.
six_form_files() {
    local id="$1"
    grep -rlF \
        -e "[[Clippings/$id]]"    -e "[[Clippings/$id|"    -e "[[Clippings/$id#" \
        -e "[[Clippings/$id.md]]" -e "[[Clippings/$id.md|" -e "[[Clippings/$id.md#" \
        "$VAULT" --include='*.md' 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 1: engine exists ────────────────────────────────────────────────────
echo "Test 1: engine file present"
assert "tools/migrate-clip-lifecycle.mjs exists" "yes" "$([ -f "$ENGINE" ] && echo yes || echo no)"

# ── Test 2: --dry-run mutates nothing ────────────────────────────────────────
echo "Test 2: --dry-run mutates nothing, writes manifest + plan"
dry_out="$(node "$ENGINE" "$VAULT" --dry-run --manifest "$MANIFEST" 2>&1)"; dry_rc=$?
assert "dry-run exit 0" "0" "$dry_rc"
assert "dry-run leaves git tree pristine" "0" "$(porcelain_count)"
assert "dry-run wrote a manifest" "yes" "$([ -f "$MANIFEST" ] && echo yes || echo no)"
assert "dry-run printed an _evidence plan line" "yes" \
    "$(printf '%s\n' "$dry_out" | grep -qF '_evidence/' && echo yes || echo no)"
assert "dry-run did NOT create _evidence dir contents" "0" \
    "$(find "$VAULT/Clippings/_evidence" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ── Test 3: --apply migrates eligible clips ──────────────────────────────────
echo "Test 3: --apply migrates the 8 eligible clips, rewrites all six forms"
apply_out="$(node "$ENGINE" "$VAULT" --apply --manifest "$MANIFEST" 2>&1)"; apply_rc=$?
assert "apply exit 0" "0" "$apply_rc"
assert "apply reports 8 migrated" "yes" \
    "$(printf '%s\n' "$apply_out" | grep -qE '8 migrated' && echo yes || echo no)"

# eligible clips now under _evidence/
assert "ID1 moved to _evidence/"  "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID1.md" ] && echo yes || echo no)"
assert "ID2 moved to _evidence/"  "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID2.md" ] && echo yes || echo no)"
assert "ID3 moved to _evidence/"  "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID3.md" ] && echo yes || echo no)"
assert "ID4 (subfolder) moved to _evidence/" "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID4BASE.md" ] && echo yes || echo no)"
# top-level originals gone
assert "ID1 gone from top-level" "no" "$([ -f "$VAULT/Clippings/$ID1.md" ] && echo yes || echo no)"
assert "ID4 gone from subfolder"  "no" "$([ -f "$VAULT/Clippings/$ID4REL.md" ] && echo yes || echo no)"

# unprocessed / ignored clips untouched
assert "sibling (unprocessed) stays top-level" "yes" "$([ -f "$VAULT/Clippings/$ID2EXTRA.md" ] && echo yes || echo no)"
assert "unharvested clip stays top-level" "yes" "$([ -f "$VAULT/Clippings/Unharvested – 2026-05-01T000000+0200.md" ] && echo yes || echo no)"
assert "_done clip untouched" "yes" "$([ -f "$VAULT/Clippings/_done/2026-05/Done Clip – 2026-04-01.md" ] && echo yes || echo no)"

# zero danglers for every migrated id (six-form, incl .md)
assert "ID1 zero stale six-form links" "0" "$(six_form_files "$ID1")"
assert "ID2 zero stale six-form links" "0" "$(six_form_files "$ID2")"
assert "ID3 zero stale six-form links" "0" "$(six_form_files "$ID3")"
assert "ID4 zero stale six-form links" "0" "$(six_form_files "$ID4REL")"

# the two mandatory .md-form citations were rewritten to _evidence/.md
SYN="$VAULT/Clippings/_synthesis/synth.md"
assert ".md]] citation → _evidence/.md]]" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID1.md]]" "$SYN" && echo yes || echo no)"
assert ".md|alias citation → _evidence/.md|alias" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID1.md|DataChaz thread]]" "$SYN" && echo yes || echo no)"
assert ".md#heading citation → _evidence/.md#heading" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID2.md#Key Ideas]]" "$SYN" && echo yes || echo no)"

# non-.md forms rewritten too
assert "daily plain backref → _evidence/" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID3]]" "$VAULT/50-Journal/Daily/2026-06-10.md" && echo yes || echo no)"
assert "external alias (subfolder) → _evidence/ basename" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID4BASE|Sub alias]]" "$VAULT/30-Resources/Tech/notes.md" && echo yes || echo no)"
assert "self-ref remapped at new path (LUNA-60)" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID2]]" "$VAULT/Clippings/_evidence/$ID2.md" && echo yes || echo no)"
# cross-dependency: a migrated clip's body link to ANOTHER migrated clip rewritten
assert "cross-dep link (ID5 body → ID7) rewritten to _evidence/" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID7]]" "$VAULT/Clippings/_evidence/$ID5.md" && echo yes || echo no)"
assert "cross-dep link (ID7 body → ID5) rewritten to _evidence/" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID5]]" "$VAULT/Clippings/_evidence/$ID7.md" && echo yes || echo no)"

# prefix-sibling untouched (both plain + .md)
assert "sibling plain link intact" "yes" \
    "$(grep -qF "[[Clippings/$ID2EXTRA]]" "$SYN" && echo yes || echo no)"
assert "sibling .md link intact" "yes" \
    "$(grep -qF "[[Clippings/$ID2EXTRA.md]]" "$SYN" && echo yes || echo no)"

# evidence_kind stamped on migrated clips (closed-set inference)
assert "ID1 evidence_kind=authors" "yes" \
    "$(grep -qF '  - authors' "$VAULT/Clippings/_evidence/$ID1.md" && echo yes || echo no)"
assert "ID3 evidence_kind=tools (github url)" "yes" \
    "$(grep -qF '  - tools' "$VAULT/Clippings/_evidence/$ID3.md" && echo yes || echo no)"
assert "migrated clip has evidence_kind: key" "yes" \
    "$(grep -qF 'evidence_kind:' "$VAULT/Clippings/_evidence/$ID2.md" && echo yes || echo no)"

# ledger written
assert "ledger written" "yes" \
    "$([ -f "$VAULT/.migrate-clip-lifecycle.ledger.jsonl" ] && echo yes || echo no)"

# ── Test 4: resume / idempotency ─────────────────────────────────────────────
echo "Test 4: a second --apply is a no-op (folder-keyed resume)"
apply2_out="$(node "$ENGINE" "$VAULT" --apply --manifest "$MANIFEST" 2>&1)"; apply2_rc=$?
assert "second apply exit 0" "0" "$apply2_rc"
assert "second apply reports 0 migrated" "yes" \
    "$(printf '%s\n' "$apply2_out" | grep -qE '0 migrated' && echo yes || echo no)"

# ── Test 5: byte-identical rollback round-trip ───────────────────────────────
echo "Test 5: --rollback restores the working tree BYTE-FOR-BYTE vs the oracle"
rb_out="$(node "$ENGINE" "$VAULT" --rollback "$MANIFEST" 2>&1)"; rb_rc=$?
assert "rollback exit 0" "0" "$rb_rc"
assert "rollback reports reverts" "yes" \
    "$(printf '%s\n' "$rb_out" | grep -qE 'reverted' && echo yes || echo no)"
assert "rollback → git tree byte-identical (porcelain empty)" "0" "$(porcelain_count)"
assert "rollback restored ID1 to top-level" "yes" "$([ -f "$VAULT/Clippings/$ID1.md" ] && echo yes || echo no)"
assert "rollback emptied _evidence/ of migrated clips" "0" \
    "$(find "$VAULT/Clippings/_evidence" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ── Test 6: --month staging ──────────────────────────────────────────────────
echo "Test 6: --month stages only that month's eligible clips"
# fixture is pristine again (rollback restored it). Stage only 2026-05.
m_out="$(node "$ENGINE" "$VAULT" --apply --month 2026-05 --manifest "$tmp/m1.json" 2>&1)"; m_rc=$?
assert "month apply exit 0" "0" "$m_rc"
assert "month apply migrated only the 4 May clips" "yes" \
    "$(printf '%s\n' "$m_out" | grep -qE '4 migrated' && echo yes || echo no)"
# 2026-05 clips moved
assert "2026-05 ID1 moved" "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID1.md" ] && echo yes || echo no)"
assert "2026-05 ID5 moved" "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID5.md" ] && echo yes || echo no)"
assert "2026-05 ID7 moved" "yes" "$([ -f "$VAULT/Clippings/_evidence/$ID7.md" ] && echo yes || echo no)"
# 2026-06 clips still top-level
assert "2026-06 ID3 still top-level" "yes" "$([ -f "$VAULT/Clippings/$ID3.md" ] && echo yes || echo no)"
assert "2026-06 ID4 still in subfolder" "yes" "$([ -f "$VAULT/Clippings/$ID4REL.md" ] && echo yes || echo no)"
assert "2026-06 ID8 still top-level" "yes" "$([ -f "$VAULT/Clippings/$ID8.md" ] && echo yes || echo no)"
# the 2026-06 daily backref to ID3 was NOT rewritten (its clip didn't move)
assert "2026-06 daily backref untouched in May batch" "yes" \
    "$(grep -qF "[[Clippings/$ID3]]" "$VAULT/50-Journal/Daily/2026-06-10.md" && echo yes || echo no)"
# ...but ID2 (a May clip) .md# citation WAS rewritten
assert "2026-05 ID2 .md# citation rewritten in May batch" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$ID2.md#Key Ideas]]" "$SYN" && echo yes || echo no)"

# ── Test 7: flat-pool basename collision is pre-detected (dry-run) + fail-safe (apply) ──
echo "Test 7: two eligible clips sharing a basename in different folders → COLLISION"
VAULT2="$tmp/vault2"
mkdir -p "$VAULT2/Clippings/2026-05" "$VAULT2/Clippings/2026-06"
DUP='Shared Note – 2026-01-01T000000+0200'   # SAME basename, two folders
{
    printf -- '---\ntype: article\nprocessed: true\ndate_clipped: 2026-05-09T010101+0200\n---\n'
    printf -- 'may copy.\n'
} > "$VAULT2/Clippings/2026-05/$DUP.md"
{
    printf -- '---\ntype: article\nprocessed: true\ndate_clipped: 2026-06-09T010101+0200\n---\n'
    printf -- 'june copy.\n'
} > "$VAULT2/Clippings/2026-06/$DUP.md"
printf -- '.migrate-clip-lifecycle.*\n' > "$VAULT2/.gitignore"
git -C "$VAULT2" init -q
git -C "$VAULT2" add -A
git -C "$VAULT2" -c user.email=t@t.dev -c user.name=test commit -qm "dup oracle"

# dry-run: must print a COLLISION line naming BOTH sources, exit with advisory 3, mutate nothing.
c_out="$(node "$ENGINE" "$VAULT2" --dry-run --manifest "$tmp/dup-plan.json" 2>&1)"; c_rc=$?
assert "dry-run advisory exit code on collision (3)" "3" "$c_rc"
assert "dry-run prints a COLLISION line" "yes" \
    "$(printf '%s\n' "$c_out" | grep -qF 'COLLISION:' && echo yes || echo no)"
assert "COLLISION names the May source" "yes" \
    "$(printf '%s\n' "$c_out" | grep -qF "Clippings/2026-05/$DUP.md" && echo yes || echo no)"
assert "COLLISION names the June source (both sources named)" "yes" \
    "$(printf '%s\n' "$c_out" | grep -qF "Clippings/2026-06/$DUP.md" && echo yes || echo no)"
assert "dry-run mutated nothing on collision" "0" "$(git -C "$VAULT2" status --porcelain | wc -l | tr -d ' ')"

# apply: must fail safe — refuse BOTH colliding clips, migrate NOTHING (no partial corruption).
ca_out="$(node "$ENGINE" "$VAULT2" --apply --manifest "$tmp/dup-manifest.json" 2>&1)"; ca_rc=$?
assert "apply non-zero exit on collision" "3" "$ca_rc"
assert "apply migrated 0 (no partial)" "yes" \
    "$(printf '%s\n' "$ca_out" | grep -qE '0 migrated' && echo yes || echo no)"
assert "apply left May dup in place" "yes" "$([ -f "$VAULT2/Clippings/2026-05/$DUP.md" ] && echo yes || echo no)"
assert "apply left June dup in place" "yes" "$([ -f "$VAULT2/Clippings/2026-06/$DUP.md" ] && echo yes || echo no)"
assert "apply wrote no clip into _evidence/ (no partial corruption)" "0" \
    "$(find "$VAULT2/Clippings/_evidence" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert "apply collision keeps git tree pristine" "0" "$(git -C "$VAULT2" status --porcelain | wc -l | tr -d ' ')"

# ── Test 8: per-clip failure AFTER link edits leaves NO torn vault (I3) ───────
# Force a mid-transaction failure: one inbound file is made read-only so the
# engine's step-5 writeFileSync throws EPERM *after* it has already rewritten
# another inbound file and moved the clip. The catch must reverse the applied
# link edit and move the clip back — pre-fix it would log "reverted" while
# leaving inbound files pointing at a now-missing _evidence/ path (torn).
echo "Test 8: per-clip failure reverses applied edits + moves clip back (no torn vault)"
VAULT3="$tmp/vault3"
mkdir -p "$VAULT3/Clippings" "$VAULT3/30-Resources/Tech"
FID='Torn Clip – 2026-05-01T000000+0200'   # eligible, no self-ref
{
    printf -- '---\ntype: article\nprocessed: true\ndate_clipped: 2026-05-01T000000+0200\n---\n'
    printf -- 'torn body.\n'
} > "$VAULT3/Clippings/$FID.md"
# Two inbound files; a-writable sorts before z-readonly so the writable one is
# rewritten first, THEN the read-only write throws (non-vacuous revert path).
printf -- '- writable cite [[Clippings/%s]]\n' "$FID" > "$VAULT3/30-Resources/Tech/a-writable.md"
printf -- '- readonly cite [[Clippings/%s]]\n' "$FID" > "$VAULT3/30-Resources/Tech/z-readonly.md"
printf -- '.migrate-clip-lifecycle.*\n' > "$VAULT3/.gitignore"
git -C "$VAULT3" init -q
git -C "$VAULT3" add -A
git -C "$VAULT3" -c user.email=t@t.dev -c user.name=test commit -qm "torn oracle"
chmod 444 "$VAULT3/30-Resources/Tech/z-readonly.md"   # writeFileSync → EPERM

f8_out="$(node "$ENGINE" "$VAULT3" --apply --manifest "$tmp/torn-manifest.json" 2>&1)"; f8_rc=$?
chmod 644 "$VAULT3/30-Resources/Tech/z-readonly.md"   # restore for cleanup/git

assert "apply exits non-zero (4) when a clip fails" "4" "$f8_rc"
assert "engine does NOT print a bare 'reverted' lie on partial" "yes" \
    "$(printf '%s\n' "$f8_out" | grep -qE 'reverted \(vault restored|PARTIAL REVERT' && echo yes || echo no)"
assert "failed clip moved back to top-level inbox" "yes" \
    "$([ -f "$VAULT3/Clippings/$FID.md" ] && echo yes || echo no)"
assert "failed clip NOT left in _evidence/" "no" \
    "$([ -f "$VAULT3/Clippings/_evidence/$FID.md" ] && echo yes || echo no)"
# The decisive no-torn-vault assertion: NO file may point at the _evidence/ path.
assert "no inbound file left pointing at _evidence/ (no torn vault)" "0" \
    "$(grep -rlF "[[Clippings/_evidence/$FID" "$VAULT3" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert "applied edit on a-writable.md was reversed to the OLD form" "yes" \
    "$(grep -qF "[[Clippings/$FID]]" "$VAULT3/30-Resources/Tech/a-writable.md" && echo yes || echo no)"
# git oracle: every tracked file is byte-identical to pre-clip state (mode
# changes are ignored by git on Windows; content must be clean). Engine state
# files are gitignored (.gitignore above) + the manifest lives outside the vault,
# so none appear in porcelain — a clean tree is the byte-identical proof.
assert "git tree byte-identical after failed clip (porcelain clean)" "0" \
    "$(git -C "$VAULT3" status --porcelain | wc -l | tr -d ' ')"

echo "Test 9: the vault-wide scan SKIPS .worktrees/ and .obsidian/ (non-content trees)"
# Staging on the real vault revealed the engine walked the vault's nested git
# worktrees (the luna vault gitignores /.worktrees/) and Obsidian state, which
# would dirty the operator's active worktree checkouts. Assert they are skipped:
# a stale clip-link inside .worktrees/ must NOT be rewritten, and a top-level
# clip inside .worktrees/Clippings/ must NOT be migrated.
VAULT9="$tmp/vault9"
mkdir -p "$VAULT9/Clippings" "$VAULT9/30-Resources" \
         "$VAULT9/.worktrees/stale/Clippings" "$VAULT9/.obsidian"
W9='Clip Nine – 2026-06-01T090000+0200'
{ printf -- '---\ntype: article\nharvested_at: 2026-06-01\nprocessed: true\n'
  printf -- 'date_clipped: 2026-06-01T090000+0200\n---\nbody.\n'; } > "$VAULT9/Clippings/$W9.md"
# main-tree inbound link (MUST be rewritten)
printf -- '- main: [[Clippings/%s]]\n' "$W9" > "$VAULT9/30-Resources/note.md"
# stale worktree copy linking the same clip (MUST be left untouched)
printf -- '- stale: [[Clippings/%s]]\n' "$W9" > "$VAULT9/.worktrees/stale/30-Resources-note.md"
# a top-level "clip" living inside a nested worktree (MUST NOT be migrated)
{ printf -- '---\ntype: article\nprocessed: true\n---\nstale clip.\n'; } \
    > "$VAULT9/.worktrees/stale/Clippings/$W9.md"
# Obsidian state file mentioning the link form (MUST be left untouched)
printf -- '{"link":"[[Clippings/%s]]"}\n' "$W9" > "$VAULT9/.obsidian/workspace.json"

node "$ENGINE" "$VAULT9" --apply --manifest "$tmp/m9.json" >/dev/null 2>&1
assert "T9 clip migrated to _evidence/" "yes" \
    "$([ -f "$VAULT9/Clippings/_evidence/$W9.md" ] && echo yes || echo no)"
assert "T9 main-tree link rewritten to _evidence/" "yes" \
    "$(grep -qF "[[Clippings/_evidence/$W9]]" "$VAULT9/30-Resources/note.md" && echo yes || echo no)"
assert "T9 .worktrees/ stale link NOT rewritten (skipped)" "yes" \
    "$(grep -qF "[[Clippings/$W9]]" "$VAULT9/.worktrees/stale/30-Resources-note.md" && echo yes || echo no)"
assert "T9 .worktrees/ inner clip NOT migrated (stays put)" "yes" \
    "$([ -f "$VAULT9/.worktrees/stale/Clippings/$W9.md" ] && echo yes || echo no)"
assert "T9 .obsidian/ state NOT rewritten (skipped)" "yes" \
    "$(grep -qF "[[Clippings/$W9]]" "$VAULT9/.obsidian/workspace.json" && echo yes || echo no)"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
