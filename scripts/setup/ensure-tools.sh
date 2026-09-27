#!/usr/bin/env bash
# ensure-tools.sh -- best-effort install of missing REQUIRED tools via the
# platform package manager (R6, HIMMEL-460). setup.sh's [0/10] preflight calls
# this so a missing git (etc.) is FETCHED, not just flagged. The fallback is
# always honest: on an unknown platform, no package manager, no root/sudo, or a
# failed install, the tool simply stays missing and the CALLER fails loud with
# the manual hint -- ensure_tools never claims success it didn't achieve.
#
# Tools with a known package name go straight to the package manager (git,
# jq, python3, shellcheck, gitleaks). bun has no homebrew-core/apt/dnf
# package, so it is bootstrapped via its official installer (HIMMEL-548).
# Everything else is ASKED of the manager first (_ensure_pm_candidate) and
# installed the same way when it has a candidate -- gh on Ubuntu >= 24.04 /
# Debian >= 13 is the motivating case (HIMMEL-2548): the old fallback claimed
# "no known package" for gh without ever checking, which is false on those
# distros. node and npm stay bespoke on purpose -- node via nvm/fnm,
# npm because apt's 9.2 is known-broken for this repo's pre-push gate.
# The fallback never claims a package does not exist without having asked.
#
# Usage:  source ensure-tools.sh; ensure_tools git jq ...   (re-check after).
#         bash ensure-tools.sh git jq ...                   (direct).
set -uo pipefail

# tool -> package name. Identity for the ones we handle; an empty result means
# "not auto-installable here" (caller keeps its manual hint).
_ensure_pkg_for() {
  case "$1" in
    git)        echo git ;;
    jq)         echo jq ;;
    python3)    echo python3 ;;
    shellcheck) echo shellcheck ;;
    gitleaks)   echo gitleaks ;;
    *)          echo "" ;;
  esac
}

# Tools deliberately left to a bespoke installer rather than ever being
# offered through the package manager, even when the manager has a candidate
# (HIMMEL-2548) -- two entries, two different reasons: node because a version
# manager is the right path, npm because the DISTRO version is known-broken
# for this repo's own pre-push gate (apt's 9.2 has an expired registry key --
# see docs/setup/new-machine.md). Without this entry the probe would happily
# offer npm too, since apt genuinely has a candidate. bun never reaches this:
# it is short-circuited earlier at the `[ "$t" = bun ]` arm. Empty result
# means "not bespoke, ask the manager instead".
_ensure_bespoke_for() {
  case "$1" in
    node) echo "install node via nvm/fnm or https://nodejs.org -- the distro package is deliberately not used" ;;
    npm)  echo "apt's npm is 9.2 and its expired registry key fails the pre-push 'npm audit signatures' gate -- install Node+npm from NodeSource (https://github.com/nodesource/distributions), or 'sudo apt-get install -y npm && sudo npm install -g npm@11'" ;;
    *)    echo "" ;;
  esac
}

# Per-tool manual-install route used in the fallback messages when the
# package manager has no candidate, or cannot be asked (HIMMEL-2548). Empty
# result means no declared route -- caller's message just says "manually".
_ensure_manual_hint() {
  case "$1" in
    gh) echo "GitHub's official apt repo (https://cli.github.com/packages) or the release tarball (https://github.com/cli/cli/releases)" ;;
    *)  echo "" ;;
  esac
}

# Per-tool fallback hint appended to an apt/dnf install FAILURE message when
# one is declared (HIMMEL-2438). gitleaks has no package on some older
# distros -- its failure message still carries the old manager:"hint"
# guidance (the official release tarball) instead of a bare "install
# manually" that leaves the adopter with no path forward. Empty result means
# no declared fallback -- caller falls back to the generic manual-install
# wording.
_ensure_fallback_hint() {
  case "$1" in
    gitleaks) echo "install gitleaks from its official release tarball, then re-run" ;;
    *)        echo "" ;;
  esac
}

