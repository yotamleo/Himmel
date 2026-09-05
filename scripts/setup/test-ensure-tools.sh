#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-ensure-tools.sh -- hermetic tests for the package-manager CANDIDATE
# PROBE in scripts/setup/ensure-tools.sh (HIMMEL-2548).
#
# The defect this suite pins, measured wet on Ubuntu 24.04 noble: ensure-tools
# printed "no known apt-get package for 'gh' -- install it manually." on a
# guest where `apt-cache policy gh` reports Candidate: 2.45.0-1ubuntu0.3 and
# `apt-get install -y gh` succeeds in a second. Two separate claims are tested:
# gh IS offered through the manager when the manager has it, and the fallback
# message never asserts a package does not exist without having ASKED.
#
# Hermetic: every case runs against a fixture PATH holding stub
# apt-cache/apt-get/dnf/brew plus symlinks to the handful of real utilities the
# script needs -- nothing is installed on the host, and `command -v gh` is
# genuinely false inside a fixture even on a station where gh is installed.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, and Git Bash on Windows runs
# it unchanged -- the stubs are /bin/sh scripts and the only host tools used are
# coreutils. There is no .ps1 twin because there is no ensure-tools.ps1: the
# Windows preflight lives in scripts/setup.ps1 and does not share this code
# path. This paragraph is the T15 marker scripts/parity/test-ws5-invariants.sh
# looks for.
#
# Usage: bash scripts/setup/test-ensure-tools.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
ensure="$here/ensure-tools.sh"
fails=0

check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails + 1)); }; }
has()   { grep -Fq -- "$1" <<<"$2" && echo yes || echo no; }

td="$(mktemp -d "${TMPDIR:-/tmp}/ensure-tools-test.XXXXXX")" || { echo "FAIL - cannot create a temp dir"; exit 1; }
cleanup() { [ -n "${td:-}" ] && [ -d "$td" ] && chmod -R u+w "$td" 2>/dev/null; rm -rf -- "$td"; }
trap cleanup EXIT
# Consumed by the sourced red-control.sh below (shellcheck cannot follow
# the source, hence the directive) -- where its stderr captures land.
# shellcheck disable=SC2034
RED_CONTROL_TMPDIR="$td"

# shellcheck source=ensure-tools.sh
# shellcheck disable=SC1091
. "$ensure"
# shellcheck source=../lib/red-control.sh
# shellcheck disable=SC1091
. "$here/../lib/red-control.sh"

# ---------------------------------------------------------------------------
# Fixture: a PATH with ONLY the utilities ensure-tools.sh touches, so a tool
# under test is genuinely absent. `id` reports uid 0 so _ensure_sudo_prefix
# takes the already-root branch and no sudo stub is needed.
# ---------------------------------------------------------------------------
mk_fixture() {
    local fx="$1" u p
    mkdir -p "$fx/bin"
    for u in awk grep sed tail head cat mktemp chmod mkdir env bash; do
        if p="$(command -v "$u" 2>/dev/null)"; then ln -sf "$p" "$fx/bin/$u"; fi
    done
    printf '#!/bin/sh\necho 0\n' > "$fx/bin/id"
    chmod +x "$fx/bin/id"
    : > "$fx/calls"
}

# A stub apt-cache. $2 is the Candidate: field to report ("(none)" = the
# manager was asked and has nothing). $3 (optional, default 0) is apt-cache's
# OWN exit status -- non-zero simulates a real query failure (corrupt/unreadable
# lists, etc), distinct from a successful "(none)" answer (HIMMEL-2548 CR
# round 1: _ensure_pm_candidate must not read a failed query as absence).
mk_apt_cache() {
    local fx="$1" cand="$2" rc="${3:-0}"
    cat > "$fx/bin/apt-cache" <<STUB
#!/bin/sh
echo "apt-cache \$*" >> "$fx/calls"
if [ "\$1" = policy ]; then
  printf '%s:\n  Installed: (none)\n  Candidate: $cand\n' "\$2"
fi
exit $rc
STUB
    chmod +x "$fx/bin/apt-cache"
}

