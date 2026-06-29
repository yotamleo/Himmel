#!/usr/bin/env bash
# scripts/luna-vitals/connectors/pull-cadence.sh
#
# ALPHA opt-in - cadence pull wrapper for the Google Health connector.
# Scheduled-pull entry point; inert until the operator arms it.
#
# Runs `bun google-health.ts pull` for a yesterday-to-today window and
# stops at the artifact file. The operator reviews the artifact and runs
# `luna-vitals write` separately. This wrapper does NOT call write.
#
# Exit codes:
#   0  - success; artifact path printed to stdout.
#   75 - re-consent needed (OAuth token expired/revoked); see stderr.
#   *  - connector error; original message already on stderr.
#
# Environment:
#   FROM                     Override pull window start (YYYY-MM-DD).
#                            Default: yesterday (UTC).
#   TO                       Override pull window end (YYYY-MM-DD).
#                            Default: today (UTC).
#   LUNA_VITALS_ARTIFACT_DIR Artifact output directory.
#                            Default: .gh-vitals/ sibling to this script.
#   PULL_CMD                 TEST SEAM: if set, passed to `bash -c` instead
#                            of the real connector. Example: PULL_CMD='exit 75'
#
# Date portability note:
#   BSD date (macOS) uses -v-1d; GNU date (Linux/Git Bash) uses
#   -d '1 day ago'. Script tries BSD first and falls back to GNU.
#   Set FROM explicitly to bypass date computation entirely.
#
# Bash 3.2-safe (macOS / Git Bash on Windows).
set -euo pipefail

RECONSENT_EXIT=75

# -- resolve paths ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
# Repo root is three levels up from scripts/luna-vitals/connectors/.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# -- date window --------------------------------------------------------------

if [ -z "${TO:-}" ]; then
    TO="$(TZ=UTC date +%Y-%m-%d)"
fi

if [ -z "${FROM:-}" ]; then
    # Try BSD date (-v-1d), fall back to GNU date (-d '1 day ago').
    FROM="$(TZ=UTC date -v-1d +%Y-%m-%d 2>/dev/null || TZ=UTC date -u -d '1 day ago' +%Y-%m-%d)"
fi

# -- artifact output ----------------------------------------------------------

artifact_dir="${LUNA_VITALS_ARTIFACT_DIR:-$SCRIPT_DIR/../.gh-vitals}"
mkdir -p "$artifact_dir"
artifact="$artifact_dir/gh-${TO}.json"

# -- run pull -----------------------------------------------------------------

# Disable errexit so we can capture the pull exit code explicitly.
set +e
if [ -n "${PULL_CMD:-}" ]; then
    # TEST-ONLY seam (eval) — must never be set in a production scheduler env.
    # PULL_CMD is evaluated in a subshell to avoid exec'ing a new binary, keeping tests fast.
    # Example: PULL_CMD='exit 75'
    ( eval "$PULL_CMD" )
else
    # cd to repo root so bun auto-loads .env from <repo>/.env (bun reads .env from CWD).
    cd "$REPO_ROOT"
    bun "$SCRIPT_DIR/google-health.ts" pull --from "$FROM" --to "$TO" --out "$artifact"
fi
pull_rc=$?
set -e

# -- handle result ------------------------------------------------------------

if [ "$pull_rc" -eq "$RECONSENT_EXIT" ]; then
    echo "[pull-cadence] re-consent needed: Google Health OAuth token has expired or was revoked." >&2
    echo "[pull-cadence] To re-auth, run auth-url then auth-exchange:" >&2
    printf '  1. bun %s/google-health.ts auth-url\n' "$SCRIPT_DIR" >&2
    printf '     (open the printed URL in a browser and grant access)\n' >&2
    printf '  2. bun %s/google-health.ts auth-exchange --code <code>\n' "$SCRIPT_DIR" >&2
    exit "$RECONSENT_EXIT"
fi

if [ "$pull_rc" -ne 0 ]; then
    echo "[pull-cadence] error: connector pull exited with code $pull_rc" >&2
    exit "$pull_rc"
fi

# -- success ------------------------------------------------------------------

echo "$artifact"
printf '[pull-cadence] review the artifact above; operator inspects it first, then land it:\n' >&2
printf '  1. bun %s/scripts/luna-vitals/cli.ts merge --det %s --out <merged.json>\n' "$REPO_ROOT" "$artifact" >&2
printf '  2. bun %s/scripts/luna-vitals/cli.ts write <merged.json> --dir <50-Vitals path>\n' "$REPO_ROOT" >&2

exit 0
