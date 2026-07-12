#!/usr/bin/env bash
# user-slug.sh — resolver for the operator's user slug.
#
# Source this file and call `user_slug` to get the operator-specific slug
# used in handover bucket paths, registry entries, and scratch dirs.
#
# Resolution order (first hit wins):
#   1. $USER_SLUG env var (preferred — explicit operator intent).
#   2. `git config user.name`, slugified (kebab-case, lowercase, non-alnum
#      stripped). Useful for fresh-clone operators who haven't set the env
#      var yet.
#   3. Refuse with a helpful error pointing at .env.example.
#
# Return codes:
#   0  printed a non-empty slug to stdout
#   2  could not resolve (env unset + git config missing/empty)
#
# Pure function: no side effects. Capture once and reuse:
#
#   user_slug_value=$(user_slug) || exit 2
#
# `user_slug_verify` prints the resolved slug + source to stderr (rc=0)
# or the helpful error (rc=2). Use in setup.sh to fail loud at install.

user_slug() {
    if [ -n "${USER_SLUG:-}" ]; then
        printf '%s' "$USER_SLUG"
        return 0
    fi
    local gname
    if gname=$(git config user.name 2>/dev/null); then
        if [ -n "$gname" ]; then
            local slug
            slug=$(printf '%s' "$gname" \
                | tr '[:upper:]' '[:lower:]' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
                | cut -c1-30 \
                | sed -E 's/-+$//')
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
  2. git config user.name: missing or empty.

Fix one of these:
  - Set USER_SLUG=<your-kebab-slug> in the shell that launches Claude
    (and persist to .env / your dotfiles).
  - Set a git identity: `git config --global user.name "Your Name"`
    (gets slugified to lowercase + dashes automatically).

See .env.example for the recommended shell setup.
EOF
    return 2
}
