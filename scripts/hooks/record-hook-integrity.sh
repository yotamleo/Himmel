#!/usr/bin/env bash
# SessionStart hook (HIMMEL-1666, schema v2 HIMMEL-2528). Pins every
# $CLAUDE_PROJECT_DIR-relative guard script (scripts/hooks/*.sh,
# scripts/guardrails/*.sh) to its git-committed blob hash at HEAD, keyed by
# this session's session_id, in a location outside every worker's
# Edit(<worktree>) grant ($HIMMEL_HOOK_INTEGRITY_DIR, default
# ~/.claude/himmel/hook-integrity).
#
# run-hook-with-bash.js's verifyProjectHookIntegrity() compares each script's
# ON-DISK content against this pin before running it — see that file's header
# comment for the full mechanism. This hook only needs to run BEFORE any tool
# call in the session, which SessionStart guarantees; it does not need to be
# fast relative to a PreToolUse hook, and it never blocks anything itself.
#
# SCHEMA v2 (HIMMEL-2528): on top of the v1 {session_id, recorded_at, pins}
# shape, a resolvable record also carries:
#   anchor_ref — e.g. "refs/remotes/origin/main", the default branch's
#     remote-tracking ref, resolved ONCE via resolve_default_branch() below
#     (a deliberate inline copy of guardrails/lib.sh's default_branch(); see
#     that function's comment for why this hook must not source it).
#   anchor     — the commit anchor_ref pointed at when this was written.
#   git_dir    — the ABSOLUTE, canonicalized --git-common-dir. The JS
#     launcher runs `git --git-dir=<record.git_dir>` for its own checks, so a
#     rewritten worktree .git pointer file cannot redirect verification to a
#     decoy repo, and a pruned worktree still verifies.
# A record missing anchor_ref is LEGACY (the exact v1 shape) — kept as a
# single clean predicate for the launcher, and it is exactly what this hook
# always wrote before HIMMEL-2528. See "ALL-OR-NOTHING v2" and "IDEMPOTENT
# MERGE" below for when each shape is written.
#
# One further OPTIONAL key, on either shape:
#   lock_unverified — true, and present at all, only when the record was
#     published WITHOUT the per-session lock because this hook could not vouch
#     for its lock lib (see "REFUSING TO SOURCE MUST NOT MEAN REFUSING TO
#     RECORD"). It marks a record that may be the product of an unserialized
#     read-merge-publish, and it is sticky once set. A healthy record does not
#     carry the key at all.
#
# HONEST RESIDUAL (HIMMEL-2085): the pin directory is an ordinary user-
# writable path, and a dispatched worker whose envelope grants unrestricted
# Bash (Bash(node *)/Bash(bash *), WORKER_BASH_ALLOW) runs as the SAME OS user
# this hook does — nothing at the filesystem level stops
# `bash -c 'echo ... > $out_dir/$session_id.json'` from forging a pin to match
# a tampered guard. block-glm-external-writes.sh's pin-dir write-fence class
# now denies that Bash/PowerShell shape for EVERY dispatched worker lane (GLM
# or native, keyed on the general HIMMEL_WORKER marker, not just GLM), closing
# the class of attack this comment used to warn was fully open. It remains a
# command-TEXT fence, not a filesystem permission boundary: an OS-user-level
# attacker (chmod the pin file writable first, a second process, a path built
# from characters/bytes never spelled out as the pin-dir string) is still out
# of scope — see that hook's own header for the full residual. The chmod/attrib
# read-only step below stays a cheap deterrent against ACCIDENTAL overwrite on
# top of that fence, not a substitute for it.
#
# Best-effort and ADVISORY like every SessionStart hook: every early exit below
# is `exit 0` with no pin file written (or left as-is, once a record already
# exists). run-hook-with-bash.js reads a missing pin file as "cannot verify"
# and fails OPEN — see its header for why that direction is the safe rollout
# default. This hook writing nothing is a same-as-today outcome, never a new
# way to break a session. The lock (below) shares that posture: if it cannot
# be acquired, this hook exits 0 without touching the record — the JS
# launcher's own write path is the one side of this protocol that DENIES on a
# lock timeout, since it is advancing an existing pin mid-session rather than
# doing this hook's best-effort initial record.
#
# The ONE thing that fail-open posture must not be stretched to cover is
# failing to vouch for this hook's own lock lib. Exiting there would make a
# missing record — and so a session with hook verification switched off —
# something an attacker can cause on demand. That case drops the LOCK and keeps
# the RECORD; see "REFUSING TO SOURCE MUST NOT MEAN REFUSING TO RECORD".
set -uo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0
# session_id is used below to build a filesystem path ($out_dir/$session_id.json)
# and comes straight off stdin JSON with no shape guarantee from this hook's
# own contract. Restrict it to the token shape a real session id actually is
# (alnum/hyphen/underscore) before it ever reaches a path - anything else
# (a `/`, `..`, a leading `-` a later `mv`/`jq` could read as a flag) exits
# clean rather than resolving outside $out_dir or being reinterpreted as an
# option. This is a defensive floor, not a response to a specific payload
# shape Claude Code is known to send.
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# Only inside a real git worktree of this project — a fixture/temp dir with no
# .git (e.g. test-plugin-hook-bash-wiring.sh's sandbox) leaves no pin file,
# which is the fail-open case above, by design.
git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

