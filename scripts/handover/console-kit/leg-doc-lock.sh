#!/usr/bin/env bash
# leg-doc-lock.sh - HIMMEL-4795. Sourced, never run. One lock shared by every
# script that writes a handover doc, so a rewrite never drops a concurrent
# append:
#   append-results.sh   appends a bullet (>>)
#   headed-arm-leg.sh   rewrites the front matter (session_ids:, HIMMEL-4786)
#   inbox-send.sh --doc rewrites the doc's "## Console Rulings" section
#   live-state.sh       rewrites a console doc's `legs:` line
# A rewrite reads the doc, writes a temp file and mv's it over the doc. An
# append that lands after the read and before the mv is lost with the old
# inode, unless the appender waits for the same lock as the rewriter.
#
# The lock is `flock -x` on fd 9, held on a file keyed by the doc's canonical
# path in ${TMPDIR:-/tmp}/himmel-inbox-doc-$UID - the directory inbox-send.sh
# has used since HIMMEL-2790, so it stays one lock, and nothing lands beside
# the doc in the handover repo (a `<doc>.lock` sidecar would show as untracked
# in the vault). The Edit tool and other hand edits take no lock; a rewriter
# keeps its own re-check for those.
#
# ponytail: the key directory follows TMPDIR, so two writers with different
# TMPDIRs take different locks and the race reopens; every writer today runs
# under the same login environment. Upgrade path: key on a fixed directory
# (XDG_RUNTIME_DIR) in all four writers at once if a lane ever sets TMPDIR.
#
# Platform guard: bash 3.2+. flock is util-linux; where it is absent (macOS)
# doc_lock returns 3 and the caller writes unlocked, exactly as before
# HIMMEL-4795.

# doc_lock <doc> <caller-name>: open fd 9 on <doc>'s lock file and take an
# exclusive flock, waiting for any other writer. rc 0 locked (release with
# doc_unlock before exec'ing or running anything long); rc 3 flock is not
# installed, nothing locked; rc 1 the lock could not be taken (reason on
# stderr, prefixed with <caller-name>), nothing locked.
doc_lock() {
    local _dl_doc _dl_dir _dl_key
    # ponytail: no flock (macOS) = unlocked writes, the pre-HIMMEL-4795
    # behaviour; upgrade path: a mkdir spin lock if a macOS console ever runs legs.
    command -v flock >/dev/null 2>&1 || return 3
    # realpath -e is GNU-only; check existence, then canonicalize without it.
    [ -e "$1" ] || { printf '%s: cannot lock %s: no such file\n' "$2" "$1" >&2; return 1; }
    _dl_doc="$(realpath -- "$1")" || return 1
    _dl_dir="${TMPDIR:-/tmp}/himmel-inbox-doc-$UID"
    # shellcheck disable=SC2174 # Only the final, per-user directory is ours.
    if ! mkdir -m 700 -p "$_dl_dir" || [ -L "$_dl_dir" ] || [ ! -O "$_dl_dir" ]; then
        printf '%s: cannot secure doc lock directory\n' "$2" >&2
        return 1
    fi
    # mkdir -m only sets the mode at creation; tighten a pre-existing one.
    chmod 700 "$_dl_dir" || { printf '%s: cannot secure doc lock directory\n' "$2" >&2; return 1; }
    _dl_key="$(printf '%s' "$_dl_doc" | sha256sum)" || return 1
    _dl_key="${_dl_key%% *}"
    if ! { exec 9>"$_dl_dir/$_dl_key.lock"; } || ! flock -x 9; then
        exec 9>&-
        printf '%s: cannot lock %s\n' "$2" "$1" >&2
        return 1
    fi
    return 0
}

# doc_unlock: release the lock doc_lock took. Safe to call when none is held.
doc_unlock() {
    exec 9>&-
}

# leg_doc_add_session_id <doc> <uuid>: append <uuid> to the doc's front-matter
# `session_ids:` line (comma-separated, one per launch), adding the line when
# absent. The doc must open on `---`. rc 0 recorded, rc 1 not recorded (doc
# unchanged). Held under doc_lock, so no locked append is lost; the cksum
# re-check still refuses the mv when an unlocked writer (a hand edit) changed
# the doc meanwhile. The temp file is a mktemp beside the doc (a fixed
# `$DOC.sid.$$` name was predictable), and cp -p first gives it the doc's mode.
leg_doc_add_session_id() {
    local _ls_doc="$1" _ls_sid="$2" _ls_sum _ls_tmp="" _ls_rc=1 _ls_lock=0
    printf '%s' "$_ls_sid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
    # rc 3 (no flock) writes unlocked, as before HIMMEL-4795; rc 1 records nothing.
    doc_lock "$_ls_doc" leg-doc-lock || _ls_lock=$?
    [ "$_ls_lock" -eq 1 ] && return 1
    _ls_sum="$(cksum < "$_ls_doc" 2>/dev/null)"
    if _ls_tmp="$(mktemp "$_ls_doc.sid.XXXXXX")" \
        && cp -p "$_ls_doc" "$_ls_tmp" \
        && awk -v sid="$_ls_sid" '
            NR == 1 { print; fm = 1; next }
            fm && /^session_ids:/ { sub(/[[:space:]]*$/, ""); print $0 "," sid; done = 1; next }
            fm && /^---$/ { if (!done) print "session_ids: " sid; fm = 0 }
            { print }' "$_ls_doc" > "$_ls_tmp" \
        && grep -q "^session_ids:.*$_ls_sid" "$_ls_tmp" \
        && [ "$(cksum < "$_ls_doc" 2>/dev/null)" = "$_ls_sum" ] \
        && mv -f "$_ls_tmp" "$_ls_doc"; then
        _ls_rc=0
    fi
    [ -n "$_ls_tmp" ] && rm -f "$_ls_tmp" 2>/dev/null
    [ "$_ls_lock" -eq 0 ] && doc_unlock
    return "$_ls_rc"
}