# A stub apt-cache whose Candidate: label is GETTEXT-TRANSLATED depending on
# ITS OWN environment at run time (HIMMEL-2548 CR round 3, codex-1): it prints
# the literal English "Candidate:" only when the resolved message locale
# (LC_ALL, else LC_MESSAGES, else LANG) is C/POSIX/unset, and a German
# "Kandidat:" label otherwise -- mirroring real apt-cache's gettext behaviour
# without depending on any locale actually being generated on the host, so the
# case using it is hermetic. $2 is the Candidate: value to report, same as
# mk_apt_cache.
mk_apt_cache_localized() {
    local fx="$1" cand="$2"
    cat > "$fx/bin/apt-cache" <<STUB
#!/bin/sh
echo "apt-cache \$*" >> "$fx/calls"
loc="\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-}}}"
case "\$loc" in
  ""|C|C.*|POSIX) label="Candidate:" ;;
  *)              label="Kandidat:" ;;
esac
if [ "\$1" = policy ]; then
  printf '%s:\n  Installed: (none)\n  %s $cand\n' "\$2" "\$label"
fi
exit 0
STUB
    chmod +x "$fx/bin/apt-cache"
}

# A stub apt-get. $2 = the exit status `install` returns; on success it drops a
# runnable stub for each package named, which is how "it got installed" is
# observed.
mk_apt_get() {
    local fx="$1" rc="$2"
    cat > "$fx/bin/apt-get" <<STUB
#!/bin/sh
echo "apt-get \$*" >> "$fx/calls"
if [ "\$1" = install ]; then
  shift
  for a in "\$@"; do
    case "\$a" in -*) continue ;; esac
    printf '#!/bin/sh\necho stub-%s\n' "\$a" > "$fx/bin/\$a"
    chmod +x "$fx/bin/\$a"
  done
  exit $rc
fi
exit 0
STUB
    chmod +x "$fx/bin/apt-get"
}

# A stub dnf. $2 = the exit status `list` returns (0 = a candidate exists).
mk_dnf() {
    local fx="$1" list_rc="$2"
    cat > "$fx/bin/dnf" <<STUB
#!/bin/sh
echo "dnf \$*" >> "$fx/calls"
for a in "\$@"; do
  if [ "\$a" = list ]; then exit $list_rc; fi
done
for a in "\$@"; do
  case "\$a" in -*|install) continue ;; esac
  printf '#!/bin/sh\necho stub-%s\n' "\$a" > "$fx/bin/\$a"
  chmod +x "$fx/bin/\$a"
done
exit 0
STUB
    chmod +x "$fx/bin/dnf"
}

# A stub brew. $2 = the exit status `info` returns (0 = the formula exists).
mk_brew() {
    local fx="$1" info_rc="$2"
    cat > "$fx/bin/brew" <<STUB
#!/bin/sh
echo "brew \$*" >> "$fx/calls"
if [ "\$1" = info ]; then exit $info_rc; fi
if [ "\$1" = install ]; then
  shift
  for a in "\$@"; do
    printf '#!/bin/sh\necho stub-%s\n' "\$a" > "$fx/bin/\$a"
    chmod +x "$fx/bin/\$a"
  done
fi
exit 0
STUB
    chmod +x "$fx/bin/brew"
}

installed_in() { PATH="$1/bin" command -v "$2" >/dev/null 2>&1 && echo yes || echo no; }
count_calls()  { grep -c -- "$2" "$1/calls" 2>/dev/null || true; }

# The false claim this ticket exists to delete. Every fallback case asserts its
# ABSENCE, not merely the presence of better wording.
FALSE_CLAIM="no known apt-get package"

