#!/usr/bin/env bash
# user-slug.sh — resolver for the operator's user slug (HIMMEL-145).
#
# Replaces the hardcoded operator user-slug references that scripts under
# scripts/handover/, scripts/improve/, marketplace/plugins/handover/, etc.
# used to embed. Source this file and call `user_slug` to get the
# operator-specific slug used in:
#   - <state-root>/<USER_SLUG>/ handover bucket paths
#   - registry.json user field
#   - default scratch dir naming
#
# Resolution order (first hit wins):
#   1. $USER_SLUG env var (preferred — explicit operator intent).
#   2. Forge username via the forge seam (GitHub login or Bitbucket nickname),
#      slugified (the operator's identity — HIMMEL-297 home-base: the slug is the
#      forge user id, HIMMEL-326). Needs the forge CLI authed + an origin; one
#      network call, so callers capture once.
#   3. `git config user.name`, slugified (kebab-case, lowercase, non-alnum
#      stripped) — offline fallback for fresh clones without gh auth.
#   4. Refuse with a helpful error pointing at the env-template.
#
# Return codes:
#   0  printed a non-empty slug to stdout
#   2  could not resolve (env unset + git config missing/empty)
#
# Pure function: no side effects, no env mutation. Callers that need a
# stable slug should capture once and reuse:
#
#   user_slug_value=$(user_slug) || exit 2
#
# To verify resolution at script entry without consuming the value, use
# `user_slug_verify` (prints the resolved slug + source to stderr; returns
# rc=0 if resolved, rc=2 otherwise).

# The forge seam supplies source #2 (forge username) for GitHub + Bitbucket.
_USER_SLUG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=forge.sh
# shellcheck disable=SC1091
. "$_USER_SLUG_DIR/forge.sh"

# Slugify: lowercase, non-alnum -> dash, trim ends, 30-char cap.
_user_slug_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-30 \
        | sed -E 's/-+$//'
}

user_slug() {
    if [ -n "${USER_SLUG:-}" ]; then
        printf '%s' "$USER_SLUG"
        return 0
    fi
    # Forge username — the operator's identity (HIMMEL-297 home-base: the slug
    # is the forge user id; HIMMEL-326 generalizes it to GitHub OR Bitbucket).
    # One network call, gated behind USER_SLUG so anyone who sets it skips this;
    # fails through to git config when the forge is undetermined (no origin) or
    # the forge CLI is absent / unauthenticated.
    local forgelogin gslug
    if forgelogin=$(forge_user_slug 2>/dev/null); then
        if [ -n "$forgelogin" ] && [ "$forgelogin" != "null" ]; then
            gslug=$(_user_slug_slugify "$forgelogin")
            if [ -n "$gslug" ]; then
                printf '%s' "$gslug"
                return 0
            fi
        fi
    fi
    # Offline fallback: git config user.name slugified.
    local gname slug
    if gname=$(git config user.name 2>/dev/null); then
        if [ -n "$gname" ]; then
            slug=$(_user_slug_slugify "$gname")
            if [ -n "$slug" ]; then
                printf '%s' "$slug"
                return 0
            fi
        fi
    fi
    return 2
}

user_slug_verify() {
    local slug
    if slug=$(user_slug); then
        local _forge_kind
        if [ -n "${USER_SLUG:-}" ]; then
            echo "user-slug: '$slug' (source: \$USER_SLUG env)" >&2
        elif _forge_kind=$(forge_detect 2>/dev/null) && [ -n "$(forge_user_slug 2>/dev/null)" ]; then
            echo "user-slug: '$slug' (source: forge username via $_forge_kind CLI)" >&2
        else
            echo "user-slug: '$slug' (source: git config user.name, slugified)" >&2
        fi
        printf '%s' "$slug"
        return 0
    fi
    cat >&2 <<'EOF'
ERR user-slug: cannot resolve USER_SLUG.

Tried (in order):
  1. $USER_SLUG env var: unset or empty.
  2. Forge username (GitHub login / Bitbucket nickname): forge undetermined
     (no origin), forge CLI unavailable/unauthenticated, or no login.
  3. git config user.name: missing or empty.

Fix one of these:
  - Set USER_SLUG=<your-kebab-slug> in the shell that launches Claude
    (and persist to .env / your dotfiles).
  - Authenticate your forge CLI (`gh auth login`, or set BITBUCKET_* env) —
    the slug becomes your forge username.
  - Set a git identity: `git config --global user.name "Your Name"`
    (gets slugified to lowercase + dashes automatically).

See `.env.example` + docs/setup/new-machine.md for the recommended
shell setup.
EOF
    return 2
}
