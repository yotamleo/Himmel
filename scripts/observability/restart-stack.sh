#!/usr/bin/env bash
# scripts/observability/restart-stack.sh — sanctioned restart helper for the
# himmel-observability-* scheduled tasks (HIMMEL-2133).
#
# WHY: schtasks /end and /run are (correctly) denied by block-destructive-
# commands.sh when they appear in the AGENT's own Bash tool call — every
# exporter/Grafana restart was a manual operator step. On 2026-08-26 that cost
# four operator round-trips for one alert-tuning change: (1) a flow-exporter
# restart to load config edits, (2) the relaunch died rc=1 on a port-still-
# held race (/end does not wait for socket release before /run), (3+4) TWO
# Grafana restarts because Grafana only reads its machine-local provisioning
# copy (%LOCALAPPDATA%/himmel/observability/grafana-provisioning), which
# install-stack.ps1 copies at INSTALL time only — a merged repo policy change
# silently does not load until someone re-syncs that copy.
#
# SANCTIONED CARVE-OUT (same posture as scripts/handover/merge-on-green.sh vs
# the merge-block classifier): block-destructive-commands.sh's schtasks-
# mutation deny inspects the AGENT'S OWN Bash command text — the outer
# `bash scripts/observability/restart-stack.sh <target>` invocation, which
# never contains the word "schtasks". It does NOT (and structurally cannot)
# inspect what a script it is asked to run does internally. This script IS
# the narrow, self-gating path that capability is authorized through — it
# refuses everything outside its own hard-coded task family (below), so it
# can never become a generic schtasks wrapper.
#
# ABSOLUTE-PATH RULE ONLY — deliberate divergence from HIMMEL-2131 (CR
# round-1, codex-1, Critical): a standing allow-rule is bound to a literal
# COMMAND-TEXT prefix and authorizes whatever script FILE actually sits at
# that path at invocation time, not a specific vetted script's content. A
# RELATIVE-path rule (`Bash(bash scripts/observability/restart-stack.sh:*)`)
# invoked with cwd inside a worktree runs THAT WORKTREE's own copy of this
# file — worktrees are agent-writable (only the primary checkout is
# block-edit-on-main-protected) — so an agent could edit its own worktree
# copy (loosen the allowlist, skip the health check, whatever it likes) and
# the standing rule would still wave it through into real schtasks
# mutations. The operator's follow-up is therefore the ABSOLUTE-path rule to
# the PRIMARY checkout ONLY — `Bash(bash
# <repo-root>/scripts/observability/restart-stack.sh:*)`
# — never the relative twin HIMMEL-2131 otherwise recommends adding
# alongside it. The primary checkout is what block-edit-on-main protects and
# what PR + CR review gates every change to. The branch guard right after
# SCRIPT_DIR below is the redundant, in-script half of this same boundary.
#
# HARD ALLOWLIST: only the four himmel-observability-* tasks registered by
# install-stack.ps1 (flow-exporter, grafana, prometheus, windows-exporter, or
# "all" of them) are reachable. Any other name is refused outright — this
# script must never grow into "restart any scheduled task".
#
# SEQUENCE per target:
#   1. grafana only: WHOLESALE-replace the machine-local grafana-provisioning
#      copy from scripts/observability/provisioning/ FIRST — this directory
#      is fully repo-derived (install-stack.ps1 populates it from the repo
#      alone), so a file DELETED from the repo tree must not linger in the
#      machine copy and stay active. Staged as copy-verify-swap, not an
#      in-place delete-then-recreate (HIMMEL-2133 CR round-2, codex-2): build
#      the fresh tree next to the target, verify it, THEN swap it in — so a
#      failure at any point before the swap leaves the live copy untouched.
#   2. schtasks //End the task, then WAIT (bounded ~30s poll) for its port to
#      actually stop listening before //Run-ing it again — closes the rc=1
#      port-held race described above.
#   3. VERIFY THE ARTIFACT, NOT THE RC: poll the task's health endpoint
#      (bounded ~60s) rather than trusting a zero schtasks exit code. On
#      failure, print the task's Last Result via schtasks //Query and exit
#      non-zero.
#   4. grafana only: health-alive is NOT config-loaded (HIMMEL-2133 CR
#      round-6, codex-2 — this is the ticket's FOUNDING failure mode: Grafana
#      can answer /api/health 200 while its provisioning was silently
#      REJECTED at startup). After a healthy /api/health, scan the newest
#      file in %LOCALAPPDATA%/himmel/observability/grafana-logs/ for a
#      provisioning error line written since this restart; a hit prints the
#      line(s) and exits a DISTINCT code (4) rather than reporting success.
#      A missing/unreadable log dir only WARNS (cannot verify) — it never
#      fails the restart, since the health check itself already passed.
#
# MSYS DOUBLE-SLASH: every schtasks switch below is written with a doubled
# leading slash ("//End", "//TN", ...), never a single one ("/End", "/TN").
# Git Bash's MSYS runtime auto-converts a single-leading-slash argument that
# LOOKS like a POSIX path into a Windows path before schtasks.exe ever sees
# it (the same class of trap as `pwsh -File` argument mangling) — a bare
# `schtasks /end /tn "..."` silently breaks under this exact invocation shape
# (`bash scripts/observability/restart-stack.sh ...`, always MSYS). The
# doubled form passes each switch through unmangled; this is not merely the
# hook-evasion shape (see SANCTIONED CARVE-OUT above), it is required for the
# command to work at all here.
#
# ABSOLUTE SCHTASKS PATH (HIMMEL-2133 CR round-3, codex-1): every call below
# uses $SCHTASKS_BIN — resolved ONCE near the top to schtasks.exe's absolute
# path, never bare `schtasks` off PATH. Closes the caller-PATH-wrapper class
# outright: a caller that puts a malicious "schtasks" earlier on PATH before
# invoking this script cannot intercept these calls. Belt, not the only
# layer — an env-prefixed invocation shape (`PATH=/evil:$PATH bash
# scripts/observability/restart-stack.sh ...`) already fails the standing
# allow-rule's literal command-text prefix match, and is separately caught by
# the block-chokepoint-env-prefix.sh hook. The hermetic suite sed-replaces
# the one $SCHTASKS_BIN assignment line in its own script COPY to point at
# its PATH-stub schtasks — production never falls back to PATH resolution.
#
# Usage: restart-stack.sh <flow-exporter|grafana|prometheus|windows-exporter|all>
#
# NO ENV-SELECTED EXECUTABLES (HIMMEL-2133 CR round-2, codex-1, Critical): this
# script calls only bare `schtasks`, `curl`, `sleep`, `git`, `cp`, `mv`, `rm`,
# `mkdir`, `promtool`, `cmp`, `date` (HIMMEL-2149 added the last three) —
# resolved off PATH, never an environment variable naming a program to run.
# `promtool` is not a plain PATH lookup like the others, though: its PRIMARY
# resolution is the himmel-observability-prometheus scheduled task's own
# registered Execute path, read via the already-pinned $SCHTASKS_BIN (machine
# state, same posture as that constant itself) — bare PATH is only its
# degrade-path fallback. See resolve_promtool below for the full mechanism,
# and its own header comment for HIMMEL-2239 CR round-1, codex-1: an earlier
# version of this resolution instead globbed LOCALAPPDATA, which turned out
# to be exactly the env-selected-executable hole this rule exists to close.
# promtool is NOT an exception to this rule any more — it is fully covered by
# it. An env-selected executable inside a sanctioned carve-out (see
# SANCTIONED CARVE-OUT above) is an arbitrary-command channel: anything that
# can set that variable in this process's environment runs as this script,
# with its authority. The hermetic suite covers every branch instead by
# copying the script into a tmp dir and putting stub `schtasks`/`curl`/`sleep`
# first on PATH (scripts/handover/test-merge-on-green.sh convention) — the
# port-free probe below is itself a `curl` connect-check for exactly this
# reason (a connection refusal is stubbable the same way a health check is).
#
# Exit codes: 0 all requested targets healthy; 2 unknown/refused target, bad
# usage, this copy is not checked out on main/master, schtasks.exe missing at
# its pinned path, or a concurrent grafana provisioning sync is in progress
# (its lock dir is held); 3 grafana provisioning sync failed AND its own
# rollback also failed (the live copy is left ABSENT — see
# sync_grafana_provisioning); 4 grafana's health check passed but its own
# log shows a provisioning error since this restart — config was likely
# REJECTED, not loaded (see verify_grafana_provisioning_loaded); 1 any other
# target failure (provisioning sync, prometheus alert-rules sync, prometheus
# config sync, promtool unresolvable (HIMMEL-2239 fail-closed refusal), port-
# free wait, schtasks //Run, or health verify).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_SRC="$SCRIPT_DIR/provisioning"

