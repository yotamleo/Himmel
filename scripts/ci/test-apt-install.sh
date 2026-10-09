#!/usr/bin/env bash
# scripts/ci/test-apt-install.sh -- .github/scripts/apt-install.sh survives a
# stalled Ubuntu archive mirror (HIMMEL-2872): cached .debs first, a bounded
# retry against an alternate mirror second, one failure line naming the mirror
# and the packages last. apt-get is a stub; no network, no sudo.
#
# Usage: bash scripts/ci/test-apt-install.sh
# Exit codes: 0 -- all cases pass; 1 -- at least one fails.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/.github/scripts/apt-install.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-apt-install.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Stub apt-get: logs argv; an install fails (or hangs, STUB_HANG=1) while the
# sources file still names the primary mirror, succeeds once it names the alt.
cat > "$TMP/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  update) exit 0 ;;
  install)
    if grep -q primary.example "$STUB_SOURCES"; then
      [ "${STUB_HANG:-0}" = 1 ] && sleep 30
      [ "${STUB_PRIMARY_OK:-0}" = 1 ] || exit 100
    fi
    [ "${STUB_ALL_FAIL:-0}" = 1 ] && exit 100
    exit 0 ;;
esac
STUB
chmod +x "$TMP/apt-get"

# run_case <name> [VAR=val...] -- sets $out, $rc, $log, $src
run_case() {
  local name="$1"; shift
  local d="$TMP/$name"
  mkdir -p "$d/archives"
  echo "deb http://primary.example/ubuntu noble main" > "$d/ubuntu.sources"
  : > "$d/log"
  out="$(env APT_GET="$TMP/apt-get" APT_SUDO= APT_ARCHIVES="$d/archives" \
    APT_SOURCES_FILES="$d/ubuntu.sources" APT_ALT_MIRROR=alt.example \
    APT_T_CACHED=5 APT_T_PLAIN=5 APT_T_ALT=5 \
    STUB_LOG="$d/log" STUB_SOURCES="$d/ubuntu.sources" "$@" \
    bash "$HELPER" ffmpeg at 2>&1)"
  rc=$?
  log="$(cat "$d/log")"
  src="$(cat "$d/ubuntu.sources")"
}

if [ ! -f "$HELPER" ]; then
  bad "helper $HELPER missing"
  echo "$fails failed" >&2
  exit 1
fi

# 1. cache hit: installs from cached debs only, no download, no mirror switch.
mkdir -p "$TMP/c1/archives"; touch "$TMP/c1/archives/ffmpeg_1.deb"
echo "deb http://primary.example/ubuntu noble main" > "$TMP/c1/ubuntu.sources"; : > "$TMP/c1/log"
out="$(env APT_GET="$TMP/apt-get" APT_SUDO= APT_ARCHIVES="$TMP/c1/archives" \
  APT_SOURCES_FILES="$TMP/c1/ubuntu.sources" APT_ALT_MIRROR=alt.example \
  STUB_LOG="$TMP/c1/log" STUB_SOURCES="$TMP/c1/ubuntu.sources" STUB_PRIMARY_OK=1 \
  bash "$HELPER" ffmpeg at 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '--no-download' "$TMP/c1/log" && [ "$(wc -l < "$TMP/c1/log")" -eq 1 ] \
  && ok "cache hit installs with --no-download in one call" || bad "cache hit (rc=$rc log=$(cat "$TMP/c1/log"))"

# 2. no cache, primary healthy: plain install, no mirror rewrite.
run_case c2 STUB_PRIMARY_OK=1
[ "$rc" -eq 0 ] && ! grep -q -- '--no-download' <<<"$log" && grep -q primary.example <<<"$src" \
  && ok "cache miss + healthy primary: plain install, mirror untouched" || bad "healthy primary (rc=$rc)"

# 3. primary fails fast: switches to the alt mirror, refreshes, installs.
run_case c3
[ "$rc" -eq 0 ] && grep -q alt.example <<<"$src" && grep -q '^update' <<<"$log" \
  && ok "failing primary falls back to the alternate mirror" || bad "fallback (rc=$rc src=$src)"

# 4. primary hangs: the bounded timeout trips and the alt mirror is used.
run_case c4 STUB_HANG=1
[ "$rc" -eq 0 ] && grep -q alt.example <<<"$src" \
  && ok "hanging primary is cut by the timeout, alternate mirror used" || bad "hang (rc=$rc)"

# 5. everything fails: non-zero, one line naming the mirror and the packages.
run_case c5 STUB_ALL_FAIL=1
n="$(grep -c 'apt-install: FAILED' <<<"$out")"
failed_line="$(grep 'apt-install: FAILED' <<<"$out")"
[ "$rc" -ne 0 ] && [ "$n" -eq 1 ] && grep -q 'alt.example' <<<"$failed_line" \
  && grep -q 'ffmpeg at' <<<"$failed_line" \
  && ok "total failure prints one line naming mirror and packages" || bad "final failure (rc=$rc n=$n out=$out)"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
