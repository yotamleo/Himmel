#!/usr/bin/env bash
# check-user-slug.sh — USER_SLUG resolve-or-advise (HIMMEL-2539; template
# twin of himmel's scripts/setup/check-user-slug.sh, same disposition as
# HIMMEL-2537).
#
# Usage: bash scripts/lib/check-user-slug.sh
#
#   resolved     stdout = the bare slug, stderr = its source line, rc=0
#   unresolved   stderr = a WARN diagnostic + the consequence, rc=3
#   usage error  stderr = the usage line, rc=2
#
# HIMMEL-2539 re-verified the HIMMEL-2537 rationale against this template
# from scratch rather than assuming it transfers: no step after [2/6] in
# setup.sh (or setup.ps1) reads USER_SLUG, nothing setup writes embeds it,
# the export dies with the process, and the template's own user-slug.sh has
# no forge lookup or --dotenv-root bridge to carry over (env var + git
# config only — porting those in is explicitly out of scope). So the
# disposition stays advisory, not fatal, same as himmel's own installer.
set -uo pipefail

if [ "$#" -gt 0 ]; then
  echo "usage: check-user-slug.sh" >&2
  exit 2
fi

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=user-slug.sh
# shellcheck disable=SC1091
. "$_here/user-slug.sh"

if _slug=$(user_slug_verify WARN); then
  printf '%s' "$_slug"
  exit 0
fi

cat >&2 <<'SLUG_ADVISORY'

  Setup CONTINUES — no step below this one uses USER_SLUG.
  Consequence: until you set USER_SLUG (env or .env) or a git identity,
  tooling that derives per-operator paths (handover buckets, scratch dir
  names) cannot resolve yours. Setting either one later needs no re-run of setup.
SLUG_ADVISORY
exit 3