# Defense in depth (HIMMEL-2133 CR round-1, codex-1, Critical): see the
# ABSOLUTE-PATH RULE ONLY header comment above — a standing allow-rule
# authorizes whatever file sits at its literal command-text path, and a
# feature-branch worktree copy of THIS script is agent-writable. Refuse to
# run at all unless this copy is checked out on main/master; an empty read
# (git unavailable, no repo context) is treated as inconclusive-but-allowed
# per this same CR's directive, not fail-closed — it is any OTHER named
# branch (a worktree) that is refused.
current_branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$current_branch" in
    ''|main|master) ;;
    *)
        echo "restart-stack: refusing to run — this copy is checked out on '$current_branch', not main/master. This helper is only authorized to run from the primary checkout; a feature-branch worktree copy could carry a locally-modified allowlist or logic. See the ABSOLUTE-PATH RULE ONLY header comment." >&2
        exit 2
        ;;
esac

# Absolute path, resolved ONCE (HIMMEL-2133 CR round-3, codex-1) — see the
# ABSOLUTE SCHTASKS PATH header comment above. Strict: no PATH fallback in
# production. The hermetic suite sed-replaces THIS line in its own script
# copy to point at its PATH-stub schtasks.
SCHTASKS_BIN="/c/Windows/System32/schtasks.exe"
if [ ! -x "$SCHTASKS_BIN" ]; then
    echo "restart-stack: schtasks.exe not found at the pinned path $SCHTASKS_BIN — refusing (no PATH fallback by design)." >&2
    exit 2
fi