out_dir="${HIMMEL_HOOK_INTEGRITY_DIR:-$HOME/.claude/himmel/hook-integrity}"
mkdir -p "$out_dir" 2>/dev/null || exit 0

# ---- pins (unchanged pin SOURCE: git-tree blobs at HEAD) ------------------
pins_fresh="$(
  {
    printf '{'
    first=1
    for dir in scripts/hooks scripts/guardrails; do
      [ -d "$CLAUDE_PROJECT_DIR/$dir" ] || continue
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        mode_type_sha="$(printf '%s' "$line" | cut -f1)"
        blob="$(printf '%s' "$mode_type_sha" | awk '{print $3}')"
        relpath="$(printf '%s' "$line" | cut -f2-)"
        if [ -z "$blob" ] || [ -z "$relpath" ]; then continue; fi
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '%s:%s' "$(printf '%s' "$relpath" | jq -Rs '.')" "$(printf '%s' "$blob" | jq -Rs '.')"
      done < <(git -C "$CLAUDE_PROJECT_DIR" ls-tree -r HEAD -- "$dir" 2>/dev/null | grep -E '\.sh$')
    done
    printf '}'
  }
)"
jq -e . >/dev/null 2>&1 <<<"$pins_fresh" || pins_fresh='{}'

# resolve_default_branch <dir> — the repo's default/integration branch name.
# INLINED, deliberately, from scripts/guardrails/lib.sh's default_branch()
# (same resolution order: origin/HEAD symbolic-ref → whichever of main/master
# exists locally → init.defaultBranch → "main"; keep the two in step).
#
# It is inlined rather than sourced because this hook is the thing that
# ESTABLISHES the integrity pins: sourcing a $CLAUDE_PROJECT_DIR-relative shell
# file executes arbitrary project-local code inside the recorder BEFORE any
# integrity check exists to vouch for it, so a tampered checkout would own the
# recorder that is supposed to pin it — and no bootstrap order fixes that,
# since the pin the check would need is the very thing being written. One
# self-contained function is not worth that; there is nothing else in lib.sh
# this hook needs. lib.sh's own ambiguity note (both local main and master, no
# origin/HEAD) is dropped: this hook is silent-by-design and its caller cannot
# act on stderr anyway.
resolve_default_branch() {
    local dir="$1" ref b has_main=0 has_master=0
    if ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
        b="${ref#origin/}"
        [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    fi
    if git -C "$dir" rev-parse --verify --quiet refs/heads/main   >/dev/null 2>&1; then has_main=1; fi
    if git -C "$dir" rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1; then has_master=1; fi
    if [ "$has_main" = 1 ];   then printf 'main';   return 0; fi
    if [ "$has_master" = 1 ]; then printf 'master'; return 0; fi
    b=$(git -C "$dir" config init.defaultBranch 2>/dev/null)
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    printf 'main'
}

# ---- ALL-OR-NOTHING v2 anchor resolution -----------------------------------
# anchor_ref/anchor/git_dir are resolved together; if any step fails, v2_ok
# drops to 0 and the record written below is the LEGACY shape (pins only) —
# exactly today's behaviour, so a fixture repo with no origin remote (no
# anchor_ref to resolve) still gets a valid record instead of no record at all.
v2_ok=1
anchor_ref=""
anchor=""
git_dir=""
default_branch_name="$(resolve_default_branch "$CLAUDE_PROJECT_DIR" 2>/dev/null)"
if [ -n "$default_branch_name" ]; then
    anchor_ref="refs/remotes/origin/$default_branch_name"
    anchor="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --verify --quiet "$anchor_ref" 2>/dev/null)"
fi
[ -n "$anchor" ] || v2_ok=0
if [ "$v2_ok" -eq 1 ]; then
    # Canonicalization idiom copied from guardrails/lib.sh:318-319
    # (_himmel_dev_marker_path) — --git-common-dir can print a path relative
    # to the -C dir, not to this script's cwd, so it must be resolved via a
    # cd+pwd round trip through that SAME dir, not realpath'd blind.
    common_dir_raw="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$common_dir_raw" ]; then
        git_dir="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && cd "$common_dir_raw" 2>/dev/null && pwd)"
    fi
    [ -n "$git_dir" ] || v2_ok=0
