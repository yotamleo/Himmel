# shellcheck shell=bash
# scripts/lib/graphify-bin.sh
#
# Resolver for the graphify CLI. graphify is a knowledge-graph tool distributed
# via PyPI as `graphifyy` (binary name `graphify`, upstream Graphify-Labs/graphify,
# Apache-2.0 as of v0.9.25 -- MIT through v0.9.24; upstream keeps the historical MIT
# text in LICENSE-MIT for pre-relicense contributions and references it from NOTICE).
# himmel neither vendors nor redistributes graphify -- `uv tool install` fetches it
# from PyPI onto the operator's own machine -- so the relicense carries no bundled-
# notice obligation here; it is a pin-review fact, not a compliance gate.
# This resolver installs it from PyPI pinned to a specific version via
# `uv tool install --with mcp graphifyy==<version>`. uv tool installs are already
# self-isolating (their own venv + a shim in uv's tool bin dir), so — unlike
# scripts/lib/qmd-bin.sh's bun-global junction — there is no separate PATH-provider
# step here: the shim lands in uv's tool bin dir, which setup.sh/adopt.sh already
# put on PATH for uv/pre-commit/jira.
#
# De-fork (HIMMEL-1048 / issue #469): this resolver previously installed from a
# himmel fork (yotamleo/graphify, HIMMEL-891) pinned to a commit SHA. The fork
# carried ZERO delta over upstream — its only reason to exist (declaring the `mcp`
# python dep, which upstream keeps optional) is already handled by the `--with mcp`
# install flag below — so it was dropped and we track upstream PyPI directly. A pin
# bump (when the nightly fork-drift guard reports a newer upstream release) is now a
# one-line change to _graphify_version() here + `synced_base` in scripts/upstreams.json.
#
# Foreign-install safety (operator requirement, 2026-07-11): before installing,
# detect whether graphify is ALREADY present — either as a `uv tool list` entry for
# graphifyy, or as any `graphify` resolved on PATH by another means (pip, pipx,
# homebrew, manual build, ...). An existing install is ADOPTED as-is and never
# reinstalled, shadowed, or duplicated. graphify_source() reports which case applies
# (see below) so callers can log provenance. Install-if-missing only.
#
# graphify_install() is idempotent: it re-checks graphify_source() first and skips
# cleanly whenever ANY install is already present (himmel-pin or foreign) — it only
# ever installs into a genuinely empty slot. Adopted installs must also RESOLVE
# (CR-r2): uv metadata with no working binary (stale receipt, missing shim, uv tool
# bin dir off PATH) WARNs with the remediation and returns nonzero — never a silent
# success, and never an auto-reinstall over existing uv metadata (that could clobber
# a foreign install's state).
#
# The pinned version is overridable via GRAPHIFY_VERSION for testing / a private
# index (mirrors the QMD_* overrides).

# Version config -- overridable per call (env var set before sourcing/calling).
#
# PIN (HIMMEL-1048): the install ref is a specific PyPI VERSION of graphifyy, not
# `latest`. A published PyPI version is immutable (PyPI forbids re-uploading a
# version with different content), so pinning the version gives the same
# content-addressed, reproducible new-machine bootstrap the old fork-SHA pin gave
# (HIMMEL-891) -- without carrying a fork. A pin bump is a reviewed change to this
# line, paired with `synced_base` in scripts/upstreams.json so the nightly
# fork-drift guard stays truthful.
_graphify_version() { printf '%s\n' "${GRAPHIFY_VERSION:-0.9.25}"; }
_graphify_pypi_name() { printf '%s\n' "graphifyy"; }
# The `uv tool install` package spec: `graphifyy==<version>`.
_graphify_pinned_source() { printf '%s==%s\n' "$(_graphify_pypi_name)" "$(_graphify_version)"; }
_graphify_bin_name() { printf '%s\n' "graphify"; }

# Prints the manual install recipe (best-effort documentation text embedded
# in WARN messages -- NOT eval'd elsewhere; graphify_install() below runs the
# equivalent command directly).
# `--with mcp` (HIMMEL-996): upstream's pyproject declares `mcp` only as an OPTIONAL
# extra ([project.optional-dependencies]), but the graphify-mcp entrypoint imports
# it at startup -- without this the CLI works and the MCP server crashes on every
# fresh install (hit on all 3 stations in the HIMMEL-985 parity audit; re-confirmed
# still optional upstream at v0.9.22, HIMMEL-1048). Drop the flag if upstream
# promotes mcp to a core dependency.
graphify_install_hint() {
  printf '%s\n' "uv tool install --with mcp $(_graphify_pinned_source)"
}

