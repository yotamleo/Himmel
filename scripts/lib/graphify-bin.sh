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
_graphify_version() { printf '%s\n' "${GRAPHIFY_VERSION:-0.9.53}"; }
_graphify_pypi_name() { printf '%s\n' "graphifyy"; }
# The default `uv tool install` package spec includes the native Kimi backend's
# runtime dependencies (openai + tiktoken). Recorded non-empty extras are still
# preserved verbatim by graphify_update below.
_graphify_pinned_source() { printf '%s[kimi]==%s\n' "$(_graphify_pypi_name)" "$(_graphify_version)"; }
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
        # The native-Kimi dep probe runs on the FRESH-install path below (:211);
        # the much more common ADOPT path (scripts/adopt.sh -- existing resolvable
        # install) must surface the same warning, not skip it via this early
        # return (CR r5, finding 7).
        _graphify_kimi_import_warn
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
    _graphify_kimi_import_warn
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

# Best-effort native-Kimi dependency probe (HIMMEL-1748). uv's graphify shim
# lives in the tool BIN dir, but the interpreter that owns its imports lives in
# the graphifyy tool venv. Resolve that real venv through `uv tool dir` across
# Windows and POSIX layouts. An unrecognized layout silently skips validation
# (WARN-not-fail contract); a resolved interpreter returns the import's truth.
#
# HIMMEL-1787 CR follow-up (PR #1680 round 4, codex-adv, previously
# inconclusive): the interpreter this spawns lives UNDER the same tool-dir
# path _graphify_mcp_holders() matches processes against (pat_dir, above),
# so this subprocess's own command line satisfies that same needle while it
# runs. It cannot race ITSELF within one graphify_update() call (this is a
# blocking, sequential invocation that exits well before any later
# _graphify_mcp_holders() call in the same run), but a SEPARATE, concurrent
# himmel-update invocation's holder probe landing in the narrow window while
# this short-lived `import` subprocess is alive would count it as a holder.
# Accepted residual, not fixed here: the only possible effect is one extra
# safe SKIP (the exact fail-closed outcome HIMMEL-1274 wants on ANY
# uncertainty) — never a false "clear", never corruption — and it self-heals
# on the very next run once the subprocess (import completes in well under a
# second) is gone. Same accepted-residual class as the stale-but-alive
# promote-lock window documented elsewhere in this codebase.
_graphify_kimi_deps_ok() {
  local tool_venv py="" c
  tool_venv="$(_graphify_uv_tool_dir)/$(_graphify_pypi_name)"
  for c in "$tool_venv/Scripts/python.exe" "$tool_venv/Scripts/python" "$tool_venv/bin/python"; do
    [ -f "$c" ] && { py="$c"; break; }
  done
  [ -n "$py" ] || return 0
  "$py" -c 'import openai, tiktoken' >/dev/null 2>&1
}

_graphify_kimi_import_warn() {
  if ! _graphify_kimi_deps_ok; then
    # NEVER print a bare copy-paste `--force` reinstall (CR codex-adv r3):
    # a live graphify-mcp holds the tool dir on Windows and that command then
    # removes the entry points before failing the replace, leaving graphify
    # BROKEN (HIMMEL-1274 — the exact hazard graphify_update's holder
    # preflight exists for). Mirror that skip message's guidance instead.
    echo "  WARNING: graphify's native Kimi backend dependencies (openai, tiktoken) are not importable -- '--backend kimi' will fail at runtime." >&2
    echo "  Repair: close the Claude Code sessions holding graphify-mcp (each live session spawns one), then run:" >&2
    echo "      uv tool install --force --with mcp '$(_graphify_pinned_source)'" >&2
  fi
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
# _graphify_mcp_holders (HIMMEL-1274)
# Count processes holding the uv tool dir open — i.e. live graphify-mcp servers.
# Echoes a COUNT on stdout; rc 1 when this platform offers no probe (the caller
# must not read the count then).
#
# Match on the COMMAND LINE, not the process name. A uv-installed graphify-mcp
# runs as a plain `python.exe` whose argv is
# `<...>\Scripts\python.exe <...>\Scripts\<entrypoint>.exe` (verified live on
# Windows, 2026-07-26), so a name-based probe finds nothing and reports "clear"
# on exactly the busy machine this guard exists for.
#
# Two needles: the entrypoint name, and the uv tool dir itself — a process
# executing anything out of that directory holds it just as effectively.
# Test seam: GRAPHIFY_MCP_HOLDERS forces the count (and "unavailable" for a
# platform with no probe). Without it a suite running on a real workstation is
# not hermetic — the probe finds the developer's OWN live graphify-mcp servers
# and every reinstall test skips. That is not hypothetical: it is how this seam
# came to exist (the pre-existing extras-preserved test went red on a machine
# with 4 live sessions).
# _graphify_pat_from_path <path> — turn a REAL filesystem path into a pattern
# that matches it in both an ERE (`pgrep -f`, `grep -E`) and a .NET regex
# (PowerShell `-match`), so one needle serves every branch of the holder probe.
#
# Two jobs. Escape the regex metacharacters a real path can contain — a `.` in
# `~/.local` otherwise matches any character, and an unbalanced `(` in a path
# like `/opt/tools (v2)/…` is a SYNTAX error that makes the whole probe rc 2,
# i.e. "unavailable" on a machine that is merely oddly named. And normalize
# BOTH separators to `[/\]`, because the same install is spelled with `/` under
# MSYS and `\` in a Windows argv.
#
# Done character-by-character rather than with sed: the separator class has to
# survive the metacharacter pass without being re-escaped, and every sed
# spelling of that needs `/` inside a bracket expression (which closes the
# s/// early) or a delimiter that then collides with `|`. Bash 3.2-safe.
_graphify_pat_from_path() {
  local s="$1" out="" ch i=0 n=${#1}
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    case "$ch" in
      /|\\)                                            out="${out}[/\\\\]" ;;
      .|"["|"]"|"^"|"$"|"*"|+|"?"|"("|")"|"{"|"}"|"|") out="${out}\\${ch}" ;;
      *)                                               out="${out}${ch}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