# ===========================================================================
# C1 -- apt-get HAS a candidate for gh: it is installed through the same
# privileged path unzip/shellcheck/gitleaks already use, exactly once.
# ===========================================================================
fx="$td/c1"; mk_fixture "$fx"; mk_apt_cache "$fx" "2.45.0-1ubuntu0.3"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C1 gh installed when apt-get has a candidate" "$(installed_in "$fx" gh)" "yes"
check "C1 exactly one apt-get install call"          "$(count_calls "$fx" '^apt-get install')" "1"
check "C1 the manager was actually asked"            "$(count_calls "$fx" '^apt-cache policy gh')" "1"
check "C1 announces the install"                     "$(has "installing 'gh' via apt-get" "$out")" "yes"
check "C1 no false no-known-package claim"           "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C2 -- apt-get has NO candidate: the message says the manager was asked and
# came up empty, carries the real install route, and claims nothing false.
# ===========================================================================
fx="$td/c2"; mk_fixture "$fx"; mk_apt_cache "$fx" "(none)"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C2 gh NOT installed"                  "$(installed_in "$fx" gh)" "no"
check "C2 no install was attempted"          "$(count_calls "$fx" '^apt-get install')" "0"
check "C2 the manager was still asked"       "$(count_calls "$fx" '^apt-cache policy gh')" "1"
check "C2 says apt-get has no candidate"     "$(has "apt-get has no candidate for 'gh'" "$out")" "yes"
check "C2 names the official apt repo route" "$(has "cli.github.com" "$out")" "yes"
check "C2 names the release tarball"         "$(has "github.com/cli/cli/releases" "$out")" "yes"
check "C2 no false no-known-package claim"   "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C3 -- apt-get present but apt-cache is NOT: the manager cannot be asked, so
# the message says exactly that rather than inventing an answer.
# ===========================================================================
fx="$td/c3"; mk_fixture "$fx"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C3 gh NOT installed"                "$(installed_in "$fx" gh)" "no"
check "C3 no install was attempted"        "$(count_calls "$fx" '^apt-get install')" "0"
check "C3 says it could not ask"           "$(has "cannot ask apt-get whether it has 'gh'" "$out")" "yes"
check "C3 names apt-cache as absent"       "$(has "(apt-cache not found)" "$out")" "yes"
check "C3 still names the install route"   "$(has "cli.github.com" "$out")" "yes"
check "C3 no false no-known-package claim" "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C3b -- apt-cache IS on PATH but its query FAILS (non-zero exit): a failed
# lookup is not evidence of absence, so this must land on the SAME "cannot
# ask" branch as C3, not the confident "has no candidate" branch (HIMMEL-2548
# CR round 1 -- the finding this suite was added to pin).
# ===========================================================================
fx="$td/c3b"; mk_fixture "$fx"; mk_apt_cache "$fx" "2.45.0-1ubuntu0.3" 1; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C3b gh NOT installed"                    "$(installed_in "$fx" gh)" "no"
check "C3b no install was attempted"            "$(count_calls "$fx" '^apt-get install')" "0"
check "C3b says it could not ask"               "$(has "cannot ask apt-get whether it has 'gh'" "$out")" "yes"
check "C3b names apt-cache as having failed"    "$(has "(apt-cache failed)" "$out")" "yes"
check "C3b does NOT claim apt-cache is absent"  "$(has "(apt-cache not found)" "$out")" "no"
check "C3b does NOT claim a confirmed absence"  "$(has "apt-get has no candidate for 'gh'" "$out")" "no"
check "C3b still names the install route"       "$(has "cli.github.com" "$out")" "yes"
check "C3b no false no-known-package claim"     "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C3c -- apt-cache's own Candidate: label is GETTEXT-TRANSLATED on a localized
# guest (HIMMEL-2548 CR round 3, codex-1): the awk pattern matches only the
# literal English word, so without forcing the C locale on the apt-cache
# invocation itself, a German "Kandidat:" line parses as no candidate and gh
# is wrongly refused on a system where apt genuinely has it. The probe now
# runs apt-cache under a forced C locale, so the label it parses is never
# translated -- gh installs the same as C1 even under a fully German
# LC_ALL/LANG/LANGUAGE environment.
# ===========================================================================
fx="$td/c3c"; mk_fixture "$fx"; mk_apt_cache_localized "$fx" "2.45.0-1ubuntu0.3"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 LANGUAGE=de_DE.UTF-8 ensure_tools gh 2>&1 )
check "C3c gh installed under a localized apt-cache" "$(installed_in "$fx" gh)" "yes"
check "C3c exactly one apt-get install call"          "$(count_calls "$fx" '^apt-get install')" "1"
check "C3c no false no-known-package claim"           "$(has "$FALSE_CLAIM" "$out")" "no"
check "C3c no false has-no-candidate claim"           "$(has "has no candidate for 'gh'" "$out")" "no"