# Provisioning stage-swap lock (HIMMEL-2133 CR round-3, codex-2): a second
# restart-stack.sh grafana invocation racing this one could stage its OWN
# "$dest.new-$$" tree (different $$, no collision there) but then both would
# try to move $dest aside and swap in at the same time — the loser's `mv`
# fails mid-swap against a $dest that already moved out from under it,
# landing in the round-2 rollback path for no real reason. mkdir is atomic
# across processes on the same filesystem, so it doubles as a lock: acquired
# in sync_grafana_provisioning, released here via the EXIT trap so it clears
# on every exit path (success, any failure, or a signal) without needing a
# release call at each return site.
PROVISIONING_LOCK=""
# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT` below
release_provisioning_lock() {
    [ -n "$PROVISIONING_LOCK" ] && rmdir "$PROVISIONING_LOCK" 2>/dev/null
    return 0
}
trap release_provisioning_lock EXIT

# resolve_task <short-name> — sets TASK_NAME/TASK_PORT/TASK_HEALTH_PATH for
# one of the hard-allowlisted targets. Returns 1 for anything else (the ONLY
# place new targets may ever be added).
TASK_NAME=""; TASK_PORT=""; TASK_HEALTH_PATH=""
resolve_task() {
    case "$1" in
        flow-exporter)
            TASK_NAME="himmel-observability-flow-exporter"
            TASK_PORT=9877
            TASK_HEALTH_PATH="/metrics"
            ;;
        grafana)
            TASK_NAME="himmel-observability-grafana"
            TASK_PORT=3000
            TASK_HEALTH_PATH="/api/health"
            ;;
        prometheus)
            TASK_NAME="himmel-observability-prometheus"
            TASK_PORT=9090
            TASK_HEALTH_PATH="/-/ready"
            ;;
        windows-exporter)
            TASK_NAME="himmel-observability-windows-exporter"
            TASK_PORT=9182
            TASK_HEALTH_PATH="/metrics"
            ;;
        *)
            return 1
            ;;
    esac
    # Defense in depth: every resolved task must be in the family this script
    # is sanctioned to touch, even if a future edit above ever gets it wrong.
    case "$TASK_NAME" in
        himmel-observability-*) ;;
        *)
            echo "restart-stack: BUG: resolved task '$TASK_NAME' is outside the himmel-observability-* family — refusing." >&2
            return 1
            ;;
    esac
    return 0
}