_graphify_mcp_holders() {
  local pat_entry='graphify-mcp' pat_dir tool_name c ps_bin="" _out=""
  if [ -n "${GRAPHIFY_MCP_HOLDERS:-}" ]; then
    [ "$GRAPHIFY_MCP_HOLDERS" = "unavailable" ] && return 1
    printf '%s\n' "$GRAPHIFY_MCP_HOLDERS"
    return 0
  fi
  tool_name="$(_graphify_pypi_name)"
  # Two tool-dir needles, OR'd (codex-adv round): the RESOLVED dir plus the
  # default layout as a fallback.
  #
  # The default-shape literal alone failed OPEN on a configured UV_TOOL_DIR —
  # `uv tool dir` honours it, and this file already derives real paths from
  # _graphify_uv_tool_dir twice (the venv probe and the receipt read), so a
  # custom root is a SUPPORTED shape, not a hypothetical. A holder living in
  # /custom/root/graphifyy matched neither needle, so the probe said "clear"
  # and graphify_update walked into `uv tool install --force` against a held
  # venv — the corruption this guard exists to stop.
  #
  # Keeping the default-shape branch too is deliberate: if `uv` is absent or
  # `uv tool dir` fails, the resolved value falls back to the default anyway,
  # and an extra alternative can only make the probe match MORE. This guard
  # must fail CLOSED, so a redundant needle is the right kind of wrong.
  local pat_root
  pat_root="$(_graphify_pat_from_path "$(_graphify_uv_tool_dir)/${tool_name}")"
  pat_dir="${pat_root}|uv[/\\\\]tools[/\\\\]${tool_name}"
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*|CYGWIN*)
      for c in pwsh powershell; do command -v "$c" >/dev/null 2>&1 && { ps_bin="$c"; break; }; done
      [ -n "$ps_bin" ] || return 1
      # Capture, THEN validate. Piping straight to stdout failed OPEN: if pwsh
      # errors or is blocked by policy the pipeline emits nothing, and the
      # caller's `case ''|*[!0-9]*) holders=0` sanitizer read that empty line as
      # "0 holders" — so the reinstall proceeded on exactly the platform this
      # guard protects, which inverts the entire point of it. An unusable probe
      # is UNAVAILABLE (rc 1), never "clear" (HIMMEL-1289, public-PR CR).
      #
      # Doubling apostrophes is the PowerShell string boundary, and it is
      # SEPARATE from the regex escaping (codex-adv round). pat_dir now carries
      # a RESOLVED path, so it can contain `'` — `C:\Users\O'Brien\...` is an
      # ordinary profile — and a lone apostrophe closes the single-quoted
      # -Command string, making it a syntax error. That is not a harmless
      # failure: an unusable probe returns 1, and the CALLER treats "cannot
      # probe" as "proceed", so the reinstall would run against a held venv —
      # the corruption this guard exists to stop, on the platform it was
      # written for. Escaping here, not in _graphify_pat_from_path, because
      # that helper also feeds pgrep/grep where `''` would be a literal.
      local ps_entry ps_dir
      ps_entry="$(printf '%s' "$pat_entry" | sed "s/'/''/g")"
      ps_dir="$(printf '%s' "$pat_dir" | sed "s/'/''/g")"
      # `ProcessId -ne $PID` excludes the PROBE ITSELF (CodeRabbit round). The
      # needles are literally present in this pwsh process's own CommandLine,
      # so Win32_Process matched it every time and the count was always one
      # too high. That is the Windows twin of the `[g]raphify-mcp` bracket
      # trick on the ps branch, and it was missing: on a machine with ZERO
      # real holders the probe returned 1, the caller read "1 holder — NOT
      # attempting the reinstall", and the graphify pin could never advance on
      # Windows at all. Measured on this host: 7 matches self-counted vs 6
      # real. Fails closed, so nothing was corrupted — it just silently never
      # updated.
      _out="$(MSYS_NO_PATHCONV=1 "$ps_bin" -NoProfile -Command \
        "@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { \$_.ProcessId -ne \$PID -and (\$_.CommandLine -match '$ps_entry' -or \$_.CommandLine -match '$ps_dir') }).Count" \
        2>/dev/null | tr -cd '0-9')" || return 1
      case "$_out" in ''|*[!0-9]*) return 1 ;; esac
      printf '%s\n' "$_out"
      ;;
    *)
      if command -v pgrep >/dev/null 2>&1; then
        # NOT `pgrep -c`: the count flag is a GNU/procps extension and macOS
        # BSD pgrep has no equivalent, so `-fc` there is a usage error.
        #
        # Branch on pgrep's OWN exit code, and do NOT pipe it into a counter.
        # `pgrep … | grep -c .` always emits a digit, so the numeric validator
        # can never fire and a BROKEN pgrep still reports "0 holders" — the
        # exact fail-open this fix was supposed to close (caught by both
        # critics on the first pass; the first attempt at it was itself
        # fail-open). pgrep's codes are load-bearing here:
        #   0 = matched, 1 = ran fine and matched NOTHING (a real zero),
        #   2/3 = usage error / fatal -> the probe is UNAVAILABLE, not clear.
        # BOTH needles, same as the Windows branch (public-PR CR): the two
        # documented above are entrypoint-name AND tool-dir, and a holder can
        # present either — a uv-installed server whose argv names the tool dir
        # without the literal entrypoint string was counted as CLEAR here while
        # Windows counted it. `pgrep -f` takes an ERE, so alternation is free.
        _out="$(pgrep -f "$pat_entry|$pat_dir" 2>/dev/null)"
        case "$?" in
          0) _out="$(printf '%s\n' "$_out" | grep -c . || true)" ;;
          1) _out=0 ;;
          *) return 1 ;;
        esac
        case "$_out" in ''|*[!0-9]*) return 1 ;; esac
        printf '%s\n' "$_out"
      elif command -v ps >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        # pgrep is preferred and tried first; this is the fallback for hosts
        # without it. The bracket in "[g]raphify-mcp" keeps the grep from
        # matching ITS OWN argv in the ps output — the classic off-by-one that
        # would report a holder on a completely idle machine and block the
        # update forever. `ps` is captured and status-checked FIRST for the
        # same reason as above: a failed ps piped into grep -c yields "0",
        # which would read as a clear machine.
        # -ww FIRST, with a fallback (public-PR CR): plain `ps -eo args` truncates
        # the command line to terminal width on procps, and the tool-dir needle
        # this branch now also searches for is a long absolute path — exactly the
        # part that gets cut. A truncated line silently reads as "no holder",
        # which is the fail-OPEN direction: it lets the destructive update
        # proceed while a graphify-mcp is live.
        #
        # It cannot be applied unconditionally, though — the MSYS `ps` that Git
        # Bash ships REJECTS -ww (verified on this host), and a hard switch would
        # turn every such host from "probes correctly" into "cannot probe at
        # all". So: try widened, fall back to plain, and only then give up.
        _out="$(ps -ww -eo args 2>/dev/null)" || _out="$(ps -eo args 2>/dev/null)" || return 1
        [ -n "$_out" ] || return 1
        # -cE + both needles, matching the pgrep branch and Windows.
        #
        # What keeps this from matching ITSELF is the pre-captured snapshot
        # above, NOT the bracket trick (CR round — the first draft of this
        # comment credited the brackets and was wrong). `ps` has already run
        # and its output is in $_out before grep starts, so grep's own argv was
        # never in the text being searched.
        #
        # The brackets alone would NOT save it: pat_dir ends with the plain,
        # unbracketed tool name, so the argv string
        #   grep -cE -- [g]raphify-mcp|uv[/\]tools[/\]graphify-mcp
        # contains a literal `graphify-mcp` that the `[g]raphify-mcp` branch
        # matches — verified. Refactoring this to a live `ps -eo args | grep`
        # pipe would therefore count grep itself and report a phantom holder,
        # blocking every update forever. Keep the capture-then-search shape.
        _out="$(printf '%s\n' "$_out" | grep -cE -- "[g]raphify-mcp|$pat_dir" || true)"
        case "$_out" in ''|*[!0-9]*) return 1 ;; esac
        printf '%s\n' "$_out"
      else
        return 1
      fi
      ;;
  esac
}

# _graphify_binary_ok (HIMMEL-1274) — does the installed graphify actually RUN?
# `uv tool install` removes the old distribution's entry points BEFORE it fails
# on a locked directory, so "the install returned nonzero" and "the binary still
# works" are INDEPENDENT facts. Presence is not the question: the broken state
# leaves the PATH shim in place and it throws a runpy traceback when invoked.
_graphify_binary_ok() {
  command -v graphify >/dev/null 2>&1 || return 1
  graphify --version >/dev/null 2>&1
}

# _graphify_skill_refresh (HIMMEL-1750) -- keep the Claude skill in step with
# the installed package by copying the skill files DIRECTLY from the package,
# never via `graphify install`. Five CR rounds established that the broad
# installer is not a safe primitive to wrap: it writes the DEFAULT profile's
# CLAUDE.md even under CLAUDE_CONFIG_DIR, and it rewrites .graphify_version
# for every OTHER installed platform (including nested roots like
# ~/.config/opencode and LOCALAPPDATA/hermes, and it creates markers where
# none existed) without refreshing their content — falsifying exactly the
# staleness warnings this helper exists to serve (upstream issue drafted via
# this ticket). The direct copy has NO side effects outside the target skill
# dir; it works for ROUTED profiles (writes ${CLAUDE_CONFIG_DIR:-$HOME/.claude});
# and it derives version, package path, and content from the SAME venv
# interpreter, so the validated version and the copied files cannot come from
# different installs (a PATH-shadowing pipx/brew graphify never gets involved).
# Copy fidelity is proven: the real installer's claude output is byte-identical
# to pkg/skill.md + pkg/skills/claude/references (verified 0.9.40, 2026-08-12).
# The CLAUDE.md always-on registration is deliberately NOT touched — skills
# are directory-discovered; the registration is a one-time nudge the full
# installer performs on fresh setups. Best-effort by contract (WARN-not-fail);
# _graphify_pin_skip_track / _graphify_pin_skip_reset (HIMMEL-1601)
#
# The reinstall-guard SKIP (holders>0, or an unprobeable platform without
# GRAPHIFY_UNPROBED_OK) is the ROUTINE outcome on any workstation with a live
# Claude Code session -- every session spawns a graphify-mcp holding the uv
# tool dir, so "no holders" is a precondition that is almost never true while
# himmel-update itself typically runs FROM inside such a session. Left as a
# single routine-looking advisory line, a skip that can never clear itself is
# indistinguishable in the logs from a step that is always up to date (the
# same silent-no-op class as HIMMEL-1154's cadence-run finding).
#
# Minimum acceptable fix (per the ticket, not the deeper reap/stage-swap/
# scheduled-slot options): escalate the skip so it cannot be mistaken for
# success, and make "skipped N runs in a row" visible WITHOUT reading logs --
# a persisted counter (survives across separate himmel-update invocations,
# co-located with the skill marker so it needs no new top-level state dir)
# that increments on every skip and resets on any non-skip outcome, printed
# loudly on every skip. This does not touch the `uv tool install --force`
# path at all -- HIMMEL-1274's fail-closed refusal is untouched.
_graphify_pin_skip_marker() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/graphify/.graphify_pin_skip_count"
}

