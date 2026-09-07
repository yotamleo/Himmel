#!/usr/bin/env bash
# scripts/lib/test-resolve-user-home.sh — unit tests for resolve-user-home.sh.
#
# Covers resolve_user_home + default_vault (HIMMEL-645/642/458), extracted
# verbatim from scripts/luna/pipeline-cadence.sh on HIMMEL-2176 Stage 1. Pins
# the fallback chain: LUNA_VAULT_PATH override wins over everything; the
# USERPROFILE+cygpath branch (Windows Git-Bash); plain $HOME fallback when
# USERPROFILE is unset (POSIX hosts); /tmp as the last-resort floor when both
# are unset. Never touches the real HOME/USERPROFILE/LUNA_VAULT_PATH — every
# case runs in a subshell with its own env so it cannot leak into (or read
# from) the operator's real environment or the live luna vault.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/resolve-user-home.sh
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
. "$SCRIPT_DIR/resolve-user-home.sh"

pass=0
fail=0

# assert_eq <desc> <got> <expected>
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  ok: $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL: $desc"
    echo "        want: [$want]"
    echo "        got:  [$got]"
  fi
}

echo "[test-resolve-user-home] resolve_user_home"

# USERPROFILE set + cygpath present -> cygpath -u "$USERPROFILE" wins over $HOME.
_fake_bin="$(mktemp -d -t resolve-user-home.XXXXXX)"
cat > "$_fake_bin/cygpath" <<'EOF'
#!/bin/sh
# Fake cygpath -u: mimics the real tool's Windows->POSIX path translation
# closely enough to prove USERPROFILE is what got fed to it.
case "$2" in
  'C:\Users\fakeop') printf '/c/Users/fakeop\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$_fake_bin/cygpath"
assert_eq "USERPROFILE + cygpath present: cygpath -u wins over \$HOME" \
  "$(PATH="$_fake_bin:$PATH" USERPROFILE='C:\Users\fakeop' HOME=/home/mismatched resolve_user_home)" \
  '/c/Users/fakeop'
rm -rf "$_fake_bin"

# USERPROFILE set but cygpath NOT on PATH -> falls through to the $HOME branch,
# unchanged (this is the POSIX/no-cygpath shape, not the Windows one).
_empty_path="$(mktemp -d -t resolve-user-home.XXXXXX)"
assert_eq "USERPROFILE set, no cygpath: falls through to \$HOME" \
  "$(PATH="$_empty_path" USERPROFILE='C:\Users\fakeop' HOME=/home/plainhome resolve_user_home)" \
  '/home/plainhome'
rm -rf "$_empty_path"

# USERPROFILE unset -> plain $HOME fallback (the POSIX host case).
assert_eq "USERPROFILE unset: plain \$HOME fallback" \
  "$(env -u USERPROFILE HOME=/home/posixuser bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; resolve_user_home')" \
  '/home/posixuser'

# Both unset -> /tmp last-resort floor.
assert_eq "both HOME and USERPROFILE unset: /tmp floor" \
  "$(env -u USERPROFILE -u HOME bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; resolve_user_home')" \
  '/tmp'

echo "[test-resolve-user-home] default_vault"

# LUNA_VAULT_PATH set -> wins outright, no home resolution involved.
assert_eq "LUNA_VAULT_PATH override wins" \
  "$(LUNA_VAULT_PATH=/some/other/vault HOME=/home/whoever default_vault)" \
  '/some/other/vault'

# LUNA_VAULT_PATH unset -> falls back to <home>/Documents/luna via
# resolve_user_home (plain $HOME branch here — the resolver itself is
# covered above).
assert_eq "no LUNA_VAULT_PATH: falls back to <home>/Documents/luna" \
  "$(env -u USERPROFILE -u LUNA_VAULT_PATH HOME=/home/posixuser bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; default_vault')" \
  '/home/posixuser/Documents/luna'

echo
echo "[test-resolve-user-home] pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
