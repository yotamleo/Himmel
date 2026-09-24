#!/usr/bin/env bash
# test-pkgbuild.sh -- the AUR package's acceptance test (HIMMEL-3059 S5, design
# §2 and §4.3). Three modes:
#
#   (default)       CONTAINER. Builds a tarball + git bundle of this checkout's
#                   HEAD, then runs `--in-container` in archlinux:base-devel
#                   (docker or podman): makepkg -si + namcap, three installs
#                   (clone, tarball, AUR) converged with converge-check.sh,
#                   `himmelctl update` deferring to pacman, pacman -R with the
#                   wiring still in place, every wired hook failing OPEN on the
#                   missing prefix, then `himmelctl uninstall` via the per-user
#                   launcher. Exit 3 when no container runtime answers.
#   --host          NO ROOT, on an Arch host (makepkg on PATH). Builds the REAL
#                   PKGBUILD (its pinned release tarball; nothing is installed
#                   into the system): sha256sums enforced + a corrupted-tarball
#                   RED control, the package file list and wrapper, print-only
#                   install hooks, namcap when present (--namcap <cmd> overrides),
#                   `himmelctl update` deferring to pacman, and the hook
#                   fail-open check against a scratch HOME wired to a prefix
#                   that is then deleted.
#   --in-container  internal: the body the default mode runs as root in the
#                   container (/src = this checkout read-only, /art = artifacts).
#
# USAGE:
#   test-pkgbuild.sh [--runtime docker|podman] [--image <ref>]
#   test-pkgbuild.sh --host [--keep] [--namcap <cmd>]
#   test-pkgbuild.sh --in-container
# Exit: 0 all assertions passed | 1 an assertion failed | 2 usage | 3 no usable
# container runtime (default mode) or no makepkg (--host): not a code failure
# shellcheck disable=SC2015  # `A && ok || bad`: both helpers return 0, so C never masks a failed A
set -uo pipefail

