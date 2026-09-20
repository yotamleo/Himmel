#!/usr/bin/env bash
# tarball-vs-clone.sh -- the HIMMEL-3059 fresh-guest acceptance body (P4).
# Installs himmel TWO ways from the SAME commit, each into its own HOME, then
# asserts they CONVERGED (ADR Q3) -- not merely that both installs exited 0:
#
#   clone path    git clone <bundle>  ->  himmelctl install
#   tarball path  the README's adopter steps, verbatim: sha256sum -c, tar -x,
#                 himmelctl install
#
# and that the checksum step is real: a corrupted copy of the tarball must FAIL
# `sha256sum -c`. Runs on a guest (scripts/test-tarball-install-vm.sh drives it)
# and, against a stub himmelctl, hermetically (scripts/release/test-tarball-vs-clone.sh).
#
# USAGE:
#   tarball-vs-clone.sh --work <dir> --tarball <himmel-V-linux.tar.gz> --bundle <git.bundle>
#   (<tarball>.sha256 must sit next to the tarball, as a release publishes it)
# Exit: 0 all assertions passed | 1 an assertion failed | 2 usage
# shellcheck disable=SC2015  # `A && step_ok || step_fail`: both helpers always return 0, so C never masks a failed A
set -uo pipefail

usage() { sed -n '/^# USAGE:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

work="" tarball="" bundle=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in --work) work="$2" ;; --tarball) tarball="$2" ;; --bundle) bundle="$2" ;; *) usage ;; esac
  shift 2
done
[ -n "$work" ] && [ -n "$tarball" ] && [ -n "$bundle" ] || usage
[ -f "$tarball" ] && [ -f "$tarball.sha256" ] && [ -f "$bundle" ] || { echo "tarball-vs-clone: tarball, tarball.sha256 or bundle missing" >&2; exit 2; }

CTL="scripts/himmelctl/bin.js"
name="$(basename -- "$tarball")"
fails=0
step_ok()   { echo "PASS  $1"; }
step_fail() { echo "FAIL  $1"; fails=$((fails+1)); }

mkdir -p "$work"
work="$(cd -- "$work" && pwd -P)"

# --- the checksum step, exactly as the README hands it to an adopter ----------
mkdir -p "$work/dl"
cp "$tarball" "$tarball.sha256" "$work/dl/"
if ( cd "$work/dl" && sha256sum -c "$name.sha256" >/dev/null ); then
  step_ok "sha256sum -c accepts the published pair"
else
  step_fail "sha256sum -c rejects the published pair"
fi

# RED control: same published hash, one flipped byte -- must FAIL, and the
# `&&` chain must never reach tar.
mkdir -p "$work/dl-bad"
cp "$tarball.sha256" "$work/dl-bad/"
python3 - "$tarball" "$work/dl-bad/$name" <<'PY'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
b[len(b) // 2] ^= 0xFF
open(sys.argv[2], 'wb').write(b)
PY
if ( cd "$work/dl-bad" && sha256sum -c "$name.sha256" >/dev/null 2>&1 && mkdir -p extracted && tar -xzf "$name" -C extracted ); then
  step_fail "RED: a corrupted tarball passed verification"
elif [ -d "$work/dl-bad/extracted" ]; then
  step_fail "RED: a corrupted tarball was extracted"
else
  step_ok "RED: a corrupted tarball fails sha256sum -c and is not extracted"
fi

# --- path B: tarball ----------------------------------------------------------
prefix_b="$work/prefix-tarball"
mkdir -p "$prefix_b"
( cd "$work/dl" && tar -xzf "$name" -C "$prefix_b" --strip-components=1 ) \
  && step_ok "tarball extracts into the prefix" || step_fail "tarball extract"
[ -f "$prefix_b/$CTL" ] && step_ok "tarball carries $CTL" || step_fail "tarball lacks $CTL"

# --- path A: clone ------------------------------------------------------------
prefix_a="$work/prefix-clone"
git clone -q "$bundle" "$prefix_a" 2>/dev/null \
  && step_ok "clone of the same commit" || step_fail "clone of the bundle"
[ -f "$prefix_a/$CTL" ] || step_fail "clone lacks $CTL"

# --- both installs, each into its OWN HOME and its OWN target repo -----------
install_side() { # install_side <label> <prefix>
  local label="$1" prefix="$2" home="$work/home-$1" target="$work/target-$1"
  mkdir -p "$home" "$target"
  git -C "$target" init -q . 2>/dev/null
  if ( cd "$prefix" && HOME="$home" node "$CTL" install --scope user </dev/null >"$work/install-$label-user.log" 2>&1 ); then
    step_ok "$label: himmelctl install --scope user exits 0"
  else
    step_fail "$label: himmelctl install --scope user (see $work/install-$label-user.log)"
  fi
  if ( cd "$target" && HOME="$home" node "$prefix/$CTL" install --scope project </dev/null >"$work/install-$label-project.log" 2>&1 ); then
    step_ok "$label: himmelctl install --scope project exits 0"
  else
    step_fail "$label: himmelctl install --scope project (see $work/install-$label-project.log)"
  fi
}
install_side clone "$prefix_a"
install_side tarball "$prefix_b"

# --- convergence: same end state, not just two zero exit codes ---------------
bash "$HERE/converge-check.sh" \
  --a-home "$work/home-clone"   --a-prefix "$prefix_a" --a-target "$work/target-clone" \
  --b-home "$work/home-tarball" --b-prefix "$prefix_b" --b-target "$work/target-tarball"
crc=$?
if [ "$crc" -eq 0 ]; then
  step_ok "clone and tarball installs CONVERGED"
else
  step_fail "clone and tarball installs did not converge (converge-check rc=$crc)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: PASS (tarball path converges with the clone path)"; else echo "RESULT: FAIL ($fails assertion(s))"; fi
[ "$fails" -eq 0 ]