# ===========================================================================
# C4 -- an already-mapped tool is UNCHANGED: shellcheck installs straight
# through, with no candidate probe at all.
# ===========================================================================
fx="$td/c4"; mk_fixture "$fx"; mk_apt_cache "$fx" "0.9.0-1"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools shellcheck 2>&1 )
check "C4 shellcheck installed"        "$(installed_in "$fx" shellcheck)" "yes"
check "C4 one apt-get install call"    "$(count_calls "$fx" '^apt-get install')" "1"
check "C4 mapped tools skip the probe" "$(count_calls "$fx" '^apt-cache')" "0"

# ===========================================================================
# C5 -- an already-mapped tool whose install FAILS keeps its declared fallback
# hint (HIMMEL-2438 behaviour, unchanged).
# ===========================================================================
fx="$td/c5"; mk_fixture "$fx"; mk_apt_get "$fx" 1
out=$( PATH="$fx/bin" ensure_tools gitleaks 2>&1 )
check "C5 gitleaks failure names the install failure" "$(has "'apt-get install gitleaks' failed" "$out")" "yes"
check "C5 gitleaks keeps its tarball hint"            "$(has "official release tarball" "$out")" "yes"

# C5b -- a PROBED tool whose install fails keeps the manual route we already
# know, instead of degrading to a bare "install it manually."
fx="$td/c5b"; mk_fixture "$fx"; mk_apt_cache "$fx" "2.45.0-1ubuntu0.3"; mk_apt_get "$fx" 1
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C5b gh install failure is reported"  "$(has "'apt-get install gh' failed" "$out")" "yes"
check "C5b gh failure still names the route" "$(has "cli.github.com" "$out")" "yes"

# ===========================================================================
# C6 -- node is DELIBERATELY left to a bespoke installer: say so, do not probe,
# and do not claim the distro has no package.
# ===========================================================================
fx="$td/c6"; mk_fixture "$fx"; mk_apt_cache "$fx" "20.19.0+dfsg-1"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools node 2>&1 )
check "C6 node NOT installed"              "$(installed_in "$fx" node)" "no"
check "C6 no probe for a bespoke tool"     "$(count_calls "$fx" '^apt-cache')" "0"
check "C6 no install for a bespoke tool"   "$(count_calls "$fx" '^apt-get install')" "0"
check "C6 says bespoke installer"          "$(has "deliberately left to a bespoke installer" "$out")" "yes"
check "C6 no false no-known-package claim" "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C6b -- npm is bespoke for a REASON: apt has it, but apt's 9.2 fails this
# repo's own pre-push `npm audit signatures` gate, so the probe must not
# install it -- and the message must say why rather than deny the package.
# ===========================================================================
fx="$td/c6b"; mk_fixture "$fx"; mk_apt_cache "$fx" "9.2.0~ds1-1"; mk_apt_get "$fx" 0
out=$( PATH="$fx/bin" ensure_tools npm 2>&1 )
check "C6b npm NOT installed from apt"       "$(installed_in "$fx" npm)" "no"
check "C6b no install for npm"               "$(count_calls "$fx" '^apt-get install')" "0"
check "C6b says bespoke installer"           "$(has "deliberately left to a bespoke installer" "$out")" "yes"
check "C6b names the push-gate reason"       "$(has "npm audit signatures" "$out")" "yes"
check "C6b no false no-known-package claim"  "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C7/C8 -- the dnf branch probes and installs the same way.
# ===========================================================================
fx="$td/c7"; mk_fixture "$fx"; mk_dnf "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C7 dnf candidate present installs gh" "$(installed_in "$fx" gh)" "yes"
check "C7 dnf was asked"                     "$(count_calls "$fx" '^dnf list')" "1"