# Presence check ONLY -- does not invoke the binary, so a real runtime error
# reaches the caller instead of being masked as "graphify not installed".
has_graphify() {
  command -v "$(_graphify_bin_name)" >/dev/null 2>&1
}

# Resolve the uv tool directory (where per-tool venvs + receipts live).
# Falls back to uv's documented default when `uv tool dir` itself is
# unavailable (uv missing, or the subcommand errors) -- best-effort only,
# used solely to look up an existing receipt for provenance, never to
# decide whether uv itself is usable.
_graphify_uv_tool_dir() {
  local d
  if command -v uv >/dev/null 2>&1; then
    d="$(uv tool dir 2>/dev/null)" && [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  fi
  printf '%s\n' "$HOME/.local/share/uv/tools"
}

# True if `uv tool list` shows the graphifyy package installed.
_graphify_uv_has_package() {
  command -v uv >/dev/null 2>&1 || return 1
  uv tool list 2>/dev/null | grep -qE "^$(_graphify_pypi_name)([[:space:]]|\$)"
}

# Prints the resolved version of the uv-managed graphifyy install (e.g. 0.9.22),
# read from `uv tool list` (which prints "graphifyy vX.Y.Z"). Empty if uv is
# absent or the package line can't be parsed. Does NOT invoke the graphify binary
# -- a real runtime error must reach the caller, not be masked as a version miss.
_graphify_installed_version() {
  command -v uv >/dev/null 2>&1 || return 0
  uv tool list 2>/dev/null \
    | grep -E "^$(_graphify_pypi_name)[[:space:]]" \
    | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*' | head -1
}

# Reports the provenance of an existing graphify install:
#   "himmel-pin"  -- installed via uv as graphifyy AT the version we pin
#   "foreign"     -- installed some other way (uv graphifyy at a DIFFERENT
#                    version, pip, pipx, homebrew, manual build, ...)
#   ""            -- not installed at all (rc 1)
# himmel-pin requires the uv-resolved version (from `uv tool list`) to equal the
# pinned _graphify_version(); anything else present classifies as foreign so the
# adopt path never clobbers an operator's own install. A uv graphifyy install whose
# version can't be read is treated as foreign (the package IS present, we just can't
# prove it's ours), never as "not installed". The PyPI-install receipt records only
# the requirement spec (e.g. `graphifyy[all]`, no `==`), so the resolved version --
# not the receipt -- is the reliable provenance signal after the HIMMEL-1048 de-fork.
graphify_source() {
  local installed
  if _graphify_uv_has_package; then
    installed="$(_graphify_installed_version)"
    if [ -n "$installed" ] && [ "$installed" = "$(_graphify_version)" ]; then
      printf '%s\n' "himmel-pin"
    else
      printf '%s\n' "foreign"
    fi
    return 0
  fi
  if has_graphify; then
    printf '%s\n' "foreign"
    return 0
  fi
  printf '%s\n' ""
  return 1
}

# Install graphify from PyPI via `uv tool install`, UNLESS an install is already
# present (adopt it instead -- see graphify_source() above). Returns an honest rc:
# 0 when graphify ends up resolvable one way or another (adopted or freshly
# installed), nonzero on a genuine failure. WARN-not-fail by contract -- callers
# (setup.sh/adopt.sh + pwsh mirrors) decide whether a graphify failure aborts;
# this function only reports.
graphify_install() {
  local src

  # graphify_source returns rc 1 on "not installed" -- harmless here (empty
  # src falls through to the install path), but guard it so a caller running
  # under `set -e` without an || context can never abort on the probe (CR-6).
  src="$(graphify_source)" || true
  case "$src" in
    himmel-pin|foreign)
      if has_graphify; then
        if [ "$src" = "himmel-pin" ]; then
          echo "  graphify already installed (source=himmel-pin) -- skipping install."
        else
          echo "  graphify already installed (source=foreign) -- adopting the existing install, not installing over it."
        fi
        # Adopt is non-invasive by contract -- WARN (never reinstall) when the
        # adopted install carries the HIMMEL-996 missing-mcp-dep defect, and
        # say so honestly when the layout cannot be validated at all.
        case "$(_graphify_mcp_import_ok; echo $?)" in
          1)
            echo "  WARNING: the adopted graphify install cannot import the 'mcp' package -- graphify-mcp will crash at startup." >&2
            echo "  Fix with: $(graphify_install_hint) (add --force to replace the existing install)" >&2
            ;;
          2)
            echo "  NOTE: could not validate the adopted install's mcp import (unrecognized install layout) -- if graphify-mcp crashes at startup, reinstall: $(graphify_install_hint)"
            ;;
        esac
        graphify_wsl_share_store
        return 0
      fi
      # CR-r2: install metadata exists but the binary does not resolve
      # (stale receipt, missing shim, uv tool bin dir off PATH). Do NOT
      # auto-reinstall over existing uv metadata -- that could clobber a
      # foreign install's state. WARN with the remediation + honest nonzero;
      # callers are WARN-and-continue by contract.
      echo "  WARNING: graphify install metadata found (source=$src) but '$(_graphify_bin_name)' is not resolvable on PATH." >&2
      echo "  uv drops its shims in the uv tool bin dir -- check it is on PATH (uv tool update-shell)." >&2
      echo "  Not reinstalling over the existing uv install -- fix PATH, or reinstall manually: $(graphify_install_hint)" >&2
      return 1
      ;;
  esac

  echo "Installing graphify ($(_graphify_pinned_source))..."
  if ! command -v uv >/dev/null 2>&1; then
    echo "  uv not found -- cannot install graphify." >&2
    return 1
  fi
  if ! uv tool install --with mcp "$(_graphify_pinned_source)"; then
    echo "  ERROR: graphify install failed." >&2
    return 1
  fi

  if has_graphify; then
    case "$(_graphify_mcp_import_ok; echo $?)" in
      1)
        echo "  WARNING: graphify installed but its MCP entrypoint cannot import the 'mcp' package." >&2
        echo "  graphify-mcp will crash at startup -- reinstall manually: $(graphify_install_hint)" >&2
        return 1
        ;;
      2)
        echo "  NOTE: could not validate the mcp import (unrecognized install layout) -- if graphify-mcp crashes at startup, reinstall: $(graphify_install_hint)"
        ;;
    esac
    echo "  graphify installed and verified (source=himmel-pin)."
    graphify_wsl_share_store
    return 0
  fi
  echo "  WARNING: graphify installed but '$(_graphify_bin_name)' is still not resolvable on PATH." >&2
  echo "  uv drops its shims in the uv tool bin dir -- check it is on PATH (uv tool update-shell)." >&2
  return 1
}

