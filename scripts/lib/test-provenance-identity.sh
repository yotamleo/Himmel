#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + jq only.
# test-provenance-identity.sh -- tests for scripts/lib/provenance-identity.sh
# (HIMMEL-3525 S16): the live-identity reader for register-kind units. A stub
# `qmd` first on PATH stands in for the registrar; BUN_INSTALL points at a
# directory with no qmd.js so qmd_cmd always falls back to it. Scratch HOME,
# nothing real is read or written.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}

td=$(mktemp -d "${TMPDIR:-/tmp}/prov-id-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${td:-}" ] && [ -d "$td" ] && rm -rf "$td"' EXIT
export HOME="$td/home"
mkdir -p "$HOME" "$td/bin"
export BUN_INSTALL="$td/no-bun"
export PATH="$td/bin:$PATH"
export QMD_STUB_LOG="$td/qmd.log"
unset PROV_READ_FOLD

# stub qmd: QMD_STUB_MODE = path (prints the show block for QMD_STUB_PATH) |
# absent (qmd's own "Collection not found", rc 1) | fail (rc 127) | nopath
# (rc 0, no Path: line). Every call's argv is logged.
cat > "$td/bin/qmd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QMD_STUB_LOG"
case "$1 $2" in
    'collection show') ;;
    *) exit 2 ;;
esac
case "${QMD_STUB_MODE:-path}" in
    path)   printf 'Collection: %s\n  Path:     %s\n  Pattern:  %s\n  Include:  yes (default)\n' \
                "$3" "$QMD_STUB_PATH" "${QMD_STUB_PATTERN:-**/*.md}" ;;
    absent) printf 'Collection not found: %s\n' "$3" >&2; exit 1 ;;
    fail)   exit 127 ;;
    nopath) printf 'Collection: %s\n' "$3" ;;
esac
STUB
chmod 755 "$td/bin/qmd"

# shellcheck source=scripts/lib/provenance-identity.sh
. "$here/provenance-identity.sh"

u='{"kind":"collection","unit":"luna"}'
# the token is computed here independently of the lib: sha256 of
# "<kind>\n<name>\n<canonical path>\n<pattern>"
tok_a=$(printf 'collection\nluna\n/vaultA\n**/*.md' | _prov_sha256)

# ── collection: present / canonical / absent / unreadable ──────────────────

QMD_STUB_MODE=path QMD_STUB_PATH=/vaultA; export QMD_STUB_MODE QMD_STUB_PATH
check "collection present -> the sha of kind+name+path+pattern" "$(prov_identity_live collection "$u")" "$tok_a"
check "collection present -> rc 0" "$(prov_identity_live collection "$u" >/dev/null; echo $?)" "0"
check "the reader called qmd collection show <name>" "$(tail -n1 "$QMD_STUB_LOG")" "collection show luna"

QMD_STUB_PATH=/vaultB
check "another path -> another token" "$([ "$(prov_identity_live collection "$u")" != "$tok_a" ] && echo differs)" "differs"

QMD_STUB_PATH=/vaultA QMD_STUB_PATTERN='**/*.txt'; export QMD_STUB_PATTERN
check "another pattern -> another token" "$([ "$(prov_identity_live collection "$u")" != "$tok_a" ] && echo differs)" "differs"
unset QMD_STUB_PATTERN

mkdir -p "$td/real-vault"
ln -s "$td/real-vault" "$td/link-vault"
real=$(cd -P "$td/real-vault" && pwd -P)
QMD_STUB_PATH="$td/link-vault"
tok_link=$(prov_identity_live collection "$u")
QMD_STUB_PATH="$td/real-vault"
tok_real=$(prov_identity_live collection "$u")
check "an existing directory is canonicalized (symlink == its target)" "$tok_link" "$tok_real"
check "the canonical token uses pwd -P" "$tok_real" "$(printf 'collection\nluna\n%s\n**/*.md' "$real" | _prov_sha256)"

QMD_STUB_MODE=absent
check "qmd says Collection not found -> ABSENT" "$(prov_identity_live collection "$u")" "ABSENT"
QMD_STUB_MODE=fail
check "qmd_cmd rc 127 -> UNREADABLE" "$(prov_identity_live collection "$u")" "UNREADABLE"
QMD_STUB_MODE=nopath
check "rc 0 with no Path: line -> UNREADABLE" "$(prov_identity_live collection "$u")" "UNREADABLE"
check "a unit with no name -> UNREADABLE" "$(prov_identity_live collection '{"kind":"collection"}')" "UNREADABLE"

# ── kinds with no reader yet (S17 added plugin/marketplace, S18 added job;
# mcp/unit/tool are still unshipped) -> rc 2, nothing printed ──────────────