_graphify_pin_skip_track() {  # $1 = short reason (e.g. "N holders" / "unprobeable")
  local marker n write_rc=0
  marker="$(_graphify_pin_skip_marker)"
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  # ponytail: unlocked read-modify-write, no lock file. himmel-update is a
  # lean-invoke operator/scheduler tool, not a multi-writer daemon -- two
  # concurrent invocations racing this exact line is rare, and the cost of
  # losing a race is a slightly-off ADVISORY count (never a wrong SKIP/
  # non-skip decision, which is decided elsewhere). Add a mkdir-based lock
  # (same pattern as refresh-graph-map.sh's own locks) if this ever needs
  # to be exact.
  n=$(cat "$marker" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  # 10# forces base 10 (CR follow-up, codex-2 @ paid panel): a digit-only
  # value like "08" passes the case-pattern validation above (all chars are
  # 0-9) but bash arithmetic reads a leading zero as an octal prefix, and
  # "08" is not valid octal -- `$((n + 1))` would itself error. Same fix
  # class critic-panel.sh already applies to its own timeout env var.
  n=$((10#$n + 1))
  # Write via mktemp + mv, NOT a predictable "$marker.tmp.$$" name (CR
  # follow-up, codex-1 @ paid panel, round 2): a plain redirect FOLLOWS a
  # symlink, and a $$-based name is guessable/racy -- another local process
  # could pre-create a symlink AT that exact predictable path before this
  # write runs, and the write would still follow it and truncate an
  # arbitrary file, defeating the mv-based protection below entirely.
  # mktemp's O_EXCL creation is itself symlink-safe (fails rather than
  # following a pre-existing entry, planted or not), and its name is
  # unpredictable. `mv` then replaces the destination directory entry
  # itself (never dereferences an existing symlink there), closing the
  # ORIGINAL $marker-write concern regardless of what currently occupies it.
  local marker_tmp
  marker_tmp="$(mktemp "$marker.XXXXXX" 2>/dev/null)" || marker_tmp=""
  if [ -n "$marker_tmp" ] && printf '%s\n' "$n" > "$marker_tmp" 2>/dev/null && mv -f "$marker_tmp" "$marker" 2>/dev/null; then
    :
  else
    write_rc=1
    if [ -n "$marker_tmp" ]; then rm -f "$marker_tmp" 2>/dev/null || true; fi
  fi
  # ponytail: a write failure (read-only/unavailable config dir) still
  # reports the in-memory $n below rather than silently reporting "1" --
  # the count is best-effort advisory, not a correctness signal, so a
  # transient write failure degrading to "the number I would have written"
  # is preferable to hiding the SKIP escalation entirely. Flag it once here.
  [ "$write_rc" -eq 0 ] || echo "  (note: could not persist the skip counter to $marker -- next run may not know this happened)" >&2
  {
    echo "  STANDING OPERATOR ACTION: graphify pin sync has SKIPPED $n consecutive himmel-update run(s) in a row ($1)."
    echo "        This cannot clear itself while every himmel-update runs from inside a live Claude Code session --"
    echo "        each one spawns a graphify-mcp that holds the guard closed. Close every session and install by"
    echo "        hand (command above), or run himmel-update from a slot with none live (e.g. a scheduled cadence)."
  } >&2
}

_graphify_pin_skip_reset() {
  rm -f "$(_graphify_pin_skip_marker)" 2>/dev/null || true
}

# the common already-current case costs one file read after the version probe.
_graphify_skill_refresh() {
  local root marker skill_ver py pkg inst dst stage backup tool_dir skill_src refs_src _cand
  local had_skill=0 had_refs=0
  root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  dst="$root/skills/graphify"
  marker="$dst/.graphify_version"
  tool_dir="$(_graphify_uv_tool_dir)"
  py=""
  for _cand in "$tool_dir/graphifyy/Scripts/python.exe" \
               "$tool_dir/graphifyy/Scripts/python" \
               "$tool_dir/graphifyy/bin/python"; do
    [ -x "$_cand" ] && { py="$_cand"; break; }
  done
  # No uv-managed venv -> nothing to refresh (foreign installs stay untouched,
  # matching the file-wide adopt-don't-clobber contract).
  [ -n "$py" ] || return 0
  pkg="$("$py" -c 'import graphify, os; print(os.path.dirname(os.path.abspath(graphify.__file__)))' 2>/dev/null)" || pkg=""
  if [ -z "$pkg" ]; then
    echo "  WARNING: graphify skill refresh SKIPPED -- the uv-managed Python cannot resolve the installed graphify package path." >&2
    return 0
  fi
  inst="$("$py" -c 'from importlib.metadata import version; print(version("graphifyy"))' 2>/dev/null)" || inst=""
  inst="${inst%$'\r'}"
  if [ -z "$inst" ]; then
    echo "  WARNING: graphify skill refresh SKIPPED -- the uv-managed Python cannot resolve graphifyy package metadata." >&2
    return 0
  fi
  skill_ver="$(cat "$marker" 2>/dev/null || true)"
  [ "$skill_ver" = "$inst" ] && [ -f "$dst/SKILL.md" ] && [ -d "$dst/references" ] && return 0
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*|CYGWIN*)
      skill_src="$pkg/skill-windows.md"
      refs_src="$pkg/skills/windows/references"
      ;;
    *)
      skill_src="$pkg/skill.md"
      refs_src="$pkg/skills/claude/references"
      ;;
  esac
  if [ ! -f "$skill_src" ] || [ ! -d "$refs_src" ]; then
    echo "  WARNING: graphify skill refresh SKIPPED -- packaged skill layout not found under the installed package (upstream layout change?); skill stays at ${skill_ver:-absent} (package $inst). Run by hand: graphify install --platform claude" >&2
    echo "  Then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks" >&2
    return 0
  fi
  if ! mkdir -p "$dst"; then
    echo "  WARNING: graphify skill refresh failed (cannot create $dst); skill stays at ${skill_ver:-absent} (package $inst)." >&2
    return 0
  fi
  # Clear staging names used by older himmel releases, then fail closed if
  # they survived or SKILL.md is a directory (mv would nest a staged file).
  rm -rf "$dst/references.tmp" "$dst/SKILL.md.tmp" 2>/dev/null
  if [ -e "$dst/references.tmp" ] || [ -L "$dst/references.tmp" ] \
     || [ -e "$dst/SKILL.md.tmp" ] || [ -L "$dst/SKILL.md.tmp" ] \
     || [ -d "$dst/SKILL.md" ]; then
    rm -rf "$dst/references.tmp" "$dst/SKILL.md.tmp" 2>/dev/null
    echo "  WARNING: graphify skill refresh SKIPPED -- unsafe staging target under $dst could not be cleared; skill stays at ${skill_ver:-absent} (package $inst). Close sessions holding it and re-run." >&2
    return 0
  fi
  stage="$(mktemp -d "$dst.refresh.XXXXXX" 2>/dev/null)" || stage=""
  backup="$(mktemp -d "$dst.backup.XXXXXX" 2>/dev/null)" || backup=""
  if [ -z "$stage" ] || [ -z "$backup" ]; then
    [ -n "$stage" ] && rm -rf "$stage" 2>/dev/null
    [ -n "$backup" ] && rm -rf "$backup" 2>/dev/null
    echo "  WARNING: graphify skill refresh failed (cannot create unique staging paths); skill stays at ${skill_ver:-absent} (package $inst)." >&2
    return 0
  fi
  # Stage both artifacts before touching live content. Unique sibling paths keep
  # concurrent refreshes from deleting or overwriting each other's copies.
  if ! cp "$skill_src" "$stage/SKILL.md" 2>/dev/null \
     || ! cp -R "$refs_src" "$stage/references" 2>/dev/null; then
    rm -rf "$stage" "$backup" 2>/dev/null
    echo "  WARNING: graphify skill refresh failed (copy from the installed package); skill stays at ${skill_ver:-absent} (package $inst). Run by hand: graphify install --platform claude" >&2
    echo "  Then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks" >&2
    return 0
  fi
  # Move the old pair aside before landing either replacement. If any move or
  # marker write fails, remove the new pair and restore the old pair so a failed
  # refresh cannot leave mixed-version content behind.
  if [ -e "$dst/SKILL.md" ] || [ -L "$dst/SKILL.md" ]; then
    if ! mv "$dst/SKILL.md" "$backup/SKILL.md"; then
      rm -rf "$stage" "$backup" 2>/dev/null
      echo "  WARNING: graphify skill refresh partially failed during the swap; marker NOT advanced; run by hand: graphify install --platform claude" >&2
      echo "  Then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks" >&2
      return 0
    fi
    had_skill=1
  fi
  if [ -e "$dst/references" ] || [ -L "$dst/references" ]; then
    if ! mv "$dst/references" "$backup/references"; then
      [ "$had_skill" -eq 1 ] && mv "$backup/SKILL.md" "$dst/SKILL.md" 2>/dev/null
      rm -rf "$stage" "$backup" 2>/dev/null
      echo "  WARNING: graphify skill refresh SKIPPED -- the existing references/ could not be moved (a file may be locked); skill stays at ${skill_ver:-absent} (package $inst). Close sessions holding it and re-run." >&2
      return 0
    fi
    had_refs=1
  fi
  if mv "$stage/references" "$dst/references" \
     && mv "$stage/SKILL.md" "$dst/SKILL.md" \
     && printf '%s' "$inst" > "$marker"; then
    rm -rf "$stage" "$backup" 2>/dev/null
    echo "  graphify skill refreshed to $inst (was ${skill_ver:-absent}) by direct copy from the package (no installer side effects)."
  else
    rm -rf "$dst/references" "$dst/SKILL.md" 2>/dev/null
    [ "$had_refs" -eq 1 ] && mv "$backup/references" "$dst/references" 2>/dev/null
    [ "$had_skill" -eq 1 ] && mv "$backup/SKILL.md" "$dst/SKILL.md" 2>/dev/null
    rm -rf "$stage" "$backup" 2>/dev/null
    echo "  WARNING: graphify skill refresh partially failed during the swap; marker NOT advanced; run by hand: graphify install --platform claude" >&2
    echo "  Then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks" >&2
  fi
  return 0
}

# Idempotent + WARN-not-fail by contract (a best-effort himmel-update step).
graphify_update() {
  local src installed pin extras spec holders
  src="$(graphify_source)" || true
  if [ -z "$src" ]; then
    # Fresh install: graphify_install installs only the PACKAGE — without the
    # refresh call the first `himmelctl update` on a new machine would leave
    # the Claude skill absent until a SECOND update reaches the already-at-pin
    # path above (CR codex-adv, HIMMEL-1750). Refresh only on success; the
    # install's own rc is preserved either way.
    local install_rc=0
    graphify_install || install_rc=$?
    [ "$install_rc" -eq 0 ] && _graphify_skill_refresh
    return "$install_rc"
  fi
  pin="$(_graphify_version)"
  installed="$(_graphify_installed_version)"
  if [ -n "$installed" ] && [ "$installed" = "$pin" ]; then
    echo "  graphify already at pinned version $pin -- up to date."
    _graphify_kimi_import_warn
    _graphify_skill_refresh
    graphify_wsl_share_store
    _graphify_pin_skip_reset
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
    # The PACKAGE is left alone, but the SKILL must still track the installed
    # version (CR codex-adv, HIMMEL-1750): the motivating case — operator
    # manually upgraded ahead of the pin — lands exactly here, and skipping the
    # refresh kept the stale skill emitting per-run version warnings. The
    # refresh keys on the INSTALLED version, so it never downgrades anything.
    _graphify_skill_refresh
    graphify_wsl_share_store
    _graphify_pin_skip_reset
    return 0
  fi
  extras="$(_graphify_installed_extras)"
  if [ -n "$extras" ]; then
    spec="$(_graphify_pypi_name)${extras}==${pin}"
  else
    spec="$(_graphify_pypi_name)[kimi]==${pin}"
  fi
  # Every place this spec is PRINTED as a copy-paste repair command single-quotes
  # it (public-PR CR). With extras recorded it reads `graphifyy[all]==0.9.31`, and
  # zsh — the macOS default — globs the brackets: pasting the unquoted form dies
  # with "no matches found" instead of installing. The quotes are for the reader's
  # shell only; the `uv tool install` this script runs itself passes "$spec" as
  # one argv word already.

  # PRE-FLIGHT (HIMMEL-1274). `uv tool install --force` removes the old
  # distribution's entry points, THEN replaces the tool dir. On Windows a live
  # graphify-mcp holds that directory open, so the removal half-succeeds: the
  # entry points are gone, the replace fails, and the machine goes from
  # "graphify present and working" to "graphify absent and broken". Refusing to
  # start is the only fail-SAFE option — a reinstall that cannot finish is worse
  # than one never attempted.
  #
  # This is the NORMAL case on a busy workstation, not an edge case: every live
  # Claude Code session spawns a graphify-mcp, and /himmel-update is routinely
  # run from inside one. The step only ever appeared to work because the pin had
  # not moved.
  if holders="$(_graphify_mcp_holders)"; then
    case "$holders" in ''|*[!0-9]*) holders=0 ;; esac
    if [ "$holders" -gt 0 ]; then
      {
        echo "  SKIP: $holders graphify-mcp process(es) hold the uv tool dir — NOT attempting the reinstall."
        echo "        graphify stays at v${installed:-?} and KEEPS WORKING; the pin has NOT advanced to $pin."
        echo "        uv would delete the old entry points and then fail to replace the locked"
        echo "        directory, leaving graphify broken (HIMMEL-1274). Refusing is the safe outcome."
        echo "        To advance the pin: close the Claude Code sessions holding graphify-mcp"
        echo "        (each live session spawns one), then re-run. Or install by hand once clear:"
        echo "            uv tool install --force --with mcp '$spec'"
      } >&2
      # Share the WSL store like EVERY other path that leaves a working
      # uv-managed install in place and returns 0 (already-at-pin,
      # not-behind-pin, successful reinstall). Omitting it here was a real gap,
      # not a deliberate difference: this SKIP is the ROUTINE outcome on a busy
      # workstation — every live Claude Code session spawns a graphify-mcp — so
      # a WSL operator would have silently lost the store link on most updates
      # (HIMMEL-1289, public-PR CR outside-diff finding).
      graphify_wsl_share_store
      # HIMMEL-1601: the PACKAGE reinstall is refused (correctly -- see
      # HIMMEL-1274 above), but the SKILL is a completely separate,
      # non-locked target (~/.claude/skills/graphify, refreshed FROM the
      # currently-installed package, never touches the held uv tool dir) --
      # refresh it here too, closing the skill-vs-package drift this skip
      # used to leave open (the skill only advanced on the OTHER, non-skip
      # return paths above). Then escalate: this skip is routine on a busy
      # workstation and can persist indefinitely (HIMMEL-1601) -- count and
      # loudly report consecutive occurrences instead of one advisory line
      # that looks identical whether this is the 1st skip or the 400th.
      _graphify_skill_refresh
      _graphify_pin_skip_track "$holders holders"
      # rc 0: nothing failed and nothing is broken — this is a deliberate,
      # healthy skip. A nonzero here would print himmel-update's generic
      # "failed (non-fatal)" warning on top, which is the misleading wording
      # this ticket exists to remove.
      return 0
    fi
  else
    # FAIL CLOSED when the probe cannot run (HIMMEL-1293). "Could not tell"
    # is not "clear", and this arm gates a DESTRUCTIVE step: `uv tool install
    # --force` removes the old entry points BEFORE replacing the tool dir, so
    # if a holder is in fact live the host goes from "graphify works" to
    # "graphify broken". The old wording called the post-install verify a
    # "safety net", but _graphify_binary_ok only DETECTS that state — it does
    # not repair it, and by then the entry points are already gone.
    #
    # The asymmetry decides it. Proceeding wrongly costs a broken install that
    # needs every Claude Code session closed plus a manual reinstall; declining
    # wrongly costs an unadvanced pin on an install that KEEPS WORKING, with
    # both remedies printed right here. This is also the contract the rest of
    # this file already keeps: _graphify_version_lt returns "not lower" on any
    # parse failure ("never clobber on uncertainty"), and _graphify_mcp_holders
    # documents itself as a guard that "must fail CLOSED". This caller was the
    # one place that read its rc 1 as permission to proceed.
    #
    # Retrying the install on verify failure — the other candidate fix — does
    # not address this case: the reason the install failed is a holder that is
    # still live on the retry, so attempt two fails identically, after the
    # entry points are already gone.
    #
    # GRAPHIFY_UNPROBED_OK=1 is the escape hatch for a host that legitimately
    # cannot probe (no pwsh/powershell on Windows; neither pgrep nor ps on a
    # slim POSIX image). Without it, fail-closed would mean such a host never
    # updates again — the same silent permanent staleness the Windows
    # self-match bug caused (HIMMEL-1274) — so the default is safe and the
    # operator keeps an explicit, one-line way out.
    if [ "${GRAPHIFY_UNPROBED_OK:-}" = "1" ]; then
      echo "  note: cannot probe for graphify-mcp holders on this platform — proceeding anyway (GRAPHIFY_UNPROBED_OK=1). If a graphify-mcp is live this reinstall can leave graphify BROKEN; the post-install verify reports that but cannot repair it." >&2
    else
      {
        echo "  SKIP: cannot probe for graphify-mcp holders on this platform — NOT attempting the reinstall."
        echo "        graphify stays at v${installed:-?} and KEEPS WORKING; the pin has NOT advanced to $pin."
        echo "        A probe that cannot run does not mean the machine is clear. If a graphify-mcp"
        echo "        IS live, uv would delete the old entry points and then fail to replace the"
        echo "        locked directory, leaving graphify broken (HIMMEL-1274/1293)."
        echo "        To advance the pin, either close the Claude Code sessions holding graphify-mcp"
        echo "        (each live session spawns one) and install by hand:"
        echo "            uv tool install --force --with mcp '$spec'"
        echo "        or, on a host that genuinely cannot probe, re-run with the override:"
        echo "            GRAPHIFY_UNPROBED_OK=1 <this command>"
      } >&2
      # Same as the holders>0 skip: a working uv-managed install is left in
      # place and we return 0, so the WSL store link must be shared here too.
      graphify_wsl_share_store
      # HIMMEL-1601: same two follow-ups as the holders>0 skip above -- the
      # skill is a separate, non-locked target so refresh it regardless of
      # whether the package reinstall could run, and escalate the skip with
      # a persisted consecutive-run counter instead of one advisory line.
      _graphify_skill_refresh
      _graphify_pin_skip_track "unprobeable platform"
      # rc 0 for the same reason as that skip — nothing failed and nothing is
      # broken. A nonzero would draw himmel-update's generic "failed
      # (non-fatal)" warning on top of a deliberate, healthy decline.
      return 0
    fi
  fi

  echo "  graphify ${installed:-?} -> $pin (uv reinstall at pin, extras='${extras:-none}')..."
  if uv tool install --force --with mcp "$spec"; then
    # VERIFY AFTER (HIMMEL-1274): a zero exit is not proof the binary resolves.
    if ! _graphify_binary_ok; then
      {
        echo "  ERROR: uv reported success but 'graphify --version' does not run — the install is BROKEN."
        echo "         Repair once no graphify-mcp process is live:"
        echo "             uv tool install --force --with mcp '$spec'"
      } >&2
      return 1
    fi
    _graphify_kimi_import_warn
    echo "  graphify updated to $pin (source=himmel-pin)."
    _graphify_skill_refresh
    graphify_wsl_share_store
    _graphify_pin_skip_reset
    return 0
  fi

  # The install FAILED. This is a DIFFERENT event class than a SKIP (a
  # skip means "refused to even attempt"; this means "attempted, and uv
  # itself failed") -- reset the consecutive-skip streak regardless of this
  # outcome (CR follow-up, codex-1): the specific "holders/unprobeable"
  # obstacle the streak tracks was NOT what blocked this run, so counting a
  # later skip as a continuation of the same streak across an intervening
  # attempt would overstate it.
  _graphify_pin_skip_reset
  # Whether that failure was harmless depends entirely on whether the
  # binary survived — report the state instead of a blanket "non-fatal",
  # which was actively wrong in the reported case.
  if _graphify_binary_ok; then
    echo "  WARNING: graphify update to $pin failed; the existing install still RUNS (v${installed:-?}) — pin not advanced." >&2
  else
    {
      echo "  ERROR: graphify update to $pin failed AND the existing install is now BROKEN ('graphify --version' does not run)."
      echo "         uv removes the old entry points before replacing the tool dir, so a mid-way failure"
      echo "         leaves no working graphify (HIMMEL-1274)."
      echo "         Repair: close every Claude Code session (each holds a graphify-mcp), then:"
      echo "             uv tool install --force --with mcp '$spec'"
    } >&2
  fi
  return 1
}