# sync_grafana_provisioning — WHOLESALE replace of the machine-local
# grafana-provisioning copy from scripts/observability/provisioning/ (same
# source/destination install-stack.ps1 uses), staged as copy-verify-swap
# (HIMMEL-2133 CR round-2, codex-2): build the fresh tree at a scratch path
# next to the target, verify a known key file landed in it, THEN move the
# live copy aside and the fresh one into place. A failure at any point
# before the swap (missing source, a failed cp, a failed verify) leaves the
# live copy completely untouched — the only window that can leave $dest
# transiently absent is the two `mv`s themselves, which is as small as a
# same-filesystem rename gets; the crash-recovery case is a scratch dir
# sitting right next to $dest under a deterministic name, never a
# half-written $dest. Guarded by the mkdir-based PROVISIONING_LOCK (HIMMEL-
# 2133 CR round-3, codex-2) so two concurrent invocations can't race the
# swap; a rollback-move failure (codex-3) is reported LOUD, distinct from
# every other failure in here (return 3, not 1) — see below.
#
# Return codes: 0 success; 1 pre-swap failure (live copy untouched); 2 the
# lock is already held; 3 the swap failed AND the rollback also failed (the
# live copy is currently ABSENT — this is the one case an operator must act
# on by hand).
sync_grafana_provisioning() {
    if [ -z "${LOCALAPPDATA:-}" ]; then
        echo "restart-stack: LOCALAPPDATA is not set — cannot resolve the Grafana provisioning tree. Refusing." >&2
        return 1
    fi
    local dest_win="$LOCALAPPDATA/himmel/observability/grafana-provisioning"
    # LOCALAPPDATA is a Windows-style path (backslashes); mkdir/cp/mv under
    # Git Bash need a POSIX-style one. cygpath is authoritative when present;
    # otherwise a plain backslash->slash swap (bash 3.2-safe pattern
    # substitution) is enough to resolve it.
    local dest
    if command -v cygpath >/dev/null 2>&1; then
        dest=$(cygpath -u "$dest_win")
    else
        dest="${dest_win//\\//}"
    fi
    # Guard (HIMMEL-2133 CR round-1, codex-2): the swap below must never fire
    # against anything but exactly this LOCALAPPDATA-rooted tree, even if a
    # future edit to the resolution above gets it wrong — LOCALAPPDATA is
    # environment-derived, so this is a real trust boundary, not paranoia.
    # Independent shape check, not a re-read of $dest itself.
    case "$dest" in
        */himmel/observability/grafana-provisioning) ;;
        *)
            echo "restart-stack: resolved provisioning destination '$dest' is not the expected himmel-observability tree — refusing to touch it." >&2
            return 1
            ;;
    esac
    if [ ! -d "$PROVISIONING_SRC" ]; then
        echo "restart-stack: provisioning source $PROVISIONING_SRC not found" >&2
        return 1
    fi

    # $dest's parent (.../himmel/observability/) may not exist yet on a
    # fresh machine — the lock mkdir right below is deliberately a PLAIN
    # mkdir (no -p, so it stays atomic/lock-shaped), so the parent must
    # exist first or every first-ever run would misreport a missing parent
    # as "lock held".
    mkdir -p "$(dirname "$dest")" || { echo "restart-stack: could not create $(dirname "$dest")" >&2; return 1; }

    # Lock (HIMMEL-2133 CR round-3, codex-2): mkdir is atomic across
    # processes on the same filesystem, so a second concurrent invocation
    # sees it already exist and refuses rather than racing the swap below.
    # Released by the script-level EXIT trap (release_provisioning_lock).
    PROVISIONING_LOCK="$dest.lock"
    if ! mkdir "$PROVISIONING_LOCK" 2>/dev/null; then
        echo "restart-stack: another restart-stack.sh grafana provisioning sync is already in progress ($PROVISIONING_LOCK exists) — refusing to run concurrently. If this is stale (a prior run crashed without exiting cleanly), remove it by hand: rmdir '$PROVISIONING_LOCK'" >&2
        PROVISIONING_LOCK=""
        return 2
    fi

    local new="$dest.new-$$" old="$dest.old-$$"
    rm -rf "$new" "$old" 2>/dev/null
    mkdir -p "$new" || { echo "restart-stack: could not create staging dir $new — leaving $dest untouched." >&2; return 1; }
    if ! cp -R "$PROVISIONING_SRC/." "$new/"; then
        echo "restart-stack: staged copy into $new failed — leaving $dest untouched." >&2
        rm -rf "$new" 2>/dev/null
        return 1
    fi
    # Verify the STAGED copy, not cp's own exit code alone — a key file
    # (alerting/policies.yaml) actually present proves the copy is real
    # before anything about $dest is touched.
    if [ ! -f "$new/alerting/policies.yaml" ]; then
        echo "restart-stack: staged copy at $new is missing alerting/policies.yaml — refusing to swap it in, leaving $dest untouched." >&2
        rm -rf "$new" 2>/dev/null
        return 1
    fi

    if [ -e "$dest" ] && ! mv "$dest" "$old"; then
        echo "restart-stack: could not move the existing provisioning tree aside — leaving $dest untouched." >&2
        rm -rf "$new" 2>/dev/null
        return 1
    fi
    if ! mv "$new" "$dest"; then
        echo "restart-stack: could not move the staged copy into place." >&2
        if [ -e "$old" ]; then
            if mv "$old" "$dest" 2>/dev/null; then
                echo "restart-stack: rolled back — the previous provisioning tree is restored at $dest." >&2
            else
                # CR round-3, codex-3: the plain-failure return (1, above and
                # below) means $dest is untouched — this branch means it is
                # NOT. Distinct exit code + a loud, explicit message naming
                # both paths, because a silent 1 here would read as "no
                # change" when Grafana's provisioning tree is actually gone.
                echo "restart-stack: CRITICAL — rollback ALSO failed. The live Grafana provisioning tree at '$dest' is currently ABSENT; the previous copy is stranded at '$old'. Restore it by hand: mv '$old' '$dest'" >&2
                return 3
            fi
        fi
        return 1
    fi
    rm -rf "$old" 2>/dev/null
    echo "restart-stack: grafana provisioning re-synced (stage-then-swap) -> $dest"
    return 0
}

# _state_root — %LOCALAPPDATA%/himmel/observability as a POSIX path (empty +
# rc 1 when LOCALAPPDATA is unset). Same cygpath/backslash-swap resolution the
# three older helpers each inline; used by the HIMMEL-2239/2242 additions
# below. Those older copies are deliberately left alone — each carries its own
# tested destination-shape guard, and rewriting them here would churn covered
# code for no behaviour change.
_state_root() {
    [ -z "${LOCALAPPDATA:-}" ] && return 1
    local win="$LOCALAPPDATA/himmel/observability"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$win"
    else
        printf '%s' "${win//\\//}"
    fi
}