# Probes whether the environment behind the graphify-mcp ENTRYPOINT can
# import the `mcp` package (its startup dependency -- HIMMEL-996).
# Interpreter resolution, most-specific first (CR: a PATH-based foreign
# install -- pip/pipx/brew -- must probe ITS interpreter, not the uv venv):
#   1. the resolved graphify-mcp console script's shebang python (posix;
#      Windows .exe launchers carry no readable shebang -- falls through);
#   2. the uv tool venv's python (bin/ posix, Scripts/ windows layouts).
# rc 0 = import OK; rc 1 = import FAILS (the known missing-dep defect);
# rc 2 = no interpreter resolvable -- UNVALIDATED, callers must say so
# rather than treat it as success.
_graphify_mcp_import_ok() {
  local py="" mcp_bin shebang tool_venv c
  mcp_bin="$(command -v graphify-mcp 2>/dev/null)"
  if [ -n "$mcp_bin" ] && [ -f "$mcp_bin" ]; then
    shebang="$(head -1 "$mcp_bin" 2>/dev/null)"
    case "$shebang" in
      '#!'*python*)
        py="${shebang#\#!}"
        case "$py" in
          */env\ *) py="$(command -v "${py##* }" 2>/dev/null)" ;;
          *)        py="${py%% *}" ;;
        esac
        [ -n "$py" ] && [ -f "$py" ] || py=""
        ;;
    esac
  fi
  if [ -z "$py" ]; then
    tool_venv="$(_graphify_uv_tool_dir)/$(_graphify_pypi_name)"
    for c in "$tool_venv/bin/python" "$tool_venv/Scripts/python.exe"; do
      [ -f "$c" ] && { py="$c"; break; }
    done
  fi
  [ -n "$py" ] || return 2
  "$py" -c 'import mcp' >/dev/null 2>&1 || return 1
  return 0
}