usage() { sed -n '/^# USAGE:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mode=container runtime="" image="archlinux:base-devel" keep=0 nc_cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) mode=host ;;
    --in-container) mode=in-container ;;
    --keep) keep=1 ;;
    --namcap) [ $# -ge 2 ] || usage; nc_cmd="$2"; shift ;;
    --runtime) [ $# -ge 2 ] || usage; runtime="$2"; shift ;;
    --image) [ $# -ge 2 ] || usage; image="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

pass=0 fail=0 xfail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
finish() {
  echo
  echo "RESULT: $pass passed, $fail failed, $xfail expected-fail"
  [ "$fail" -eq 0 ]
  exit $?
}

# check_print_only <install-file> -- the .install hooks may only echo (design
# §4.3): statically (every non-comment line is a function head, a brace or an
# echo), and by running each function with no HOME in an empty scratch cwd that
# must stay empty.
check_print_only() {
  local f="$1" extra d fn out
  extra="$(grep -vE '^[[:space:]]*(#.*)?$|^[a-z_]+\(\) \{$|^\}$|^[[:space:]]+echo '"'"'[^'"'"']*'"'"'$' "$f")"
  [ -z "$extra" ] && ok "install hooks: every statement is an echo of a literal" || bad "install hooks carry a non-echo statement" "$extra"
  d="$(mktemp -d)" || { bad "install hooks: mktemp failed"; return 0; }
  for fn in post_install post_upgrade pre_remove; do
    out="$( cd "$d" && env -i PATH=/usr/bin:/bin bash -c ". '$f' && $fn" 2>&1 )"
    [ -n "$out" ] && ok "install hooks: $fn prints" || bad "install hooks: $fn printed nothing"
  done
  [ -z "$(ls -A "$d")" ] && ok "install hooks wrote nothing (scratch cwd still empty)" || bad "install hooks wrote files"
  rm -rf "$d"
  grep -q 'himmelctl uninstall, then pacman -R himmel' "$f" && ok "pre_remove documents the order: himmelctl uninstall, then pacman -R" || bad "removal order missing from the install hooks"
  ! grep -qE '/home|getent|passwd|~[a-z]' "$f" && ok "install hooks never look for users' homes" || bad "install hooks reference other users' homes"
}

# hooks_fail_open <scope> <settings.json> <env-file> -- runs every distinct hook command
# wired in settings.json, as Claude Code would (bash -c, the settings env
# applied, a JSON event on stdin), and expects rc 0 from each: rc 2 blocks the
# tool call (fail closed) and any other non-zero rc surfaces a hook error on
# every event, which design §4.3 also rules out ("expect no hook errors").
# Runs in the caller's shell (never a subshell) so the counters survive.
# Expected-fail (XFAIL, HIMMEL-3574): the user-scope safety hooks are wired as
# `bash "<prefix>/scripts/hooks/X.sh"`, so with the prefix gone bash exits 127
# (non-blocking, but an error on every event). Only that exact shape is an
# XFAIL; rc 2 or any other error stays a FAIL.
XFAIL_3574='auto-approve-safe-bash block-edit-on-main block-read-secrets inject-initiative'
hooks_fail_open() {
  local scope="$1" settings="$2" envfile="$3" n=0 bad_n=0 ev cmd rc err envv how
  mapfile -t envv < "$envfile"
  while IFS=$'\t' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    n=$((n+1))
    err="$(printf '{"session_id":"s5","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"true"},"cwd":"%s","prompt":"hi"}' "$ev" "$PWD" \
      | env "${envv[@]}" timeout 30 bash -c "$cmd" 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" -eq 127 ] && [ "$scope" = user ] && case "$err" in *"No such file or directory"*) true ;; *) false ;; esac \
       && case " $XFAIL_3574 " in *" $(basename "${cmd%\"}" .sh) "*) true ;; *) false ;; esac; then
      xfail=$((xfail+1))
      echo "XFAIL $scope hook errors on the missing prefix, rc 127 (known: HIMMEL-3574): $cmd"
    elif [ "$rc" -ne 0 ]; then
      bad_n=$((bad_n+1))
      how="errors (non-blocking hook error on every $ev)"; [ "$rc" -eq 2 ] && how="fails CLOSED (blocks the tool call)"
      bad "$scope hook $how on the missing prefix, rc $rc: $cmd" "$(printf '%s' "$err" | head -2 | tr '\n' '|')"
    fi
  done < <(jq -r '.hooks // {} | to_entries[] | .key as $e | .value[] | .hooks[]? | select(.type == "command") | [$e, .command] | @tsv' "$settings" | sort -u)
  [ "$n" -gt 0 ] && ok "$scope hook fail-open: $n distinct wired hook command(s) run against the missing prefix" || bad "$scope hook fail-open is VACUOUS: no hook command was wired"
  [ "$n" -gt 0 ] && [ "$bad_n" -eq 0 ] && ok "$scope hook fail-open: no hook fails closed or errors beyond the known XFAILs" || true
}