# resolve_promtool — HIMMEL-2239: the rules validation below had NEVER run on
# this station. It probed `command -v promtool`, but promtool is not on PATH —
# it ships INSIDE the Prometheus release install-stack.ps1 downloads and
# unpacks, right next to the prometheus.exe this very script //Runs. So the
# gate printed a skip and synced alert rules UNVALIDATED at rc=0: a validation
# step reporting success having validated nothing. Reproduced live twice on
# 2026-08-29, once during HIMMEL-2211's own deployment; alerts.rules.test.yml's
# header records three earlier legs reaching the same wrong "promtool is
# absent" conclusion from the same bare probe.
#
# HIMMEL-2239 CR round-1, codex-1, Critical: the first fix resolved
# PROMTOOL_BIN by globbing %LOCALAPPDATA%/himmel/observability/prometheus-*/ —
# fully env-derived. An attacker who sets LOCALAPPDATA=/evil just creates
# /evil/himmel/observability/prometheus-9/promtool.exe and the shape guard
# passed, because the ENTIRE matching tree was derived from that same
# variable — the guard checked the shape of a path whose every component the
# attacker also controlled. That is precisely the channel the header's NO
# ENV-SELECTED EXECUTABLES rule forbids ("anything that can set that variable
# in this process's environment runs as this script, with its authority");
# "it's a directory, not a program name" does not survive contact with that
# rationale once the directory determines what gets EXECUTED. (Writing a YAML
# file to a forged path — _state_root/_prometheus_state_path's pre-existing
# destination-resolution behaviour, untouched by this fix — is a materially
# weaker sink and is not what this rewrite addresses.)
#
# Fixed source: the himmel-observability-prometheus SCHEDULED TASK's own
# registered Execute path, read through the already-pinned $SCHTASKS_BIN (see
# ABSOLUTE SCHTASKS PATH above) — machine state, not process environment,
# mirroring that constant's own no-PATH-fallback posture. promtool.exe ships
# beside the prometheus.exe the task launches, so this one query answers both
# "does an installed stack exist" and "where is its promtool". Bonus: the
# resolved promtool is now guaranteed to be the exact release the live stack
# runs, so the old sort-across-multiple-installs version question no longer
# exists — this fix is shorter than what it replaced, not longer.
#
# The task name is hardcoded here rather than read from $TASK_NAME — it must
# resolve identically regardless of what restart_one has set up so far, and
# "himmel-observability-prometheus" is already hard-allowlisted in
# resolve_task.
#
# HIMMEL-2239 CR round-2, codex-1, Important: the first cut of this parsed by
# LABEL — `grep '^Task To Run:'` — which only matches English Windows. On a
# German station the field is `Auszuführende Aufgabe:`, the label-grep misses,
# resolution fell back to PATH, and if promtool wasn't there too the whole
# sync refused on a station with a perfectly good installed stack. That is
# the SAME mistake HIMMEL-2239 itself was filed over: concluding "the tool is
# absent" from a probe that was looking the wrong way (alerts.rules.test.yml's
# header already records three legs making it). Fixed by parsing the VALUE
# SHAPE instead of the localized LABEL: scan the whole `//V //FO LIST` output
# for a Windows drive-letter path ending in `prometheus.exe` — the path is
# never translated, only the field label is, so this needs no locale table.
# This also resolves codex-2 (a parent directory literally named "foo.exe.d"
# no longer truncates the match): matching is anchored on `prometheus\.exe`
# specifically, not "the first .exe", so it walks past any exe-flavoured
# directory name to the real terminal executable.
#
# Degrades to bare `promtool` on PATH (never hard-fails on its own) when the
# task query fails OR no such path is found in its output — see the
# LOCALIZED-schtasks note above for why a parse miss must never be misread as
# "promtool is absent". If PATH also has nothing, the fail-closed refusal in
# _sync_repo_file_to_state stands.
#
# Sets PROMTOOL_BIN and returns 0; returns 1 with PROMTOOL_BIN empty.
PROMTOOL_BIN=""
resolve_promtool() {
    PROMTOOL_BIN=""
    local exe_path posix_path task_dir cand

    # [\\] (a bracket expression, not `\\`) is the portable way to match a
    # literal backslash in POSIX ERE here — greedy `.*` is safe because the
    # task registers exactly one "prometheus.exe" occurrence on this line.
    exe_path="$("$SCHTASKS_BIN" //Query //TN himmel-observability-prometheus //V //FO LIST 2>/dev/null \
        | grep -oE '[A-Za-z]:[\\].*prometheus\.exe' | head -n 1)"
    if [ -n "$exe_path" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            posix_path="$(cygpath -u "$exe_path")"
        else
            posix_path="${exe_path//\\//}"
        fi
        task_dir="$(dirname "$posix_path")"
        for cand in "$task_dir/promtool.exe" "$task_dir/promtool"; do
            if [ -x "$cand" ]; then
                PROMTOOL_BIN="$cand"
                return 0
            fi
        done
    fi

    # Task query failed, no prometheus.exe path was found in its output, or
    # its directory had no promtool — degrade to PATH (see the LOCALIZED-
    # schtasks note above).
    if command -v promtool >/dev/null 2>&1; then
        PROMTOOL_BIN="promtool"
        return 0
    fi
    return 1
}

# _prometheus_state_path <basename> — prints the machine-local path a
# repo-derived Prometheus file syncs to, guarding the resolved shape exactly
# the way sync_grafana_provisioning guards its own (LOCALAPPDATA is
# environment-derived, so this is a real trust boundary). Prints nothing and
# returns 1 on an unset LOCALAPPDATA or an unexpected shape, having said why.
_prometheus_state_path() {
    local base="$1" dest
    if ! dest="$(_state_root)" || [ -z "$dest" ]; then
        echo "restart-stack: LOCALAPPDATA is not set — cannot resolve the machine-local $base. Refusing." >&2
        return 1
    fi
    dest="$dest/$base"
    case "$dest" in
        */himmel/observability/"$base") ;;
        *)
            echo "restart-stack: resolved destination '$dest' is not the expected himmel-observability tree — refusing to touch it." >&2
            return 1
            ;;
    esac
    printf '%s' "$dest"
}

