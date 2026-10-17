#!/usr/bin/env bash
# test-flag-parity.sh — Tests for scripts/lint/flag-parity.sh.
#
# Usage: bash scripts/lint/test-flag-parity.sh
#
# Cases:
#   1. clean fixture          : doc flag exists in the script → exit 0
#   2. injected mismatch      : doc names a flag the script lacks → exit 1, names doc + flag
#   3. baseline               : the same drift as a baseline row → exit 0; a new flag still fails
#   4. --write-baseline       : writes the row, keeps #-lines
#   5. --staged / --changed   : only drift touching a staged / changed file is reported
#   6. flag scope             : a flag after `|` or `&&` belongs to another command
#   7. ambiguous basename     : skipped, never a false FAIL
#   8. --advisory             : an undocumented usage-header flag is listed, exit unchanged
#   9. real tree              : passes against the shipped baseline
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

# shellcheck disable=SC2015,SC2016  # A && ok || bad is a test idiom; fixtures hold literal backticks
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/flag-parity.sh"
repo_root=$(cd "$here/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-flag-parity.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q . && git config user.email t@t && git config user.name t
mkdir -p scripts docs
cat > scripts/tool.sh <<'EOF'
#!/usr/bin/env bash
# Usage: tool.sh --alpha --beta
case "$1" in --alpha) :;; --beta) :;; esac
EOF
cat > docs/a.md <<'EOF'
Run `scripts/tool.sh --alpha` first.
EOF
git add -A && git commit -qm base

out=$(bash "$lint" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "1 clean fixture" || bad "1 clean fixture (rc=$rc: $out)"

echo 'Then `scripts/tool.sh --gamma`.' >> docs/a.md
out=$(bash "$lint" 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"docs/a.md"* ]] && [[ "$out" == *"--gamma"* ]]; then ok "2 injected mismatch fails"; else bad "2 injected mismatch (rc=$rc: $out)"; fi

bash "$lint" --baseline bl.tsv --write-baseline > /dev/null
out=$(bash "$lint" --baseline bl.tsv 2>&1); rc=$?
[ "$rc" = 0 ] && ok "3a baselined drift passes" || bad "3a baselined (rc=$rc: $out)"
echo 'And `scripts/tool.sh --delta`.' >> docs/a.md
out=$(bash "$lint" --baseline bl.tsv 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"--delta"* ]] && [[ "$out" != *"--gamma"* ]]; then ok "3b new drift beyond baseline fails"; else bad "3b new drift (rc=$rc: $out)"; fi

printf '# keep me\n' > bl2.tsv
bash "$lint" --baseline bl2.tsv --write-baseline > /dev/null
if head -1 bl2.tsv | grep -q '^# keep me' && grep -q -- '--gamma' bl2.tsv; then ok "4 --write-baseline keeps #-lines"; else bad "4 write-baseline"; fi

git add -A && git commit -qm drift
echo 'x' >> README.txt && git add README.txt
out=$(bash "$lint" --staged 2>&1); rc=$?
[ "$rc" = 0 ] && ok "5a --staged ignores untouched drift" || bad "5a staged (rc=$rc: $out)"
git commit -qm unrelated
echo '# touched' >> docs/a.md && git add docs/a.md
out=$(bash "$lint" --staged 2>&1); rc=$?
[ "$rc" = 1 ] && ok "5b --staged sees drift in a staged doc" || bad "5b staged (rc=$rc)"
git commit -qm touch-doc
echo '# touched' >> scripts/tool.sh && git add scripts/tool.sh && git commit -qm touch-script
out=$(bash "$lint" --changed HEAD~1..HEAD 2>&1); rc=$?
[ "$rc" = 1 ] && ok "5c --changed on a script re-checks docs citing it" || bad "5c changed (rc=$rc)"

git reset -q --hard HEAD~3
git reset -q --hard HEAD
printf 'Run `scripts/tool.sh --alpha | jq --arg x` and `scripts/tool.sh --beta && git push --force`.\n' > docs/a.md
out=$(bash "$lint" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "6 flags after | or && are another command's" || bad "6 flag scope (rc=$rc: $out)"

mkdir -p other
cp scripts/tool.sh other/tool.sh
echo 'Run `tool.sh --nope`.' > docs/a.md
git add -A
out=$(bash "$lint" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "7 ambiguous basename skipped" || bad "7 ambiguous (rc=$rc: $out)"
git rm -q -r --cached other && rm -rf other

echo 'Run `scripts/tool.sh --alpha`.' > docs/a.md
git add -A
out=$(bash "$lint" --advisory 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"advisory"*"--beta"* ]]; then ok "8 --advisory lists undocumented --beta"; else bad "8 advisory (rc=$rc: $out)"; fi

mkdir -p scripts
printf '#!/usr/bin/env bash\necho no flags here\n' > scripts/bare.sh
echo 'Run `scripts/bare.sh --ghost`.' > docs/a.md
git add -A
out=$(bash "$lint" 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"--ghost"* ]]; then ok "10 script with no flag tokens still fails a documented flag"; else bad "10 empty carried (rc=$rc: $out)"; fi
: > empty.tsv
out=$(bash "$lint" --baseline empty.tsv 2>&1); rc=$?
[ "$rc" = 1 ] && ok "11 empty baseline file does not swallow drift" || bad "11 empty baseline (rc=$rc: $out)"

echo 'Run `scripts/bare.sh --ghost`.' > "docs/with space.md"
git add -A
out=$(bash "$lint" 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"with space.md"* ]]; then ok "12 a doc filename with a space is scanned"; else bad "12 space name (rc=$rc: $out)"; fi
rm docs/a.md
out=$(bash "$lint" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "13 a tracked doc missing from disk refuses to report clean" || bad "13 missing doc (rc=$rc: $out)"

cd "$repo_root" || exit 1
out=$(bash "$lint" --baseline scripts/lint/flag-parity-baseline.tsv 2>&1); rc=$?
[ "$rc" = 0 ] && ok "9 real tree passes with the baseline" || bad "9 real tree (rc=$rc: $out)"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
