#!/usr/bin/env bash
# scripts/setup/install-cs.sh — install claude-squad (cs) on macOS or Linux.
#
# Invoked by scripts/setup.sh step 7 when the operator opts in via
# `--with-cs` or the interactive TTY prompt. Returns non-zero on failure
# so the caller can WARN and continue rather than aborting setup.
#
# Windows install lives in setup.ps1 (native winget + zip extract) — this
# script refuses on mingw to keep the install path unambiguous.
#
# License note: claude-squad is AGPL-3.0. The fork mirror at
# yotamleo/claude-squad is auto-synced daily from smtg-ai/claude-squad via
# .github/workflows/sync-upstream.yml. Linux uses the fork's install.sh
# for the source audit trail; macOS uses upstream brew (maintainer-signed).

set -e

PLATFORM="$(uname | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM" in
  mingw*|msys*|cygwin*)
    echo "install-cs.sh: Windows detected — use scripts/setup.ps1 -WithCs instead." >&2
    exit 2
    ;;
esac

# --- already installed? ---
# Verify the `cs` on PATH is actually claude-squad — common name collisions:
# Coursier (Scala) ships a `cs` binary, and operators sometimes alias `cs` to
# other tools. If the version string doesn't mention claude-squad, refuse
# rather than silently skip + leave the operator with an unrelated tool.
if command -v cs >/dev/null 2>&1; then
  cs_path="$(command -v cs)"
  if cs_ver="$(cs version 2>&1)" && echo "$cs_ver" | grep -qi 'claude.squad\|claude-squad'; then
    echo "  cs already on PATH at $cs_path — skipping install."
    echo "$cs_ver" | head -1 | sed 's/^/  /'
    exit 0
  else
    echo "ERROR: '$cs_path' is on PATH but does not look like claude-squad:" >&2
    echo "$cs_ver" | head -3 | sed 's/^/    /' >&2
    echo "  Refusing to install over an unrelated tool. Rename or remove the" >&2
    echo "  conflicting binary, or install cs manually per docs/setup/claude-squad.md." >&2
    exit 1
  fi
fi

# --- tmux check ---
if ! command -v tmux >/dev/null 2>&1; then
  echo "  tmux not found — cs requires it. Attempting install..."
  case "$PLATFORM" in
    darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install tmux
      else
        echo "ERROR: Homebrew not installed; cannot auto-install tmux." >&2
        echo "  Install Homebrew: https://brew.sh" >&2
        exit 1
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y tmux
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y tmux
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y tmux
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm tmux
      else
        echo "ERROR: no known package manager (apt/dnf/yum/pacman); install tmux manually." >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unsupported platform '$PLATFORM'; install tmux manually." >&2
      exit 1
      ;;
  esac
fi

# --- cs install ---
case "$PLATFORM" in
  darwin)
    if ! command -v brew >/dev/null 2>&1; then
      echo "ERROR: Homebrew not installed; cannot auto-install claude-squad." >&2
      echo "  Install Homebrew first: https://brew.sh" >&2
      exit 1
    fi
    brew install claude-squad
    # cs is the conventional short name — upstream README symlinks it.
    brew_prefix="$(brew --prefix)"
    if [ ! -e "$brew_prefix/bin/cs" ]; then
      ln -sf "$brew_prefix/bin/claude-squad" "$brew_prefix/bin/cs"
    fi
    ;;
  linux)
    # Pull install.sh from the himmel-owned fork (auto-synced from upstream
    # daily). Provides a single audit point if upstream is ever compromised.
    # Internal binary fetches inside install.sh still go to upstream releases
    # — fork has no published releases yet.
    #
    # CS_FORK_OWNER override: a fork of himmel run by a different operator
    # can point at their own claude-squad fork (or upstream `smtg-ai`) without
    # editing this script. Default = yotamleo per the HIMMEL-151 mirror.
    fork_owner="${CS_FORK_OWNER:-yotamleo}"
    fork_install_url="https://raw.githubusercontent.com/${fork_owner}/claude-squad/main/install.sh"
    tmp_dir="$(mktemp -d)"
    # Clean up on signals too, not just normal EXIT — a Ctrl-C / SIGTERM
    # mid-install otherwise leaks the /tmp/tmp.XXXXXX dir.
    trap 'rm -rf "$tmp_dir"' EXIT INT TERM HUP
    if ! curl -fsSL -o "$tmp_dir/install.sh" "$fork_install_url"; then
      echo "ERROR: failed to fetch install.sh from $fork_install_url" >&2
      exit 1
    fi
    # Snapshot cs resolution BEFORE install.sh so a silent no-op (install.sh
    # claims success but leaves cs unchanged) is visible. Reaching here usually
    # means cs is absent — the top-of-script check exits 0 when a real cs is
    # already present. Light signal; the verify block below is the hard gate.
    cs_before="$(command -v cs 2>/dev/null || echo '<none>')"
    # Run install.sh, streaming to the terminal (tee) AND capturing it so a
    # zero-output run can be flagged. Read install.sh's OWN exit via
    # PIPESTATUS[0] (not $? — that's tee's, and pipefail isn't set here) so a
    # real install failure isn't masked by tee succeeding; a nonzero exit still
    # aborts the script (existing set -e behavior preserved). PIPESTATUS is read
    # immediately after the pipeline so the explicit-rc check can't trip set -e.
    install_log="$tmp_dir/install.log"
    bash "$tmp_dir/install.sh" 2>&1 | tee "$install_log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
      echo "ERROR: install.sh exited $rc — aborting." >&2
      exit "$rc"
    fi
    if [ ! -s "$install_log" ]; then
      echo "  WARNING: install.sh exited 0 but produced no output — possible silent no-op." >&2
    fi
    cs_after="$(command -v cs 2>/dev/null || echo '<none>')"
    if [ "$cs_before" = "$cs_after" ]; then
      echo "  Note: 'cs' resolution unchanged by install.sh (before/after: $cs_after) — see verify below." >&2
    fi
    ;;
  *)
    echo "ERROR: unsupported platform '$PLATFORM'." >&2
    exit 1
    ;;
esac

# --- verify ---
if ! command -v cs >/dev/null 2>&1; then
  # ~/.local/bin may not be on PATH in this shell yet — check directly.
  if [ -x "$HOME/.local/bin/cs" ]; then
    echo "  cs installed at $HOME/.local/bin/cs (not yet on PATH this shell)."
    echo "  Add to PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  else
    echo "ERROR: cs install completed but 'cs' is not on PATH and not at ~/.local/bin/cs." >&2
    exit 1
  fi
else
  echo "  cs installed: $(command -v cs)"
  cs version 2>/dev/null | head -1 | sed 's/^/  /'
fi