# _sync_repo_file_to_state <src> <dest> <label> <promtool-check-kind> —
# validate, back up, stage, rename. Shared by the alert-rules (HIMMEL-2149)
# and prometheus.yml (HIMMEL-2242) syncs: they differ only in WHICH file and
# WHICH promtool subcommand, and a second hand-rolled copy of this dance is a
# second place for it to drift out of step.
#
# Validation is FAIL-CLOSED on an unresolvable promtool (HIMMEL-2239). The
# previous best-effort skip is exactly what let an unvalidated sync run
# unnoticed; and now that promtool is resolved from the stack's own install
# dir, "unresolvable" means there is no installed Prometheus on this station —
# i.e. no live stack for this helper to deploy into — so refusing costs
# nothing real and closes the vacuous-gate class.
#
# Return codes: 0 success; 1 promtool unresolvable, the source failed its
# promtool check, or the destination could not be backed up / staged /
# written — in every failure case the previous copy is left untouched.
_sync_repo_file_to_state() {
    local src="$1" dest="$2" label="$3" kind="$4"

    if ! resolve_promtool; then
        echo "restart-stack: promtool could not be resolved — looked at the himmel-observability-prometheus scheduled task's registered Execute path (via schtasks //Query //TN himmel-observability-prometheus //V //FO LIST; a task-query failure or a line that doesn't parse both land here) and then on PATH. Refusing to sync $label UNVALIDATED (HIMMEL-2239)." >&2
        return 1
    fi
    if ! "$PROMTOOL_BIN" check "$kind" "$src"; then
        echo "restart-stack: promtool check $kind failed against $src — refusing to sync $label, leaving $dest untouched." >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")" || { echo "restart-stack: could not create $(dirname "$dest")" >&2; return 1; }

    if [ -f "$dest" ]; then
        if cmp -s "$src" "$dest"; then
            echo "restart-stack: $label already current -> $dest"
            return 0
        fi
        local bak
        # -$$ (pid) suffix (HIMMEL-2149 CR round-1, codex-1): the date-only
        # timestamp has 1s resolution, so two syncs within the same second
        # would collide and the second overwrite the first .bak.
        # ponytail: these .bak-* files are never pruned (CR round-2, codex-2)
        # — accepted: a manual restart helper, invoked rarely, backing up a
        # tiny YAML file; unbounded here means "a handful of KB over years".
        # If this ever needs bounding, prune to the newest N on each sync.
        bak="$dest.bak-$(date +%Y%m%dT%H%M%S)-$$"
        if ! cp "$dest" "$bak"; then
            echo "restart-stack: could not back up existing $dest to $bak — refusing to overwrite it." >&2
            return 1
        fi
    fi

    # Stage-then-rename (same posture as sync_grafana_provisioning's stage-
    # then-swap): a `cp` straight onto $dest would truncate it in place, and
    # a failed/interrupted write could leave a half-written file that
    # Prometheus then refuses to load on the restart that follows. `mv` on
    # the same filesystem is a rename, not a copy.
    local tmp="$dest.new-$$"
    rm -f "$tmp" 2>/dev/null
    if ! cp "$src" "$tmp"; then
        echo "restart-stack: could not stage $src -> $tmp" >&2
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        echo "restart-stack: could not move staged copy $tmp -> $dest" >&2
        rm -f "$tmp" 2>/dev/null
        return 1
    fi

    echo "restart-stack: $label re-synced -> $dest"
    return 0
}

# sync_prometheus_alert_rules — HIMMEL-2149: restart-stack.sh only //End+
# //Run the scheduled task, it never re-synced alerts.rules.yml — a merged
# rules change (that ticket's own SessionDead page->warn) never reached the
# running Prometheus until a full install-stack.ps1 re-run, proven live.
# Validated with `promtool check rules` against the repo's OWN copy before
# anything live is touched; see _sync_repo_file_to_state for the shared
# validate-backup-stage-rename body and its fail-closed posture.
sync_prometheus_alert_rules() {
    local src="$SCRIPT_DIR/alerts.rules.yml" dest
    if [ ! -f "$src" ]; then
        echo "restart-stack: alert-rules source $src not found" >&2
        return 1
    fi
    dest="$(_prometheus_state_path alerts.rules.yml)" || return 1
    _sync_repo_file_to_state "$src" "$dest" "prometheus alert rules" rules
}

# sync_prometheus_config — HIMMEL-2242: the rules got a re-sync path
# (HIMMEL-2149); prometheus.yml itself never did, so the SCRAPE config was
# install-time state only. Any change to scrape_timeout / scrape_interval /
# targets / job definitions merged to main and silently never reached the
# running Prometheus, which kept serving the copy install-stack.ps1 wrote at
# INSTALL time. Proven live 2026-08-29: HIMMEL-2211's `scrape_timeout: 30s`
# was merged on main and /api/v1/status/config still reported the 10s default
# after a full rc=0 "healthy" restart, so the flow-exporter target kept going
# down ~51x/day. This is the HIMMEL-2133 class (repo file -> install-time copy
# -> live process, with a re-sync path for only some of the copies), one file
# short.
#
# `promtool check config` on the SOURCE also parses the rule_files it names —
# relative to the source, i.e. the repo's own alerts.rules.yml — so this one
# check covers both halves of what the prometheus target syncs.
sync_prometheus_config() {
    local src="$SCRIPT_DIR/prometheus.yml" dest
    if [ ! -f "$src" ]; then
        echo "restart-stack: prometheus config source $src not found" >&2
        return 1
    fi
    dest="$(_prometheus_state_path prometheus.yml)" || return 1
    _sync_repo_file_to_state "$src" "$dest" "prometheus config" config
}

