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
    if grep -Ev '^[[:space:]]*#' "$STUB_SOURCES" | grep -m1 . | grep -q "${STUB_BAD:-primary.example}"; then
      if [ "${STUB_HANG:-0}" = 1 ]; then
        sleep "${STUB_HANG_SECS:-30}"
        : > "$STUB_LOG.survived"
      fi
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
  local stub_src="$d/ubuntu.sources" alt="alt.example"
  if [ "${FIXTURE:-}" = real ]; then
    # ubuntu-24.04 runner shape: cloud-init comment header with a URL, then a
    # deb822 stanza whose URIs: points at a mirror list (azure first).
    printf '%s\n' '## Ubuntu distribution repository' '## See http://help.ubuntu.com/community/UpgradeNotes' \
      'Types: deb' "URIs: mirror+file:$d/apt-mirrors.txt" 'Suites: noble noble-updates' \
      'Components: main universe' > "$d/ubuntu.sources"
    printf 'http://azure.example/ubuntu/\tpriority:1\nhttp://archive.ubuntu.com/ubuntu/\tpriority:2\n' > "$d/apt-mirrors.txt"
    stub_src="$d/apt-mirrors.txt"
    [ "${FIXTURE_ALT+set}" = set ] && alt="$FIXTURE_ALT"
  else
    echo "deb http://primary.example/ubuntu noble main" > "$d/ubuntu.sources"
  fi
  : > "$d/log"
  out="$(env APT_GET="$TMP/apt-get" APT_SUDO= APT_ARCHIVES="$d/archives" \
    APT_SOURCES_FILES="$d/ubuntu.sources" APT_ALT_MIRROR="$alt" \
    APT_T_CACHED=5 APT_T_PLAIN=5 APT_T_ALT=5 \
    STUB_LOG="$d/log" STUB_SOURCES="$stub_src" "$@" \
    bash "$HELPER" ffmpeg at 2>&1)"
  rc=$?
  log="$(cat "$d/log")"
  src="$(cat "$d/ubuntu.sources")"
  mirrors="$(cat "$d/apt-mirrors.txt" 2>/dev/null)"
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
[ ! -e "$TMP/c2/archives/partial" ] \
  && ok "partial/ is removed on exit so the cache save can read the directory" || bad "partial/ left behind"

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

# 6. real runner sources (HIMMEL-2872 judge j2268a): the comment header names
#    help.ubuntu.com and the stanza is mirror+file:, so the primary is the first
#    mirror in the list and the fallback must rewrite that list, not the comments.
FIXTURE=real STUB_BAD=azure.example run_case c6a
first_mirror="$(head -n 1 <<<"$mirrors")"
[ "$rc" -eq 0 ] && grep -q 'alt.example' <<<"$first_mirror" && ! grep -q 'azure.example' <<<"$mirrors" \
  && grep -q 'help.ubuntu.com' <<<"$src" && grep -q 'azure.example' <<<"$out" && ! grep -q 'help.ubuntu.com' <<<"$out" \
  && ok "mirror+file: primary is the first listed mirror and the list is rewritten" \
  || bad "real-runner fallback (rc=$rc first=$first_mirror out=$out)"
FIXTURE=real STUB_BAD=azure.example STUB_ALL_FAIL=1 run_case c6b
failed_line="$(grep 'apt-install: FAILED' <<<"$out")"
[ "$rc" -ne 0 ] && grep -q 'mirrors=azure.example,alt.example ' <<<"$failed_line" \
  && ok "real-runner failure line names the listed mirror, not a comment URL" || bad "real-runner failure line ($failed_line)"

# 7. default alternate is genuinely different from the primary.
FIXTURE=real FIXTURE_ALT='' STUB_BAD=azure.example STUB_ALL_FAIL=1 run_case c7a
grep -q 'mirrors=azure.example,archive.ubuntu.com ' <<<"$out" \
  && ok "default alternate is archive.ubuntu.com" || bad "default alt ($out)"
printf '%s\n' 'Types: deb' "URIs: mirror+file:$TMP/c7b/apt-mirrors.txt" > "$TMP/c7b.sources"
mkdir -p "$TMP/c7b/archives"; printf 'http://archive.ubuntu.com/ubuntu/\tpriority:1\n' > "$TMP/c7b/apt-mirrors.txt"; : > "$TMP/c7b/log"
out="$(env APT_GET="$TMP/apt-get" APT_SUDO= APT_ARCHIVES="$TMP/c7b/archives" APT_SOURCES_FILES="$TMP/c7b.sources" \
  APT_T_PLAIN=5 APT_T_ALT=5 STUB_LOG="$TMP/c7b/log" STUB_SOURCES="$TMP/c7b/apt-mirrors.txt" STUB_BAD=archive.ubuntu.com STUB_ALL_FAIL=1 \
  bash "$HELPER" ffmpeg 2>&1)"
grep -q 'mirrors=archive.ubuntu.com,us.archive.ubuntu.com ' <<<"$out" \
  && ok "primary archive.ubuntu.com gets a different default alternate" || bad "distinct default alt ($out)"

# 8. the timeout is behavioural: a hung install is killed, not waited out.
SECONDS=0
run_case c8 STUB_HANG=1 STUB_HANG_SECS=8 APT_T_PLAIN=1
[ "$rc" -eq 0 ] && [ ! -e "$TMP/c8/log.survived" ] && [ "$SECONDS" -lt 6 ] \
  && ok "hung install is killed by the timeout (not waited out)" || bad "timeout (rc=$rc elapsed=${SECONDS}s survived=$([ -e "$TMP/c8/log.survived" ] && echo yes || echo no))"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
