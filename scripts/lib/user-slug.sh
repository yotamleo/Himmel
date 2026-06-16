#!/usr/bin/env bash
# user-slug.sh — resolver for the operator's user slug (HIMMEL-145).
#
# Replaces the hardcoded `yotam` user-slug references that scripts under
# scripts/handover/, scripts/improve/, marketplace/plugins/handover/, etc.
# used to embed. Source this file and call `user_slug` to get the
# operator-specific slug used in:
#   - <state-root>/<USER_SLUG>/ handover bucket paths
#   - registry.json user field
#   - default scratch dir naming
#
# Resolution order (first hit wins):
#   1. $USER_SLUG env var (preferred — explicit operator intent).
#   2. GitHub username via `gh api user -q .login`, slugified (the operator's
#      identity — HIMMEL-297 home-base: the slug is the GitHub user id). Needs
#      gh installed + authed; one network call, so callers capture once.
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
    # GitHub username — the operator's identity (HIMMEL-297 home-base: the slug
    # is the GitHub user id). One network call, gated behind USER_SLUG so anyone
    # who sets it skips this; fails through to git config when gh is absent or
    # unauthenticated.
    local ghlogin gslug
    if command -v gh >/dev/null 2>&1; then
        ghlogin=$(gh api user -q .login 2>/dev/null) || ghlogin=""
        if [ -n "$ghlogin" ] && [ "$ghlogin" != "null" ]; then
            gslug=$(_user_slug_slugify "$ghlogin")
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
        if [ -n "${USER_SLUG:-}" ]; then
            echo "user-slug: '$slug' (source: \$USER_SLUG env)" >&2
        elif command -v gh >/dev/null 2>&1 && [ -n "$(gh api user -q .login 2>/dev/null)" ]; then
            echo "user-slug: '$slug' (source: GitHub username via gh api user)" >&2
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
  2. GitHub username (gh api user): gh unavailable, unauthenticated, or no login.
  3. git config user.name: missing or empty.

Fix one of these:
  - Set USER_SLUG=<your-kebab-slug> in the shell that launches Claude
    (and persist to .env / your dotfiles).
  - Authenticate gh: `gh auth login` (the slug becomes your GitHub username).
  - Set a git identity: `git config --global user.name "Your Name"`
    (gets slugified to lowercase + dashes automatically).

See `.env.example` + docs/setup/new-machine.md for the recommended
shell setup.
EOF
    return 2
}
