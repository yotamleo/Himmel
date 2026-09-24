#!/usr/bin/env bash
# go-gate.sh — shared predicates for the HIMMEL-2919 console-GO merge gate.
#
# Extracted (HIMMEL-3142) so merge-on-green.sh and block-unresolved-cr-merge.sh
# enforce the exact same rule instead of drifting. Before this, only
# merge-on-green.sh consulted `.locks/go/` — a console-spawned leg that ran
# `gh pr merge` directly never consulted it at all, so the console's GO was
# advisory on that path (PR #798 merged with no GO file anywhere).
#
# console_leg() (HIMMEL-3149) closes the outer half: the test for whether the
# caller's session IS a console-spawned leg (HIMMEL_CONSOLE_LEG truthy) was
# hand-copied at merge-on-green.sh's _truthy(), block-unresolved-cr-merge.sh's
# gate 3, and go.sh's own inline check — byte-identical today, but nothing
# kept them that way. go_gate() below is reached only once console_leg() has
# already said yes; call console_leg() first — go_gate() does not re-check it.
#
# Both functions: sourceable from hooks and scripts, `return`-only (never
# `exit`), no `set -e` toggling. bash 3.2-safe.

# console_leg — rc 0 iff HIMMEL_CONSOLE_LEG is truthy (this process IS a
# console-spawned leg, exported by headed-arm-leg.sh). Same five falsy
# spellings every call site used before HIMMEL-3149, case-insensitive,
# whitespace-stripped: empty, 0, false, off, no — anything else is truthy.
console_leg() {
    case "$(printf '%s' "${HIMMEL_CONSOLE_LEG:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

# go_gate <pr-num> <head-sha> <go-root> <nwo>
#   Pure: no gh call, no fs write — only a read under <go-root>/.locks/go/.
#   Callers resolve <pr-num>/<head-sha>, <go-root> (go_resolve_root()) and
#   <nwo> (HIMMEL-3578: owner/repo, so a GO minted for one repo's PR #N at a
#   given sha never validates for another repo's PR #N at the same sha)
#   themselves. A fresh gh query INSIDE this function would let the GO check
#   drift from the exact head the caller already certified — for
#   merge-on-green.sh that is the sha check-ci just certified and
#   --match-head-commit pins on the merge below — which is the TOCTOU this
#   gate exists to prevent, not a convenience worth adding.
#
#   rc 0 = the GO file <go-root>/.locks/go/<pr-num>.<head-sha> exists,
#          carries the line `head=<head-sha>` exactly, AND carries a
#          `mac=` line equal to go_mac <pr-num> <head-sha> <nwo> (HIMMEL-3543,
#          HIMMEL-3578) — the merge is bound, and bound by the console that
#          holds the GO key, to this exact repo.
#   rc 2 = refused; one-line reason on stdout naming the exact GO path, so the
#          leg (or the operator reading its output) can tell which condition
#          failed — no go-root, no file, a file for a different (stale) head,
#          no key to verify with, or a missing/invalid mac — never a generic
#          "not allowed".
go_gate() {
    local pr_num="$1" head_sha="$2" go_root="$3" nwo="$4"
    local go_file="${go_root:-<unresolved handover root>}/.locks/go/$pr_num.$head_sha"
    local want="" got=""
    if [ -z "$go_root" ] || ! grep -qxF "head=$head_sha" "$go_file" 2>/dev/null; then
        printf 'PR #%s at %s has no console GO (%s) — this is a console-spawned leg; send READY to your console and wait for GO; a GO for an older head is stale, never reuse it.\n' "$pr_num" "$head_sha" "$go_file"
        return 2
    fi
    if ! want=$(go_mac "$pr_num" "$head_sha" "$nwo"); then
        printf 'PR #%s at %s: cannot verify the console GO (%s) — no readable GO key at %s, or openssl is missing; send BLOCKED to your console (the console re-runs go.sh, which mints the key).\n' "$pr_num" "$head_sha" "$go_file" "$(go_key_file)"
        return 2
    fi
    got=$(sed -n 's/^mac=//p' "$go_file" 2>/dev/null | head -n 1)
    if [ -z "$got" ] || [ "$got" != "$want" ]; then
        printf 'PR #%s at %s: the GO file (%s) has no/invalid mac — not written by the console'"'"'s go.sh (or written before HIMMEL-3543); send BLOCKED to your console: the console re-runs go.sh %s %s.\n' "$pr_num" "$head_sha" "$go_file" "$pr_num" "$head_sha"
        return 2
    fi
    return 0
}

# --- HIMMEL-3543/HIMMEL-3578: GO authentication ------------------------------
# A GO used to be the mere existence of a file with a head= line, so any
# process able to write the handover root (a console-spawned leg included)
# could forge its own. go.sh now signs "himmel-go-v2|<nwo>|<pr>|<sha>" with
# HMAC-SHA256 under a key only go.sh mints (the console's zero-`!` path: it
# creates the key on first use, mode 0600); go_gate verifies the mac and never
# creates a key. The key's *.key name puts it under block-read-secrets (a
# leg's cat/Read/Grep of it is hook-denied), and it sits outside every leg's
# additionalDirectories grant.
# ponytail: same-uid ceiling — legs run as the console's Unix user, so a leg
# that deliberately evades can still (1) write a helper script that reads the
# key indirectly, (2) run go.sh under `env -u HIMMEL_CONSOLE_LEG`, (3) re-point
# the verifier with a HOME= prefix, (4) overwrite the key (no hook denies a
# Write to ~/.config/himmel/go-hmac.key), or (5) plant a key before the
# console's first GO (go.sh only tests -e, not owner or mode) — each a
# deliberate evasion the classifier sees, not an accidental two-line write,
# upgrade path: a separate-uid or OS-keyring signer (HIMMEL-3578).

# go_key_file — path of the console's GO signing key.
go_key_file() {
    printf '%s/.config/himmel/go-hmac.key\n' "${HOME:-}"
}

# go_mac <pr-num> <head-sha> <nwo> — HMAC-SHA256(key,
# "himmel-go-v2|<nwo>|<pr>|<sha>") as 64 lowercase hex on stdout. rc 1 (nothing
# printed) when HOME is unset, <nwo> is empty (HIMMEL-3578: a mac with no repo
# bound would validate against any repo — fail closed instead), the key is
# missing/unreadable/not 64 hex, or openssl is absent. The key is read with the
# `read` builtin and reaches openssl on stdin only — never argv, where any
# user's `ps` could see it. HMAC is built by hand (RFC 2104) because openssl's
# own HMAC takes its key on argv. The v1→v2 domain-tag bump means a GO minted
# before HIMMEL-3578 fails this verification by construction — it must be
# re-minted once.
go_mac() {
    local key="" kfile i b hx ipad="" opad="" inner="" nwo="$3"
    [ -n "${HOME:-}" ] || return 1
    [ -n "$nwo" ] || return 1
    kfile=$(go_key_file)
    [ -f "$kfile" ] && [ -r "$kfile" ] || return 1
    IFS= read -r key < "$kfile" || [ -n "$key" ] || return 1
    case "$key" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    [ "${#key}" -eq 64 ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    # Zero-pad the 32-byte key to SHA-256's 64-byte block, then XOR each byte
    # with the inner (0x36) and outer (0x5c) pads, as printf \x escapes.
    key="${key}$(printf '%064d' 0)"
    i=0
    while [ "$i" -lt 128 ]; do
        b=$((16#${key:$i:2}))
        printf -v hx '\\x%02x' $((b ^ 0x36)); ipad="$ipad$hx"
        printf -v hx '\\x%02x' $((b ^ 0x5c)); opad="$opad$hx"
        i=$((i + 2))
    done
    # shellcheck disable=SC2059  # the format IS the \x-escaped pad bytes
    inner=$({ printf "$ipad"; printf 'himmel-go-v2|%s|%s|%s' "$nwo" "$1" "$2"; } \
        | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
    [ "${#inner}" -eq 64 ] || return 1
    inner=$(printf '%s' "$inner" | sed 's/../\\x&/g')
    # shellcheck disable=SC2059  # as above: \x-escaped digest bytes
    inner=$({ printf "$opad"; printf "$inner"; } \
        | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
    [ "${#inner}" -eq 64 ] || return 1
    printf '%s\n' "$inner"
}

# --- HIMMEL-3572 row 1: one root for the GO writer and the gate --------------
# go.sh and merge-on-green.sh run in different processes (the console, the
# leg) whose HANDOVER_DIR can disagree: a console armed with a clean env had
# none, fell back to the harness repo's inline handovers/ stub, and wrote an
# rc=0 GO the leg's gate (reading the .env-configured root) never saw. Both
# sides resolve through go_resolve_root so an env that is empty OR names the
# harness repo's own stub yields the root the anchor's .env configures.

# _go_in_harness <path> <anchor> — rc 0 iff <path> lies inside the anchor's
# own git repository (any worktree of it): the harness's inline stub.
# HIMMEL-3570: an inherited GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE
# overrides `-C`, so a caller's env — not the path we were given — would pick
# the repo rev-parse answers about, which is exactly the GO root this
# function decides. unset scrubs each call's own subshell only, so a
# sourcing caller's env is never mutated.
_go_in_harness() {
    local a b
    a=$(
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
        git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
    ) || return 1
    b=$(
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
        git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
    ) || return 1
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# go_resolve_root <anchor> — print the GO root, rc 0; rc 2 when unresolvable.
# Requires handover_root (scripts/lib/handover-path.sh) already in scope.
#   1. a live HANDOVER_DIR outside the harness repo  → it (explicit, unchanged)
#   2. else the anchor's .env HANDOVER_DIR           → it (must be a directory;
#      a configured root that is gone fails rc 2 — never a stub fallback)
#   3. else handover_root as before (Mode A: the inline default is the root)
go_resolve_root() {
    local anchor="$1" live="${HANDOVER_DIR:-}" cfg=""
    if [ -n "$live" ] && ! _go_in_harness "$live" "$anchor"; then
        handover_root
        return
    fi
    cfg=$(
        unset HANDOVER_DIR
        # shellcheck source=scripts/lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$anchor/scripts/lib/load-dotenv.sh" >/dev/null 2>&1 || exit 0
        load_dotenv --root "$(_load_dotenv_primary_for "$anchor" 2>/dev/null)" HANDOVER_DIR >/dev/null 2>&1
        printf '%s' "${HANDOVER_DIR:-}"
    )
    if [ -n "$cfg" ]; then
        ( HANDOVER_DIR="$cfg"; handover_root )
        return
    fi
    handover_root
}
