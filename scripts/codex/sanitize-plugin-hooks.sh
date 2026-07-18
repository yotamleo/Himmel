#!/usr/bin/env bash
# sanitize-plugin-hooks.sh (HIMMEL-651)
#
# DEPRECATED (HIMMEL-1104, 2026-07-17) — upstream FIXED the bug this works around.
# codex PR #30229 ("Relax hooks.json top-level metadata validation", 2026-06-26)
# added `description` to the `HooksFile` serde struct, so a root-level
# `description` is accepted from **rust-v0.143.0** onward. Before that, HooksFile
# carried `#[serde(deny_unknown_fields)]` with no `description` field, so the key
# failed the parse and codex dropped the hooks block — the behaviour below.
# PREFER UPGRADING CODEX to >= rust-v0.143.0 over running this. It is retained
# only as a manual escape hatch for installs pinned below that version: it
# MUTATES external upstream plugin files, which is not something to do by default
# to fix a bug upstream has already fixed. Removing the automatic invocation from
# install-himmel-codex.{sh,ps1} phase 3 is tracked separately.
#
# Strip the top-level `description` key from external-plugin `hooks.json` files
# under the Codex plugin cache. Codex versions BEFORE rust-v0.143.0 reject a
# top-level `description` ("unknown field description") and skip those hooks at
# boot; from rust-v0.143.0 the key is accepted and this script is unnecessary
# (see the deprecation notice above). himmel-owned plugins don't ship that shape;
# on an affected version this clears the boot-time noise from external plugins
# (warp, hookify, ralph-loop, security-guidance, …).
#
# Idempotent + re-runnable: re-run after a `codex` plugin update re-adds the
# field. Only the `description` key is removed; the `hooks` block is preserved.
#
#   sanitize-plugin-hooks.sh            # strip in place, report
#   sanitize-plugin-hooks.sh --dry-run  # report what WOULD change, mutate nothing
#
# Env overrides: CODEX_HOME (default ~/.codex).
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

CACHE="${CODEX_HOME:-$HOME/.codex}/plugins/cache"
if [ ! -d "$CACHE" ]; then
  echo "OK: no Codex plugin cache at $CACHE (nothing to sanitize)."
  exit 0
fi

scanned=0
stripped=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  # `has("description")` -> true only when the top-level key is present. A parse
  # error (malformed JSON) exits non-zero too; those land in the elif below.
  if jq -e 'has("description")' "$f" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "WOULD STRIP : $f"
    else
      # Temp beside the target so the replace is an atomic same-filesystem
      # rename (a $TMPDIR temp could be a cross-fs, non-atomic copy).
      tmp="$(mktemp "$(dirname "$f")/.hooks.json.XXXXXX")"
      # `has("description")` already proved this file parses, so a del failure
      # here is an I/O error (disk full / unwritable), never a parse error —
      # keep jq's stderr visible and label it as a write failure.
      if jq 'del(.description)' "$f" > "$tmp"; then
        mv "$tmp" "$f"
        echo "STRIPPED    : $f"
      else
        rm -f "$tmp"
        echo "SKIP (write failed): $f" >&2
        continue
      fi
    fi
    stripped=$((stripped + 1))
  elif ! jq empty "$f" >/dev/null 2>&1; then
    # Unparseable JSON: left untouched (correct), but tell the operator so a
    # "why didn't this plugin's hooks load" hunt has a signal.
    echo "SKIP (unparseable): $f" >&2
  fi
done < <(find "$CACHE" -name hooks.json 2>/dev/null)

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY-RUN: $stripped of $scanned hooks.json would be sanitized."
elif [ "$stripped" -eq 0 ]; then
  echo "OK: nothing to sanitize ($scanned hooks.json already clean)."
else
  echo "OK: sanitized $stripped of $scanned hooks.json. Restart Codex to clear the warnings."
fi