# --- --host -------------------------------------------------------------------
if [ "$mode" = host ]; then
  command -v makepkg >/dev/null 2>&1 || { echo "test-pkgbuild: --host needs makepkg (an Arch host); use the container mode elsewhere" >&2; exit 3; }
  command -v jq >/dev/null 2>&1 || { echo "test-pkgbuild: jq is required" >&2; exit 2; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-aur-host.XXXXXX")" || exit 1
  [ "$keep" = 1 ] && echo "scratch kept: $tmp" || trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
  b="$tmp/build"; mkdir -p "$b"
  cp "$HERE/PKGBUILD" "$HERE/himmel.install" "$b/"

  # sha256sums is mandatory and pinned: never SKIP, one per source.
  # shellcheck disable=SC1091,SC2154  # the sourced PKGBUILD defines source and sha256sums
  ( . "$b/PKGBUILD"
    [ "${#sha256sums[@]}" -eq "${#source[@]}" ] && ! printf '%s\n' "${sha256sums[@]}" | grep -qvE '^[0-9a-f]{64}$' ) \
    && ok "PKGBUILD pins a 64-hex sha256 for every source (no SKIP)" || bad "PKGBUILD sha256sums missing, short or SKIP"

  if ( cd "$b" && BUILDDIR="$b/work" SRCDEST="$b" PKGDEST="$b" makepkg -f -d --noconfirm --nocolor >"$tmp/makepkg.log" 2>&1 ); then
    ok "makepkg builds the package from the pinned release tarball"
  else
    bad "makepkg failed" "$(tail -5 "$tmp/makepkg.log" | tr '\n' '|')"; finish
  fi
  grep -qE 'Validating source files with sha256sums|Validating source files with sha256sums\.\.\.' "$tmp/makepkg.log" && grep -qE 'himmel-.*-linux\.tar\.gz \.\.\. Passed' "$tmp/makepkg.log" \
    && ok "makepkg validated the tarball against sha256sums" || bad "no sha256sums validation line in the makepkg log"

  # RED: the same PKGBUILD over a tarball with one flipped byte must fail verify.
  r="$tmp/red"; mkdir -p "$r"; cp "$b/PKGBUILD" "$b/himmel.install" "$r/"
  src="$(ls "$b"/himmel-*-linux.tar.gz)"
  python3 - "$src" "$r/$(basename "$src")" <<'PY'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
b[len(b) // 2] ^= 0xFF
open(sys.argv[2], 'wb').write(b)
PY
  if cmp -s "$src" "$r/$(basename "$src")"; then
    bad "RED control could not build a corrupted copy"
  elif ( cd "$r" && SRCDEST="$r" makepkg --verifysource -d --noconfirm --nocolor >"$tmp/red.log" 2>&1 ); then
    bad "RED: makepkg accepted a corrupted tarball"
  else
    grep -q 'FAILED' "$tmp/red.log" && ok "RED: a corrupted tarball fails makepkg's sha256sums check" || bad "RED: makepkg failed, but not on the checksum" "$(tail -3 "$tmp/red.log" | tr '\n' '|')"
  fi

  pkg=""; for f in "$b"/himmel-*.pkg.tar.*; do case "$f" in *.sig) ;; *) [ -f "$f" ] && pkg="$f" ;; esac; done
  [ -f "$pkg" ] || { bad "no package file in $b"; finish; }
  bsdtar -tf "$pkg" > "$tmp/list"
  grep -qx 'opt/himmel/scripts/himmelctl/bin.js' "$tmp/list" && ok "package carries /opt/himmel/scripts/himmelctl/bin.js" || bad "package lacks the entry point"
  grep -qx 'usr/bin/himmelctl' "$tmp/list" && ok "package carries the /usr/bin/himmelctl wrapper" || bad "package lacks /usr/bin/himmelctl"
  stray="$(grep -vE '^(\.PKGINFO|\.BUILDINFO|\.MTREE|\.INSTALL|opt/|opt/himmel(/.*)?|usr/|usr/bin/|usr/bin/himmelctl|usr/share/|usr/share/licenses/|usr/share/licenses/himmel(/.*)?)$' "$tmp/list")"
  [ -z "$stray" ] && ok "package installs nothing outside /opt/himmel, the wrapper and its license" || bad "package installs stray paths" "$(printf '%s' "$stray" | head -3 | tr '\n' '|')"
  ! grep -qE '^opt/himmel/\.git(/|$)' "$tmp/list" && ok "the packaged tree has no .git (update routes to pacman, never git pull)" || bad "the packaged tree carries .git"
  owners="$(bsdtar -tvf "$pkg" | awk '$3 != "root" || $4 != "root"' | grep -vE ' \.(PKGINFO|BUILDINFO|MTREE|INSTALL)$')"
  [ -z "$owners" ] && ok "every packaged file is owned root:root" || bad "packaged files not owned by root" "$(printf '%s' "$owners" | head -2 | tr '\n' '|')"
  x="$tmp/x"; mkdir -p "$x"; bsdtar -xf "$pkg" -C "$x" 2>/dev/null
  [ "$(cat "$x/usr/bin/himmelctl")" = "$(printf '#!/bin/sh\nexec node /opt/himmel/scripts/himmelctl/bin.js "$@"')" ] \
    && ok "wrapper is exactly: exec node /opt/himmel/scripts/himmelctl/bin.js \"\$@\" (sets no PATH or env)" || bad "wrapper content differs" "$(tr '\n' '|' < "$x/usr/bin/himmelctl")"
  [ -x "$x/usr/bin/himmelctl" ] && ok "wrapper is executable" || bad "wrapper is not executable"
  cmp -s "$x/.INSTALL" "$HERE/himmel.install" && ok "the package's .INSTALL is himmel.install" || bad "package .INSTALL differs from himmel.install"
  check_print_only "$HERE/himmel.install"

  nc="${nc_cmd:-namcap}"
  if command -v "${nc%% *}" >/dev/null 2>&1; then
    $nc "$b/PKGBUILD" >"$tmp/namcap-pkgbuild.log" 2>&1; $nc "$pkg" >"$tmp/namcap-pkg.log" 2>&1
    errs="$(cat "$tmp/namcap-pkgbuild.log" "$tmp/namcap-pkg.log" | grep -E ' E: ')"
    echo "      namcap PKGBUILD: $(wc -l < "$tmp/namcap-pkgbuild.log") line(s); package: $(wc -l < "$tmp/namcap-pkg.log") line(s)"
    sed 's/^/      namcap: /' "$tmp/namcap-pkgbuild.log" "$tmp/namcap-pkg.log" | head -20
    [ -z "$errs" ] && ok "namcap reports no errors (E:) on the PKGBUILD or the package" || bad "namcap errors" "$(printf '%s' "$errs" | head -3 | tr '\n' '|')"
  else
    echo "NOTE  namcap not installed: skipped here (the container mode runs it)"
  fi

  # The packaged tree at a scratch prefix, installed for a scratch HOME. The
  # clean env keeps the operator's HIMMEL_*/CLAUDE_* out, and no step may reach
  # the real crontab or systemd user units (checked before and after).
  pre="$tmp/opt/himmel"; mkdir -p "$tmp/opt"; cp -a "$x/opt/himmel" "$pre"; chmod -R a-w "$pre"
  home="$tmp/home" target="$tmp/target"; mkdir -p "$home" "$tmp/prov"; git init -q "$target"
  printf '%s\n' "HOME=$home" "PATH=/usr/bin:/bin" "HIMMEL_PROVENANCE_DIR=$tmp/prov" "LANG=C.UTF-8" > "$tmp/env"
  units() { find "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" 2>/dev/null | LC_ALL=C sort | sha256sum; }
  cron0="$(crontab -l 2>/dev/null | sha256sum)"; units0="$(units)"
  mapfile -t envv < "$tmp/env"
  tree0="$( cd "$pre" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum )"
  ( cd "$home" && env -i "${envv[@]}" node "$pre/scripts/himmelctl/bin.js" install --scope user </dev/null >"$tmp/install.log" 2>&1 ) \
    && ok "himmelctl install --scope user from a read-only packaged prefix exits 0" || bad "himmelctl install from the packaged prefix failed" "$(tail -4 "$tmp/install.log" | tr '\n' '|')"
  ( cd "$target" && env -i "${envv[@]}" node "$pre/scripts/himmelctl/bin.js" install --scope project </dev/null >"$tmp/install-project.log" 2>&1 ) \
    && ok "himmelctl install --scope project into a scratch repo exits 0" || bad "himmelctl install --scope project failed" "$(tail -4 "$tmp/install-project.log" | tr '\n' '|')"
  jq -e --arg p "$pre" '.env.HIMMEL_REPO == $p' "$home/.claude/settings.json" >/dev/null 2>&1 \
    && ok "HIMMEL_REPO is the flat packaged prefix (§1.4: stable across pacman upgrades)" || bad "HIMMEL_REPO is not the packaged prefix" "$(jq -c '.env.HIMMEL_REPO' "$home/.claude/settings.json" 2>&1)"
  ( cd "$home" && env -i "${envv[@]}" node "$pre/scripts/himmelctl/bin.js" update </dev/null >"$tmp/update.log" 2>&1 ); urc=$?
  [ "$urc" -ne 0 ] && grep -q 'pacman -Syu himmel' "$tmp/update.log" \
    && ok "himmelctl update on the packaged prefix refuses (rc $urc) and names pacman -Syu" || bad "himmelctl update did not defer to pacman" "rc=$urc: $(tail -3 "$tmp/update.log" | tr '\n' '|')"
  tree1="$( cd "$pre" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum )"
  [ "$tree0" = "$tree1" ] && ok "install + update left the packaged prefix byte-identical" || bad "the packaged prefix changed"
  [ "$cron0" = "$(crontab -l 2>/dev/null | sha256sum)" ] && [ "$units0" = "$(units)" ] \
    && ok "the real crontab and systemd user units are untouched" || bad "the install reached the real crontab or systemd user units"

  # pacman -R with the wiring still in place: the prefix is gone, settings stay.
  chmod -R u+w "$pre"; rm -rf "$pre"
  printf '%s\n' "HIMMEL_REPO=$pre" >> "$tmp/env"
  cd "$home" && hooks_fail_open user "$home/.claude/settings.json" "$tmp/env"
  printf '%s\n' "CLAUDE_PROJECT_DIR=$target" >> "$tmp/env"
  cd "$target" && hooks_fail_open project "$target/.claude/settings.json" "$tmp/env"
  finish