for k in mcp unit tool; do
    out=$(prov_identity_live "$k" '{"unit":"x"}'); rc=$?
    check "kind $k has no reader -> rc 2" "$rc" "2"
    check "kind $k has no reader -> no output" "$out" ""
done

# ── job (HIMMEL-3525 S18): cron only, one crontab -l snapshot per call ─────

cat > "$td/bin/crontab" <<'CRON_STUB'
#!/usr/bin/env bash
case "${CRONTAB_STUB_MODE:-ok}" in
    absent) echo "no crontab for tester" >&2; exit 1 ;;
    fail)   exit 127 ;;
    ok)     printf '%s\n' "${CRONTAB_STUB_TABLE:-}" ;;
esac
CRON_STUB
chmod 755 "$td/bin/crontab"

check "job, a non-cron scheduler -> rc 2 (no reader yet)" \
    "$(prov_identity_live job '{"unit":"HIMMEL-X","fields":{"scheduler":"at"}}'; echo $?)" "2"

uj_job='{"unit":"HIMMEL-Qmd-Reindex","fields":{"scheduler":"cron"}}'
export CRONTAB_STUB_MODE CRONTAB_STUB_TABLE
CRONTAB_STUB_MODE=absent
check "job, no crontab -> ABSENT" "$(prov_identity_live job "$uj_job")" "ABSENT"
CRONTAB_STUB_MODE=fail
check "job, a failed crontab -l -> UNREADABLE" "$(prov_identity_live job "$uj_job")" "UNREADABLE"
CRONTAB_STUB_MODE=ok CRONTAB_STUB_TABLE='0 3 * * * run.sh # unrelated'
check "job, no matching line -> ABSENT" "$(prov_identity_live job "$uj_job")" "ABSENT"
CRONTAB_STUB_TABLE='0 3 * * * run.sh # HIMMEL-Qmd-Reindex'
tok_job=$(printf 'job\n0 3 * * * run.sh # HIMMEL-Qmd-Reindex' | _prov_sha256)
check "job, exactly one matching line -> the token of that line" "$(prov_identity_live job "$uj_job")" "$tok_job"
CRONTAB_STUB_TABLE=$'0 3 * * * run.sh # HIMMEL-Qmd-Reindex\n0 4 * * * run.sh # HIMMEL-Qmd-Reindex'
check "job, 2+ matching lines -> UNREADABLE (never guess which one)" "$(prov_identity_live job "$uj_job")" "UNREADABLE"
unset CRONTAB_STUB_MODE CRONTAB_STUB_TABLE
rm -f "$td/bin/crontab"

# ── deferred from S17 round 3: _provid_marketplace's stype read must never
# let a non-object .source crash the reader (HIMMEL-3525) ──────────────────

mkt_dir="$td/mkt-cfg/plugins"; mkdir -p "$mkt_dir"
printf '{"weird":{"source":"just-a-string"}}\n' > "$mkt_dir/known_marketplaces.json"
PROV_CFG_DIR="$td/mkt-cfg"
check "marketplace, a non-object .source -> UNREADABLE, not a crash" \
    "$(prov_identity_live marketplace '{"unit":"weird"}')" "UNREADABLE"
unset PROV_CFG_DIR

# ── per-run cache under the fold's temp dir ─────────────────────────────────

QMD_STUB_MODE=path QMD_STUB_PATH=/vaultA
PROV_READ_FOLD="$td/fold.jsonl"; : > "$PROV_READ_FOLD"
: > "$QMD_STUB_LOG"
first=$(prov_identity_live collection "$u")
second=$(prov_identity_live collection "$u")
check "cache: same token twice" "$second" "$first"
check "cache: one qmd call per name per run" "$(grep -c 'collection show luna' "$QMD_STUB_LOG")" "1"
check "cache: lives beside the fold file" "$([ -d "$PROV_READ_FOLD.identity.d" ] && echo yes)" "yes"
QMD_STUB_MODE=fail
: > "$QMD_STUB_LOG"
check "cache: an UNREADABLE read is not cached" "$(prov_identity_live collection '{"unit":"other"}'; prov_identity_live collection '{"unit":"other"}')" "UNREADABLEUNREADABLE"
check "cache: ... so it is retried" "$(grep -c 'collection show other' "$QMD_STUB_LOG")" "2"
unset PROV_READ_FOLD
: > "$QMD_STUB_LOG"
QMD_STUB_MODE=path
prov_identity_live collection "$u" >/dev/null
prov_identity_live collection "$u" >/dev/null
check "no fold (install side) -> no cache, every call reads" "$(grep -c 'collection show luna' "$QMD_STUB_LOG")" "2"

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
