#!/usr/bin/env bash
# scripts/lib/render-lease.sh -- the render lease registry (HIMMEL-1509).
#
# WHY: the static :00 launch-window rule is RETIRED. Renders and the orphan
# sweep now coordinate DYNAMICALLY through this registry: every codex
# adversarial render acquires a per-branch lease at launch, the sweep reads the
# registry before it may kill anything, and the same lease doubles as the
# same-branch launch claim (subsumes HIMMEL-1496's TOCTOU: two concurrent
# kickoffs on one branch race no further than one atomic mkdir).
#
# LAYOUT (one directory per lease, under the registry root):
#   <registry>/<branch-slug>/lease.record   KEY<TAB>VALUE lines (see below)
#   <registry>/<branch-slug>/heartbeat      ISO-8601 UTC, rewritten ~60s by
#                                           codex-render-client-lease.ps1
#   <registry>/<branch-slug>/tokens         cxc broker tokens observed for the
#                                           render's cwd (ps1-written, optional)
#   <registry>/.registry.lock/              cross-writer mutex (mkdir = lock)
#   <registry>/kill-ledger.jsonl            append-only sweep evidence ledger
#                                           (written/consumed by
#                                           sweep-codex-orphans.ps1)
# lease.record keys: branch, worktree (native/mixed path form), acquired_by
# (wrapper msys pid), started_at (ISO UTC), leader_pid (msys), leader_winpid
# (native, Windows only), leader_identity (proc_tree_process_identity string),
# status (launching|running), claim_nonce (this acquisition's identity - see
# release below).
#
# THE LOCK: mkdir is the only acquisition primitive -- never scan-then-create.
# Lease acquisition itself is one mkdir of the lease dir; the registry-level
# .registry.lock only serializes claim/reclaim against the sweep's
# read-before-kill pass. Lock owner is tagged with its pid SPACE
# ("msys:<pid>" here, "win:<pid>" from PowerShell) because the two runtimes
# cannot verify each other's pids. Stale-break disposition (HIMMEL-1509 r4):
# a same-space owner probed ALIVE is NEVER broken -- not even by age (a slow
# sweep or mid-claim launcher legitimately holds the lock; contenders wait
# out their retries and refuse); a same-space owner probed DEAD is broken
# immediately; only a cross-space or unverifiable owner falls back to the
# AGE break (RENDER_LEASE_LOCK_STALE_SECS), and each break says which
# disposition fired.
#
# FAIL-CLOSED POSTURE (every rc documented on its function):
#   * only a CONFIRMED-dead holder is reclaimed; an unverifiable holder refuses;
#   * an unusable registry refuses the launch instead of launching untracked;
#   * release happens ONLY on a verified-clean exit (the launcher calls it from
#     its cleanup-rc==0 path); every other exit leaves the lease as evidence
#     for the sweep/orchestrator to adjudicate;
#   * release removes ONLY this process's own acquisition (HIMMEL-1509 r9):
#     claim stamps a claim_nonce into the record and remembers it in-process;
#     release verifies the on-disk nonce still matches before rm - a former
#     holder whose stale lease was reclaimed can never delete a successor's
#     live lease (the lease-release sibling of the r7 lock-release rule).
#
# REQUIRES: scripts/lib/proc-tree.sh sourced first (identity primitives).
# CONVENTIONS: bash 3.2-safe (no mapfile/associative arrays), ASCII only,
# same as proc-tree.sh. No comment line may BEGIN with the linter's name.
# COVERAGE: scripts/lib/test-render-lease.sh (unit) plus
# scripts/cr/test-run-codex-adversarial.sh (launcher integration).

render_lease_registry_dir() {
    printf '%s\n' "${RENDER_LEASE_DIR:-$HOME/.claude/handover/bridge/render-leases}"
}

# render_lease_slug <branch> -- filesystem-safe INJECTIVE slug (HIMMEL-1509
# r6, codex-2). [A-Za-z0-9._-] passes through; every other BYTE becomes
# '+HH' (two uppercase hex; '/' -> +2F, '+' itself -> +2B). Because '+' can
# only ever appear as the start of a fixed-width +HH escape, the map parses
# uniquely left-to-right: distinct branches (e.g. feat/a+b vs feat/a/b) can
# NEVER share a lease dir. Byte-wise under LC_ALL=C so multibyte input
# encodes per byte and every escape stays exactly two hex digits.
# Mirrored EXACTLY by Get-RenderLeaseSlug in sweep-codex-orphans.ps1.
render_lease_slug() {
    local branch="$1" out='' ch i len
    local LC_ALL=C
    len=${#branch}
    i=0
    while [ "$i" -lt "$len" ]; do
        ch=${branch:$i:1}
        case "$ch" in
            [A-Za-z0-9._-]) out="$out$ch" ;;
            *) out=$(printf '%s+%02X' "$out" "'$ch") ;;
        esac
        i=$((i + 1))
    done
    printf '%s\n' "$out"
}