# Echo the first supported package manager on PATH, or "" (rc 1) if none.
_ensure_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt-get; return 0; fi
  if command -v dnf     >/dev/null 2>&1; then echo dnf;     return 0; fi
  if command -v brew    >/dev/null 2>&1; then echo brew;    return 0; fi
  echo ""; return 1
}

# Ask a package manager whether it has a candidate for a tool with no fixed
# _ensure_pkg_for mapping (HIMMEL-2548) -- the honest replacement for
# guessing "no known package". rc 0 = has a candidate, rc 1 = asked and has
# none, rc 2 = the query tool itself is not on PATH (cannot be asked at
# all), rc 3 = the query tool IS on PATH but its own invocation failed
# (corrupt/unreadable package lists, etc) -- asked, but the answer is
# unusable (HIMMEL-2548 CR round 2). The caller must treat 2 and 3 as two
# DIFFERENT reasons it could not confirm absence, never as proof of
# absence itself, and must not blur them into one message. Only apt-get
# distinguishes them today -- dnf/brew fold both shapes into rc 1 (see
# _ensure_no_candidate_msg below, which reports what the manager said
# without asserting absence for exactly that reason).
_ensure_pm_candidate() {
  local pm="$1" pkg="$2" cand out status
  case "$pm" in
    apt-get)
      command -v apt-cache >/dev/null 2>&1 || return 2
      # apt-cache's own exit status settles "no candidate" vs "could not ask"
      # exactly (HIMMEL-2548 CR round 1): it exits 0 even for a package it
      # cannot find (no Candidate: line, or "(none)"), and non-zero on a real
      # failure (unreadable/corrupt lists, etc). Output and status are
      # captured SEPARATELY, not via the pipeline below -- for two reasons
      # (HIMMEL-2548 CR round 2): it yields apt-cache's OWN exit status
      # unambiguously, rather than a pipeline status that merges two
      # commands' outcomes; and awk exits early (it has `exit` right after
      # the first match), which can SIGPIPE apt-cache on a SUCCESSFUL
      # lookup -- under this file's `set -o pipefail` that would turn a
      # healthy probe into a non-zero pipeline status (known-findings
      # `grep-q-pipe-under-pipefail`: a status read off such a pipeline is
      # not trustworthy in either direction). Do not collapse this back
      # into a pipeline.
      # LC_ALL=C is forced on this invocation ONLY (never globally in this
      # file -- dnf/brew are checked by exit status alone, never by parsing
      # output, so they need no locale pin) -- apt-cache's `Candidate:` label
      # is gettext-translated (German "Kandidat:", French "Candidat :", etc),
      # and the awk pattern below matches only the literal English word. On a
      # localized guest an untranslated match would silently find nothing,
      # so the probe returns 1 ("no candidate") on a system where apt
      # genuinely HAS the package -- the exact overclaim HIMMEL-2548 exists
      # to delete, resurrected by locale instead of by a missing check.
      # LC_ALL=C alone is sufficient: it forces the C locale for message
      # lookup regardless of LC_MESSAGES/LANG, and gettext only consults
      # LANGUAGE when the resolved message locale is not C/POSIX, so LC_ALL=C
      # also neutralizes an inherited LANGUAGE without pinning it separately.
      out=$(LC_ALL=C apt-cache policy "$pkg" 2>/dev/null)
      status=$?
      [ "$status" -eq 0 ] || return 3
      cand=$(printf '%s\n' "$out" | awk -F': *' '/^[[:space:]]*Candidate:/{print $2; exit}')
      [ -n "$cand" ] && [ "$cand" != "(none)" ] && return 0
      return 1
      ;;
    dnf)
      dnf list "$pkg" >/dev/null 2>&1 && return 0
      return 1
      ;;
    brew)
      brew info --formula "$pkg" >/dev/null 2>&1 && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Wording for the rc-1 ("asked, and the manager has none") fallback message,