fi

# --- --in-container -----------------------------------------------------------
if [ "$mode" = in-container ]; then
  [ "$(id -u)" = 0 ] && [ -d /src ] && [ -d /art ] || { echo "test-pkgbuild: --in-container runs as root in the container, with /src and /art mounted" >&2; exit 2; }
  pacman -Syu --noconfirm --needed git jq nodejs python namcap sudo >/tmp/pacman.log 2>&1 || { echo "FAIL  pacman could not install the test deps"; tail -5 /tmp/pacman.log; exit 1; }
  useradd -m -d /build builder && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
  tgz="$(ls /art/himmel-*-linux.tar.gz)"; name="$(basename "$tgz")"; tag="${name#himmel-}"; tag="${tag%-linux.tar.gz}"
  sum="$(cut -d' ' -f1 < "$tgz.sha256")"
  b=/build/pkg; install -d -o builder "$b"
  cp /src/packaging/aur/PKGBUILD /src/packaging/aur/himmel.install "$tgz" "$b/"; chown -R builder "$b"
  # Point the recipe at the local artifact: same package(), same hash discipline.
  sed -i -e "s|^pkgver=.*|pkgver=${tag//-pre./pre}|" -e "s|^source=.*|source=(\"$name\")|" -e "s|^sha256sums=.*|sha256sums=('$sum')|" "$b/PKGBUILD"
  su builder -c "cd $b && makepkg -si --noconfirm --nocolor" >/tmp/makepkg.log 2>&1 \
    && ok "makepkg -si builds and installs the package" || { bad "makepkg -si failed" "$(tail -5 /tmp/makepkg.log | tr '\n' '|')"; finish; }
  namcap "$b/PKGBUILD" "$b"/himmel-*.pkg.tar.zst >/tmp/namcap.log 2>&1
  sed 's/^/      namcap: /' /tmp/namcap.log | head -20
  ! grep -q ' E: ' /tmp/namcap.log && ok "namcap reports no errors (E:)" || bad "namcap errors" "$(grep ' E: ' /tmp/namcap.log | head -3 | tr '\n' '|')"
  [ "$(pacman -Qq himmel)" = himmel ] && [ -x /usr/bin/himmelctl ] && ok "pacman owns himmel; /usr/bin/himmelctl is on PATH" || bad "package not installed"

  # Three installs of the same commit, one per HOME, all as the same user.
  w=/build/w; install -d -o builder "$w"
  su builder -c "set -e; cd $w; git clone -q /art/himmel.bundle clone; mkdir -p tarball && tar -xzf '$tgz' -C tarball --strip-components=1; for s in clone tarball aur; do mkdir -p home-\$s target-\$s; git -C target-\$s init -q .; done" \
    || bad "could not stage the clone and tarball trees"
  inst() { # inst <side> <himmelctl argv...>
    local s="$1"; shift
    su builder -c "cd $w/\$0 && HOME=$w/home-$s $* install --scope user </dev/null && cd $w/target-$s && HOME=$w/home-$s $* install --scope project </dev/null" "$( [ "$s" = aur ] && echo . || echo "$s" )" >"/tmp/install-$s.log" 2>&1 \
      && ok "$s: himmelctl install (user + project) exits 0" || bad "$s: install failed" "$(tail -3 "/tmp/install-$s.log" | tr '\n' '|')"
  }
  inst clone "node $w/clone/scripts/himmelctl/bin.js"
  inst tarball "node $w/tarball/scripts/himmelctl/bin.js"
  inst aur /usr/bin/himmelctl
  bash /src/scripts/release/converge-check.sh \
    --a-home "$w/home-clone" --a-prefix "$w/clone" --a-target "$w/target-clone" \
    --b-home "$w/home-tarball" --b-prefix "$w/tarball" --b-target "$w/target-tarball" \
    --c-home "$w/home-aur" --c-prefix /opt/himmel --c-target "$w/target-aur" \
    && ok "clone, tarball and AUR installs CONVERGED" || bad "the three installs did not converge"

  su builder -c "HOME=$w/home-aur himmelctl update </dev/null" >/tmp/update.log 2>&1; urc=$?
  [ "$urc" -ne 0 ] && grep -q 'pacman -Syu himmel' /tmp/update.log && ok "himmelctl update on the package refuses and names pacman -Syu" || bad "himmelctl update did not defer to pacman" "rc=$urc"

  pacman -R --noconfirm himmel >/tmp/remove.log 2>&1 && ok "pacman -R himmel with the wiring still in place" || bad "pacman -R failed"
  grep -q 'himmelctl uninstall, then pacman -R himmel' /tmp/remove.log && ok "pre_remove printed the removal order" || bad "pre_remove output missing"
  [ ! -e /opt/himmel ] && [ ! -e /usr/bin/himmelctl ] && ok "the payload is gone" || bad "payload left behind"
  printf '%s\n' "HOME=$w/home-aur" "PATH=/usr/bin:/bin" "HIMMEL_REPO=/opt/himmel" > /tmp/hook.env
  hooks_fail_open user "$w/home-aur/.claude/settings.json" /tmp/hook.env
  echo "CLAUDE_PROJECT_DIR=$w/target-aur" >> /tmp/hook.env
  cd "$w/target-aur" && hooks_fail_open project "$w/target-aur/.claude/settings.json" /tmp/hook.env

  su builder -c "HOME=$w/home-aur $w/home-aur/.local/bin/himmelctl uninstall --yes </dev/null" >/tmp/uninstall.log 2>&1 \
    && ok "himmelctl uninstall via the per-user launcher works after pacman -R (~/.himmel/uninstall/ fallback)" || bad "uninstall after removal failed" "$(tail -3 /tmp/uninstall.log | tr '\n' '|')"
  ! jq -e '[(.hooks // {}) | .[] | length] | add // 0 | . > 0' "$w/home-aur/.claude/settings.json" >/dev/null 2>&1 \
    && ok "no himmel hooks remain wired after uninstall" || bad "hooks still wired after uninstall"
  finish