# render_lease_dir_for <branch> -- print the lease dir, or fail (rc 1, no
# output) for a branch whose slug would escape or alias the registry root.
render_lease_dir_for() {
    local slug
    slug=$(render_lease_slug "$1")
    case "$slug" in
        ''|.|..) return 1 ;;
    esac
    printf '%s/%s\n' "$(render_lease_registry_dir)" "$slug"
}

_render_lease_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _render_lease_secs <value> -- print the value when it is a positive integer,
# else 600 (HIMMEL-1509 r7: env knobs must be validated BEFORE they reach
# shell arithmetic; same fallback contract as the sweep's env resolvers).
# Shared by every env read (RENDER_LEASE_TTL_SECS, RENDER_LEASE_LOCK_STALE_SECS).
_render_lease_secs() {
    case "$1" in
        ''|*[!0-9]*) printf '600\n'; return 0 ;;
    esac
    if [ "$1" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "$1"
    else
        printf '600\n'
    fi
}

# _render_lease_delay <value> -- print the value when it is a simple
# non-negative decimal (0 and fractions are legitimate retry DELAYS, unlike
# the seconds knobs), else the 0.5 default (HIMMEL-1509 r9, codex-3: the last
# raw RENDER_LEASE_* numeric env read - garbage must never reach sleep).
_render_lease_delay() {
    case "$1" in
        ''|*[!0-9.]*|.|.*|*.|*.*.*) printf '0.5\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# _render_lease_pid_alive <pid> -- rc 0 alive, 1 confirmed dead,
# 2 unverifiable (helper missing). Never treats "cannot check" as dead.
_render_lease_pid_alive() {
    command -v proc_tree_process_alive >/dev/null 2>&1 || return 2
    if proc_tree_process_alive "$1"; then return 0; fi
    return 1
}

# render_lease_lock_acquire -- rc 0 acquired, 1 contended (held by a live or
# unverifiable owner through every retry), 2 registry unusable.
# Stale-break disposition (r4): verified-live same-space owner -> NEVER
# broken (age included); confirmed-dead same-space owner -> broken
# immediately; cross-space/unverifiable owner -> age break only.
render_lease_lock_acquire() {
    local registry lock attempt owner opid stale owner_live alive_rc mtime now stale_secs
    registry=$(render_lease_registry_dir)
    mkdir -p "$registry" 2>/dev/null || return 2
    [ -d "$registry" ] || return 2
    lock="$registry/.registry.lock"
    # r7 codex-2: validate the env knob BEFORE it reaches arithmetic - garbage
    # must fall back to the 600s default, never collapse or error the check.
    stale_secs=$(_render_lease_secs "${RENDER_LEASE_LOCK_STALE_SECS:-}")
    # Same validation contract for the retry-count knob (panel r7 codex-1):
    # garbage must fall back to the default, never error out of the loop.
    local max_attempts
    case "${RENDER_LEASE_LOCK_ATTEMPTS:-}" in
        ''|*[!0-9]*) max_attempts=10 ;;
        0) max_attempts=10 ;;
        *) max_attempts="$RENDER_LEASE_LOCK_ATTEMPTS" ;;
    esac
    # And for the retry delay (r9 codex-3): validated before it reaches sleep.
    local delay_secs
    delay_secs=$(_render_lease_delay "${RENDER_LEASE_LOCK_DELAY_SECS:-}")
    attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if mkdir "$lock" 2>/dev/null; then
            printf 'msys:%s\n' "$$" > "$lock/owner.pid" 2>/dev/null || true
            return 0
        fi
        stale=0
        owner_live=0
        owner=$(cat "$lock/owner.pid" 2>/dev/null)
        case "$owner" in
            msys:*)
                opid=${owner#msys:}
                case "$opid" in
                    ''|*[!0-9]*) ;;
                    *)
                        alive_rc=0
                        _render_lease_pid_alive "$opid" || alive_rc=$?
                        case "$alive_rc" in
                            0) owner_live=1 ;;
                            1) stale=1 ;;
                        esac
                        ;;
                esac
                ;;
        esac
        if [ "$stale" -eq 1 ]; then
            echo "render-lease: breaking registry lock held by confirmed-dead owner ($owner): $lock" >&2
        elif [ "$owner_live" -eq 0 ]; then
            # Cross-space or unverifiable owner: age is the only safe judge.
            # A verified-live owner never reaches this branch.
            mtime=$(_render_lease_mtime "$lock")
            case "$mtime" in
                ''|*[!0-9]*) ;;
                *)
                    now=$(date +%s)
                    if [ $((now - mtime)) -gt "$stale_secs" ]; then
                        stale=1
                        echo "render-lease: age-breaking registry lock with cross-space/unverifiable owner ('$owner', older than ${stale_secs}s): $lock" >&2
                    fi
                    ;;
            esac
        fi
        [ "$stale" -eq 1 ] && rm -rf "$lock" 2>/dev/null
        attempt=$((attempt + 1))
        sleep "$delay_secs"
    done
    return 1
}