# per package manager (HIMMEL-2548 CR round 1). apt-get's own exit status
# (see _ensure_pm_candidate above) proves the difference between "no such
# package" and "the query itself failed" -- rc 1 for apt-get only happens
# after a SUCCESSFUL lookup, so the confident "has no candidate" wording is
# earned. dnf and brew cannot make that distinction: `dnf list` and
# `brew info --formula` both exit 1 for a genuinely missing package AND for a
# failed metadata refresh or network error, so a broken dnf cache would
# otherwise get the same false "it does not exist" claim this ticket exists
# to remove. Guessing the difference from stderr text would be its own
# speculative heuristic, so instead the dnf/brew wording reports what the
# manager said without asserting absence. Do NOT unify these two wordings --
# the asymmetry is deliberate, not an oversight.
_ensure_no_candidate_msg() {
  local pm="$1" t="$2"
  case "$pm" in
    apt-get) echo "$pm has no candidate for '$t' on this system" ;;
    *)       echo "$pm reported no installable candidate for '$t' (a failed metadata refresh looks the same)" ;;
  esac
}

# bun's official installer requires `unzip` (bun ships as a .zip release
# asset) -- stock Ubuntu 24.04 ships curl+tar but NOT unzip by default
# (observed on the ubuntu_new clean-tools VM: "error: unzip is required to
# install bun"; a curl-only preflight missed this entirely, so qmd then
# failed downstream on "bun not found" even though the FIRST failure was
# never surfaced). Installed through the SAME privileged apt/dnf path
# already used for shellcheck/gitleaks (above), before the installer itself
# ever runs; brew/macOS ships unzip built in, so nothing to do there.
_ensure_bun_prereq_unzip() {
  command -v unzip >/dev/null 2>&1 && return 0
  local pm sudo_pfx
  pm=$(_ensure_detect_pm) || pm=""
  [ "$pm" = brew ] && return 0
  if [ -z "$pm" ]; then
    echo "  ensure-tools: bun's installer needs unzip -- no supported package manager (apt-get/dnf/brew) found; install unzip manually, then re-run" >&2
    return 1
  fi
  if ! sudo_pfx=$(_ensure_sudo_prefix); then
    echo "  ensure-tools: bun's installer needs unzip -- run this yourself: sudo $pm install -y unzip" >&2
    return 1
  fi
  echo "  ensure-tools: installing 'unzip' via $pm (required by bun's installer)..."
  if [ "$pm" = apt-get ]; then
    $sudo_pfx apt-get update >/dev/null 2>&1 || true
    $sudo_pfx apt-get install -y unzip >/dev/null 2>&1
  else
    $sudo_pfx dnf install -y unzip >/dev/null 2>&1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    echo "  ensure-tools: bun's installer needs unzip -- run this yourself: sudo $pm install -y unzip" >&2
    return 1
  fi
  return 0
}