fi

# ---- lock lib: VERIFY, then source -----------------------------------------
# The lock lib is resolved relative to THIS script (mirrors
# run-hook-with-bash.js's own require('./hook-integrity.js')), and it lives in
# scripts/hooks/ — INSIDE the tree pinned above — rather than in scripts/lib/,
# which nothing pins.
#
# Being pinned is NECESSARY BUT NOT SUFFICIENT, and that is the whole point of
# the check below. verifyProjectHookIntegrity() (hook-integrity.js) verifies
# the ONE script the launcher is about to run: it derives relPath from that
# script's own path and looks up pins[relPath]. A library is never launched as
# a hook, so a pin on it would be written every session and read by nobody.
# Sourcing it unverified executes arbitrary project-local shell INSIDE the
# recorder that establishes every other pin — the same class as the
# project-local guardrails/lib.sh this hook deliberately stopped sourcing (see
# resolve_default_branch's comment). So compare the bytes on disk against the
# committed blob BEFORE the dot.
#
# The comparison anchor is $anchor_ref, deliberately NOT HEAD. pins_fresh above
# is built from `ls-tree HEAD`, so an attacker who commits a tampered lib
# locally moves HEAD with it and would be self-certifying; the remote-tracking
# default branch is the one ref a local worker cannot move. anchor_ref is
# already resolved ~30 lines above, so there is no bootstrap ordering problem
# here, and the expected blob comes from git — never from a previous session's
# record — so the first run is as protected as the hundredth.
#
# EVERY failure direction refuses to source: a MISMATCH, a missing lib, and an
# anchor that cannot be resolved at all — no origin remote, a detached or
# unfetched checkout, an adopter repo mid-clone, or a branch on which this lib
# is not yet committed at the anchor. None of them stops the RECORD being
# written; they only drop the lock. See "REFUSING TO SOURCE MUST NOT MEAN
# REFUSING TO RECORD" below for why that split is the whole point, and why
# exiting instead would be strictly worse than the hole this closes.
#
# DO NOT DELETE THIS ON HOT-PATH GROUNDS. The zero-git-spawn guarantee belongs
# to hook-integrity.js's LAUNCHER fast path, which runs on every hook
# invocation. The RECORDER is not that path: it runs once per session at
# SessionStart and already spawns git heavily (ls-tree across two directories,
# resolve_default_branch, the anchor resolution above). The two extra git calls
# here are free by comparison and cannot affect the fast-path guarantee,
# because the fast path never invokes the recorder. Removing them silently
# reopens the hole.
hooks_dir="$(cd "$(dirname "$0")" && pwd)"
lock_lib="$hooks_dir/hook-integrity-lock.sh"
lock_lib_want=""
lock_lib_have=""
if [ -n "$anchor_ref" ]; then
    lock_lib_want="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --verify --quiet \
        "$anchor_ref:scripts/hooks/hook-integrity-lock.sh" 2>/dev/null)"
