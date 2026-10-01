#!/usr/bin/env bash
# test-plan-index.sh — HIMMEL-4000. Hermetic tests for plan-index.sh: a lookup by
# ticket key returns its version/theme/goal, no change = no rebuild, a change =
# rebuild, the source plan dir is never written, a failing/missing qmd fails the
# refresh and leaves the fingerprint unadvanced. Fixture plan dir + stub qmd +
# temp out dir in a scratch tempdir; never the real qmd, plan dir or ~/.himmel/state.
#
# PLATFORM GUARD: no .ps1 twin, by design — the roadmap tooling is operator-side
# (the console kit it pairs with is Linux-only); this suite needs bash + python3.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/plan-index.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/plan-index-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v python3 >/dev/null 2>&1 || { printf 'skip - python3 not available\n'; exit 0; }

plan="$W/plan"; out="$W/out"; mir="$W/mirror"; calls="$W/qmd-calls"
mkdir -p "$plan/stage1" "$plan/stage3" "$mir"
printf 'key\ttheme\tepic\tgoals\timpact\timpact_evidence\talignment\tdeps\tdup_of\tclose_flag\tclose_evidence\tnotes\nHIMMEL-111\tKnowledge substrate\tHIMMEL-100\tG7;G3\t2\te\t0.5\t\t\tnone\t\tn\nHIMMEL-222\tGuard safety\tPROPOSED-EPIC:Guard safety\tG1\t2\te\t0.5\t\t\tnone\t\tn\n' > "$plan/stage1/C01.tsv"
printf 'key\tuser_impact\tissue_plain\nHIMMEL-111\tinternal\tA plain sentence about the zebra widget.\nHIMMEL-222\tinternal\tGuards plain text.\n' > "$plan/stage1/C01.explain.tsv"
printf 'key\troi\tconfidence\teffort_mid\trank\tversion\tcommit\tslice_effort\tlayer\treason\nHIMMEL-111\t1\t1\t1\t1\tv1.0.1\tcommitted\t\tbugs\twhy-one\nHIMMEL-222\t1\t1\t1\t2\tv1.0.2\tcommitted\t\tfeatures\twhy-two\n' > "$plan/stage3/placement.tsv"
printf '{"stage":3}\n' > "$plan/stage3/meta.json"
echo one > "$mir/HIMMEL-111.md"
plan_sum() { (cd "$plan" && find . -type f | sort | xargs sha256sum | sha256sum); }

# stub qmd: records every call and remembers the registered path (a file beside the
# call log); QMD_FAIL=1 fails the embed step.
cat > "$W/qmd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$QMD_CALLS"
reg="$QMD_CALLS.registered"
case "$1 ${2:-}" in
    "collection list") [ -f "$reg" ] && echo "roadmap-plan (3 files)"; exit 0 ;;
    "collection add") printf '%s\n' "$3" > "$reg"; exit 0 ;;
    "collection show") [ -f "$reg" ] && echo "Path: $(cat "$reg")"; exit 0 ;;