# bun bootstrap -- bun is not in homebrew-core / apt / dnf, so the official
# installer is the portable path (mac + linux, no tap). It lands the binary in
# $HOME/.bun/bin, which is NOT on PATH in this subprocess -- the CALLER (setup.sh)
# adds ~/.bun/bin to PATH and re-checks. The installer source is captured first
# (then piped to bash) so a curl failure is detected directly rather than masked
# by `bash` succeeding on empty stdin. Honest fallback: if curl is absent or the
# fetch fails, bun stays missing and the caller fails loud with the manual hint.
_ensure_install_bun() {
  # Idempotent (HIMMEL-2438): a previous run (or a previous adopt/setup)
  # already dropped a working bun into $HOME/.bun/bin -- re-running the
  # official installer would only append ANOTHER identical PATH block to
  # ~/.bashrc (observed: re-running deps ensure grew the file by one block
  # per run). The binary being there and executable is the ONLY thing this
  # function bootstraps, so skip straight to the honest not-on-PATH notice.
  if [ -x "$HOME/.bun/bin/bun" ]; then
    echo "  ensure-tools: bun is already installed at ~/.bun/bin -- not on your PATH; add it (export PATH=\"\$HOME/.bun/bin:\$PATH\") to your shell rc"
    return 0
  fi
  # curl (to FETCH the installer) is checked before unzip (which the
  # installer's own BODY needs, once fetched) -- the more fundamental
  # blocker surfaces first.
  if ! command -v curl >/dev/null 2>&1; then
    echo "  ensure-tools: 'bun' needs curl to bootstrap (curl not found) -- install bun manually: https://bun.sh" >&2
    return 1
  fi
  if ! _ensure_bun_prereq_unzip; then
    return 1
  fi
  echo "  ensure-tools: installing 'bun' via the official installer (https://bun.sh/install)..."
  local installer errfile lastline
  installer=$(curl -fsSL https://bun.sh/install 2>/dev/null) || installer=""
  # Capture the installer's OWN stderr to a temp file (HIMMEL-2438 wet-run
  # fix (B), same shape as the apt/dnf stderr surfacing above) instead of
  # swallowing it entirely -- a failure message now names the installer
  # body's own last non-empty stderr line.
  errfile=$(mktemp "${TMPDIR:-/tmp}/ensure-tools-bun.XXXXXX" 2>/dev/null) || errfile=""
  if [ -n "$installer" ]; then
    if [ -n "$errfile" ]; then
      printf '%s' "$installer" | bash >/dev/null 2>"$errfile" && { rm -f "$errfile"; return 0; }
    else
      printf '%s' "$installer" | bash >/dev/null 2>&1 && return 0
    fi
  fi
  lastline=""
  [ -n "$errfile" ] && [ -s "$errfile" ] && lastline=$(grep -v '^[[:space:]]*$' "$errfile" | tail -n1)
  [ -n "$errfile" ] && rm -f "$errfile"
  if [ -n "$lastline" ]; then
    echo "  ensure-tools: bun official installer failed -- $lastline -- install bun manually: https://bun.sh" >&2
  else
    echo "  ensure-tools: bun official installer failed -- install bun manually: https://bun.sh" >&2
  fi
  return 1
}

# uv bootstrap (HIMMEL-2521): uv has no apt/dnf package on stock Ubuntu/
# Debian, and routing pre-commit/uv through `python3 -m pip` fails on those
# same distros -- python3 ships without pip, and PEP 668 marks the system
# interpreter externally-managed even when pip IS present. The official
# installer (mirrors _ensure_install_bun's shape exactly) lands the binary in
# $HOME/.local/bin, which is NOT on PATH in this subprocess -- same honest
# "not on your PATH" notice as bun's own idempotency branch. No pip anywhere
# in this path.
#
# $1 (optional): "upgrade" -- the old pip-manager route supported
# `--upgrade`; skip the idempotency early-return so `himmelctl deps upgrade`
# re-runs the official installer (which itself overwrites in place) instead
# of silently no-op'ing on an already-present uv. Only deps-engine.js's
# built shell line ever passes it (this file's own bare calls never do), so
# static analysis can't see a caller that supplies $1.
# shellcheck disable=SC2120
_ensure_install_uv() {
  if [ -x "$HOME/.local/bin/uv" ] && [ "${1:-}" != upgrade ]; then
    echo "  ensure-tools: uv is already installed at ~/.local/bin -- not on your PATH; add it (export PATH=\"\$HOME/.local/bin:\$PATH\") to your shell rc"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    :
  else
    echo "  ensure-tools: 'uv' needs curl to bootstrap (curl not found) -- install uv manually: https://astral.sh/uv/install.sh" >&2
    return 1
  fi
  echo "  ensure-tools: installing 'uv' via the official installer (https://astral.sh/uv/install.sh)..."
  local installer errfile lastline
  installer=$(curl -fsSL https://astral.sh/uv/install.sh 2>/dev/null) || installer=""
  errfile=$(mktemp "${TMPDIR:-/tmp}/ensure-tools-uv.XXXXXX" 2>/dev/null) || errfile=""
  if [ -n "$installer" ]; then
    if [ -n "$errfile" ]; then
      printf '%s' "$installer" | sh >/dev/null 2>"$errfile" && { rm -f "$errfile"; return 0; }
    else
      printf '%s' "$installer" | sh >/dev/null 2>&1 && return 0
    fi
  fi
  lastline=""
  [ -n "$errfile" ] && [ -s "$errfile" ] && lastline=$(grep -v '^[[:space:]]*$' "$errfile" | tail -n1)
  [ -n "$errfile" ] && rm -f "$errfile"
  if [ -n "$lastline" ]; then
    echo "  ensure-tools: uv official installer failed -- $lastline -- install uv manually: https://astral.sh/uv/install.sh" >&2
  else
    echo "  ensure-tools: uv official installer failed -- install uv manually: https://astral.sh/uv/install.sh" >&2
  fi
  return 1
}

# pre-commit bootstrap (HIMMEL-2521): `uv tool install pre-commit` instead of
# `python3 -m pip install --user pre-commit` -- same PEP 668 / missing-pip
# reason as uv above, and uv is what this repo already standardizes on. Looks
# for uv on the CURRENT PATH first, then at the fixed ~/.local/bin location
# the official installer above uses (this subprocess's PATH was not updated
# by a uv install that just ran in the same `ensure_tools` loop), bootstraps
# uv via _ensure_install_uv when neither is found, then re-resolves once.
#
# $1 (optional): "upgrade" -- the old pip-manager route supported
# `--upgrade`; when already installed, run `uv tool upgrade` instead of the
# plain `uv tool install`, which is a no-op once pre-commit is present. Only
# deps-engine.js's built shell line ever passes it (this file's own bare
# calls never do), so static analysis can't see a caller that supplies $1.
# shellcheck disable=SC2120
_ensure_install_precommit() {
  local mode="${1:-}" uv_bin uv_tool_list uv_tool_list_rc pc_installed pc_force_flag pc_err
  uv_bin=$(command -v uv 2>/dev/null) || uv_bin=""
  [ -z "$uv_bin" ] && [ -x "$HOME/.local/bin/uv" ] && uv_bin="$HOME/.local/bin/uv"
  if [ -z "$uv_bin" ]; then
    if ! _ensure_install_uv "$mode"; then
      echo "  ensure-tools: 'pre-commit' needs uv, and uv could not be installed -- install uv manually (https://astral.sh/uv/install.sh), then run: uv tool install pre-commit" >&2
      return 1
    fi
    uv_bin=$(command -v uv 2>/dev/null) || uv_bin=""
    [ -z "$uv_bin" ] && [ -x "$HOME/.local/bin/uv" ] && uv_bin="$HOME/.local/bin/uv"
  fi
  if [ -z "$uv_bin" ]; then
    echo "  ensure-tools: 'pre-commit' needs uv, and uv was just installed but is not on PATH -- add ~/.local/bin to your PATH, then run: uv tool install pre-commit" >&2
    return 1
  fi
  # `uv tool upgrade` only works on a pre-commit uv itself installed --
  # a pre-commit found on PATH via some other means (apt, pipx, a manual
  # install) is not something uv can upgrade, so check `uv tool list` before
  # taking that branch; anything else falls through to the plain install
  # below, which places a uv-managed pre-commit on PATH (CR follow-up).
  # Captured into a variable and tested for non-emptiness, never the exit
  # status of a `| grep -q` pipe: under this file's `set -o pipefail`, an
  # early grep match SIGPIPEs the producer, and the pipeline status becomes
  # the producer's non-zero one, flipping a genuine match to look like a
  # failure (grep-q-pipe-under-pipefail, HIMMEL-1430).
  #
  # `uv tool list` alone -- not a `command -v pre-commit` PATH check -- is
  # what proves uv manages it: gating on PATH too meant a uv-managed
  # pre-commit whose shim isn't on PATH fell through to `uv tool install`,
  # which no-ops on an already-installed tool, silently skipping the upgrade
  # (pr-check round 3 finding).
  #
  # A FAILING `uv tool list` (uv present but broken/corrupt) must not be
  # read the same as an EMPTY one (uv fine, pre-commit just not installed
  # yet) -- the former reports the failure and bails; only the latter falls
  # through to the install/upgrade below (HIMMEL-3628).
  uv_tool_list=$("$uv_bin" tool list 2>/dev/null)
  uv_tool_list_rc=$?
  if [ "$uv_tool_list_rc" -ne 0 ]; then
    echo "  ensure-tools: '$uv_bin tool list' failed (exit $uv_tool_list_rc) -- cannot tell whether 'pre-commit' is installed; run it yourself: $uv_bin tool list" >&2
    return 1
  fi
  pc_installed=$(printf '%s\n' "$uv_tool_list" | grep '^pre-commit ') || true
  if [ "$mode" = upgrade ] && [ -n "$pc_installed" ]; then
    echo "  ensure-tools: upgrading 'pre-commit' via 'uv tool upgrade'..."
    "$uv_bin" tool upgrade pre-commit >/dev/null 2>&1 || { echo "  ensure-tools: 'uv tool upgrade pre-commit' failed -- run it yourself: $uv_bin tool upgrade pre-commit" >&2; return 1; }
    return 0
  fi
  echo "  ensure-tools: installing 'pre-commit' via 'uv tool install'..."
  # A pip/pipx/manual pre-commit shim already on PATH (e.g. left over from
  # this dep's pre-HIMMEL-2521 pip route) lands in the same ~/.local/bin uv
  # installs into, so a plain `uv tool install` refuses to overwrite it
  # ("Executable already exists ... use --force"); upgrade mode replaces it
  # (pr-check round 4 finding).
  pc_force_flag=""
  [ "$mode" = upgrade ] && pc_force_flag="--force"
  pc_err=$("$uv_bin" tool install $pc_force_flag pre-commit 2>&1 >/dev/null) || {
    pc_err=$(printf '%s\n' "$pc_err" | grep -v '^[[:space:]]*$' | tail -n1)
    echo "  ensure-tools: 'uv tool install pre-commit' failed${pc_err:+ -- $pc_err} -- run it yourself: $uv_bin tool install $pc_force_flag pre-commit" >&2
    return 1
  }
  return 0
}

# Non-interactive privilege probe (HIMMEL-2438): echoes the prefix to use for
# an apt/dnf call ("" when already root, "sudo -n" when passwordless sudo is
# configured) on stdout with rc 0, or nothing with rc 1 when neither holds.
# `sudo -n true` proves passwordless sudo (an already-cached ticket, or a
# NOPASSWD rule) WITHOUT ever prompting -- a real prompt would hang a
# headless run with no tty to answer it. The caller (below) treats rc 1 as
# "tell the adopter the exact command to run themselves", never a silent
# "install manually" that hides WHY the install didn't happen.
_ensure_sudo_prefix() {
  if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then echo ""; return 0; fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo "sudo -n"; return 0; fi
  return 1
}

# ensure_tools <tool>... -- attempt to install the auto-installable missing ones.
# Always returns 0; the caller re-checks `command -v` to see what truly remains.
ensure_tools() {
  [ "$#" -gt 0 ] || return 0
  local pm t pkg sudo_pfx errfile rc lastline hint msg bespoke candrc
  pm=$(_ensure_detect_pm) || pm=""   # bun needs no pm; others fall through below
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 && continue
    # bun: no system package -- bootstrap via its official installer (mac + linux),
    # independent of any package manager.
    if [ "$t" = bun ]; then
      _ensure_install_bun
      continue
    fi
    # uv/pre-commit: bootstrapped via the official installer / uv tool
    # install (HIMMEL-2521) -- never routed through the package-manager
    # branch below, same bypass as bun above.
    if [ "$t" = uv ]; then
      _ensure_install_uv
      continue
    fi
    if [ "$t" = "pre-commit" ]; then
      _ensure_install_precommit
      continue
    fi
    if [ -z "$pm" ]; then
      echo "  ensure-tools: no supported package manager (apt-get/dnf/brew) found -- cannot auto-install '$t'; install it manually." >&2
      continue
    fi
    pkg=$(_ensure_pkg_for "$t")
    if [ -z "$pkg" ]; then
      bespoke=$(_ensure_bespoke_for "$t")
      if [ -n "$bespoke" ]; then
        echo "  ensure-tools: '$t' is deliberately left to a bespoke installer -- $bespoke" >&2
        continue
      fi
      hint=$(_ensure_manual_hint "$t")
      _ensure_pm_candidate "$pm" "$t"
      candrc=$?
      if [ "$candrc" -eq 0 ]; then
        pkg="$t"
      elif [ "$candrc" -eq 2 ] || [ "$candrc" -eq 3 ]; then
        # rc 2 and rc 3 are two DIFFERENT reasons the manager could not be
        # asked (HIMMEL-2548 CR round 2) -- collapsing them into one
        # hardcoded "(apt-cache not found)" would be false for rc 3, where
        # apt-cache WAS found and simply failed; that is the exact overclaim
        # this ticket exists to delete, so each gets its own accurate
        # parenthetical instead.
        if [ "$candrc" -eq 2 ]; then
          msg="  ensure-tools: cannot ask $pm whether it has '$t' (apt-cache not found) -- install it manually"
        else
          msg="  ensure-tools: cannot ask $pm whether it has '$t' (apt-cache failed) -- install it manually"
        fi
        if [ -n "$hint" ]; then msg="$msg: $hint"; else msg="$msg."; fi
        echo "$msg" >&2
        continue
      else
        msg="  ensure-tools: $(_ensure_no_candidate_msg "$pm" "$t") -- install it manually"
        if [ -n "$hint" ]; then msg="$msg: $hint"; else msg="$msg."; fi
        echo "$msg" >&2
        continue
      fi
    fi
    if [ "$pm" = brew ]; then
      echo "  ensure-tools: installing '$t' via brew..."
      brew install "$pkg" >/dev/null 2>&1 || echo "  ensure-tools: 'brew install $pkg' failed -- install '$t' manually." >&2
      continue
    fi
    # apt-get / dnf need root (HIMMEL-2438 defect 1: this used to run
    # unprivileged and fail with a message that never named the real cause).
    # Neither root nor passwordless sudo means the adopter must run the
    # privileged install themselves -- told with the EXACT command, never a
    # silent skip.
    if ! sudo_pfx=$(_ensure_sudo_prefix); then
      echo "  ensure-tools: '$t' needs $pm but no root/sudo available -- run this yourself: sudo $pm install -y $pkg" >&2
      continue
    fi
    echo "  ensure-tools: installing '$t' via $pm..."
    # Capture stderr to a temp file instead of swallowing it entirely
    # (HIMMEL-2438) -- a failure message now surfaces apt-get/dnf's own last
    # non-empty stderr line, not just a generic "install manually".
    errfile=$(mktemp "${TMPDIR:-/tmp}/ensure-tools.XXXXXX" 2>/dev/null) || errfile=""
    if [ "$pm" = apt-get ]; then
      $sudo_pfx apt-get update >/dev/null 2>&1 || true
      if [ -n "$errfile" ]; then
        $sudo_pfx apt-get install -y "$pkg" >/dev/null 2>"$errfile"
      else
        $sudo_pfx apt-get install -y "$pkg" >/dev/null 2>&1
      fi
    else
      if [ -n "$errfile" ]; then
        $sudo_pfx dnf install -y "$pkg" >/dev/null 2>"$errfile"
      else
        $sudo_pfx dnf install -y "$pkg" >/dev/null 2>&1
      fi
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      lastline=""
      [ -n "$errfile" ] && [ -s "$errfile" ] && lastline=$(grep -v '^[[:space:]]*$' "$errfile" | tail -n1)
      hint=$(_ensure_fallback_hint "$t")
      # A PROBED tool's install can fail too (HIMMEL-2548) -- when
      # _ensure_fallback_hint declares nothing, the manual-install route we
      # already resolved for the probe is a better fallback than a bare
      # "install manually". gitleaks keeps its own hint either way.
      [ -z "$hint" ] && hint=$(_ensure_manual_hint "$t")
      msg="  ensure-tools: '$pm install $pkg' failed"
      [ -n "$lastline" ] && msg="$msg -- $lastline"
      if [ -n "$hint" ]; then msg="$msg -- $hint"; else msg="$msg -- install '$t' manually."; fi
      echo "$msg" >&2
    fi
    [ -n "$errfile" ] && rm -f "$errfile"
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ensure_tools "$@"
fi