# port_is_free <port> — 0 (free) / 1 (still held). A bare `curl` connect
# check (HIMMEL-2133 CR round-2, codex-1): no env-selected probe, and the
# same tool the health check already uses, so the hermetic suite stubs both
# through one PATH-stub `curl`. A connection REFUSAL (curl exit 7) means
# nothing is listening; any other outcome — a real response, a protocol
# error, a timeout — means something answered or the read was inconclusive,
# so it counts as still held (never mistake "couldn't tell" for "free").
# HIMMEL-2149: on this Windows host, curl against a CLOSED localhost port
# measures >1s before the connection-refused error (rc 7) surfaces — at
# --max-time 1 a genuinely free port instead exits 28 (timeout), which the
# check above then reads as still held, so wait_port_free NEVER saw free.
# Measured: same probe against a certainly-closed port exits 28 at
# --max-time 1 but correctly exits 7 at --max-time 3. Bumped to 3s; never
# mistake a too-short timeout's 28 for held.
port_is_free() {
    local port="$1" rc=0
    curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null || rc=$?
    [ "$rc" -eq 7 ]
}

# wait_port_free <port> — bounded ~120s poll (30 x (up to 3s curl + 1s
# sleep)), up from ~60s now that each try's curl can itself take up to 3s
# (HIMMEL-2149). Left at 30 tries rather than tightened: this only restarts
# a background stack, a slower worst-case wait is cheap, and fail-closed
# semantics matter more here than shaving seconds off a timeout path.
wait_port_free() {
    local port="$1" tries=0 max=30
    while [ "$tries" -lt "$max" ]; do
        port_is_free "$port" && return 0
        tries=$((tries + 1))
        [ "$tries" -lt "$max" ] && sleep 1
    done
    return 1
}

# health_ok <url> — a plain 200 from curl, short per-request timeout.
health_ok() {
    local url="$1" code
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null) || return 1
    [ "$code" = "200" ]
}

# wait_health <url> — bounded ~60s poll (30 x 2s). This is the "verify the
# artifact, not the rc" gate: a zero schtasks //Run exit means the task
# scheduler accepted the start request, nothing more.
wait_health() {
    local url="$1" tries=0 max=30
    while [ "$tries" -lt "$max" ]; do
        health_ok "$url" && return 0
        tries=$((tries + 1))
        [ "$tries" -lt "$max" ] && sleep 2
    done
    return 1
}

# _grafana_logs_dir — resolves %LOCALAPPDATA%/himmel/observability/
# grafana-logs the same way sync_grafana_provisioning resolves its own
# destination (same cygpath/backslash-swap logic). Prints nothing and
# returns 1 if LOCALAPPDATA is unset.
_grafana_logs_dir() {
    [ -z "${LOCALAPPDATA:-}" ] && return 1
    local win="$LOCALAPPDATA/himmel/observability/grafana-logs"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$win"
    else
        printf '%s' "${win//\\//}"
    fi
}

# _newest_file_in <dir> — the most-recently-modified regular file directly in
# <dir>, or empty. `find -printf` over `ls -t` (SC2012): doesn't break on a
# non-alphanumeric filename.
_newest_file_in() {
    find "$1" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-
}

# snapshot_grafana_log_watermark — called BEFORE //End, so
# verify_grafana_provisioning_loaded (after the restart) can tell which log
# lines are new. Best-effort: a missing dir/file just leaves the watermark
# empty, which verify_grafana_provisioning_loaded treats as "scan everything
# in the newest file" (see there).
GRAFANA_LOG_WATERMARK_FILE=""
GRAFANA_LOG_WATERMARK_LINES=0
snapshot_grafana_log_watermark() {
    local dir file
    dir="$(_grafana_logs_dir)" || return 0
    [ -d "$dir" ] || return 0
    file="$(_newest_file_in "$dir")"
    [ -n "$file" ] || return 0
    GRAFANA_LOG_WATERMARK_FILE="$dir/$file"
    GRAFANA_LOG_WATERMARK_LINES="$(wc -l < "$GRAFANA_LOG_WATERMARK_FILE" 2>/dev/null || echo 0)"
}