esac
if [ "${QMD_FAIL:-0}" = 1 ] && [ "$1" = embed ]; then exit 3; fi
exit 0
STUB
chmod +x "$W/qmd"
export QMD_CALLS="$calls"
run() { ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" "$@" --plan-dir "$plan" --out "$out" --watch "$mir"; }

r="$(run --refresh 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "first refresh rc=0" || fail "first refresh rc=$rc: $r"
doc="$(cat "$out/docs/HIMMEL-111.md" 2>/dev/null)"
contains "ticket doc has version" "$doc" "version: v1.0.1"
contains "ticket doc has theme" "$doc" "theme: Knowledge substrate"
contains "ticket doc has epic" "$doc" "epic: HIMMEL-100"
contains "ticket doc has goals" "$doc" "G7"
contains "ticket doc has plain explain (phrase lookup)" "$doc" "zebra widget"
contains "ticket doc has reason" "$doc" "why-one"
contains "version doc lists member" "$(cat "$out/docs/version-v1.0.1.md" 2>/dev/null)" "HIMMEL-111"
contains "theme doc lists member" "$(cat "$out/docs/"theme-*knowledge-substrate*.md 2>/dev/null)" "HIMMEL-111"
contains "qmd collection registered" "$(cat "$calls")" "collection add $out/docs --name roadmap-plan"
contains "qmd embed ran" "$(cat "$calls")" "embed -c roadmap-plan"

: > "$calls"
r="$(run --refresh 2>&1)"
contains "no change: reports unchanged" "$r" "unchanged"
[ ! -s "$calls" ] && pass "no change: qmd not called (no rebuild)" || fail "no change rebuilt: $(cat "$calls")"

echo two >> "$mir/HIMMEL-111.md"
r="$(run --refresh 2>&1)"
contains "mirror change: rebuilds" "$r" "rebuilt"
[ -s "$calls" ] && pass "mirror change: qmd called" || fail "mirror change did not call qmd"

sed -i.bak 's/why-one/why-changed/' "$plan/stage3/placement.tsv"; rm -f "$plan/stage3/placement.tsv.bak"
r="$(run --refresh 2>&1)"
contains "plan change: rebuilds" "$r" "rebuilt"
contains "plan change reaches the doc" "$(cat "$out/docs/HIMMEL-111.md")" "why-changed"

before="$(plan_sum)"
run --refresh --force >/dev/null 2>&1
[ "$before" = "$(plan_sum)" ] && pass "source plan dir content untouched by refresh" || fail "plan dir changed"
[ "$(find "$plan" -type f | wc -l)" = 4 ] && pass "no file added to the plan dir" || fail "plan dir gained files"

echo three >> "$mir/HIMMEL-111.md"; cp "$out/.fp" "$W/fp.keep"
r="$(QMD_FAIL=1 run --refresh 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "failing qmd: refresh non-zero" || fail "failing qmd rc=0"
[ "$(cat "$out/.fp")" = "$(cat "$W/fp.keep")" ] && pass "failing qmd: fingerprint not advanced" || fail "fingerprint advanced on failure"
r="$(run --refresh 2>&1)"; contains "failed run retried next time" "$r" "rebuilt"

echo four >> "$mir/HIMMEL-111.md"; cp "$out/.fp" "$W/fp.keep"
r="$(ROADMAP_QMD_BIN="$W/no-such-qmd" bash "$SUT" --refresh --plan-dir "$plan" --out "$out" --watch "$mir" 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "missing qmd: refresh non-zero" || fail "missing qmd rc=0"
[ "$(cat "$out/.fp")" = "$(cat "$W/fp.keep")" ] && pass "missing qmd: fingerprint not advanced" || fail "fingerprint advanced with no qmd"

r="$(run --check 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then contains "--check reports stale" "$r" "stale"; else fail "--check on stale should be non-zero"; fi

# an existing collection is rescanned: `update` runs before `embed`
: > "$calls"; echo five >> "$mir/HIMMEL-111.md"
run --refresh >/dev/null 2>&1
u="$(grep -n '^update' "$calls" | head -1 | cut -d: -f1)"; e="$(grep -n '^embed' "$calls" | head -1 | cut -d: -f1)"
[ -n "$u" ] && [ -n "$e" ] && [ "$u" -lt "$e" ] && pass "qmd update runs before embed" || fail "update did not precede embed: $(cat "$calls")"

# a collection of the same name pointing at another directory is refused
printf '%s\n' "$W/elsewhere" > "$calls.registered"
echo six >> "$mir/HIMMEL-111.md"; cp "$out/.fp" "$W/fp.keep"
r="$(run --refresh 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "collection pointing elsewhere: refresh non-zero" || fail "collection elsewhere rc=0"
[ "$(cat "$out/.fp")" = "$(cat "$W/fp.keep")" ] && pass "collection elsewhere: fingerprint not advanced" || fail "fingerprint advanced on wrong collection path"
printf '%s\n' "$out/docs" > "$calls.registered"

# a ticket key that is not a plain key never becomes a path outside the docs dir
cp -r "$plan" "$W/plan2"
printf '../../escape\t1\t1\t1\t3\tv1\tc\t\tbugs\tx\n' >> "$W/plan2/stage3/placement.tsv"
r="$(ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" --refresh --plan-dir "$W/plan2" --out "$W/out2" 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "bad ticket key: refresh non-zero" || fail "bad ticket key rc=0"
[ ! -e "$W/out2/escape.md" ] && pass "bad ticket key: nothing written outside docs" || fail "path-traversal key wrote a file"

# two group names with one slug each keep their own doc
cp -r "$plan" "$W/plan3"
sed -i.bak 's/Knowledge substrate/Guard-safety/' "$W/plan3/stage1/C01.tsv"; rm -f "$W/plan3/stage1/C01.tsv.bak"
ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" --refresh --plan-dir "$W/plan3" --out "$W/out3" >/dev/null 2>&1
[ "$(find "$W/out3/docs" -name 'theme-*.md' | wc -l)" = 2 ] && pass "slug collision: both theme docs kept" || fail "slug collision overwrote a theme doc"

# --out inside/over the plan dir never deletes the plan
cp -r "$plan" "$W/plan4"; before4="$(cd "$W/plan4" && find . -type f | sort | xargs sha256sum | sha256sum)"
ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" --refresh --plan-dir "$W/plan4" --out "$W/plan4/stage1/.." >/dev/null 2>&1; rc2=$?
[ "$rc2" != 0 ] && pass "out overlapping the plan dir: refresh non-zero" || fail "overlapping out rc=0"
[ "$before4" = "$(cd "$W/plan4" && find . -type f | sort | xargs sha256sum | sha256sum)" ] && pass "overlapping out: plan dir intact" || fail "overlapping out destroyed the plan dir"

# every path the build replaces is guarded: a plan dir that is the docs dir, or a docs.new-named dir under out
for rel in docs docs.new; do
    mkdir -p "$W/pg-o-$rel"; cp -r "$plan" "$W/pg-o-$rel/$rel"
    pb="$(cd "$W/pg-o-$rel/$rel" && find . -type f | sort | xargs sha256sum | sha256sum)"
    ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" --refresh --plan-dir "$W/pg-o-$rel/$rel" --out "$W/pg-o-$rel" >/dev/null 2>&1
    [ "$pb" = "$(cd "$W/pg-o-$rel/$rel" && find . -type f | sort | xargs sha256sum | sha256sum)" ] && pass "plan dir named $rel under out survives a refresh" || fail "plan dir named $rel was destroyed"
done
ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" --refresh --plan-dir "$plan" --out "$mir" --watch "$mir" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "out inside a watch path: refused" || fail "docs under a watch path accepted"
bash "$SUT" --refresh --plan-dir >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "missing option value: exit 2" || fail "missing option value rc=$rc"

# deleted docs with a kept key are stale, and a refresh restores them
rm -rf "$out/docs"
r="$(run --check 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "missing docs: --check stale despite kept key" || fail "--check fresh with docs deleted"
r="$(run --refresh 2>&1)"; contains "missing docs: refresh rebuilds" "$r" "rebuilt"
[ -f "$out/docs/HIMMEL-111.md" ] && pass "missing docs: restored" || fail "docs not restored"

# a held lock refuses a concurrent refresh
mkdir "$out/.lock"; echo seven >> "$mir/HIMMEL-111.md"
r="$(run --refresh 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "held lock: refresh non-zero" || fail "refresh ran under a held lock"
rmdir "$out/.lock"
r="$(run --refresh 2>&1)"; contains "released lock: refresh proceeds" "$r" "rebuilt"
[ ! -e "$out/.lock" ] && pass "lock released after refresh" || fail "lock left behind"

if [ "$fails" = 0 ]; then echo "all passed"; exit 0; fi
echo "$fails failed"; exit 1