fi
if [ -f "$lock_lib" ]; then
    # --no-filters, deliberately: hash the RAW bytes on disk, which are the
    # exact bytes about to be sourced. This block previously passed
    # `--path scripts/hooks/hook-integrity-lock.sh` so the hash would be
    # comparable with a blob written through an attribute-driven filter. That
    # reasoning was wrong in the one way that matters here: --path makes git
    # run whatever `filter.<name>.clean` command a .gitattributes entry selects
    # for that path, and BOTH the attributes file and the filter command are
    # repository-controlled. So the verification step itself would (a) execute
    # an attacker-chosen command inside the recorder -- precisely the code
    # execution this whole block exists to prevent -- and (b) hash the FILTERED
    # output, which a clean filter can trivially make equal the trusted blob
    # while the tampered file stays on disk and gets sourced a few lines below.
    # A bare `hash-object <file>` is no better: with no --path git still looks
    # attributes up under the file's own path.
    #
    # CONSEQUENCE, stated rather than left implicit: this compares raw disk
    # bytes against the TREE blob, which is the post-clean-filter form. They are
    # identical whenever no clean/eol filter is configured for this path -- the
    # normal case, and the only case this repo has. Where one IS configured the
    # two legitimately differ, the comparison fails, and the recorder takes the
    # degraded lock-free record path below. That is the fail-closed direction
    # and it is the intended trade: verification deliberately does not honour
    # filters, so a filtered `.sh` under scripts/hooks/ will ALWAYS take the
    # degraded path. The fix for that would be to stop filtering the file, never
    # to re-admit the filter here.
    #
    # The on-disk path is still passed as an operand because the lib may sit
    # outside $CLAUDE_PROJECT_DIR.
    lock_lib_have="$(git -C "$CLAUDE_PROJECT_DIR" hash-object \
        --no-filters -- "$lock_lib" 2>/dev/null)"
fi
lock_verified=0
if [ -n "$lock_lib_want" ] && [ "$lock_lib_want" = "$lock_lib_have" ]; then
    lock_verified=1
fi

# ---- REFUSING TO SOURCE MUST NOT MEAN REFUSING TO RECORD -------------------
# The two are separate decisions and conflating them inverts this hook's whole
# purpose. run-hook-with-bash.js fails OPEN on a missing record —
# verifyProjectHookIntegrity does `const pins = recordPins(record); if (!pins)
# return { ok: true }`, and loadIntegrityRecord returns null for a missing,
# unreadable or malformed file. So a recorder that exits without writing when
# it cannot vouch for its lock lib hands an attacker a one-step OFF SWITCH for
# the entire integrity system: make the lib's bytes differ from the anchor blob
# — no code execution needed, no pinned byte touched — and every hook in that
# session runs unverified. The same thing happens BY ACCIDENT on any branch
# where this lib is not yet committed at the anchor.
#
# So on every verify failure this hook still records; it just records WITHOUT
# THE LOCK. The pins are the security artifact; the lock is a concurrency
# optimization for the rare case of a second writer (the JS launcher advancing
# a pin mid-session) racing this one. Losing serialization can cost a lost pin
# ADVANCE, which the launcher re-derives and re-publishes under its own lock;
# losing the record costs the whole session's verification. That is not a close
# call — and a lock-free publish here is not even a new risk, it is exactly what
# this hook did unconditionally before HIMMEL-2528 added the lock.
#
# DO NOT "fix" the degraded path by inlining a bare `mkdir "$dest.lock"` in
# place of the lib: a lock dir with no owner file is refused by
# hil_lock_reclaim FOREVER (owner missing => not ours to interpret), so a
# crash between mkdir and the owner write would wedge every future session on
# that record. Publishing lock-free is the safe degradation; a half-implemented
# lock is not.
dest="$out_dir/$session_id.json"
lock_held=0
tmp=""

