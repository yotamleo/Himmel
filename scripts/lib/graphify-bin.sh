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
_graphify_version() { printf '%s\n' "${GRAPHIFY_VERSION:-0.9.31}"; }
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

# Idempotent + WARN-not-fail by contract (a best-effort himmel-update step).
graphify_update() {
  local src installed pin extras spec holders
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
  # Every place this spec is PRINTED as a copy-paste repair command single-quotes
  # it (public-PR CR). With extras recorded it reads `graphifyy[all]==0.9.30`, and
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
    echo "  graphify updated to $pin (source=himmel-pin)."
    graphify_wsl_share_store
    return 0
  fi

  # The install FAILED. Whether that was harmless depends entirely on whether
  # the binary survived — report the state instead of a blanket "non-fatal",
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