# graphify_price_hooks [<project-dir>] -- keep the graphify PreToolUse hook-guard
# PRICED in this repo's harness configs (HIMMEL-2480). Idempotent; safe to re-run.
#
# WHY. Upstream `graphify install` writes two Claude PreToolUse entries
# (install.py::_claude_pretooluse_hooks -- matchers "Bash|Grep" and "Read|Glob",
# NO timeout, absolute exe path) plus one Codex entry (matcher "Bash",
# `graphify hook-check`), and exposes no matcher/timeout knob (only
# GRAPHIFY_HOOK_STRICT). Nothing in himmel runs that installer -- graphify_install
# above is a plain `uv tool install`, and _graphify_skill_refresh copies the skill
# DIRECTLY out of the installed package precisely to avoid it (HIMMEL-1750) -- but
# the operator IS told to run it by hand in several places (the skill-refresh
# WARNs above, docs/token-economy.md, scripts/ci/check-claude-md-budget.sh), and
# every such run re-adds the stock entries. This is the re-apply step that follows.
#
# Measured cost of the stock entries (graphify 0.9.53, 2026-09-03): ~170 ms idle
# per call, fired on Bash, Grep, Read AND Glob -- the four highest-frequency
# tools. himmel already spawns ~25 processes per Bash call, so on Bash the guard
# is noise; on Read/Glob it is the ONLY extra spawn, and with 7 concurrent
# sessions Windows process creation is the bottleneck that trips the 15 s hook
# budget (HIMMEL-2480). The nudge is a feature, so it is PRICED, not dropped:
#   - Claude: ONE entry, matcher "Grep|Glob", timeout 3, PATH-resolved command
#     that exits 0 when graphify is absent -- advisory by construction, so its
#     absence can never block a tool call.
#   - Codex: DROPPED. `graphify hook-check` is an intentional upstream NO-OP
#     (cli.py: bare `sys.exit(0)`, because Codex Desktop rejects
#     hookSpecificOutput.additionalContext on PreToolUse) -- it spawned a python
#     per Codex Bash call to do literally nothing.
#
# Best-effort by contract: a missing file or unparseable JSON WARNs and returns
# 0 -- this never aborts setup / adopt / himmel-update.
#
# node resolution (HIMMEL-2480 follow-up): a bare `command -v node` check here
# previously no-op'd this entire function -- with a soft NOTE, not a WARNING --
# on exactly the shell class it exists to serve (a pwsh-launched Git Bash,
# where node is genuinely installed but absent from THAT shell's minimal
# PATH). Route through resolve-node.sh's `resolve_node` instead (same runtime
# resolver run-node.sh uses for hook commands: nvm-windows, PATH, and other
# well-known install locations, in that order -- see its own WHY). When no
# node resolves at all, fall back to python3: already a hard dep of two other
# helpers in this file (_graphify_installed_extras, _graphify_version_lt), so
# it is reuse, not a third implementation of the same rewrite (jq would be
# that). The two engines are kept behaviorally identical -- same PRICED entry,
# same isGuard predicate, same first-match-in-place replacement, same 2-space
# indent + trailing newline, same verdict strings, and the python engine's
# json.dumps is called with ensure_ascii=False so it writes non-ASCII raw
# like JS JSON.stringify instead of \uXXXX-escaping it -- and proven byte-
# identical by scripts/lib/test-graphify-bin.sh's node-vs-python identity
# assertions (stock-shape fixture plus a non-ASCII value, both engines'
# output diffed with cmp -s) and its forced-python idempotence check. If
# NEITHER resolves, this is a loud WARNING (not the old soft NOTE), so an
# operator can never mistake a skip for a completed reprice.
# _graphify_price_hooks_warn_disagreement <engine_stdout> <settings_seen>
# <hooks_seen> <root> <native_root> -- bash-side guard for the path-
# translation silent-no-op class (HIMMEL-2480 follow-up; see the banner
# comment above graphify_price_hooks). <settings_seen>/<hooks_seen> are
# bash's OWN `[ -f ]` view of the two files, recorded BEFORE the engine ran --
# bash's path view is the one the operator actually typed, so it is the
# authority on whether a file exists. If bash saw a file but the engine's own
# verdict line for that same file says "absent", that is a path-translation
# (or permission) failure, NOT an absent file: WARN loudly so the operator
# never mistakes it for a quiet, correct "nothing to price". <engine_stdout>
# is always exactly two lines, settings then codex (graphify_price_hooks
# calls reprice() in that fixed order), so line 1 / line 2 map 1:1 to the two
# seen-flags.
_graphify_price_hooks_warn_disagreement() {
  local out="$1" settings_seen="$2" hooks_seen="$3" root="$4" native_root="$5"
  local line1 line2
  line1="$(sed -n '1p' <<< "$out")"
  line2="$(sed -n '2p' <<< "$out")"
  if [ "$settings_seen" = 1 ] && grep -qE 'absent \(nothing to price\)' <<< "$line1"; then
    echo "  WARNING: bash can see $root/.claude/settings.json but the pricing engine (given root=$native_root) reported it absent -- this looks like a path-translation failure, not a missing file." >&2
    echo "  Usual cause: MSYS_NO_PATHCONV=1 or MSYS2_ARG_CONV_EXCL set in this shell -- unset them and re-run, or verify the file directly." >&2
  fi
  if [ "$hooks_seen" = 1 ] && grep -qE 'absent \(nothing to price\)' <<< "$line2"; then
    echo "  WARNING: bash can see $root/.codex/hooks.json but the pricing engine (given root=$native_root) reported it absent -- this looks like a path-translation failure, not a missing file." >&2
    echo "  Usual cause: MSYS_NO_PATHCONV=1 or MSYS2_ARG_CONV_EXCL set in this shell -- unset them and re-run, or verify the file directly." >&2
  fi
}