# On WSL, share the WINDOWS-side global graph store instead of regenerating:
# graph extraction is LLM-backed (real spend), and the store is plain JSON
# (~/.graphify/global-graph.json + manifest -- no sqlite/WAL hazard, so
# sharing over /mnt/c is safe, unlike .tokensave). Symlinks ~/.graphify at
# the Windows user's store when: running under WSL, the Windows store
# exists, and ~/.graphify is absent or an empty directory. Never touches an
# existing populated ~/.graphify (merge is the operator's call). Best-effort
# by contract: always returns 0.
graphify_wsl_share_store() {
  grep -qi microsoft /proc/version 2>/dev/null || return 0
  command -v wslpath >/dev/null 2>&1 || return 0
  command -v cmd.exe >/dev/null 2>&1 || return 0
  # Cheap check first -- skip the costly cmd.exe interop once already linked.
  [ -L "$HOME/.graphify" ] && return 0
  local win_home win_store
  # cmd.exe interop warns (and can fail) from a linux-fs cwd -- run it from /mnt/c.
  win_home="$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  [ -n "$win_home" ] || return 0
  win_store="$(wslpath -u "$win_home" 2>/dev/null)/.graphify"
  [ -d "$win_store" ] || return 0
  if [ -e "$HOME/.graphify" ]; then
    if [ -d "$HOME/.graphify" ] && [ -z "$(ls -A "$HOME/.graphify" 2>/dev/null)" ]; then
      rmdir "$HOME/.graphify" 2>/dev/null || return 0
    else
      echo "  graphify store: ~/.graphify already has content -- NOT replacing it with the shared Windows store (merge manually if desired)."
      return 0
    fi
  fi
  if ln -s "$win_store" "$HOME/.graphify" 2>/dev/null; then
    echo "  graphify store: linked ~/.graphify -> $win_store (shared Win+WSL store; both sides contribute, nothing regenerates)."
  fi
  return 0
}

# graphify_register_mcp <scope> -- register the graphify MCP server (the
# mcp__graphify__* tools) with Claude Code at <scope> (local|user|project;
# default user), so an install actually delivers the MCP tools and not just the
# CLI (HIMMEL-1047). ONE implementation consumed by setup.sh + adopt.sh (and,
# via the CLI entry below, the pwsh mirrors). SCOPE-DEPENDENT entrypoint:
#   - user/local (a PERSONAL config) -> the ABSOLUTE path (robust in the MCP
#     launch context; matches /himmel-doctor's absolute-not-bare convention).
#     uv places the shim in `uv tool dir --bin` (graphify-mcp.exe on Windows,
#     graphify-mcp on posix), with a PATH lookup as fallback.
#   - project (a COMMITTED .mcp.json) -> the BARE name, PATH-resolved per
#     machine: a machine-specific absolute path would break for teammates on
#     other machines (CR HIMMEL-1047).
# Idempotent PER SCOPE (skips only when graphify already exists AT THE TARGET
# scope, so a personal user entry never suppresses a project registration) and
# WARN-not-fail by contract: a missing claude/entrypoint or an add hiccup prints
# the manual command and returns 0, never aborting the caller.
graphify_register_mcp() {
  local scope="${1:-user}" bin_dir mcp_arg="" hint
  # Scope-appropriate manual hint: project = the portable bare name; user/local =
  # the absolute path. Used by every "register later / manually" message below so
  # a project adopter is never told to commit a machine-specific path.
  if [ "$scope" = "project" ]; then
    hint="claude mcp add -s $scope graphify -- graphify-mcp"
  else
    hint="claude mcp add -s $scope graphify -- \"\$(uv tool dir --bin)/graphify-mcp\""
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "  graphify MCP: 'claude' CLI not found -- skipping registration (CLI still installed)." >&2
    echo "  Register later: $hint" >&2
    return 0
  fi
  if [ "$scope" = "project" ]; then
    # Committed .mcp.json must stay portable across machines -> bare name,
    # resolved from PATH per machine (setup/adopt put uv's bin dir on PATH).
    mcp_arg="graphify-mcp"
  else
    # `|| true`: a plain `bin_dir=$(...)` assignment propagates the substitution's
    # exit status, so under a caller's `set -e` (adopt.sh is `set -euo pipefail`) a
    # missing/failing uv would ABORT the adopt instead of warn-not-failing.
    bin_dir="$(uv tool dir --bin 2>/dev/null || true)"
    if [ -n "$bin_dir" ] && [ -f "$bin_dir/graphify-mcp.exe" ]; then
      mcp_arg="$bin_dir/graphify-mcp.exe"
    elif [ -n "$bin_dir" ] && [ -f "$bin_dir/graphify-mcp" ]; then
      mcp_arg="$bin_dir/graphify-mcp"
    else
      mcp_arg="$(command -v graphify-mcp 2>/dev/null || true)"
    fi
    if [ -z "$mcp_arg" ]; then
      echo "  graphify MCP: 'graphify-mcp' entrypoint not found -- skipping (check the uv tool bin dir)." >&2
      echo "  Register later: $hint" >&2
      return 0
    fi
  fi
  # Attempt the add AT THE TARGET SCOPE. `claude mcp get` has no scope flag, so an
  # unscoped pre-check would let a user entry suppress a project add; instead add
  # directly and treat "already exists in <scope> config" (rc!=0) as an idempotent
  # skip. Any other failure is WARN-not-fail.
  local add_out add_rc
  # `if var=$(...)`: the assignment sits in a condition, where set -e is EXEMPT.
  # A bare `add_out=$(...)` would propagate a nonzero `claude mcp add` — notably
  # the COMMON "already exists" idempotent case (rc=1) — and abort a `set -e`
  # caller (adopt.sh) before the handling below ever runs.
  if add_out="$(claude mcp add -s "$scope" graphify -- "$mcp_arg" 2>&1)"; then
    add_rc=0
  else
    add_rc=$?
  fi
  if [ "$add_rc" -eq 0 ]; then
    echo "  graphify MCP: registered (scope=$scope, $mcp_arg) -- mcp__graphify__* tools available."
  elif printf '%s' "$add_out" | grep -qi "already exists"; then
    echo "  graphify MCP: already registered at $scope scope -- skipping."
  else
    echo "  WARNING: graphify MCP registration failed -- CLI works; register manually:" >&2
    echo "  $hint" >&2
  fi
}