# One EXIT trap for both paths. It must not name hil_lock_release
# unconditionally: on the degraded path the lib was never sourced, so that
# function does not exist. `return 0` because a cleanup step's own rc must
# never leak (this runs under `set -u` with no `-e`, and the last `[` in the
# body would otherwise decide it).
#
# Reached only through the trap, so the analyzer reads the body as dead code.
# SC2317 and SC2329 are the SAME finding under two linter generations (0.10.x
# emits 2317, 0.11.x renamed it to 2329); the pre-commit gate pins 0.10.0 while
# a dev box may carry 0.11, so BOTH have to be listed or the file lints clean by
# hand and still fails the gate.
# shellcheck disable=SC2317,SC2329
cleanup() {
    [ -n "$tmp" ] && rm -f "$tmp"
    [ "$lock_held" -eq 1 ] && hil_lock_release "$dest"
    return 0
}
trap cleanup EXIT

# ---- lock (when the lib is vouched for) + read-merge-publish ---------------
if [ "$lock_verified" -eq 1 ]; then
    # shellcheck source=/dev/null
    . "$lock_lib" || exit 0
    # A lock we cannot take means ANOTHER writer holds it and is publishing
    # this same record right now. Exiting without writing is correct there and
    # is NOT the off-switch above: the record still gets written, by them.
    hil_lock_acquire "$dest" || exit 0
    lock_held=1
fi

existing_json=""
if [ -e "$dest" ]; then
    existing_json="$(jq -e '.' "$dest" 2>/dev/null)" || existing_json=""
fi
existing_shape="none"
if [ -n "$existing_json" ]; then
    existing_anchor_ref_probe="$(printf '%s' "$existing_json" | jq -r '.anchor_ref // empty' 2>/dev/null)"
    if [ -n "$existing_anchor_ref_probe" ]; then
        existing_shape="v2"
    else
        existing_shape="legacy"
    fi
fi

recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# lock_unverified marks a record that was published WITHOUT the lock because
# the lock lib could not be vouched for. Additive and OPTIONAL — it is absent
# from a healthy record, so the normal shape is byte-for-byte what it always
# was, and the JS launcher (which reads .pins/.anchor_ref/.anchor/.git_dir and
# ignores unknown keys) needs no change to tolerate it. It is STICKY across the
# merge below: once any writer has touched a record lock-free, that record may
# be the product of an unserialized read-merge-publish, and a later clean pass
# does not undo that.
if [ "$lock_verified" -eq 1 ]; then lock_unverified_json=false; else lock_unverified_json=true; fi