graphify_price_hooks() {
  local root="${1:-}"
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 0
  fi

  # Defensive source: a caller (setup.sh/adopt.sh) may already have sourced
  # resolve-node.sh, so resolve_node can already be defined -- re-sourcing is
  # harmless. A missing resolve-node.sh here must not break this best-effort
  # function; it just falls through to the python3 fallback below.
  if ! command -v resolve_node >/dev/null 2>&1; then
    local _pgh_dir=""
    _pgh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _pgh_dir=""
    if [ -n "$_pgh_dir" ] && [ -f "$_pgh_dir/resolve-node.sh" ]; then
      # shellcheck source=scripts/lib/resolve-node.sh
      # shellcheck disable=SC1091
      . "$_pgh_dir/resolve-node.sh"
    fi
  fi
  local _node=""
  if command -v resolve_node >/dev/null 2>&1; then
    _node="$(resolve_node)" || _node=""
  fi

  # HIMMEL-2480 follow-up (path-translation silent no-op). $root is bash's
  # own POSIX/MSYS view of the path -- handed straight to a NATIVE Windows
  # node/python. MSYS normally rewrites a POSIX argv into Windows form on the
  # way into a real .exe, but that rewrite is OFF under MSYS_NO_PATHCONV=1 /
  # MSYS2_ARG_CONV_EXCL='*' (both real himmel scripts and operator shells set
  # for git operations) -- the engine then looks for the untranslated path,
  # finds nothing, and reports "absent" at rc 0: a silent no-op. Translate
  # explicitly instead of relying on that implicit rewrite: cygpath exists
  # only on MSYS/Cygwin, where the translation is needed; elsewhere (Linux/
  # macOS) $root is already native and cygpath is absent, so this is a no-op.
  local _pgh_native_root="$root"
  if command -v cygpath >/dev/null 2>&1; then
    _pgh_native_root="$(cygpath -w "$root" 2>/dev/null)" || _pgh_native_root="$root"
  fi

  # BASH -- not the engine -- is the authority on whether these files exist:
  # see _graphify_price_hooks_warn_disagreement above for why. Recorded
  # before either engine runs.
  local _pgh_settings_seen=0 _pgh_hooks_seen=0
  [ -f "$root/.claude/settings.json" ] && _pgh_settings_seen=1
  [ -f "$root/.codex/hooks.json" ] && _pgh_hooks_seen=1

  if [ -n "$_node" ]; then
    local _pgh_out _pgh_rc=0
    _pgh_out="$("$_node" - "$_pgh_native_root" <<'PRICE_JS'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

// The ONE priced Claude entry (HIMMEL-2480 operator ruling). The PATH-resolved
// command shape is deliberately the same one PR #2120 uses on these lines, so a
// later rebase there resolves by taking main.
const PRICED = {
  matcher: 'Grep|Glob',
  hooks: [
    {
      type: 'command',
      command: 'command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0',
      timeout: 3,
    },
  ],
};

// Match ONLY individual guard hooks, not the whole PreToolUse entry (HIMMEL-2480
// CR finding 1). An entry may legitimately bundle several hooks under one
// matcher, so entry-level deletion would silently drop an unrelated hook that
// happens to share an entry with a graphify guard. Upstream's own installer
// filters at entry level -- this is us deliberately being safer than upstream;
// do not "simplify" it back. The subcommand name is the discriminator that
// survives an absolute-path, quoted or bare `graphify`.
//
// Match against hook.command SPECIFICALLY, not the whole serialized hook
// object (HIMMEL-2480 follow-up, CR finding): an object-wide match lets an
// unrelated hook get deleted just because "graphify" and "hook-guard"/
// "hook-check" each happen to appear somewhere else on the hook (metadata,
// an env var, a path) while the actual command is unrelated.
// Anchored to the EXECUTABLE token, not two free-floating substrings
// (HIMMEL-2480 CR round 3, finding 1 -- third and final narrowing of this
// matcher: whole-entry -> whole-hook-object -> command field -> this). The
// regex requires "graphify" (optionally ".exe"/".EXE", optionally quoted)
// to sit at a genuine argv-token boundary (string start, whitespace, a
// quote, or a path separator right before it) and the subcommand
// (hook-guard/hook-check) to be the VERY NEXT token. That rejects a
// filename that merely CONTAINS both words -- e.g.
// "scripts/hooks/my-graphify-hook-guard-shim.sh": the "-" right after
// "graphify" is not a token boundary, so the pattern never starts a match
// there.
//
// LOAD-BEARING for idempotence -- do not "tidy" this into an anchored
// (^...$) or single-match form: our OWN priced entry is
// `command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0`,
// which contains "graphify" TWICE -- once as a `command -v` probe argument
// (not followed by hook-guard) and once after `exec` (immediately followed
// by hook-guard). The regex is deliberately unanchored to the string START
// so `.test()` can find that second occurrence anywhere in the command;
// anchoring it would make this function fail to recognize its own output
// and re-add the priced entry forever.
//
// The subcommand's trailing boundary says the subcommand must END THE
// TOKEN: the next character, if there is one, must be ASCII whitespace.
// It replaced a \b (HIMMEL-2489), which was a word boundary -- and "-" is
// a non-word char, so \b read "hook-guard-wrapper" as "hook-guard"
// plus a boundary and an operator hook for a DIFFERENT subcommand was
// silently deleted on reprice. Same for a non-ASCII suffix: the shell
// passes `hook-guard<non-ascii>` as one argument naming a different
// subcommand, so it must SURVIVE too (#2125 CR round 2).
//
// Spelled as an explicit negated ASCII class rather than the shorter
// (?!\S) or (?=\s|$). Both of those read \s, and the two engines do
// not agree on what \s IS: measured over the live patterns, each of
// those spellings diverges on exactly three inputs -- U+FEFF (JS \s
// matches, Python's does not) and U+0085 / U+001C (Python matches, JS
// does not). So `graphify hook-guard<U+FEFF>` would be a guard in node
// and not in python: one engine deleting a hook the other keeps, the
// same data-loss class this whole matcher exists to close. The ASCII
// literals agree exactly -- 0 mismatches over the same inputs. The
// neg7-bom row in test-graphify-bin.sh pins this.
//
// The LEADING boundary's character class is spelled the same way, with
// explicit ASCII whitespace (` \t\n`) rather than \s, for the identical
// cross-engine reason (#2489 follow-up, CR round 2 approved fix): a leading
// \s lets JS treat a stray U+FEFF glued onto the front of an unrelated
// command as a token boundary -- and Python treats U+0085/U+001C the same
// way -- so `<U+FEFF>graphify hook-guard search` would start a match (and
// get wrongly recognized as a guard) in one engine but not the other. BOM/
// NEL/FS are not real shell token separators, so the correct answer is NOT
// a guard in either engine. The neg8-lead-bom, neg9-lead-nel and
// neg10-lead-fs rows in test-graphify-bin.sh pin this. The MIDDLE separator
// (between the executable and the subcommand) carries the same rule for the
// same reason -- `graphify<U+FEFF>hook-guard` is one unrelated argv token,
// not two, so it must survive in both engines too (neg11-mid-bom,
// neg12-mid-nel, neg13-mid-fs).
//
// Deliberately NOT treating `;`/`&`/`|` as boundaries: missing one would
// only leave an operator's guard hook uncollapsed (a stale duplicate),
// whereas a too-wide boundary DELETES a hook. Idempotence is unaffected --
// our own priced entry has a space after the subcommand.
//
// \r is deliberately excluded from all three classes (HIMMEL-2489 panel
// finding, post-merge follow-up): a raw carriage return is NOT a shell
// token separator. `<CR>graphify hook-guard search`, `graphify<CR>hook-guard`
// and `hook-guard<CR>-wrapper` are each ONE argv token -- the shell never
// splits on a bare CR the way it does on space/tab/newline. Including \r
// in the leading or middle class would start/continue a match across a
// non-boundary and wrongly recognize an unrelated command as a guard; in
// the trailing class it would wrongly REJECT a legitimate longer
// subcommand as ending at the CR. Both are the "too-wide" direction the
// comment above explicitly forbids -- a too-wide boundary DELETES an
// unrelated operator hook on reprice. The neg14-lead-cr, neg15-mid-cr and
// neg16-trail-cr rows in test-graphify-bin.sh pin this.
const GUARD_RE = /(?:^|[ \t\n"'/\\])graphify(?:\.exe)?["']?[ \t\n]+(?:hook-guard|hook-check)(?![^ \t\n])/i;
const isGuard = (hook) => {
  const cmd = hook && typeof hook.command === 'string' ? hook.command : '';
  return GUARD_RE.test(cmd);
};

function atomicWrite(file, content) {
  // Finding 2 (HIMMEL-2480 CR round 3): resolve THROUGH any symlink before
  // writing. A dotfile manager (stow, chezmoi, a personal dotfiles repo)
  // routinely makes settings.json/hooks.json a symlink; renaming a temp
  // file straight onto that path REPLACES the symlink itself with a
  // regular file -- the link is destroyed and the real target it pointed
  // at is left stale. Resolving first and writing/renaming onto the
  // RESOLVED path keeps the symlink intact and updates what it points at
  // instead. A non-symlink file resolves to itself (no behavior change); a
  // not-yet-existing path throws ENOENT, in which case there is nothing to
  // resolve through and the original path is used, matching prior behavior.
  let target = file;
  try {
    target = fs.realpathSync(file);
  } catch {
    // Doesn't exist yet (or a dangling symlink) -- nothing to resolve.
  }
  const tmp = target + '.' + process.pid + '.tmp';
  // Finding 3 (Suggestion): best-effort mode preservation. The temp file
  // is created with default permissions (0666 & ~umask), so without this a
  // config that was mode 0600 comes back 0644 after every reprice --
  // access silently broadened on a file that can carry environment values.
  // Stat the EXISTING resolved target (before it is replaced) and apply
  // its mode to the temp file; a target that doesn't exist yet keeps
  // current (OS-default) behavior. Best-effort: a chmod failure is noted
  // on stderr but never aborts the reprice (WARN-not-fail, like the rest
  // of this function).
  let mode = null;
  try {
    mode = fs.statSync(target).mode;
  } catch {
    // Target doesn't exist yet -- nothing to preserve.
  }
  try {
    fs.writeFileSync(tmp, content);
    if (mode !== null) {
      try {
        fs.chmodSync(tmp, mode);
      } catch (e) {
        console.error('  NOTE: could not preserve file mode on ' + target + ': ' + e.message);
      }
    }
    fs.renameSync(tmp, target);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    throw e;
  }
}

// Replace IN PLACE at the position of the FIRST entry containing a guard hook,
// so an already-priced file is byte-identical on a re-run (appending instead
// would reorder the array every time). Within each entry, drop only the guard
// hooks; keep the entry (with its remaining hooks) if any survive, drop the
// entry entirely only when it becomes empty.
function reprice(file, replacement) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return 'absent (nothing to price): ' + file;
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    return 'UNPARSEABLE, left untouched: ' + file;
  }
  const pre = data && data.hooks && data.hooks.PreToolUse;
  if (!Array.isArray(pre)) return 'no hooks.PreToolUse array, left untouched: ' + file;
  const entryHasGuard = (entry) => Array.isArray(entry && entry.hooks) && entry.hooks.some(isGuard);
  const at = pre.findIndex(entryHasGuard);
  const next = [];
  for (const entry of pre) {
    if (!entryHasGuard(entry)) {
      next.push(entry);
      continue;
    }
    const remaining = entry.hooks.filter((h) => !isGuard(h));
    if (remaining.length > 0) next.push({ ...entry, hooks: remaining });
  }
  if (replacement) next.splice(at < 0 ? next.length : at, 0, replacement);
  if (JSON.stringify(next) === JSON.stringify(pre)) return 'already priced: ' + file;
  data.hooks.PreToolUse = next;
  atomicWrite(file, JSON.stringify(data, null, 2) + '\n');
  return 'repriced: ' + file;
}

for (const line of [
  reprice(path.join(root, '.claude', 'settings.json'), PRICED),
  reprice(path.join(root, '.codex', 'hooks.json'), null),
]) {
  console.log('  graphify hook pricing -- ' + line);
}
PRICE_JS
)" || _pgh_rc=$?
    printf '%s\n' "$_pgh_out"
    # A non-zero exit here (e.g. atomicWrite rethrowing on EACCES/ENOSPC, an
    # unremovable rename) must NOT reach the caller: this function is
    # best-effort by contract (see its header) and `local _pgh_out; _pgh_out=$(...)`
    # on separate lines -- unlike `local x=$(...)` -- propagates the command
    # substitution's exit status, which would abort adopt.sh/setup.sh under
    # their `set -euo pipefail`. WARN loudly instead of swallowing silently
    # (three prior silent-no-op bugs in this function already taught that
    # lesson) and still return 0.
    if [ "$_pgh_rc" -ne 0 ]; then
      echo "  WARNING: graphify hook pricing (node engine) exited $_pgh_rc for root '$root' -- pricing may be incomplete or unapplied; see output above for detail." >&2
    fi
    _graphify_price_hooks_warn_disagreement "$_pgh_out" "$_pgh_settings_seen" "$_pgh_hooks_seen" "$root" "$_pgh_native_root"
    return 0
  fi

  # No node resolvable anywhere -- fall back to python3 (behaviorally
  # identical port of the JS above; see the function-level comment for why
  # python3 and not jq).
  if command -v python3 >/dev/null 2>&1; then
    local _pgh_out _pgh_rc=0
    _pgh_out="$(python3 - "$_pgh_native_root" <<'PRICE_PY'