# render_lease_lock_release -- remove the registry lock ONLY when its owner
# record names this process (HIMMEL-1509 r7, codex-1): a former holder whose
# lock was broken must never delete a successor's newly acquired lock. A
# mismatched or unreadable owner leaves the lock in place (the dead-owner /
# age breaks self-heal it) and says so loudly.
render_lease_lock_release() {
    local lock owner
    lock="$(render_lease_registry_dir)/.registry.lock"
    [ -e "$lock" ] || return 0
    owner=$(tr -d '[:space:]' < "$lock/owner.pid" 2>/dev/null)
    if [ "$owner" = "msys:$$" ]; then
        rm -rf "$lock" 2>/dev/null || true
        return 0
    fi
    echo "render-lease: NOT releasing registry lock: owner record '${owner:-<unreadable>}' is not this process (msys:$$) - it was re-acquired after a break; leaving it to its owner: $lock" >&2
    return 0
}

# render_lease_field <lease_dir> <key> -- print the recorded value (empty when
# absent/unreadable). Everything after the FIRST tab is the value (r7 glm-3:
# exact parity with the PS twin's Substring-after-first-tab parse, so a
# tab-bearing value can never diverge between the twins).
render_lease_field() {
    awk -F'\t' -v k="$2" '$1==k { sub(/^[^\t]*\t/, ""); print; exit }' "$1/lease.record" 2>/dev/null
}

# _render_lease_write_record <dir> <branch> <worktree> <leader_pid>
#   <leader_winpid> <leader_identity> <status> [claim_nonce] -- atomic tmp+mv
# rewrite. started_at and claim_nonce are preserved from an existing record
# when not supplied, so bind keeps both the launch time and the acquisition
# identity (r9).
_render_lease_write_record() {
    local dir="$1" branch="$2" worktree="$3" leader_pid="$4" leader_winpid="$5" leader_identity="$6" status="$7" claim_nonce="${8:-}"
    local tmpf="$dir/lease.record.tmp.$$" started_at
    started_at=$(render_lease_field "$dir" started_at)
    [ -n "$started_at" ] || started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [ -n "$claim_nonce" ] || claim_nonce=$(render_lease_field "$dir" claim_nonce)
    {
        printf 'branch\t%s\n' "$branch" &&
        printf 'worktree\t%s\n' "$worktree" &&
        printf 'acquired_by\t%s\n' "$$" &&
        printf 'started_at\t%s\n' "$started_at" &&
        printf 'leader_pid\t%s\n' "$leader_pid" &&
        printf 'leader_winpid\t%s\n' "$leader_winpid" &&
        printf 'leader_identity\t%s\n' "$leader_identity" &&
        printf 'status\t%s\n' "$status" &&
        printf 'claim_nonce\t%s\n' "$claim_nonce"
    } > "$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 1; }
    mv -f "$tmpf" "$dir/lease.record" 2>/dev/null || { rm -f "$tmpf"; return 1; }
    return 0
}

# render_lease_heartbeat_fresh <lease_dir> <ttl_secs> -- rc 0 when the lease
# still shows recent life. Uses the heartbeat file's mtime, falling back to
# lease.record's own mtime (a POSIX render never starts the ps1 heartbeat; its
# freshly-written record must still read as live). An unreadable mtime reads
# as FRESH: the caller is deciding whether it may steal the lease, and a lost
# probe must never become a reason to reclaim more eagerly.
render_lease_heartbeat_fresh() {
    local anchor="$1/heartbeat" ttl="$2" mtime now
    [ -e "$anchor" ] || anchor="$1/lease.record"
    [ -e "$anchor" ] || return 1
    mtime=$(_render_lease_mtime "$anchor")
    case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
    now=$(date +%s)
    [ $((now - mtime)) -le "$ttl" ]
}

# _render_lease_holder_state <lease_dir> -- rc 0 live, 1 stale (confirmed dead,
# reclaimable), 2 unverifiable (fail-closed: treat as held).
_render_lease_holder_state() {
    local lease_dir="$1" leader_pid leader_identity acquired_by rc
    [ -r "$lease_dir/lease.record" ] || return 2
    if render_lease_heartbeat_fresh "$lease_dir" "$(_render_lease_secs "${RENDER_LEASE_TTL_SECS:-}")"; then
        return 0
    fi
    leader_pid=$(render_lease_field "$lease_dir" leader_pid)
    leader_identity=$(render_lease_field "$lease_dir" leader_identity)
    if [ -n "$leader_pid" ] && [ -n "$leader_identity" ]; then
        rc=0
        proc_tree_process_identity_matches "$leader_pid" "$leader_identity" || rc=$?
        case "$rc" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    fi
    # Launching-status record: the wrapper pid is the only anchor.
    acquired_by=$(render_lease_field "$lease_dir" acquired_by)
    case "$acquired_by" in
        ''|*[!0-9]*) return 2 ;;
    esac
    rc=0
    _render_lease_pid_alive "$acquired_by" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# render_lease_claim <branch> <worktree> -- atomically acquire the per-branch
