# shellcheck shell=bash
# scripts/lib/graphify-bin.sh
#
# Resolver for the graphify CLI (HIMMEL-891). graphify is a knowledge-graph
# tool distributed via PyPI as `graphifyy` (binary name `graphify`, upstream
# Graphify-Labs/graphify, MIT). This resolver installs it from the himmel
# fork (yotamleo/graphify, pinned to a full commit SHA; himmel-main is the
# fork's tracking branch — HIMMEL-891 plumbing; the ADOPTION VERDICT stays
# open under HIMMEL-621) via
# `uv tool install --from git+<fork>@<pinned-sha> graphifyy`. uv tool installs
# are already self-isolating (their own venv + a shim in uv's tool bin dir),
# so — unlike scripts/lib/qmd-bin.sh's bun-global junction — there is no
# separate PATH-provider step here: the shim lands in uv's tool bin dir,
# which setup.sh/adopt.sh already put on PATH for uv/pre-commit/jira.
#
# Foreign-install safety (operator requirement, 2026-07-11): before
# installing, detect whether graphify is ALREADY present — either as a
# `uv tool list` entry for graphifyy, or as any `graphify` resolved on PATH
# by another means (pip, pipx, homebrew, manual build, ...). An existing
# install is ADOPTED as-is and never reinstalled, shadowed, or duplicated.
# graphify_source() reports which case applies (see below) so callers can
# log provenance. Install-if-missing only.
#
# graphify_install() is idempotent: it re-checks graphify_source() first and
# skips cleanly whenever ANY install is already present (himmel-fork or
# foreign) — it only ever installs into a genuinely empty slot. Adopted
# installs must also RESOLVE (CR-r2): uv metadata with no working binary
# (stale receipt, missing shim, uv tool bin dir off PATH) WARNs with the
# remediation and returns nonzero — never a silent success, and never an
# auto-reinstall over existing uv metadata (that could clobber a foreign
# install's state).
#
# Fork repo/ref are overridable via GRAPHIFY_FORK_REPO / GRAPHIFY_FORK_REF
# for testing or a private mirror (mirrors QMD_FORK_REPO/QMD_FORK_BRANCH).

# Fork config -- overridable per call (env var set before sourcing/calling).
#
# PIN (HIMMEL-891 CR-1/CR-r3): the install ref is a FULL COMMIT SHA on the
# fork -- not the himmel-main branch, and not a tag either. A mutable branch
# (or a force-moved tag: tags are NOT immutable) is a supply-chain trust
# boundary on new-machine bootstrap: anyone who can move the ref moves what
# every future `setup.sh --with-graphify` installs, silently. The commit SHA
# is the only content-addressed, unmovable ref -- and unlike the marketplace
# installer (tag/branch names only, hence claude-obsidian's tag pin),
# `uv tool install --from git+...` resolves commit revs, so the stricter pin
# is available here. The fork tag v0.9.13-himmel.1 points at this same
# commit as human-readable release provenance. himmel-main stays the fork's
# TRACKING branch (where upstream merges land); a pin bump is a reviewed
# change to this file.
_graphify_fork_repo() { printf '%s\n' "${GRAPHIFY_FORK_REPO:-https://github.com/yotamleo/graphify}"; }
# = v0.9.13-himmel.1
_graphify_fork_ref() { printf '%s\n' "${GRAPHIFY_FORK_REF:-df74ab44817d3b7f8ecafb333ec99899fe634f9d}"; }
_graphify_pinned_source() { printf 'git+%s@%s\n' "$(_graphify_fork_repo)" "$(_graphify_fork_ref)"; }
_graphify_pypi_name() { printf '%s\n' "graphifyy"; }
_graphify_bin_name() { printf '%s\n' "graphify"; }

# Prints the manual install recipe (best-effort documentation text embedded
# in WARN messages -- NOT eval'd elsewhere; graphify_install() below runs the
# equivalent command directly).
graphify_install_hint() {
  printf '%s\n' "uv tool install --from $(_graphify_pinned_source) $(_graphify_pypi_name)"
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

# Reports the provenance of an existing graphify install:
#   "himmel-fork"  -- installed via uv from THIS fork at THIS pinned ref
#   "foreign"      -- installed some other way (uv from elsewhere, uv from
#                     the same repo at a DIFFERENT ref, pip, pipx, homebrew,
#                     manual build, ...)
#   ""             -- not installed at all (rc 1)
# himmel-fork requires the receipt to carry BOTH the fork repo URL AND the
# pinned ref, each matched as a FIXED string (grep -qF -- no regex surprises
# from dots in URLs/versions, and a same-repo-different-ref install
# classifies as foreign, CR-2). Two separate fixed-string probes rather than
# one `git+<url>@<ref>` match because uv serializes git sources into the
# receipt as separate keys (git = "<url>", rev = "<ref>") -- the combined
# literal never appears there. The receipt check is best-effort (a missing/
# unreadable receipt for a uv-managed graphifyy install is treated as
# foreign, never as "not installed" -- the package IS present, we just
# can't prove the source).
graphify_source() {
  local tool_dir receipt
  if _graphify_uv_has_package; then
    tool_dir="$(_graphify_uv_tool_dir)"
    receipt="$tool_dir/$(_graphify_pypi_name)/uv-receipt.toml"
    if [ -f "$receipt" ] \
       && grep -qF "$(_graphify_fork_repo)" "$receipt" 2>/dev/null \
       && grep -qF "$(_graphify_fork_ref)" "$receipt" 2>/dev/null; then
      printf '%s\n' "himmel-fork"
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

# Install graphify from the himmel fork via `uv tool install`, UNLESS an
# install is already present (adopt it instead -- see graphify_source()
# above). Returns an honest rc: 0 when graphify ends up resolvable one way
# or another (adopted or freshly installed), nonzero on a genuine failure.
# WARN-not-fail by contract -- callers (setup.sh/adopt.sh + pwsh mirrors)
# decide whether a graphify failure aborts; this function only reports.
graphify_install() {
  local src

  # graphify_source returns rc 1 on "not installed" -- harmless here (empty
  # src falls through to the install path), but guard it so a caller running
  # under `set -e` without an || context can never abort on the probe (CR-6).
  src="$(graphify_source)" || true
  case "$src" in
    himmel-fork|foreign)
      if has_graphify; then
        if [ "$src" = "himmel-fork" ]; then
          echo "  graphify already installed (source=himmel-fork) -- skipping install."
        else
          echo "  graphify already installed (source=foreign) -- adopting the existing install, not installing over it."
        fi
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
  if ! uv tool install --from "$(_graphify_pinned_source)" "$(_graphify_pypi_name)"; then
    echo "  ERROR: graphify install failed." >&2
    return 1
  fi

  if has_graphify; then
    echo "  graphify installed and verified (source=himmel-fork)."
    return 0
  fi
  echo "  WARNING: graphify installed but '$(_graphify_bin_name)' is still not resolvable on PATH." >&2
  echo "  uv drops its shims in the uv tool bin dir -- check it is on PATH (uv tool update-shell)." >&2
  return 1
}

# CLI entry -- only when EXECUTED (not sourced). Lets the pwsh mirrors
# (scripts/setup.ps1, scripts/adopt.ps1) delegate to this ONE implementation
# (`bash scripts/lib/graphify-bin.sh install`) instead of duplicating the
# detect/install recipe natively (mirrors qmd-bin.sh's CLI entry, HIMMEL-877).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    install) graphify_install ;;
    source)  graphify_source ;;
    *) echo "Usage: bash scripts/lib/graphify-bin.sh install|source" >&2; exit 2 ;;
  esac
fi