import json
import os
import re
import sys

root = sys.argv[1]

# The ONE priced Claude entry (HIMMEL-2480 operator ruling) -- same shape,
# same key order, as the node engine's PRICED object.
PRICED = {
    'matcher': 'Grep|Glob',
    'hooks': [
        {
            'type': 'command',
            'command': 'command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0',
            'timeout': 3,
        }
    ],
}

# Anchored to the EXECUTABLE token, not two free-floating substrings
# (HIMMEL-2480 CR round 3, finding 1 -- third and final narrowing of this
# matcher: whole-entry -> whole-hook-object -> command field -> this).
# Mirrors the node engine's GUARD_RE exactly (see its comment for the full
# rationale): "graphify" (optionally ".exe"/".EXE", optionally quoted) must
# sit at a genuine argv-token boundary (string start, whitespace, a quote,
# or a path separator right before it), with the subcommand
# (hook-guard/hook-check) as the VERY NEXT token. \x22/\x27 spell " and '
# so the character class needs no string-quoting gymnastics inside this
# raw string.
#
# LOAD-BEARING for idempotence -- our OWN priced entry is
# `command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0`,
# which contains "graphify" TWICE (a `command -v` probe argument, not
# followed by hook-guard; and the one after `exec`, which is). re.search
# (not re.match/fullmatch) finds that second occurrence anywhere in the
# string -- do not anchor this to the string start.
#
# The subcommand's trailing boundary says the subcommand must END THE
# TOKEN: the next character, if there is one, must be ASCII whitespace.
# It replaced a \b (HIMMEL-2489), which was a word boundary -- and "-" is
# a non-word char, so \b read "hook-guard-wrapper" as "hook-guard"
# plus a boundary and an operator hook for a DIFFERENT subcommand was
# silently deleted on reprice. Same for a non-ASCII suffix: the shell
# passes `hook-guard<non-ascii>` as one argument naming a different
# subcommand, so it must SURVIVE too (#2125 CR round 2).
#
# Spelled as an explicit negated ASCII class rather than the shorter
# (?!\S) or (?=\s|$). Both of those read \s, and the two engines do
# not agree on what \s IS: measured over the live patterns, each of
# those spellings diverges on exactly three inputs -- U+FEFF (JS \s
# matches, Python's does not) and U+0085 / U+001C (Python matches, JS
# does not). So `graphify hook-guard<U+FEFF>` would be a guard in node
# and not in python: one engine deleting a hook the other keeps, the
# same data-loss class this whole matcher exists to close. The ASCII
# literals agree exactly -- 0 mismatches over the same inputs. The
# neg7-bom row in test-graphify-bin.sh pins this.
#
# The LEADING boundary's character class is spelled the same way, with
# explicit ASCII whitespace (` \t\n`) rather than \s, for the identical
# cross-engine reason (see the node engine's GUARD_RE comment for the full
# rationale): a leading \s would let one engine treat a stray BOM/NEL/FS
# character glued onto the front of an unrelated command as a token
# boundary, wrongly recognizing it as a guard in one engine and not the
# other. The neg8-lead-bom, neg9-lead-nel and neg10-lead-fs rows in
# test-graphify-bin.sh pin this. The MIDDLE separator (between the
# executable and the subcommand) carries the same rule for the same reason
# -- `graphify<U+FEFF>hook-guard` is one unrelated argv token, not two, so
# it must survive in both engines too (neg11-mid-bom, neg12-mid-nel,
# neg13-mid-fs).
#
# Deliberately NOT treating `;`/`&`/`|` as boundaries: missing one would
# only leave an operator's guard hook uncollapsed (a stale duplicate),
# whereas a too-wide boundary DELETES a hook. Idempotence is unaffected --
# our own priced entry has a space after the subcommand.
#
# \r is deliberately excluded from all three classes (HIMMEL-2489 panel
# finding, post-merge follow-up): a raw carriage return is NOT a shell
# token separator. `<CR>graphify hook-guard search`, `graphify<CR>hook-guard`
# and `hook-guard<CR>-wrapper` are each ONE argv token -- the shell never
# splits on a bare CR the way it does on space/tab/newline. Including \r
# in the leading or middle class would start/continue a match across a
# non-boundary and wrongly recognize an unrelated command as a guard; in
# the trailing class it would wrongly REJECT a legitimate longer
# subcommand as ending at the CR. Both are the "too-wide" direction the
# comment above explicitly forbids -- a too-wide boundary DELETES an
# unrelated operator hook on reprice. The neg14-lead-cr, neg15-mid-cr and
# neg16-trail-cr rows in test-graphify-bin.sh pin this (py-neg14/15/16
# under the forced-python engine).
_GUARD_RE = re.compile(
    r'(?:^|[ \t\n\x22\x27/\\])graphify(?:\.exe)?[\x22\x27]?[ \t\n]+(?:hook-guard|hook-check)(?![^ \t\n])',
    re.IGNORECASE,
)