# launch claim. rc 0 acquired; 1 refused (live/unverifiable holder, or lock
# contention); 2 registry unusable. Only a CONFIRMED-dead holder is reclaimed
# (loudly, on stderr); everything doubtful refuses.
render_lease_claim() {
    local branch="$1" worktree="$2" lease_dir state_rc lock_rc claim_nonce
    lease_dir=$(render_lease_dir_for "$branch") || return 2
    lock_rc=0
    render_lease_lock_acquire || lock_rc=$?
    if [ "$lock_rc" -ne 0 ]; then
        [ "$lock_rc" -eq 2 ] && return 2
        return 1
    fi
    if [ -e "$lease_dir" ]; then
        state_rc=0
        _render_lease_holder_state "$lease_dir" || state_rc=$?
        if [ "$state_rc" -ne 1 ]; then
            render_lease_lock_release
            return 1
        fi
        echo "render-lease: reclaiming stale lease for branch '$branch' (holder confirmed dead): $lease_dir" >&2
        rm -rf "$lease_dir" 2>/dev/null
    fi
    if ! mkdir "$lease_dir" 2>/dev/null; then
        render_lease_lock_release
        return 2
    fi
    # r9 codex-1: this acquisition's identity. Remembered in-process so
    # release can verify the on-disk lease is STILL our claim (not identity
    # material - just a collision-resistant marker for one acquisition).
    claim_nonce="$$-$(date +%s)-$RANDOM"
    if ! _render_lease_write_record "$lease_dir" "$branch" "$worktree" "" "" "" launching "$claim_nonce"; then
        rm -rf "$lease_dir" 2>/dev/null
        render_lease_lock_release
        return 2
    fi
    _RENDER_LEASE_CLAIM_NONCE=$claim_nonce
    render_lease_lock_release
    return 0
}

# render_lease_bind <branch> <leader_pid> <leader_winpid> <leader_identity> --
# record the identity-verified leader on an already-held lease (no registry
# lock: the lease dir is single-writer by acquisition). rc 0 bound, 1 failed.
render_lease_bind() {
    local branch="$1" lease_dir worktree
    lease_dir=$(render_lease_dir_for "$branch") || return 1
    [ -d "$lease_dir" ] || return 1
    worktree=$(render_lease_field "$lease_dir" worktree)
    _render_lease_write_record "$lease_dir" "$branch" "$worktree" "$2" "$3" "$4" running
}

# render_lease_release <branch> -- drop the lease, ONLY when it is still this
# process's own acquisition (HIMMEL-1509 r9, codex-1): the on-disk claim_nonce
# must match the nonce remembered by OUR claim. A former holder whose stale
# lease was reclaimed by a successor must never delete the successor's live
# lease - mismatch (or no in-process claim, or an unreadable record) leaves
# the lease loudly. Callers still invoke this ONLY on a verified-clean exit.
render_lease_release() {
    local lease_dir disk_nonce disk_owner
    lease_dir=$(render_lease_dir_for "$1") || return 0
    [ -e "$lease_dir" ] || return 0
    disk_nonce=$(render_lease_field "$lease_dir" claim_nonce)
    if [ -n "${_RENDER_LEASE_CLAIM_NONCE:-}" ] && [ "$disk_nonce" = "$_RENDER_LEASE_CLAIM_NONCE" ]; then
        rm -rf "$lease_dir" 2>/dev/null || true
        return 0
    fi
    disk_owner=$(render_lease_field "$lease_dir" acquired_by)
    echo "render-lease: NOT releasing lease for branch '$1': on-disk claim is not this process's acquisition (reclaimed by acquired_by=${disk_owner:-<unreadable>}); leaving it to its owner: $lease_dir" >&2
    return 0
}

# render_lease_probe <branch> -- read-only pre-flight for launch sites.
# rc 0 = no live claim (absent, or holder confirmed dead so a fresh claim
# would reclaim); rc 1 = held (live or unverifiable). Never mutates.
render_lease_probe() {
    local lease_dir state_rc
    lease_dir=$(render_lease_dir_for "$1") || return 0
    [ -e "$lease_dir" ] || return 0
    state_rc=0
    _render_lease_holder_state "$lease_dir" || state_rc=$?
    [ "$state_rc" -eq 1 ] || return 1
    return 0
}