# verify_grafana_provisioning_loaded — HIMMEL-2133 CR round-6, codex-2: this
# ticket's FOUNDING failure was Grafana answering /api/health 200 while its
# provisioning was silently rejected at startup, needing a second manual
# restart to notice. A healthy port is not a healthy config. Scans only the
# lines APPENDED to the newest grafana log file since
# snapshot_grafana_log_watermark (or, if that never found a file, the last
# ~200 lines of whatever newest file exists now) for a provisioning error
# line. Returns 0 (nothing found / cannot verify — see the WARNING) or 1
# (found — the caller maps this to the distinct exit code 4, never silent).
verify_grafana_provisioning_loaded() {
    local dir file
    dir="$(_grafana_logs_dir)"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "restart-stack: WARNING — grafana log dir not found (LOCALAPPDATA unset, or %LOCALAPPDATA%/himmel/observability/grafana-logs missing) — cannot verify provisioning actually loaded; trusting the health check alone." >&2
        return 0
    fi
    file="$(_newest_file_in "$dir")"
    if [ -z "$file" ]; then
        echo "restart-stack: WARNING — no grafana log file found in $dir — cannot verify provisioning actually loaded; trusting the health check alone." >&2
        return 0
    fi
    file="$dir/$file"

    local new_lines
    if [ "$file" = "$GRAFANA_LOG_WATERMARK_FILE" ] && [ "$GRAFANA_LOG_WATERMARK_LINES" -gt 0 ]; then
        # Same file as before the restart — only what was appended since,
        # bounded to ~200 lines of scan cost.
        new_lines="$(tail -n "+$((GRAFANA_LOG_WATERMARK_LINES + 1))" "$file" 2>/dev/null | tail -n 200)"
    else
        # No watermark (first-ever run, or the file rotated) — everything in
        # the newest file is "since the restart" as far as this check knows.
        new_lines="$(tail -n 200 "$file" 2>/dev/null)"
    fi

    local hits
    hits="$(printf '%s\n' "$new_lines" | grep -i 'logger=provisioning' | grep -iE 'level=error|lvl=eror')"
    if [ -n "$hits" ]; then
        echo "restart-stack: grafana's health check passed, but its log shows a provisioning ERROR since this restart — config was likely REJECTED, not loaded:" >&2
        printf '%s\n' "$hits" >&2
        return 1
    fi
    return 0
}

# restart_one <short-name> — the full sequence for one allowlisted target.
restart_one() {
    local short="$1"
    resolve_task "$short" || { echo "restart-stack: BUG: resolve_task failed for an already-validated target '$short'" >&2; return 1; }

    echo "restart-stack: restarting $TASK_NAME (port $TASK_PORT)"

    if [ "$short" = "grafana" ]; then
        # Propagate sync_grafana_provisioning's own exit code, not a
        # collapsed 1 (HIMMEL-2133 CR round-3): 2 (lock held) and 3 (rollback
        # also failed) are distinct signals a caller/operator needs intact.
        local sync_rc=0
        sync_grafana_provisioning || sync_rc=$?
        [ "$sync_rc" -eq 0 ] || return "$sync_rc"
        snapshot_grafana_log_watermark
    fi

    # Rules first, then the config that references them (HIMMEL-2242): a
    # single `promtool check config` on the repo source already validated
    # both, so either order is safe, and this one keeps the existing
    # HIMMEL-2149 call site first.
    if [ "$short" = "prometheus" ]; then
        sync_prometheus_alert_rules || return 1
        sync_prometheus_config || return 1
    fi

    # //End: stop the task if running. A non-zero exit here (e.g. the task
    # was already stopped) is not itself fatal — wait_port_free below is the
    # real gate before //Run.
    "$SCHTASKS_BIN" //End //TN "$TASK_NAME" >/dev/null 2>&1 || true

    if ! wait_port_free "$TASK_PORT"; then
        echo "restart-stack: port $TASK_PORT still held after ~30s waiting for $TASK_NAME to release it — refusing to //Run into a possibly-still-bound port." >&2
        return 1
    fi

    if ! "$SCHTASKS_BIN" //Run //TN "$TASK_NAME" >/dev/null 2>&1; then
        echo "restart-stack: schtasks //Run failed for $TASK_NAME" >&2
        return 1
    fi

    local health_url="http://127.0.0.1:$TASK_PORT$TASK_HEALTH_PATH"
    if ! wait_health "$health_url"; then
        echo "restart-stack: health check failed for $TASK_NAME at $health_url after ~60s. Last Result:" >&2
        "$SCHTASKS_BIN" //Query //TN "$TASK_NAME" //V //FO LIST 2>&1 | grep -i "Last Result" >&2 || true
        return 1
    fi

    if [ "$short" = "grafana" ] && ! verify_grafana_provisioning_loaded; then
        echo "restart-stack: $TASK_NAME responded healthy but provisioning verification failed (see the error above) — not reporting success." >&2
        return 4
    fi

    echo "restart-stack: $TASK_NAME healthy at $health_url"
    return 0
}

target="${1:-}"
case "$target" in
    all)
        # Propagate the WORST per-target rc, not a flattened 1 — rc=3
        # (rollback failed, live provisioning ABSENT) is the documented
        # emergency signal and must survive the `all` path for programmatic
        # callers (panel round-4 codex-2, HIMMEL-2133).
        overall=0
        for t in flow-exporter grafana prometheus windows-exporter; do
            rc=0; restart_one "$t" || rc=$?
            [ "$rc" -gt "$overall" ] && overall=$rc
        done
        exit "$overall"
        ;;
    flow-exporter|grafana|prometheus|windows-exporter)
        restart_one "$target"
        exit $?
        ;;
    *)
        echo "restart-stack: refusing target '${target:-<none>}' — only the himmel-observability-* task family is reachable here (flow-exporter|grafana|prometheus|windows-exporter|all). This helper must never become a generic schtasks wrapper." >&2
        echo "Usage: $0 <flow-exporter|grafana|prometheus|windows-exporter|all>" >&2
        exit 2
        ;;
esac