# Match against the hook's `command` field SPECIFICALLY, not the whole
# serialized hook object (HIMMEL-2480 follow-up, CR finding): an object-wide
# match lets an unrelated hook get deleted just because "graphify" and
# "hook-guard"/"hook-check" each happen to appear somewhere else on the hook
# (metadata, an env var, a path) while the actual command is unrelated.
def is_guard(hook):
    cmd = hook.get('command') if isinstance(hook, dict) else None
    if not isinstance(cmd, str):
        return False
    return bool(_GUARD_RE.search(cmd))


def entry_has_guard(entry):
    hooks = entry.get('hooks') if isinstance(entry, dict) else None
    return isinstance(hooks, list) and any(is_guard(h) for h in hooks)


def atomic_write(file_path, content):
    # Finding 2 (HIMMEL-2480 CR round 3): resolve THROUGH any symlink before
    # writing -- see the node engine's atomicWrite for the full rationale
    # (dotfile managers routinely make settings.json/hooks.json a symlink;
    # replacing it via rename destroys the link and leaves its real target
    # stale). os.path.realpath resolves a symlink to its real target and,
    # unlike Node's realpathSync, does not raise on a not-yet-existing
    # path -- it simply returns the path unchanged, which already matches
    # prior behavior (write beside the given path) for that case.
    target = os.path.realpath(file_path)
    tmp = target + '.' + str(os.getpid()) + '.tmp'
    # Finding 3 (Suggestion): best-effort mode preservation -- see the node
    # engine's atomicWrite for the full rationale. Stat the EXISTING
    # resolved target before it's replaced; a target that doesn't exist yet
    # keeps current (OS-default) behavior.
    mode = None
    try:
        mode = os.stat(target).st_mode
    except OSError:
        pass
    try:
        with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
        if mode is not None:
            try:
                os.chmod(tmp, mode)
            except OSError as e:
                print('  NOTE: could not preserve file mode on ' + target + ': ' + str(e), file=sys.stderr)
        os.replace(tmp, target)  # os.replace, not os.rename: rename fails on Windows when the destination exists.
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