# Reads the extras recorded in the uv receipt for the graphifyy install (e.g.
# "[all]"), or "" when there are none / the receipt is unreadable / python3 is
# absent. Used ONLY by graphify_update() to preserve the operator's chosen extras
# when himmel-update reinstalls at a bumped pin (dropping [all] on an update would
# be a silent regression). Best-effort — a miss just means "no extras", never an error.
_graphify_installed_extras() {
  local receipt
  receipt="$(_graphify_uv_tool_dir)/$(_graphify_pypi_name)/uv-receipt.toml"
  [ -f "$receipt" ] || { printf ''; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
  python3 - "$receipt" <<'PY' 2>/dev/null || printf ''
import re, sys
try:
    txt = open(sys.argv[1]).read()
except Exception:
    raise SystemExit(0)
# graphifyy's requirement entry, then its extras list (if any).
m = re.search(r'name\s*=\s*"graphifyy"[^}]*?extras\s*=\s*\[([^\]]*)\]', txt, re.S)
if not m:
    raise SystemExit(0)
items = re.findall(r'"([^"]+)"', m.group(1))
if items:
    sys.stdout.write("[" + ",".join(items) + "]")
PY
}

# Returns 0 (true) when version $1 is STRICTLY LOWER than version $2 (semver-ish
# major.minor.patch compare via python3). Any parse failure / missing python3 ->
# return 1 (NOT lower), so graphify_update fails SAFE: when we cannot prove the
# install is behind the pin, we do NOT reinstall (never clobber on uncertainty).
_graphify_version_lt() {
  # Fail SAFE on an empty/absent version string (CR HIMMEL-1048): the python
  # key() below defaults every unparseable component to 0, so an EMPTY $1 would
  # compare as (0,0,0) < pin -> "lower" -> trigger an unwanted force-reinstall of
  # a uv graphifyy whose version could not be read (the "foreign, unprovable"
  # case). Guard it here so an unreadable version is treated as NOT-behind
  # (leave as-is), honoring this function's own never-clobber-on-uncertainty contract.
  [ -n "$1" ] && [ -n "$2" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import re, sys
def key(v):
    v = v.strip().lstrip('vV')
    parts = (re.split(r'[.\-+]', v) + ['0', '0', '0'])[:3]
    out = []
    for p in parts:
        m = re.match(r'\d+', p)
        out.append(int(m.group()) if m else 0)
    return tuple(out)
sys.exit(0 if key(sys.argv[1]) < key(sys.argv[2]) else 1)
PY
}

# graphify_update -- bring graphify to the PINNED version (himmel-update entry,
# HIMMEL-1048). Distinct from graphify_install (install-if-missing +
# adopt-don't-clobber, for setup/adopt): this one PROPAGATES a pin bump to an
# existing uv install so `himmelctl update` actually rolls machines forward after
# the de-fork pin moves.
#   - not installed              -> graphify_install (fresh install at the pin).
#   - uv graphifyy == pin         -> up to date, no-op.
#   - uv graphifyy BEHIND pin     -> upgrade (force-reinstall at the pin),
#                                    PRESERVING the recorded extras (e.g. [all]) + --with mcp.
#   - uv graphifyy ahead/equal/unparseable -> left as-is (never downgrade).
#   - foreign NON-uv install (pip/pipx/brew) -> left untouched.
#
# DESIGN NOTE (CR codex-1, adjudicated): graphify_source classifies ANY uv
# graphifyy whose version != pin as "foreign", and codex flagged that
# graphify_update upgrading such an install is "clobbering a foreign install".
# That is INTENTIONAL here and is the operator's explicit directive ("make sure
# himmelctl updates graphify", 2026-07-21): post-de-fork graphify is a
# himmel-version-managed tool, and `himmelctl update` is the opt-in "bring my
# tools current" operation — so rolling a BEHIND uv install forward to the pin is
# the desired behavior, NOT a bug. The safety envelope that keeps this from being
# a true clobber: it ONLY ever upgrades (never downgrades — an ahead install is
# left alone), it PRESERVES the operator's chosen extras, it NEVER touches a
# non-uv install (pip/pipx/brew), and it logs the transition. The adopt-don't-
# clobber contract still governs graphify_install (fresh setup), where disturbing
# an existing install WOULD be wrong; update is a deliberately different verb.
# Idempotent + WARN-not-fail by contract (a best-effort himmel-update step).
graphify_update() {
  local src installed pin extras spec
  src="$(graphify_source)" || true
  if [ -z "$src" ]; then
    graphify_install
    return $?
  fi
  pin="$(_graphify_version)"
  installed="$(_graphify_installed_version)"
  if [ -n "$installed" ] && [ "$installed" = "$pin" ]; then
    echo "  graphify already at pinned version $pin -- up to date."
    graphify_wsl_share_store
    return 0
  fi
  if ! _graphify_uv_has_package; then
    echo "  graphify present (foreign non-uv install, v${installed:-?}) -- himmel-update leaves it as-is (never clobber pip/pipx/brew)."
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo "  uv not found -- cannot update graphify." >&2
    return 1
  fi
  # Only ever UPGRADE a strictly-behind install to the pin -- never downgrade or
  # touch an install that is equal/ahead/unparseable (CR codex-1: a uv graphifyy
  # at a different version is 'foreign' to graphify_source, so bringing it current
  # must stay a fail-safe upgrade, not an unconditional clobber). The ==pin case
  # already returned above; here installed != pin, so this splits behind (upgrade)
  # from ahead/unknown (leave). Extras are still preserved on the upgrade path.
  if ! _graphify_version_lt "$installed" "$pin"; then
    echo "  graphify installed v${installed:-?} is not behind the pin $pin (equal / ahead / unparseable) -- leaving as-is (himmel-update never downgrades or clobbers a non-behind install)."
    graphify_wsl_share_store
    return 0
  fi
  extras="$(_graphify_installed_extras)"
  spec="$(_graphify_pypi_name)${extras}==${pin}"
  echo "  graphify ${installed:-?} -> $pin (uv reinstall at pin, extras='${extras:-none}')..."
  if uv tool install --force --with mcp "$spec"; then
    echo "  graphify updated to $pin (source=himmel-pin)."
    graphify_wsl_share_store
    return 0
  fi
  echo "  WARNING: graphify update to $pin failed (non-fatal)." >&2
  return 1
}

# CLI entry -- only when EXECUTED (not sourced). Lets the pwsh mirrors
# (scripts/setup.ps1, scripts/adopt.ps1) delegate to this ONE implementation
# (`bash scripts/lib/graphify-bin.sh install`) instead of duplicating the
# detect/install recipe natively (mirrors qmd-bin.sh's CLI entry, HIMMEL-877).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    install) graphify_install ;;
    update)  graphify_update ;;
    source)  graphify_source ;;
    share-store) graphify_wsl_share_store ;;
    register-mcp) graphify_register_mcp "${2:-user}" ;;
    *) echo "Usage: bash scripts/lib/graphify-bin.sh install|update|source|share-store|register-mcp [scope]" >&2; exit 2 ;;
  esac
fi
