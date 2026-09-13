#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-merged-count.sh - RED/GREEN suite for
# merged-count.sh (HIMMEL-3021): the merged-PR denominator unions the
# private-archive bundle with the public repo for windows straddling the
# 2026-09-09 cutover.
#
# Builds a throwaway git repo + `git bundle create` fixture at test time (3
# first-parent "(#N)" commits inside the pre-cutover part, plus one
# non-"(#N)" commit that must NOT count), per the HIMMEL-3021 brief. Uses a
# gh stub returning 2 post-cutover PRs + 1 chore(propagate) PR.
#
# Platform guard: no .ps1 twin, by design, same convention as
# test-ledger-metrics.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/merged-count.sh"
fails=0

check_exit() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected exit [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

check_eq() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle] in [$haystack]"; fails=$((fails + 1)) ;;
    esac
}

RUN=$(mktemp -d "${TMPDIR:-/tmp}/test-merged-count.XXXXXX") || { echo "FAIL - setup: mktemp failed"; exit 1; }
trap 'rm -rf "$RUN"' EXIT

# --- build the fixture private-bundle repo: 3 first-parent "(#N)" commits
# inside [2026-09-01, 2026-09-09T09:30) plus one non-"(#N)" commit that must
# not count.
SRC="$RUN/priv-src"
git init -q -b main "$SRC" 2>/dev/null || git init -q "$SRC"
git -C "$SRC" checkout -q -B main 2>/dev/null
git -C "$SRC" config user.email t@example.com
git -C "$SRC" config user.name test
GIT_AUTHOR_DATE="2026-09-06T10:00:00" GIT_COMMITTER_DATE="2026-09-06T10:00:00" \
    git -C "$SRC" commit -q --allow-empty -m "feat: A (#301)"
GIT_AUTHOR_DATE="2026-09-07T10:00:00" GIT_COMMITTER_DATE="2026-09-07T10:00:00" \
    git -C "$SRC" commit -q --allow-empty -m "feat: B (#302)"
GIT_AUTHOR_DATE="2026-09-08T09:00:00" GIT_COMMITTER_DATE="2026-09-08T09:00:00" \
    git -C "$SRC" commit -q --allow-empty -m "chore: not a squash merge"
GIT_AUTHOR_DATE="2026-09-08T12:00:00" GIT_COMMITTER_DATE="2026-09-08T12:00:00" \
    git -C "$SRC" commit -q --allow-empty -m "feat: C (#303)"
BUNDLE="$RUN/priv.bundle"
git -C "$SRC" bundle create "$BUNDLE" main >/dev/null 2>&1 \
    || { echo "FAIL - setup: could not create fixture bundle"; exit 1; }

# --- gh stub: 2 post-cutover PRs (#201, #202) + 1 chore(propagate) PR (#203)
# merged just after the cutover.
STUB_DIR="$RUN/stub-gh"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB_EOF'
#!/usr/bin/env bash
set -u
case "$*" in
    "pr list "*)
        cat <<'JSON'
[
  {"number":201,"title":"feat: A (#201)","mergedAt":"2026-09-10T08:00:00Z","author":{"login":"someone"}},
  {"number":202,"title":"feat: B (#202)","mergedAt":"2026-09-10T09:00:00Z","author":{"login":"someone"}},
  {"number":203,"title":"chore(propagate): sync","mergedAt":"2026-09-09T10:00:00Z","author":{"login":"someone"}}
]
JSON
        exit 0 ;;
    *) echo "gh: stub does not implement: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

# --- (a) straddling window: bundle(3) + public excluding propagate(2) = 5
OUT=$("$SCRIPT" --since 2026-09-01T00:00:00Z --until 2026-09-12T00:00:00Z --bundle "$BUNDLE" 2>/dev/null)
EXIT=$?
check_exit "straddling: exits 0" "$EXIT" "0"
check_eq "straddling: bundle(3) + public-excl-propagate(2) = 5" "$OUT" "5"

# --- (b) post-cutover-only window (since after the propagate PR's mergedAt):
# no exclusion needed, no bundle read, count=2 by date filtering alone.
OUT=$("$SCRIPT" --since 2026-09-09T12:00:00Z --until 2026-09-12T00:00:00Z --bundle /nonexistent/does-not-exist.bundle 2>/dev/null)
EXIT=$?
check_exit "post-cutover: exits 0" "$EXIT" "0"
check_eq "post-cutover: 2 PRs, bundle never opened (bundle path is bogus)" "$OUT" "2"

# --- (c) missing bundle on a straddling window -> exit 2, names the env var
# and the default path
ERR=$("$SCRIPT" --since 2026-09-01T00:00:00Z --until 2026-09-12T00:00:00Z --bundle /nonexistent/does-not-exist.bundle 2>&1 >/dev/null)
EXIT=$?
check_exit "missing bundle: exits 2" "$EXIT" "2"
check_contains "missing bundle: error names the missing path" "$ERR" "/nonexistent/does-not-exist.bundle"
check_contains "missing bundle: error names HIMMEL_PRIVATE_BUNDLE" "$ERR" "HIMMEL_PRIVATE_BUNDLE"

# --- (d) HIMMEL_PRIVATE_BUNDLE=/nonexistent must NOT trip a post-cutover
# window (bundle is genuinely never opened, not merely unused).
OUT=$(HIMMEL_PRIVATE_BUNDLE=/nonexistent/does-not-exist.bundle "$SCRIPT" --since 2026-09-09T12:00:00Z --until 2026-09-12T00:00:00Z 2>/dev/null)
EXIT=$?
check_exit "post-cutover with bogus HIMMEL_PRIVATE_BUNDLE: exits 0" "$EXIT" "0"
check_eq "post-cutover with bogus HIMMEL_PRIVATE_BUNDLE: still 2" "$OUT" "2"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-merged-count.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-merged-count.sh: $fails failure(s)"
    exit 1
fi