# Replace IN PLACE at the position of the FIRST entry containing a guard hook,
# so an already-priced file is byte-identical on a re-run (appending instead
# would reorder the array every time) -- mirrors the node engine's reprice()
# exactly, including hook-level (not entry-level) filtering: an entry may
# bundle several hooks under one matcher, so entry-level deletion would
# silently drop an unrelated hook sharing an entry with a graphify guard.
# Upstream's own installer filters at entry level -- this is us deliberately
# being safer than upstream; do not "simplify" it back.
def reprice(file_path, replacement):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            raw = f.read()
    except OSError:
        return 'absent (nothing to price): ' + file_path
    try:
        data = json.loads(raw)
    except ValueError:
        return 'UNPARSEABLE, left untouched: ' + file_path
    hooks = data.get('hooks') if isinstance(data, dict) else None
    pre = hooks.get('PreToolUse') if isinstance(hooks, dict) else None
    if not isinstance(pre, list):
        return 'no hooks.PreToolUse array, left untouched: ' + file_path
    at = -1
    for i, e in enumerate(pre):
        if entry_has_guard(e):
            at = i
            break
    next_list = []
    for entry in pre:
        if not entry_has_guard(entry):
            next_list.append(entry)
            continue
        remaining = [h for h in entry['hooks'] if not is_guard(h)]
        if remaining:
            new_entry = dict(entry)
            new_entry['hooks'] = remaining
            next_list.append(new_entry)
        # else: entry becomes empty -> drop entirely
    if replacement is not None:
        next_list.insert(len(next_list) if at < 0 else at, replacement)
    if next_list == pre:
        return 'already priced: ' + file_path
    data['hooks']['PreToolUse'] = next_list
    # ensure_ascii=False (HIMMEL-2480 follow-up): json.dumps defaults to
    # ensure_ascii=True and \uXXXX-escapes non-ASCII, while the node
    # engine's JSON.stringify writes it raw -- on an adopter's settings.json
    # containing non-ASCII (an operator's $TARGET, not a file himmel
    # controls), that divergence made "did the content change" flip on
    # every run that alternated engines: node writes it raw, a later
    # python-engine run re-escapes it -> reports repriced even though
    # nothing meaningful changed, then flips back under node.
    atomic_write(file_path, json.dumps(data, ensure_ascii=False, indent=2, separators=(',', ': ')) + '\n')
    return 'repriced: ' + file_path


for line in (
    reprice(os.path.join(root, '.claude', 'settings.json'), PRICED),
    reprice(os.path.join(root, '.codex', 'hooks.json'), None),
):
    print('  graphify hook pricing -- ' + line)
PRICE_PY
)" || _pgh_rc=$?
    printf '%s\n' "$_pgh_out"
    # See the node engine's matching comment above: a non-zero exit here must
    # not propagate through this `set -e`-sensitive assignment shape and abort
    # a caller under `set -euo pipefail`. WARN loudly, still return 0.
    if [ "$_pgh_rc" -ne 0 ]; then
      echo "  WARNING: graphify hook pricing (python3 engine) exited $_pgh_rc for root '$root' -- pricing may be incomplete or unapplied; see output above for detail." >&2
    fi
    _graphify_price_hooks_warn_disagreement "$_pgh_out" "$_pgh_settings_seen" "$_pgh_hooks_seen" "$root" "$_pgh_native_root"
    return 0
  fi

  echo "  WARNING: graphify hook pricing SKIPPED -- neither node nor python3 could be found (checked resolve-node.sh's nvm-windows/PATH/well-known-location probes, plus PATH for python3)." >&2
  echo "  Install one, then re-apply: bash scripts/lib/graphify-bin.sh price-hooks" >&2
  return 0
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
    price-hooks) graphify_price_hooks "${2:-}" ;;
    *) echo "Usage: bash scripts/lib/graphify-bin.sh install|update|source|share-store|register-mcp [scope]|price-hooks [project-dir]" >&2; exit 2 ;;
  esac
fi