fx="$td/c8"; mk_fixture "$fx"; mk_dnf "$fx" 1
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C8 dnf no candidate does not install" "$(installed_in "$fx" gh)" "no"
check "C8 dnf reports the ambiguous wording" "$(has "dnf reported no installable candidate for 'gh' (a failed metadata refresh looks the same)" "$out")" "yes"
check "C8 no false no-known-package claim"   "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C8b -- dnf's rc-1 wording must NOT assert a confirmed absence (HIMMEL-2548
# CR round 1): `dnf list` exits 1 both for a genuinely missing package and for
# a failed metadata refresh, so the message must not claim the former.
# ===========================================================================
fx="$td/c8b"; mk_fixture "$fx"; mk_dnf "$fx" 1
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C8b does NOT assert dnf has no candidate" "$(has "dnf has no candidate for 'gh'" "$out")" "no"
check "C8b uses the ambiguity-aware wording"     "$(has "dnf reported no installable candidate for 'gh'" "$out")" "yes"
check "C8b still names the install route"        "$(has "cli.github.com" "$out")" "yes"
check "C8b no false no-known-package claim"      "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# C9 -- the brew branch probes and installs the same way.
# ===========================================================================
fx="$td/c9"; mk_fixture "$fx"; mk_brew "$fx" 0
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C9 brew formula present installs gh" "$(installed_in "$fx" gh)" "yes"
check "C9 brew was asked"                   "$(count_calls "$fx" '^brew info')" "1"

# ===========================================================================
# C10 -- no package manager at all: the pre-existing honest message, unchanged.
# ===========================================================================
fx="$td/c10"; mk_fixture "$fx"
out=$( PATH="$fx/bin" ensure_tools gh 2>&1 )
check "C10 no-pm message"                   "$(has "no supported package manager" "$out")" "yes"
check "C10 no false no-known-package claim" "$(has "$FALSE_CLAIM" "$out")" "no"

# ===========================================================================
# RED control (HIMMEL-2518 contract) -- C1 must be non-vacuous. Mutant: the
# candidate probe always answers "no candidate". Against the SAME
# candidate-present fixture, the predicted SPECIFIC wrong value is
# "installed=no manual=yes" -- gh silently not installed and the fallback
# message printed. A mutant that crashed or printed nothing yields
# "installed=no manual=no", which is NOT the prediction and fails the control.
# ===========================================================================
mutant="$td/ensure-tools-mutant.sh"
sed 's/^_ensure_pm_candidate() {$/_ensure_pm_candidate() { return 1;/' "$ensure" > "$mutant"
if ! grep -Fq '_ensure_pm_candidate() { return 1;' "$mutant"; then
    echo "FAIL - RED control broken: the mutation did not apply (has _ensure_pm_candidate been renamed?)"
    fails=$((fails + 1))
else
    fx="$td/rc"; mk_fixture "$fx"; mk_apt_cache "$fx" "2.45.0-1ubuntu0.3"; mk_apt_get "$fx" 0
    # Probe wrapper: the fallback message goes to stderr and "did it install?"
    # is state, not output -- fold both into one stdout line for the assert.
    cat > "$fx/probe.sh" <<PROBE
#!/bin/sh
msg=\$(bash "$mutant" gh 2>&1)
inst=no; command -v gh >/dev/null 2>&1 && inst=yes
man=no
case "\$msg" in *"install it manually"*) man=yes ;; esac
echo "installed=\$inst manual=\$man"
PROBE
    chmod +x "$fx/probe.sh"
    red_control_run --env "PATH=$fx/bin" -- "$fx/bin/bash" "$fx/probe.sh"
    red_control_assert \
        --label "C1 probe-always-negative" \
        --observed     "$RED_CONTROL_OUT" \
        --expect-wrong "installed=no manual=yes" \
        --correct      "installed=yes manual=no" \
        --note "WITHOUT the candidate probe answering, gh is never offered and the adopter is told to install manually on a system whose manager HAS the package" \
        || fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