if [ "$existing_shape" = "v2" ]; then
    # IDEMPOTENT MERGE, never lower anything (HIMMEL-2528 §6). anchor_ref and
    # git_dir are fixed at the FIRST v2 write and never re-derived on a
    # later merge — only .anchor may advance, and only to a strict
    # descendant of what is already stored.
    existing_anchor_ref="$(printf '%s' "$existing_json" | jq -r '.anchor_ref')"
    existing_anchor="$(printf '%s' "$existing_json" | jq -r '.anchor // empty')"
    existing_git_dir="$(printf '%s' "$existing_json" | jq -r '.git_dir // empty')"

    chosen_anchor="$existing_anchor"
    if [ -n "$existing_git_dir" ]; then
        candidate_anchor="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --verify --quiet "$existing_anchor_ref" 2>/dev/null)"
        if [ -n "$candidate_anchor" ] && [ "$candidate_anchor" != "$existing_anchor" ]; then
            if git --git-dir="$existing_git_dir" merge-base --is-ancestor "$existing_anchor" "$candidate_anchor" 2>/dev/null; then
                chosen_anchor="$candidate_anchor"
            fi
        fi
    fi

    record="$(printf '%s' "$existing_json" | jq -c \
        --arg sid "$session_id" \
        --arg ts "$recorded_at" \
        --arg anchor "$chosen_anchor" \
        --argjson pf "$pins_fresh" \
        --argjson lu "$lock_unverified_json" \
        '.session_id = $sid
         | .recorded_at = $ts
         | .anchor = $anchor
         | .pins = ($pf * (.pins // {}))
         | (if ($lu or (.lock_unverified == true))
            then .lock_unverified = true else . end)')"
else
    # No existing record, an unreadable/malformed one, or a LEGACY one: this
    # REPLACES wholesale rather than merging. A merge here would trap a
    # pre-v2-deploy session in legacy-deny forever (there is nothing yet to
    # preserve); this is the bootstrap path (HIMMEL-2528 §4/§6).
    if [ "$v2_ok" -eq 1 ]; then
        record="$(jq -nc \
            --arg sid "$session_id" \
            --arg ts "$recorded_at" \
            --arg anchor_ref "$anchor_ref" \
            --arg anchor "$anchor" \
            --arg git_dir "$git_dir" \
            --argjson pins "$pins_fresh" \
            --argjson lu "$lock_unverified_json" \
            '{session_id: $sid, recorded_at: $ts, anchor_ref: $anchor_ref, anchor: $anchor, git_dir: $git_dir, pins: $pins}
             + (if $lu then {lock_unverified: true} else {} end)')"
    else
        record="$(jq -nc \
            --arg sid "$session_id" \
            --arg ts "$recorded_at" \
            --argjson pins "$pins_fresh" \
            --argjson lu "$lock_unverified_json" \
            '{session_id: $sid, recorded_at: $ts, pins: $pins}
             + (if $lu then {lock_unverified: true} else {} end)')"
    fi
fi

printf '%s' "$record" | jq -e . >/dev/null 2>&1 || exit 0

# Stage BESIDE the destination, not under $TMPDIR — mktemp under a different
# filesystem (TMPDIR can be tmpfs while $out_dir is not, or vice versa) can't
# guarantee the `mv` below is atomic; same-directory staging can.
tmp="$(mktemp "$out_dir/.hook-integrity.XXXXXX" 2>/dev/null)" || exit 0
# No second trap: the one installed above already removes $tmp once it is set,
# and it is the only one that knows whether the lock is actually held.

printf '%s\n' "$record" > "$tmp" 2>/dev/null || exit 0

# Validate before publishing: a malformed pin file must not become a permanent
# fail-open for the whole session by being read and rejected on every hook
# call — better to leave things as they are, the same outcome as never
# having run this pass.
jq -e . "$tmp" >/dev/null 2>&1 || exit 0

# chmod-before-rename: the published record is mode 0400 (below); a rename
# OVER an existing read-only file is refused on Windows, where rename target
# permissions (not just the source) gate the operation.
if [ -e "$dest" ]; then
    chmod 600 "$dest" 2>/dev/null || true
    command -v attrib >/dev/null 2>&1 && attrib -R "$dest" >/dev/null 2>&1
fi
mv -f "$tmp" "$dest" 2>/dev/null || exit 0
# Read-only best-effort (see the residual note above — deterrent, not a
# defense). chmod is the POSIX/Git-Bash path; attrib covers a native cmd.exe
# HOME on Windows where chmod may be a no-op. Failure here is not fatal — the
# pin file still exists and still protects the accidental/careless case.
chmod 400 "$dest" 2>/dev/null || true
command -v attrib >/dev/null 2>&1 && attrib +R "$dest" >/dev/null 2>&1

# Re-read what actually landed; if it is somehow not valid JSON, leave things
# as they are rather than treat a corrupt publish as success.
jq -e . "$dest" >/dev/null 2>&1 || exit 0
exit 0