fi

# --- default: the container driver ----------------------------------------------
if [ -z "$runtime" ]; then
  for r in docker podman; do command -v "$r" >/dev/null 2>&1 && "$r" info >/dev/null 2>&1 && { runtime="$r"; break; }; done
fi
[ -n "$runtime" ] && "$runtime" info >/dev/null 2>&1 || { echo "test-pkgbuild: no container runtime answers (docker/podman daemon not reachable); run --host on an Arch box instead" >&2; exit 3; }
repo="$(cd -- "$HERE/../.." && pwd)"
art="$(mktemp -d "${TMPDIR:-/tmp}/himmel-aur-art.XXXXXX")" || exit 1
trap 'rm -rf "$art"' EXIT
bash "$repo/scripts/release/build-tarball.sh" --version 0.0.0 --src "$repo" --out "$art" >"$art/build.log" 2>&1 \
  || { echo "test-pkgbuild: tarball build failed:" >&2; tail -5 "$art/build.log" >&2; exit 1; }
git -C "$repo" bundle create "$art/himmel.bundle" HEAD >/dev/null 2>&1 || { echo "test-pkgbuild: git bundle failed" >&2; exit 1; }
rm -f "$art/build.log"
"$runtime" run --rm -v "$repo:/src:ro" -v "$art:/art:ro" "$image" bash /src/packaging/aur/test-pkgbuild.sh --in-container
