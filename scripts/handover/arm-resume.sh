#!/usr/bin/env bash
# arm-resume.sh — actually create the scheduled relaunch + dedupe.
#
# Unlike scripts/handover/schedule-resume.sh (which prints the
# platform scheduler command for operator copy-paste review), this
# script:
#   1. dedupes against the CURRENT handover's HIMMEL-Resume-<name> job
#      in the OS scheduler — refuses (rc=3) or replaces with --force,
#      so we never end up with two claude sessions cron-relaunched for
#      the SAME handover (the user's stated requirement for HIMMEL-122).
#      Distinct handovers each get their own slot (HIMMEL-340); pass
#      --dedup-any to instead defer to ANY existing slot (the auto-arm
#      watchdog safety-arm semantics — never queue a duplicate relaunch).
#   2. directly invokes schtasks / at / crontab — does NOT round-trip
#      through schedule-resume.sh's mixed prose+command stdout (the
#      v1 attempt at this script did, which silently failed because
#      bash parsed the prose lines as commands and the banner lied
#      about success)
#   3. injects a HIMMEL-Resume-<task_name> marker into the at-job
#      body so POSIX dedup actually matches (v1 grepped for a marker
#      that schedule-resume.sh never emitted)
#   4. emits a loud post-arm banner reminding operator to /exit
#   5. makes the relaunch self-cleaning: the spawned launcher deletes
#      its OWN scheduler entry as its first action (schtasks .bat
#      self-/delete; crontab entry self-removes; at auto-removes), so a
#      fired slot never lingers to block a same-handover re-arm or fire
#      twice.
#   6. checks for time collisions with other HIMMEL-* claude-launching
#      scheduled tasks (HIMMEL-407): HARD-REFUSES (rc=6) on an exact-
#      minute match; WARNs (continues) within ±COLLISION_WINDOW_MINUTES
#      (default 5 min). --force bypasses both. --dedup-any arms run
#      WARN-ONLY so unattended watchdog arms never refuse.
#
# This is the *arm* half of HIMMEL-122 (auto-resume on usage-cap
# detection). The *detect* half (monitoring claude-statusline / API
# rate-limit signals to auto-trigger this) is a separate wedge.
#
# Usage:
#   bash scripts/handover/arm-resume.sh \
#     --time <HH:MM> --handover <path> [--force] [--dedup-any] [--dry-run]
#
# Required:
#   --time <HH:MM>     24h local time. Today if future, tomorrow if past.
#   --handover <path>  Resume marker file path. Must exist. Pasted into
#                      the claude relaunch prompt so the next session
#                      picks up state.
#
# Optional:
#   --force            Replace the existing same-handover HIMMEL-Resume job
#                      (always THIS handover's own job only — never a sibling
#                      chain's, even under --dedup-any; HIMMEL-1563).
#                      Default refuses (rc=3) — explicit opt-in only.
#                      Also bypasses the time-collision check (HIMMEL-407).
#   --long-gap         Sanction a far park: an explicit HH:MM more than 60 min
#                      out (HIMMEL-1475, rc=9), OR --time smart resolving to a
#                      multi-hour/day quota-exhaustion park (HIMMEL-2113,
#                      rc=19). Default REFUSES both so a long wait is an
#                      explicit choice, not a silent default (ALWAYS-CONTINUE:
#                      an orchestrator leg arms <=30-60 min out while work
#                      remains). ARM_RESUME_SAFETY_ARM=1 is exempt from BOTH
#                      guards. The "smart/auto sentinels are exempt" wording
#                      this replaced was stale/scoped wrong: that exemption is
#                      structural and rc=9-only (that guard lives in the
#                      explicit-HH:MM branch, which smart/auto never reach) --
#                      it never covered smart's OWN rc=19 park refusal, which
#                      --long-gap is what overrides.
#   --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
#                      handover's (HIMMEL-340 safety-arm semantics).
#   --dry-run          Print what would be scheduled, touch nothing.
#
# Env:
#   ARM_MAX_SLOTS           Soft cap on concurrent resume slots (default 4, 0
#                           disables). Arming past it WARNs but never blocks.
#   COLLISION_WINDOW_MINUTES Minutes around another HIMMEL-* task's fire time
#                           that trigger a WARN (default 5). An exact-minute
#                           match always refuses (rc=6) unless --force.
#   ARM_COLLISION_WINDOW    Test seam: overrides COLLISION_WINDOW_MINUTES.
#   ARM_RESUME_SAFETY_ARM   Internal signal (=1) marking an automated
#                           machine-wide SAFETY arm (auto-arm-on-cap.sh,
#                           spawn-glm cap-respawn) so the HIMMEL-1475 long-gap
#                           guard exempts it. NOT a public flag: set only by
#                           the in-repo automated callers in their child env.
#   ARM_NAME_TEMPLATE       Naming template for the derived session identity
#                           (HIMMEL-716): placeholders {ticket} {slug}
#                           {session}. Unset = the built-in ticket-first
#                           composition. See _compose_arm_name.
#   ARM_WITH_LIVE_WORKERS   Exact value 1 bypasses the live lane-worker guard
#                           with a loud warning. Use only when intentionally
#                           killing in-flight workers at session exit. Also
#                           downgrades a reconcile/census tool FAILURE (e.g. a
#                           malformed meta.json) from a hard refusal to a loud
#                           warning naming the offending path (HIMMEL-1511) --
#                           without it, that failure exits 2 unconditionally.
#   SCHTASKS_CMD            Windows scheduler binary. Default `schtasks`; tests
#                           pin it to a stub path so the suite drives the stub
#                           through this seam instead of relying on PATH
#                           resolution order (HIMMEL-1610). Same shape as the
#                           GH_CMD seam in graph-publish / the forge backends.
#                           Left at its default, arm-resume also tries a fast
#                           PowerShell wildcard listing first (HIMMEL-1337)
#                           before falling back to a full `schtasks /query`.
#   ARM_TICKET_DUP_OK       Exact value 1 overrides the HIMMEL-1329 ticket-level
#                           mutex refusal (rc 13) -- arms anyway when this
#                           ticket already has another slot under a different
#                           handover. Env twin of --force for this check.
#   ARM_VAULT_CWD_OK        Exact value 1 overrides the HIMMEL-1330 single-writer
#                           auto-detected-cwd refusal (rc 14) -- arms anyway
#                           into a vault/state repo with no explicit
#                           --cwd/--worktree/resume_cwd:.
#
# Exit codes:
#   0  scheduler armed (or printed under --dry-run)
#   1  usage / input error
#   2  required tool missing or env unusable (no schtasks/at/crontab;
#      no platform match; dedup-check tool itself errored — fail-closed
#      rather than risk a duplicate)
#   3  dedup block — a same-handover HIMMEL-Resume job exists (or, under
#      --dedup-any, any HIMMEL-Resume job exists); pass --force to replace
#   4  scheduler invocation failed (job NOT armed; stderr above)
#   5  refused — --channels passed while the bun Telegram bridge is live
#      (HIMMEL-225: a 2nd getUpdates consumer 409s + the dev-channels prompt
#      hangs an unattended relaunch). Drop --channels (the bun bridge owns
#      Telegram) or, after stopping the bridge, override with ARM_CHANNELS_OK=1.
#   6  time collision — the requested time exactly matches another HIMMEL-*
#      scheduled task (HIMMEL-407). Pass --force to override, or choose a
#      different time (suggest_free_slot prints nearby free options).
#   7  refused — the handover's queue lock (scripts/handover/queue-lock.sh)
#      is currently FRESH: a session is LIVE on this queue right now
#      (HIMMEL-856). Override with QUEUE_LOCK_TAKEOVER=1.
#   8  refused — this handover already has a PENDING arm recorded on
#      ANOTHER host in the cross-machine arms registry (HIMMEL-856; the
#      win2+main double-arm shape). Override with ARM_DUP_OK=1. A record
#      stops being PENDING (and stops causing this refusal) once the arm it
#      names actually fires and the relaunched session acquires its queue
#      lock — queue-lock.sh CONSUMES (drops) it at that point (HIMMEL-882);
#      this script also prunes ITS OWN host's prior records for the same
#      handover on every re-arm, so neither a fired arm nor a superseded
#      re-arm blocks a later cross-host arm forever.
#   9  long-gap refused — an explicit --time HH:MM more than 60 min out
#      without --long-gap (HIMMEL-1475). Pass --long-gap to sanction an
#      overnight/idle wait, or pick a nearer --time. Automated safety arms
#      (ARM_RESUME_SAFETY_ARM=1) are exempt; smart/auto sentinels are exempt
#      by design.
#   19 quota-park refused — --time smart resolved to a multi-hour/day park at
#      the next usage-window reset (HIMMEL-2113 Ask A): refuses FAST, before
#      the worker census / queue-lock / shipped-work-preflight phases spend
#      real wall-clock discovering the same park anyway. Pass --time HH:MM to
#      arm a specific slot instead, or --long-gap to accept the park.
#      ARM_RESUME_SAFETY_ARM=1 is exempt, same as the rc 9 guard.
#   12 temp-target refused — the resolved work directory OR the handover file
#      itself lives under a TEMP/scratch root (HIMMEL-1365), so arming would
#      create a REAL scheduled task launching an UNATTENDED session against a
#      throwaway path. Set ARM_FIXTURE_OK=1 (or the original ARM_TEMP_CWD_OK=1)
#      when that is genuinely intended (a test harness arming its own fixture).
#      --dry-run is exempt.
#   11 shipped-work refused — the work this handover re-arms already looks
#      landed (HIMMEL-1331): its ticket is Done/Closed, or its branch has a
#      MERGED PR, or an OPEN+MERGEABLE one. The ERR names which check tripped.
#      Only POSITIVE evidence refuses — a missing gh/Jira CLI, no network or a
#      detached HEAD skip the probe. Pass --force or set ARM_SHIPPED_OK=1 for a
#      deliberate follow-up leg on the same ticket.
#   10 live workers refused — one or more GLM/claudex bridge rows are running
#      with a live or unprobeable pid (HIMMEL-1463). Unprobeable fails closed as
#      possibly alive. Wait for them or explicitly set ARM_WITH_LIVE_WORKERS=1
#      to accept that session exit may kill them.
#   13 ticket-dup refused — this ticket already has another armed resume slot
#      under a DIFFERENT handover file (HIMMEL-1329). The identity dedup (rc 3)
#      only catches the SAME handover armed twice; this catches two handovers
#      naming the same ticket. Pass --force or set ARM_TICKET_DUP_OK=1 for a
#      deliberate parallel leg on the same ticket.
#   14 vault-cwd refused — no --cwd/--worktree/resume_cwd: named a work repo,
#      so the auto-detected cwd (the handover's own git toplevel) would be
#      used, and that directory is a SINGLE-WRITER repo (HIMMEL-1330) — e.g. a
#      himmel/code handover parked in the luna vault, about to arm INSIDE the
#      vault and inherit its direct-to-main commit behavior. Set
#      'resume_cwd: <work-repo>' in the handover frontmatter, pass
#      --cwd/--worktree, or set ARM_VAULT_CWD_OK=1 if arming into the vault is
#      genuinely intended. --dry-run is exempt.
#   15 already-fired refused — the flow-run ledger holds an `armed-resume`
#      start row for THIS task name with NO matching end row, i.e. this
#      handover's arm fired and that run never recorded completion
#      (HIMMEL-1879). The scheduler reads clean because a fired arm deletes its
#      own registration, so rc 3 cannot see it; re-arming would put a SECOND
#      session on one seat. A run that COMPLETED never trips this (stable
#      handovers re-arm all day), and ARM_RESUME_SAFETY_ARM=1 is exempt. Pass
#      --force when the session is known gone (crashed before its end row).
#   16 --list-temp-arms found at least one armed entry targeting a temp/scratch
#      path (HIMMEL-1365 sweep). REPORT ONLY — nothing is ever deleted. 0 = clean.
#   18 --list-temp-arms found NO temp target but could not INSPECT one or more
#      armed entries — the scheduler would not describe them (access denied, or
#      the task vanished between the roster read and the query). Not a clean
#      bill of health, and rc 0 would let a machine caller record one
#      (HIMMEL-1998). Re-run where schtasks can read them. 16 outranks this: a
#      sweep with BOTH a hit and an uninspectable entry exits 16 and says so in
#      the report, because the hit is the actionable half.
#   17 split-leg refused — the handover is `<prefix>-session-N.md` and its
#      sibling `<prefix>-session-<N-1>.md` was written inside this leg window
#      AND was never itself a relaunch point (no `armed-resume` ledger row
#      names its arm identity): one leg wrote two numbered files and is arming the
#      wrong half, so the other half's state would be orphaned (HIMMEL-1830).
#      Fold them into ONE file and arm that; ARM_SPLIT_LEG_OK=1 or --force opts
#      out. Safety arms (ARM_RESUME_SAFETY_ARM=1) are exempt.
#   20 fable-tier refused — --model names a Fable-family model on a
#      non-console arm with no --fable-ok (HIMMEL-2332, operator ruling 30:
#      "we shouldn't arm fable unless theres a good reason"). Pass
#      --fable-ok "<reason>" to arm it anyway, or drop --model to get the
#      opus default. *-console.md handovers are exempt (ruling 25 -- the
#      console lane is ALWAYS Fable). rc 0-19 were already taken by this
#      script, so 20 is the first free code.
#   21 base-not-verified refused — the handover's `fence:` frontmatter key
#      (HIMMEL-2383, console ruling 66) names a fence scripts/console/base-status.sh
#      could not certify clean: it reported a PENDING/RED merged PR, OR it
#      could not run at all (missing script, gh query error, a truncated
#      merged-PR list) — a certification failure refuses exactly like a
#      certified-dirty base, never a silent unchecked proceed (CR finding
#      codex-1). Docs with no `fence:` key are unaffected. Pass
#      --provisional-base-ok to arm anyway — this WARNS loudly and prints
#      the warning text (paste it into the leg's first message per ruling
#      66) instead of refusing.
set -euo pipefail

RESUME_TIME=""
HANDOVER_PATH=""
FORCE=0
DRY_RUN=0
RESUME_CWD_OVERRIDE=""
CHANNELS=""
MODEL=""
FABLE_OK=""
DEDUP_ANY=0
WORKTREE_BRANCH=""
WSL_DISTRO=""
AUTOMERGE=0
LONG_GAP=0
LIST_TEMP_ARMS=0
SAFETY_CHILD=0
PROVISIONAL_BASE_OK=0

# Local HH:MM from an epoch (armored python3 — portable, no GNU `date -d`;
# capture via file so a wedged Store stub can't hang the $() call sites).
_epoch_hhmm() { py_armor_capture -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone().strftime("%H:%M"))' "$1" && printf '%s\n' "$PY_ARMOR_OUT"; }

usage() {
    cat <<'EOF'
Usage: arm-resume.sh --time <HH:MM> --handover <path> [--wsl-distro <name>] [--force] [--long-gap] [--dedup-any] [--dry-run] [--automerge] [--safety-child] [--model <name>] [--fable-ok <reason>] [--provisional-base-ok]

Arms the OS scheduler to relaunch claude at the given time with a
resume prompt referencing the given handover file. Dedup-guarded
against existing HIMMEL-Resume-* jobs; pass --force to replace.

Required:
  --time <HH:MM|smart|auto>
                       24h local time, OR a sentinel resolved from the
                       claude-statusline usage cache:
                         smart — usage-aware: relaunch ASAP when the bank
                                 has headroom, else wait for the binding
                                 window's reset (scripts/handover/resume-slot.sh).
                                 Maximizes throughput — prefer this.
                         auto  — next 5-hour cap reset regardless of headroom
                                 (scripts/handover/cap-reset-time.sh).
                       A past HH:MM rolls to tomorrow; sentinels carry their
                       own (possibly multi-day) date.
  --handover <path>    Resume marker file (must exist)

Optional:
  --cwd <path>       Working directory for the relaunched claude.
                     Default: git toplevel containing the --handover
                     file. Override when the handover lives in a
                     different repo than the one claude should run
                     from (e.g. hop.sh writes the snapshot under
                     the state repo but the origin session was in himmel).
                     If the handover file's YAML frontmatter contains
                     'resume_cwd: <path>', that value is used when
                     --cwd is omitted (set this for cross-repo
                     handovers so the correct repo is used without
                     requiring an explicit --cwd every time).
  --worktree <branch>  Run the relaunch in a FRESH himmel worktree for
                     <branch> (type/slug) instead of a shared checkout —
                     for code arms that must not collide with concurrent
                     github-sync / Telegram-bridge sessions. Creates the
                     worktree at arm time and resumes there. Mutually
                     exclusive with --cwd (the worktree IS the cwd). A
                     handover 'resume_worktree: <branch>' frontmatter key
                     does the same when the flag is omitted. (HIMMEL-387)
  --channels <spec>  Pass --channels <spec> to the relaunched claude so
                     the spawned session opens that channel. NOT for
                     Telegram: the always-on bun bridge (HIMMEL-207/208)
                     owns the single getUpdates slot, so a --channels
                     Telegram relaunch 409s against it AND its dev-channels
                     prompt hangs an unattended launch. This script REFUSES
                     --channels (rc=5) while the bun bridge is live — drop
                     it and relaunch PLAIN (bridge reaches Telegram on its
                     own). Override only after `bun supervisor.ts --kill`
                     with ARM_CHANNELS_OK=1. Omit for a silent relaunch.
  --model <name>     Pass --model <name> to the relaunched claude (e.g.
                     opus, sonnet, haiku, or a full model id). Passed
                     through verbatim — no validation against a model
                     list. Omitted defaults to opus for an ordinary
                     (non-console) arm (HIMMEL-2332, ruling 30); a
                     *-console.md handover keeps the operator's default
                     model instead (ruling 25 — the console lane is
                     ALWAYS Fable). A Fable-family value (matched by
                     substring, e.g. fable, claude-fable-5) on a
                     non-console arm is refused (rc=20) unless paired
                     with --fable-ok. Not part of the dedup identity:
                     the same handover still dedupes regardless of
                     --model.
  --fable-ok <reason>
                     Justify an explicit Fable-family --model pin on a
                     non-console arm (HIMMEL-2332, ruling 30). Free
                     prose, but must not contain a double quote. Ignored
                     (no-op) when --model is absent or not Fable-family,
                     and unnecessary on a *-console.md handover, which
                     is always exempt (ruling 25).
  --provisional-base-ok
                     Arm anyway when the handover's `fence:` frontmatter
                     key names a fence scripts/console/base-status.sh
                     could not certify clean — PENDING/RED, or the
                     certification itself failed (missing script, gh
                     query error, truncated list) — (HIMMEL-2383, ruling
                     66) instead of refusing (rc=21). WARNS loudly and
                     prints the warning text on stderr — paste it into
                     the leg's first message. No-op on a handover with
                     no `fence:` key, or when the fence checks out clean.
  --wsl-distro <name>
                     Windows-host only: arm through schtasks, but relaunch
                     claude inside this WSL distro. --cwd / resume_cwd is
                     interpreted as an in-distro path.
  --force            Replace the existing same-handover HIMMEL-Resume job;
                     also bypasses the time-collision check (HIMMEL-407).
  --long-gap         Sanction a far park: an explicit --time HH:MM more than
                     60 min out (HIMMEL-1475, rc=9), OR --time smart resolving
                     to a quota-exhaustion park (HIMMEL-2113, rc=19). Default
                     REFUSES both (ALWAYS-CONTINUE: arm <=30-60 min out while
                     work remains). ARM_RESUME_SAFETY_ARM=1 is exempt from
                     both guards; smart/auto's exemption from the rc=9 guard
                     is structural (that branch never runs for them) and does
                     NOT cover smart's own rc=19 park refusal.
  --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
                     handover's: arm only if NO resume slot exists at all.
                     The safety-arm semantics the auto-arm watchdogs use so
                     a machine-wide cap can never queue duplicate relaunches.
                     Default (omitted) is per-handover dedup — N distinct
                     handovers each get their own slot (HIMMEL-340).
  --dry-run          Print what would be scheduled, touch nothing
  --list-temp-arms   Read-only sweep (HIMMEL-1365): report every armed
                     HIMMEL-Resume-* entry whose runner targets a temp/scratch
                     path, then exit (16 = hits, 0 = clean). Never deletes —
                     disable a hit instead, which is reversible. Needs neither
                     --time nor --handover.
  --automerge        Set ARMAUTOMERGE=1 and CR_MERGE_GATE_OK=1 in the
                     relaunched session's environment (HIMMEL-1382, feature
                     lineage HIMMEL-1042 armed auto-merge opt-in). Default
                     omits both vars.
  --safety-child     Set AUTO_ARM_SAFETY_CHILD=1 in the relaunched session's
                     environment (HIMMEL-812): that session is the child of an
                     auto-arm SAFETY escalation, so auto-arm-on-cap.sh's stale
                     path warns it once and does NOT arm again. Depth limit for
                     the self-sustaining +5h relaunch chain — the hook passes
                     this on its own stale arms; nothing else should.

Env:
  ARM_MAX_SLOTS           Soft cap on concurrent resume slots (default 4, 0
                          disables). Arming past it WARNs but never blocks.
  ARM_MIN_LEAD_SEC        Minimum seconds of lead a --time smart/auto SENTINEL
                          target must still have left when arming reaches the
                          scheduler (default 120, HIMMEL-1879). Below it the
                          sentinel target is pushed forward to the next whole
                          minute past the floor — arming itself can outrun a
                          4-minute ASAP slot, and a task registered at or after
                          its own fire time never fires. An explicit --time
                          HH:MM is NEVER moved: a lapsed one refuses (rc 2).
  ARM_EXPECTED_RUNTIME_SEC  Estimated own wall-clock runtime in seconds
                          (default 180, HIMMEL-2113). An explicit --time
                          closer than this plus ARM_MIN_LEAD_SEC prints an
                          early advisory WARN (not a refusal) at parse time,
                          before any slow phase runs.
  ARM_PROFILE             Exact value 1 prints a "PROFILE arm-resume: ..." line
                          to stderr on exit with per-phase wall-clock seconds
                          (usage-cache-slot-resolve, worker-census, shipped-
                          work-preflight, queue-lock-probe, arms-registry-
                          cross-host — HIMMEL-2113 Ask B). Off by default
                          (zero-cost: skips the date(1) calls entirely).
  ARM_FIXTURE_OK          Exact value 1 opts in to arming a REAL scheduler
                          entry against a temp/scratch handover or work dir
                          (HIMMEL-1365, rc 12). For a test harness arming its
                          own fixture. ARM_TEMP_CWD_OK=1 is the original
                          spelling of the same opt-in and still works.
  COLLISION_WINDOW_MINUTES Minutes on either side of another HIMMEL-* task's
                          fire time that trigger a near-collision WARN (default
                          5). An exact-minute overlap always refuses (rc=6)
                          unless --force. Set ARM_COLLISION_WINDOW in tests.
  ARM_RESUME_DOTENV_ROOT  Directory whose `.env` the two pre-arm WARN loads
                          read INSTEAD of the primary checkout's
                          (HIMMEL-2254). For a test harness that must control
                          ARMAUTOMERGE / CR_REQUIRE_CROSS_MODEL /
                          CR_FLOOR_FALLBACK: those are read from a FILE, so
                          `unset`ting them in the caller's shell does not make
                          them absent. Point this at an empty dir and every key
                          is genuinely absent. UNSET (production) leaves the
                          resolution order completely unchanged.
  ARM_RESUME_SAFETY_ARM   Internal signal (=1) marking an automated
                          machine-wide SAFETY arm (auto-arm-on-cap.sh,
                          spawn-glm cap-respawn) so the HIMMEL-1475 long-gap
                          guard exempts it. NOT a public flag — set only by the
                          in-repo automated callers in their child env.
  ARM_NAME_TEMPLATE       Template for the derived session identity
                          (HIMMEL-716). Placeholders: {ticket} (inferred key),
                          {slug} (worktree/handover name-half), {session}
                          (chain position, renders sN or empty). One template
                          drives BOTH the `claude -n` title and the scheduler
                          row's identity segment (each still sanitized for its
                          surface). Unset = the built-in ticket-first
                          composition; e.g. '{slug}' for slug-only names. A
                          template that renders empty falls back to the plain
                          HIMMEL-Resume-<path> name with no -n.
  ARM_WITH_LIVE_WORKERS   Exact value 1 bypasses the live lane-worker refusal
                          with a loud warning. The armed session exit may kill
                          those in-flight workers; wait for them by default.
                          Also downgrades a reconcile/census tool FAILURE
                          (e.g. a malformed meta.json) from a hard refusal to
                          a loud warning naming the offending path
                          (HIMMEL-1511) -- without it, that failure exits 2
                          unconditionally.
EOF
}

# Arg parsing — accept --flag <value> or --flag=<value>, any order,
# unknown flags are rejected loudly. Avoids the v1 "$3 == --force"
# positional trap.
while [ $# -gt 0 ]; do
    case "$1" in
        --time)        RESUME_TIME="${2:-}"; shift 2 ;;
        --time=*)      RESUME_TIME="${1#--time=}"; shift ;;
        --handover)    HANDOVER_PATH="${2:-}"; shift 2 ;;
        --handover=*)  HANDOVER_PATH="${1#--handover=}"; shift ;;
        --cwd)         RESUME_CWD_OVERRIDE="${2:-}"; shift 2 ;;
        --cwd=*)       RESUME_CWD_OVERRIDE="${1#--cwd=}"; shift ;;
        --worktree)    WORKTREE_BRANCH="${2:-}"; shift 2 ;;
        --worktree=*)  WORKTREE_BRANCH="${1#--worktree=}"; shift ;;
        --channels)    CHANNELS="${2:-}"; shift 2 ;;
        --channels=*)  CHANNELS="${1#--channels=}"; shift ;;
        --model)
            # Require a real value: a missing/empty value or a following
            # option (e.g. `--model --dry-run`) must error, not silently
            # consume the next flag and arm the real scheduler.
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR arm-resume: --model requires a non-empty, non-option value" >&2
                exit 2
            fi
            # cmd.exe treats " as a delimiter even through cadence_cmd_escape's
            # backslash-escaping (see the WSL wsl_command guard above), so a
            # MODEL carrying one could split the generated .bat command.
            case "$2" in
                *'"'*)
                    echo "ERR arm-resume: --model must not contain a double quote" >&2
                    exit 2
                    ;;
                *[![:graph:]]*)
                    echo "ERR arm-resume: --model must contain only printable, non-whitespace characters" >&2
                    exit 2
                    ;;
            esac
            MODEL="$2"; shift 2
            ;;
        --model=*)
            MODEL="${1#--model=}"
            if [ -z "$MODEL" ] || [ "${MODEL#-}" != "$MODEL" ]; then
                echo "ERR arm-resume: --model requires a non-empty, non-option value" >&2
                exit 2
            fi
            case "$MODEL" in
                *'"'*)
                    echo "ERR arm-resume: --model must not contain a double quote" >&2
                    exit 2
                    ;;
                *[![:graph:]]*)
                    echo "ERR arm-resume: --model must contain only printable, non-whitespace characters" >&2
                    exit 2
                    ;;
            esac
            shift
            ;;
        --wsl-distro)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "ERR arm-resume: --wsl-distro requires a non-empty value" >&2
                exit 2
            fi
            WSL_DISTRO="$2"; shift 2
            ;;
        --wsl-distro=*)
            WSL_DISTRO="${1#--wsl-distro=}"
            if [ -z "$WSL_DISTRO" ]; then
                echo "ERR arm-resume: --wsl-distro requires a non-empty value" >&2
                exit 2
            fi
            shift
            ;;
        --fable-ok)
            # HIMMEL-2332: justifies an explicit Fable-family --model pin on
            # a non-console arm (ruling 30). Same missing/empty/option-value
            # shape as --model above.
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR arm-resume: --fable-ok requires a non-empty, non-option value" >&2
                exit 2
            fi
            # Same cmd.exe-delimiter reason as the --model double-quote
            # guard above — a reason carrying " could split the generated
            # .bat command if it is ever echoed there.
            case "$2" in
                *'"'*)
                    echo "ERR arm-resume: --fable-ok must not contain a double quote" >&2
                    exit 2
                    ;;
                # Free prose, so spaces are fine ([:print:] includes them) --
                # but the reason is ECHOED into the guard line and the closing
                # arm banner, so a newline or control character in it could
                # forge or corrupt a banner line an operator reads as ours.
                # Constrain it to ONE printable line (panel [codex-3]).
                *[![:print:]]*)
                    echo "ERR arm-resume: --fable-ok must be a single printable line (no newlines or control characters)" >&2
                    exit 2
                    ;;
            esac
            FABLE_OK="$2"; shift 2
            ;;
        --fable-ok=*)
            FABLE_OK="${1#--fable-ok=}"
            if [ -z "$FABLE_OK" ] || [ "${FABLE_OK#-}" != "$FABLE_OK" ]; then
                echo "ERR arm-resume: --fable-ok requires a non-empty, non-option value" >&2
                exit 2
            fi
            case "$FABLE_OK" in
                *'"'*)
                    echo "ERR arm-resume: --fable-ok must not contain a double quote" >&2
                    exit 2
                    ;;
                # Twin of the --fable-ok <value> guard above (panel [codex-3]).
                *[![:print:]]*)
                    echo "ERR arm-resume: --fable-ok must be a single printable line (no newlines or control characters)" >&2
                    exit 2
                    ;;
            esac
            shift
            ;;
        --force)       FORCE=1; shift ;;
        --long-gap)    LONG_GAP=1; shift ;;
        --dedup-any)   DEDUP_ANY=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --automerge)   AUTOMERGE=1; shift ;;
        --safety-child) SAFETY_CHILD=1; shift ;;
        --list-temp-arms) LIST_TEMP_ARMS=1; shift ;;
        --provisional-base-ok) PROVISIONAL_BASE_OK=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "ERR arm-resume: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -n "$WSL_DISTRO" ] && ! [[ "$WSL_DISTRO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERR arm-resume: invalid --wsl-distro name: $WSL_DISTRO" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# HIMMEL-1365 -- temp/scratch-path detection.
#
# Defined HERE (right after the arg loop) rather than beside its arming-path
# caller further down, because --list-temp-arms is a READ-ONLY sweep that must
# answer without --time/--handover and without running any of the arming
# preamble (worker census, handover parse, queue lock). One definition, two
# callers: the refusal below and the sweep here.
_arm_is_temp_path() { # <path> -> rc 0 when it lives under a temp/scratch root
    local _p="$1" _root
    [ -n "$_p" ] || return 1
    # Lowercase + forward slashes so Windows drive-letter and backslash forms
    # compare the same as the MSYS view of the same directory.
    _p="${_p//\\//}"
    _p=$(printf '%s' "$_p" | tr '[:upper:]' '[:lower:]')
    case "$_p" in
        # Each root matches BOTH as a prefix and as the exact path (r6 round).
        # `/tmp` already carried its bare form; `/var/tmp` and `/var/folders`
        # did not, so arming with either as the literal target slipped past a
        # guard that catches every directory beneath them -- the same
        # root-itself gap the r1 round closed for the $TMPDIR loop below.
        /tmp/*|/tmp|/var/tmp/*|/var/tmp|/var/folders/*|/var/folders) return 0 ;;
        # HIMMEL-1999 item 3: the bare root too, not only its descendants. An
        # exact `…/AppData/Local/Temp` that belongs to ANOTHER user -- or that
        # this shell's TEMP/TMPDIR does not mirror, so the loop below misses it
        # -- is the same throwaway target as a directory inside it.
        */appdata/local/temp/*|*/appdata/local/temp) return 0 ;;
        */scratchpad/*|*/scratchpad) return 0 ;;
    esac
    # Whatever THIS shell calls temp, too -- covers a relocated TMPDIR.
    for _root in "${TMPDIR:-}" "${TEMP:-}" "${TMP:-}"; do
        [ -n "$_root" ] || continue
        _root="${_root//\\//}"
        _root=$(printf '%s' "$_root" | tr '[:upper:]' '[:lower:]')
        _root="${_root%/}"
        # The ROOT ITSELF counts, not just its children (codex-1): the literal
        # list above already pairs `/tmp/*` with `/tmp`, and arming with the cwd
        # set to exactly $TMPDIR is the same throwaway-target shape as arming one
        # directory below it.
        case "$_p" in "$_root"|"$_root"/*) return 0 ;; esac
    done
    return 1
}

# --list-temp-arms (HIMMEL-1365 sweep half): REPORT, never delete, every armed
# HIMMEL-Resume-* entry whose runner targets a temp/scratch path. Deletion stays
# an operator decision -- the incident response was `Disable-ScheduledTask`
# precisely because it is reversible and preserves the artifact.
# Exit 0 = nothing suspect, 16 = at least one temp-targeted arm reported.
if [ "${LIST_TEMP_ARMS:-0}" -eq 1 ]; then
    _lta_hits=0
    _lta_degraded=0
    # The five XML predefined entities; &amp; last so it cannot re-introduce one.
    _lta_unxml() { # <text> -> the same text with entities decoded
        printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g'
    }
    _lta_report() { # <entry-label> <runner-path-or-empty> <body-text>
        local _label="$1" _runner="$2" _body="$3" _p _bad=""
        # The two paths a fired arm actually enters: the cd target and the
        # handover the resume prompt loads.
        #
        # Every runner shape spells its `cd` differently, and a sweep that
        # UNDER-reports is the failure that matters (codex-1, r2 round):
        #   - Windows .bat:  cd /d "C:\...\work"
        #   - `at` body:     cd '/path' || exit 1     (LINE-LEADING, single-quoted
        #                    by _bash_single_quote -- a capture that keeps the
        #                    quotes compares "'/tmp/x'" against /tmp/* and MISSES)
        #   - crontab:       ...| crontab -; cd /path && { ... }   (ONE line, the
        #                    cd is MID-line, so a `^cd` anchor never sees it)
        # So: one unanchored pattern per quoting style, plus the strip pass below.
        # A stray extra candidate (`/d`, a bare token) is harmless -- it simply
        # is not a temp path -- while a missed one is a false clean.
        while IFS= read -r _p; do
            [ -n "$_p" ] || continue
            _p="${_p#\'}"; _p="${_p%\'}"
            _p="${_p#\"}"; _p="${_p%\"}"
            _p="${_p//\\ / }"   # crontab paths go through printf %q ("\ " space)
            if _arm_is_temp_path "$_p"; then _bad="${_bad}
      target: $_p"; fi
        done <<EOF
$(printf '%s\n' "$_body" | sed -n 's/.*cd \/d "\([^"]*\)".*/\1/p')
$(printf '%s\n' "$_body" | sed -n "s/.*cd '\([^']*\)'.*/\1/p")
$(printf '%s\n' "$_body" | sed -n 's/.*cd "\([^"]*\)".*/\1/p')
$(printf '%s\n' "$_body" | sed -n 's/.*cd \([^ ;&|]*\).*/\1/p')
$(printf '%s\n' "$_body" | sed -n 's/.*"load \([^"]*\) overnight mode.*/\1/p')
$(printf '%s\n' "$_body" | sed -n "s/.*load \([^ ']*\) overnight mode.*/\1/p")
EOF
        if [ -n "$_bad" ]; then
            _lta_hits=$((_lta_hits + 1))
            echo "  TEMP-ARM  $_label${_runner:+  (runner: $_runner)}$_bad"
        fi
    }
    echo "arm-resume --list-temp-arms: armed HIMMEL-Resume-* entries targeting a temp/scratch path"
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*)
            while IFS= read -r _lta_name; do
                [ -n "$_lta_name" ] || continue
                # HIMMEL-1998: read the runner out of the task's XML, not out
                # of `/fo LIST /v`. That listing's "Task To Run:" label is
                # LOCALIZED -- on a non-English Windows the sed matches
                # nothing, the runner path comes back EMPTY, and a
                # temp-targeted arm sweeps CLEAN, which is the wrong direction
                # for a safety sweep (the same locale class the /sd render
                # tracks as _locale_degraded). The XML element names come from
                # the Task Scheduler schema and never translate.
                _lta_v=$(MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /query /tn "$_lta_name" /xml ONE 2>/dev/null) || _lta_v=""
                # `/xml` declares UTF-16 but writes the console codepage down a
                # pipe; \r is the only thing that needs stripping here.
                _lta_v=$(printf '%s\n' "$_lta_v" | tr -d '\r')
                _lta_cmd=$(printf '%s\n' "$_lta_v" | sed -n 's|.*<Command>\(.*\)</Command>.*|\1|p' | head -1)
                _lta_args=$(printf '%s\n' "$_lta_v" | sed -n 's|.*<Arguments>\(.*\)</Arguments>.*|\1|p' | head -1)
                # Entities are decoded AFTER the elements are located (panel r2
                # codex-2): decoding the whole document first would let an
                # `&lt;Command&gt;…` sitting inside an <Arguments> body
                # materialise a second tag-shaped match and steer the
                # extraction away from the real runner.
                _lta_cmd=$(_lta_unxml "$_lta_cmd")
                _lta_args=$(_lta_unxml "$_lta_args")
                _lta_run="$_lta_cmd${_lta_args:+ $_lta_args}"
                if [ -z "$_lta_cmd" ]; then
                    # Never skip the entry (`continue` here was a silent clean):
                    # an unreadable task still gets its name swept below, and
                    # the operator is told the inspection was degraded.
                    _lta_degraded=$((_lta_degraded + 1))
                    echo "  UNREADABLE  $_lta_name  (schtasks /query /xml returned no <Command> -- swept by task name only)"
                fi
                _lta_bat=$(printf '%s' "$_lta_cmd" | tr -d '"')
                _lta_body=""
                # cygpath the win path back to the MSYS view so we can read it.
                if command -v cygpath >/dev/null 2>&1 && [ -n "$_lta_bat" ]; then
                    _lta_bat=$(cygpath -u "$_lta_bat" 2>/dev/null || printf '%s' "$_lta_bat")
                fi
                [ -f "$_lta_bat" ] && _lta_body=$(tr -d '\r' < "$_lta_bat")
                if [ -z "$_lta_body" ]; then
                    # A missing .bat is itself worth reporting when the TASK NAME
                    # carries the scratchpad stem (the 2026-07 incident shape).
                    _lta_body="cd /d \"$(printf '%s' "$_lta_name" | tr '_' '/')\""
                fi
                _lta_report "$_lta_name" "$_lta_run" "$_lta_body"
            done <<EOF
$(MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /query /fo CSV /nh 2>/dev/null | grep -o '"\\\?HIMMEL-Resume-[^"]*"' | sed 's/["\\]//g' | sort -u)
EOF
            ;;
        *)
            if command -v atq >/dev/null 2>&1; then
                while IFS= read -r _lta_line; do
                    [ -n "$_lta_line" ] || continue
                    _lta_id=$(printf '%s' "$_lta_line" | awk '{print $1}')
                    [ -n "$_lta_id" ] || continue
                    _lta_body=$(at -c "$_lta_id" 2>/dev/null) || continue
                    case "$_lta_body" in *HIMMEL-Resume-*) ;; *) continue ;; esac
                    _lta_report "at-job-$_lta_id" "" "$_lta_body"
                done <<EOF
$(atq 2>/dev/null)
EOF
            fi
            if command -v crontab >/dev/null 2>&1; then
                while IFS= read -r _lta_line; do
                    case "$_lta_line" in *HIMMEL-Resume-*) ;; *) continue ;; esac
                    _lta_report "crontab: ${_lta_line%% *}..." "" "$_lta_line"
                done <<EOF
$(crontab -l 2>/dev/null)
EOF
            fi
            ;;
    esac
    if [ "$_lta_hits" -eq 0 ]; then
        if [ "$_lta_degraded" -gt 0 ]; then
            # "No hits" is only a clean bill of health when every entry was
            # actually readable (HIMMEL-1998). Its OWN exit code, not 0: a
            # machine caller reads the status, not the warning text, and rc 0
            # is this sweep's documented "nothing suspect" answer.
            echo "  no temp-targeted arm found, but $_lta_degraded entry/entries could not be inspected — NOT a clean sweep; re-run where schtasks can read them"
            exit 18
        else
            echo "  none — no armed resume entry targets a temp/scratch path"
        fi
        exit 0
    fi
    echo ""
    if [ "$_lta_degraded" -gt 0 ]; then
        # 16 outranks 18 (panel r2 codex-1): a found hit is the actionable
        # answer, and downgrading it to "could not inspect" would bury it. The
        # degraded count still has to be SAID, or this report reads as complete.
        echo "  ...and $_lta_degraded further entry/entries could not be inspected at all — this sweep is NOT exhaustive."
    fi
    echo "  $_lta_hits temp-targeted arm(s). REPORT ONLY — nothing was changed."
    echo "  Disable (reversible, preserves the artifact) rather than delete:"
    echo "      Disable-ScheduledTask -TaskName '<name>'      # Windows"
    echo "      at -r <job-id>   /   crontab -e               # POSIX"
    exit 16
fi

if [ -z "$RESUME_TIME" ] || [ -z "$HANDOVER_PATH" ]; then
    echo "ERR arm-resume: --time and --handover are required" >&2
    usage >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# HIMMEL-2332 -- Fable-tier arm guard. Operator ruling 30: "we shouldn't arm
# fable unless theres a good reason" / "make sure this is STRUCTURAL
# otherwise it won't work". The --model passthrough (HIMMEL-2192) is opt-in,
# so an arm that omits it relaunches on the operator's default model, which
# is the Fable tier -- expensive. Two worker legs got armed unpinned on
# 2026-08-31 and landed on Fable parents where Opus was right.
#
# Placed HERE, deliberately: right after the required-args check and before
# SCRIPT_DIR/py-armor sourcing, so it fires before any scheduler work (cwd
# resolution, dedup query, worker census, ...) starts, and so --dry-run
# (which exits much later, at the DRY_RUN check right after schedule_arm)
# still exercises it -- MODEL is set before that .bat/schtasks-args content
# is ever composed, so all four --model consumption sites downstream inherit
# the default/refusal for free without themselves changing.
#
# Ruling 25 exempts the CONSOLE lane, which is ALWAYS Fable: a console arm
# (handover basename *-console.md, case-insensitive) must stay
# ceremony-free -- neither defaulted to opus nor required to justify a Fable
# pin. Computed from the raw --handover path as typed; the file-existence
# check happens later, so no canonicalization dependency is needed here.
_arm_is_console=0
case "$(basename -- "$HANDOVER_PATH" | tr '[:upper:]' '[:lower:]')" in
    *-console.md) _arm_is_console=1 ;;
esac

# Fable-FAMILY match, not a literal string -- fable, fable-5, claude-fable-5,
# Claude-Fable-5 all match. A plain `case` glob on a lowercased form, same
# idiom the rest of this script uses (no `[[ ... ]]` regex).
_arm_model_is_fable=0
if [ -n "$MODEL" ]; then
    case "$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')" in
        *fable*) _arm_model_is_fable=1 ;;
    esac
fi

MODEL_REASON=""
if [ -n "$MODEL" ] && [ "$_arm_model_is_fable" -eq 1 ] && [ "$_arm_is_console" -eq 0 ] && [ -z "$FABLE_OK" ]; then
    # rc 0-19 are already taken by this script (see the Exit codes table
    # near the top of the file) -- 20 is the first free code.
    echo "ERR arm-resume: --model $MODEL is Fable-family, and ruling 30 (\"we shouldn't arm fable unless theres a good reason\") refuses arming it unjustified. Pass --fable-ok \"<reason>\" to arm it anyway, or drop --model to get the opus default. *-console.md handovers are exempt (ruling 25 -- the console lane is ALWAYS Fable)." >&2
    exit 20
elif [ -n "$MODEL" ] && [ "$_arm_model_is_fable" -eq 1 ] && [ "$_arm_is_console" -eq 1 ]; then
    MODEL_REASON="model=$MODEL (fable pinned; console arm -- ruling 25, exempt)"
elif [ -n "$MODEL" ] && [ "$_arm_model_is_fable" -eq 1 ]; then
    MODEL_REASON="model=$MODEL (fable pinned; reason: $FABLE_OK)"
elif [ -z "$MODEL" ] && [ "$_arm_is_console" -eq 0 ]; then
    MODEL="opus"
    MODEL_REASON="model=opus (no --model given; non-console arms default to opus -- ruling 30)"
elif [ -z "$MODEL" ] && [ "$_arm_is_console" -eq 1 ]; then
    MODEL_REASON="model=<operator default> (console arm, unpinned -- ruling 25 keeps the fable default)"
else
    # Explicit non-Fable pin (or a harmless --fable-ok on a non-Fable/absent
    # pin, which is belt-and-braces and needs no warning here).
    MODEL_REASON="model=$MODEL (explicitly pinned)"
fi
# Printed at guard time, not only in the closing banner (REQUIRED: --dry-run
# exits before the banner, and the tests inspect the dry-run output). stdout,
# not stderr -- this is a report, not an error.
echo "arm-resume: $MODEL_REASON"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe). The auto-arm-on-cap
# watchdog calls this script, so the armor chain is only as strong as the
# weakest python call here — every one goes through the shared armor.
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/py-armor.sh"

# HIMMEL-2113 Ask B: opt-in phase timing. ARM_PROFILE=1 wraps the slow phases
# (usage-cache/slot resolve, worker census, queue-lock probe, arms-registry
# cross-host check, shipped-work preflight) with wall-clock second markers and
# prints one summary line at the end -- zero-cost by default (the ARM_PROFILE
# guard skips every date(1) call when off, matching the existing fail-open
# telemetry/handover_root sourcing pattern below).
ARM_PROFILE="${ARM_PROFILE:-0}"
_ARM_PROFILE_LOG=()
# HIMMEL-2125: the currently-open phase (set by _arm_phase_t0, cleared by
# _arm_phase_done). A refusal/exit INSIDE a phase -- worker-census, queue-lock,
# arms-registry -- used to leave _ARM_PROFILE_LOG with no entry at all for that
# phase, since _arm_phase_done only ever ran on the RETURN path; the profile
# line then named every phase except the one that actually burned the time.
_ARM_PROFILE_CUR_LABEL=""
_ARM_PT0=0
# _arm_phase_t0 <label> -- opens a profiled phase, setting BOTH the start epoch
# ($_ARM_PT0) and the in-flight label directly in the CALLER's shell.
#
# Call it as a bare statement -- NEVER as `_arm_pt0=$(_arm_phase_t0 label)`.
# A command substitution runs in a SUBSHELL, so a label assigned in there is
# discarded the instant it returns, leaving $_ARM_PROFILE_CUR_LABEL empty in
# the parent and the EXIT trap with nothing to report. That is exactly how the
# first cut of this marker managed to look correct and do nothing.
_arm_phase_t0() {
    _ARM_PROFILE_CUR_LABEL=""
    _ARM_PT0=0
    [ "$ARM_PROFILE" = "1" ] || return 0
    _ARM_PROFILE_CUR_LABEL="${1:-}"
    _ARM_PT0=$(date +%s)
}
_arm_phase_done() {
    [ "$ARM_PROFILE" = "1" ] || return 0
    local _label="$1" _t0="${2:-$_ARM_PT0}"
    _ARM_PROFILE_LOG+=("$_label=$(( $(date +%s) - _t0 ))s")
    _ARM_PROFILE_CUR_LABEL=""
}
# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
_arm_profile_report() {
    # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
    [ "$ARM_PROFILE" = "1" ] || return 0
    # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
    if [ -n "$_ARM_PROFILE_CUR_LABEL" ]; then
        _ARM_PROFILE_LOG+=("${_ARM_PROFILE_CUR_LABEL}=inflight")
    fi
    # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
    [ "${#_ARM_PROFILE_LOG[@]}" -gt 0 ] || return 0
    # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
    echo "PROFILE arm-resume: ${_ARM_PROFILE_LOG[*]}" >&2
}
# On an EXIT trap so a REFUSAL (rc=7/9/11/13/19/...) still emits the timings --
# those are exactly the paths where "which phase burned the time" matters most,
# and the two hand-picked print sites this replaced only fired on the two
# success exits. The worker-census block below (DRY_RUN=0) registers its OWN
# EXIT trap (bash allows only one) -- it chains to this same function rather
# than clobbering it, so both cleanups still run post-census.
trap _arm_profile_report EXIT

# CodeRabbit #1911 (security): a stderr capture at a PREDICTABLE path
# (/tmp/arm-resume.<label>.$$) lets a local process pre-create a symlink there
# before bash opens the redirect, retargeting our own error capture onto a
# caller-writable file. mktemp's random suffix closes that -- same fail-closed
# contract as _arm_worker_stderr_file below (empty/missing result refuses,
# never silently continues without a capture file).
_arm_mktemp_or_fail() {
    local _label="$1" _t
    _t=$(mktemp "${TMPDIR:-/tmp}/arm-resume.${_label}.XXXXXX") || _t=""
    [ -n "$_t" ] && [ -f "$_t" ] || return 1
    printf '%s\n' "$_t"
}

# Resolve the requested slot to an absolute epoch (TARGET_EPOCH). Three forms:
#   smart  — usage-aware: ASAP when the bank is free, else the binding window's
#            reset (resume-slot.sh, HIMMEL-204). Operator no longer has to
#            guess AND we don't park hours away when quota is available.
#   auto   — next 5-hour cap reset regardless of headroom (cap-reset-time.sh,
#            HIMMEL-126). Kept for "explicitly wait for the reset".
#   HH:MM  — explicit local clock time; today if still future, else tomorrow.
TARGET_EPOCH=""
# HIMMEL-1879 part 1: wall-clock at the moment slot resolution starts. The
# smart/ASAP slot is "now + 4 min" measured HERE, but everything between here
# and schtasks /create -- the worker census, the shipped-work preflight's two
# NETWORK probes, the queue lock, the collision scan, worktree creation -- can
# take longer than that lead. The task then registers already-expired and the
# HIMMEL-938 verify deletes it: net zero arms. _ARM_SENTINEL marks the arms
# whose target is a SYSTEM-computed "as soon as practical" (smart/auto), which
# may therefore be moved forward; an explicit HH:MM is an operator's clock
# choice and is never silently moved (a lapsed one exits 2 loudly instead).
_ARM_START_EPOCH=$(date +%s)
# The same instant in the exact wire format the flow-run ledger stamps its rows
# with (`date -u +%Y-%m-%dT%H:%M:%SZ`). Captured rather than converted so the
# fired-evidence check below can compare LEXICOGRAPHICALLY -- that format is
# fixed-width UTC, so string order IS time order, and no epoch<->ISO conversion
# (python, GNU `date -d`) is needed on the arm's hot path.
_ARM_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_ARM_SENTINEL=0
case "$RESUME_TIME" in
    smart)
        # --max-age 3600: arming runs at session END, when the statusline may
        # not have re-rendered for several minutes, so tolerate older usage
        # data than a live render would. The 5-hour / 7-day windows move
        # slowly; an hour-old reading is still a sound ASAP-vs-wait signal. A
        # genuinely abandoned cache (>1h) still errors out. SLOT_MAX_AGE
        # overrides for tests / tighter freshness; RESUME_SLOT_CACHE injects a
        # fixture cache (test seam — keeps the smart path end-to-end testable).
        # The THRESHOLD is deliberately NOT in _slot_args (HIMMEL-1271):
        # resume-slot.sh runs as a plain child of this process, so a
        # RESUME_SLOT_THRESHOLD set in the environment already reaches it —
        # including down the auto-arm-on-cap.sh -> arm-resume -> resume-slot
        # chain. Forwarding it as a flag would be a redundant second copy of
        # the same knob (and a second place for its default to drift).
        _slot_args=(--max-age "${SLOT_MAX_AGE:-3600}")
        [ -n "${RESUME_SLOT_CACHE:-}" ] && _slot_args+=(--cache "$RESUME_SLOT_CACHE")
        # One --emit all call (epoch<TAB>hhmm<TAB>reason) — avoids a second,
        # independent read of a ~60s-rewritten cache that could disagree with
        # the chosen epoch. set +e so we can relay resume-slot's own ERR.
        _arm_phase_t0 "usage-cache-slot-resolve"
        _slot_err=$(_arm_mktemp_or_fail slot-err) || {
            echo "ERR arm-resume: --time smart could not resolve a slot: mktemp failed for the stderr capture file" >&2
            exit 1
        }
        set +e
        _slot_out=$(bash "$SCRIPT_DIR/resume-slot.sh" "${_slot_args[@]}" --emit all 2>"$_slot_err")
        _slot_rc=$?
        set -e
        _arm_phase_done "usage-cache-slot-resolve" "$_ARM_PT0"
        if [ "$_slot_rc" -ne 0 ]; then
            echo "ERR arm-resume: --time smart could not resolve a slot:" >&2
            sed 's/^/    /' "$_slot_err" >&2
            rm -f "$_slot_err"
            echo "    Pass --time HH:MM manually, or open Claude Code once to refresh" >&2
            echo "    the statusline usage cache, then retry --time smart." >&2
            exit 1
        fi
        # HIMMEL-1968: a SUCCESSFUL resolve used to discard resume-slot's stderr,
        # so its near-wall WARN (ASAP into a >=85% window under a raised
        # threshold) never reached the operator. Relay it, then drop the file.
        if [ -s "$_slot_err" ]; then
            sed 's/^/    /' "$_slot_err" >&2
        fi
        rm -f "$_slot_err"
        TARGET_EPOCH=$(printf '%s' "$_slot_out" | cut -f1)
        _reason=$(printf '%s' "$_slot_out" | cut -f3-)
        echo "arm-resume: --time smart -> $(_epoch_hhmm "$TARGET_EPOCH") (${_reason:-usage-aware})"
        _ARM_SENTINEL=1
        # HIMMEL-2113 Ask A: fail FAST and LOUD on a multi-hour quota-exhaustion
        # park, BEFORE the worker census / cache-dir GC / queue-lock / shipped-
        # work preflight below spend minutes discovering it anyway (the exact
        # incident shape: several minutes of census ending in a silently-chosen
        # 7-day wait). "smart" only ever resolves to ASAP (+buffer, a few
        # minutes out) or a wait-for-reset park, so a >1h gap here IS a park,
        # no reason-string match needed. Reuses the existing >3600s ALWAYS-
        # CONTINUE threshold and its --long-gap override (the explicit-HH:MM
        # long-gap guard, below) -- same semantics, same flag, one less thing
        # to document. `auto` is exempt (see its own branch): it is documented
        # to always park at the next cap reset, so parking there is expected,
        # not a surprise. ARM_RESUME_SAFETY_ARM=1 is exempt for the same reason
        # the long-gap guard exempts it -- a machine-wide SAFETY arm at a
        # multi-hour cap reset is an automated escalation, not an operator
        # choice it could reconsider.
        _arm_park_gap=$(( TARGET_EPOCH - $(date +%s) ))
        if [ "$_arm_park_gap" -gt 3600 ] && [ "$LONG_GAP" -eq 0 ] && [ "${ARM_RESUME_SAFETY_ARM:-}" != "1" ]; then
            _apgh=$(( _arm_park_gap / 3600 )); _apgm=$(( (_arm_park_gap % 3600) / 60 ))
            {
                echo "ERR arm-resume: --time smart would park ${_apgh}h${_apgm}m out at $(_epoch_hhmm "$TARGET_EPOCH") (${_reason:-usage-aware}) -- refusing now instead of burning minutes on the worker census first (rc=19)."
                echo "    Choices: pass --time HH:MM to arm a specific slot anyway, or --long-gap to accept this park."
            } >&2
            exit 19
        fi
        unset _arm_park_gap
        ;;
    auto)
        _arm_phase_t0 "usage-cache-slot-resolve"
        _cap_err=$(_arm_mktemp_or_fail cap-err) || {
            echo "ERR arm-resume: --time auto could not resolve cap-reset: mktemp failed for the stderr capture file" >&2
            exit 1
        }
        if ! TARGET_EPOCH=$(bash "$SCRIPT_DIR/cap-reset-time.sh" --epoch 2>"$_cap_err"); then
            # codex-2: record the in-flight phase BEFORE this exit -- the old
            # order only called _arm_phase_done on the success fallthrough
            # below, so a failed cap-reset-time.sh (the exact case here) left
            # ARM_PROFILE=1 with no usage-cache-slot-resolve timing at all.
            _arm_phase_done "usage-cache-slot-resolve" "$_ARM_PT0"
            echo "ERR arm-resume: --time auto could not resolve cap-reset:" >&2
            sed 's/^/    /' "$_cap_err" >&2
            rm -f "$_cap_err"
            echo "    Pass --time HH:MM manually, or open Claude Code once to refresh" >&2
            echo "    the statusline usage cache, then retry --time auto." >&2
            exit 1
        fi
        rm -f "$_cap_err"
        _arm_phase_done "usage-cache-slot-resolve" "$_ARM_PT0"
        echo "arm-resume: --time auto -> $(_epoch_hhmm "$TARGET_EPOCH") (next cap reset)"
        _ARM_SENTINEL=1
        ;;
    *)
        if ! [[ "$RESUME_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            echo "ERR arm-resume: --time must be HH:MM (24h), 'smart', or 'auto', got: $RESUME_TIME" >&2
            exit 1
        fi
        # HIMMEL-708: emit the epoch AND the three schedule fields the derive
        # block below would otherwise compute in a SECOND python round-trip.
        # For the common explicit-HH:MM path this collapses two py_armor calls
        # (each ~4 helper spawns: 2 mktemp + interpreter + 2 rm) into one.
        # `cand` is already local (astimezone), so its strftime fields equal
        # what fromtimestamp(epoch).astimezone() yields in the derive block.
        py_armor_capture -c '
import sys
from datetime import datetime, timedelta
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
rolled = 0
if cand <= now:          # time already passed today -> tomorrow
    cand += timedelta(days=1)
    rolled = 1
# 6th field (rolled, 0/1) drives the HIMMEL-1674 Part B loud-roll WARN below.
print(int(cand.timestamp()), cand.strftime("%H:%M"), cand.strftime("%m/%d/%Y"), cand.strftime("%Y%m%d%H%M"), int((cand - now).total_seconds()), rolled)
' "$RESUME_TIME" || {
            echo "ERR arm-resume: could not resolve --time $RESUME_TIME to an epoch (python3 failed/timed out)" >&2
            exit 2
        }
        # 5th field is the gap in RAW SECONDS (HIMMEL-1475 CR-fix): a floored-
        # to-minutes value made 60m01s-60m59s read as 60 and slip past a
        # >60min check. The guard compares gap_sec > 3600 directly.
        read -r TARGET_EPOCH RESUME_TIME START_DATE AT_STAMP _GAP_SEC _ROLLED <<<"$PY_ARMOR_OUT"
        _SCHED_FIELDS_DERIVED=1
        # HIMMEL-2113 Ask D: outrun warning for an EXPLICIT --time, printed
        # IMMEDIATELY (before any slow phase -- worker census, cache-dir GC,
        # queue-lock, the shipped-work preflight's network probes). The
        # elapsed-aware lead-floor bump below (search HIMMEL-1879) only moves
        # smart/auto SENTINEL targets -- an explicit HH:MM is an operator's
        # clock choice and is never silently moved, so today the only "this
        # target is too close" signal for it is the post-arm verify, which
        # fires AFTER every slow phase already burned the wall-clock. This is
        # purely advisory (a WARN, not a refusal) -- the authoritative check
        # stays the end-of-script rollover guard; this just surfaces the risk
        # at parse time instead of after the fact.
        _arm_expected_runtime=${ARM_EXPECTED_RUNTIME_SEC:-180}
        case "$_arm_expected_runtime" in ''|*[!0-9]*) _arm_expected_runtime=180 ;; esac
        _arm_lead_floor=${ARM_MIN_LEAD_SEC:-120}
        case "$_arm_lead_floor" in ''|*[!0-9]*) _arm_lead_floor=120 ;; esac
        # codex-1: the digit check above accepts a leading-zero value (e.g.
        # "0180"), which bash arithmetic then reads as OCTAL and aborts under
        # set -e ("value too great for base") the moment a digit 8/9 appears.
        # 10# forces base-10 on both operands regardless of leading zeros.
        if [ "${_GAP_SEC:-0}" -lt $(( 10#$_arm_expected_runtime + 10#$_arm_lead_floor )) ]; then
            echo "WARN arm-resume: --time $RESUME_TIME is only ${_GAP_SEC}s away; this script's own runtime (~${_arm_expected_runtime}s, ARM_EXPECTED_RUNTIME_SEC) plus the ${_arm_lead_floor}s lead floor (ARM_MIN_LEAD_SEC) can outrun that lead and roll the arm to tomorrow -- pick a later --time or accept the risk (a lapsed target still refuses loudly at the end, HIMMEL-1879)." >&2
        fi
        unset _arm_expected_runtime _arm_lead_floor
        # HIMMEL-1674 Part B: a past HH:MM silently rolled to tomorrow above.
        # Surface it LOUDLY when the roll is a FAR park (gap > 3600s -- the same
        # threshold the long-gap guard below uses): that is the "resume in 10
        # minutes silently became resume in 24 hours" accident class. A NEAR roll
        # (< 60 min, the intentional midnight-crossing case: arm 00:10 at 23:50)
        # stays silent -- the success banner already shows tomorrow's date for it.
        # The mid-run target-lapse race (target still future at derivation but
        # past by /create time) is a separate path, already closed by the
        # HIMMEL-938 post-arm NextRunTime verify (create-after-target -> exit 2).
        if [ "${_ROLLED:-0}" = "1" ] && [ "${_GAP_SEC:-0}" -gt 3600 ]; then
            _rgh=$(( _GAP_SEC / 3600 )); _rgm=$(( (_GAP_SEC % 3600) / 60 ))
            echo "WARN arm-resume: --time $RESUME_TIME was already past for today -- rolled the arm to TOMORROW $RESUME_TIME ($START_DATE, ~${_rgh}h${_rgm}m out). A lapsed target silently becomes a 24h wait; if that was not intended, pick a later --time and re-arm." >&2
            unset _rgh _rgm
        fi
        # HIMMEL-1475 long-gap guard. An explicit HH:MM work arm parked more
        # than 60 min out is a deliberate choice, not a default: the
        # ALWAYS-CONTINUE directive says an orchestrator leg should arm
        # <=30-60 min out while work remains (the original failure was a leg
        # parking the chain 4 HOURS on operator-blocked items while
        # independent work sat idle). Refuse (rc=9) unless the operator owns
        # the choice with --long-gap (mirrors the --force dedup override).
        # The gap is compared in RAW SECONDS (>3600), not floored minutes: a
        # //60 floor made 60m01s-60m59s read as 60 and slip past a >60 check.
        #
        # EXEMPT — these are NOT explicit work-arm choices, so the guard does
        # not target them:
        #   * ARM_RESUME_SAFETY_ARM=1 marks an automated machine-wide SAFETY
        #     arm (auto-arm-on-cap.sh's stale-cache escalation + spawn-glm's
        #     cap-respawn both set it in their child env; those callers arm at
        #     a multi-hour cap reset and cannot pass --long-gap). This is a
        #     dedicated internal signal, NOT a public flag: --dedup-any is a
        #     dedup-scope knob any caller can add, so it must NOT bypass the
        #     guard (a far arm with only --dedup-any is still refused — LG5b).
        #   * smart/auto are system-computed sentinels resolved in their own
        #     branches above and never reach this HH:MM arm.
        # Only an explicit per-handover work arm (the orchestrator's
        # --time HH:MM) is guarded.
        # The exemption is an EXACT string compare on literal "1" (CR-fix):
        # a numeric `-ne 1` treats a non-numeric ambient value (e.g. "yes",
        # "true", garbage) as a FAILED expression whose non-zero return makes
        # the whole && chain false and SKIPS the refusal — the guard silently
        # drops. Anything other than the literal "1" (unset, "0", junk) → the
        # guard applies. See also the launch-body unset that prevents this var
        # leaking into a resumed session (HIMMEL-1475).
        if [ "${_GAP_SEC:-0}" -gt 3600 ] && [ "$LONG_GAP" -eq 0 ] && [ "${ARM_RESUME_SAFETY_ARM:-}" != "1" ]; then
            _gh=$(( _GAP_SEC / 3600 )); _gm=$(( (_GAP_SEC % 3600) / 60 ))
            {
                # HIMMEL-2147: when this refusal was CAUSED by a past-time
                # rollover (the requested HH:MM had already passed today, so
                # the HIMMEL-1674 Part B block above silently retargeted it to
                # tomorrow), say so up front -- otherwise the refusal reads as
                # a generic "queue not empty?" nag with no visible link back to
                # the WARN a few lines above it, and a retry that just re-passes
                # the same now-further-past --time repeats the same confusing
                # refusal.
                #
                # HIMMEL-2247: this rollover line PREFIXES the WARN, it does
                # not replace it. As an `else` it silently dropped the
                # ALWAYS-CONTINUE citation (and the "is the queue actually
                # empty?" prompt) from EVERY rolled far arm -- and a rolled
                # arm is the worst case for the guardrail, not an exempt one:
                # it is a ~24h park. The directive citation is the whole
                # point of the refusal, so it is emitted unconditionally.
                if [ "${_ROLLED:-0}" = "1" ]; then
                    echo "ERR arm-resume: requested time was already past for today -- rolled to tomorrow $RESUME_TIME ($START_DATE), ${_gh}h${_gm}m out."
                fi
                echo "WARN arm-resume: arming ${_gh}h${_gm}m out ($RESUME_TIME) — is the queue actually empty? ALWAYS-CONTINUE directive says arm <=30-60 min while work remains."
                echo "    Refusing without --long-gap (rc=9). A longer park is fine for an overnight/idle"
                echo "    wait but must be an explicit choice — re-run with --long-gap, or pick a nearer (still-future) --time."
            } >&2
            exit 9
        fi
        ;;
esac

# HIMMEL-2254: the dotenv ROOT both pre-arm WARN loads below resolve against.
# load_dotenv reads a `.env` FILE, and `_load_dotenv_primary_for` falls back to
# the PRIMARY checkout when the candidate has none -- so a caller that unsets
# ARMAUTOMERGE in its own shell still gets the operator's on-disk value, and a
# suite asserting "no --automerge => no grant" fails on exactly the hosts that
# adopted the HIMMEL-2147 default. ARM_RESUME_DOTENV_ROOT redirects the READ to
# a caller-owned directory (one with no `.env` makes every key genuinely
# absent, load_dotenv no-ops rc 0). Unset => the original expression verbatim,
# so production resolution is untouched.
_arm_dotenv_root() {
    if [ -n "${ARM_RESUME_DOTENV_ROOT:-}" ]; then
        printf '%s' "$ARM_RESUME_DOTENV_ROOT"
        return 0
    fi
    _load_dotenv_primary_for "$SCRIPT_DIR/../.."
}

# HIMMEL-2128 — two ADVISORY pre-arm WARNs (never refusals), placed here right
# after schedule resolution and before the worker census / cache-dir GC /
# queue-lock / shipped-work preflight below spend real wall-clock -- the same
# "surface early" placement as the HIMMEL-2113 Ask D outrun warning above.
# Both fire on --dry-run too (advisory only, rc stays whatever it already was).

# (a) ARMAUTOMERGE. The launch body always `unset ARMAUTOMERGE ...` before
# conditionally re-exporting it, so the only thing that decides whether the
# armed session gets ARMAUTOMERGE=1 is whether --automerge was passed on THIS
# invocation (the AUTOMERGE flag) -- an ambient ARMAUTOMERGE in this shell is
# irrelevant to the child. Warn here so a chain that expects merge-on-green
# does not silently discover, hours later, that it stopped at every green PR
# instead of shipping through it.
#
# HIMMEL-2147: an explicit --automerge always wins; when it wasn't passed,
# default it from the primary checkout's ARMAUTOMERGE .env value (the
# standing ruling, HIMMEL-2128 pre-arm checklist item 5) before deciding
# whether to WARN below. Same load_dotenv bridge the CR_FLOOR_FALLBACK load
# right after this uses (process env wins; a load_dotenv READ FAILURE is
# advisory-only, arming never refuses over it).
if [ "$AUTOMERGE" -ne 1 ] && [ -f "$SCRIPT_DIR/../lib/load-dotenv.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    if load_dotenv --root "$(_arm_dotenv_root)" ARMAUTOMERGE; then
        case "$(printf '%s' "${ARMAUTOMERGE:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
            1|true|on|yes) AUTOMERGE=1 ;;
        esac
    fi
fi
if [ "$AUTOMERGE" -ne 1 ]; then
    echo "WARN arm-resume: --automerge was not passed -- the armed session will NOT set ARMAUTOMERGE=1, so merge-on-green.sh will not fire and the chain stops at every green PR instead of merging it. Pass --automerge if this arm is meant to ship through green PRs unattended." >&2
fi

# (b) CR_FLOOR_FALLBACK. When CR_REQUIRE_CROSS_MODEL is on (HIMMEL-1237) and no
# fallback is configured (HIMMEL-2128), a mid-chain exhaustion of every
# non-Claude critic leaves clear-cr-marker gate 3b with no escape: it refuses
# every subsequent branch until a human resets the bank or sets
# CR_FLOOR_FALLBACK, which PARKS the whole armed chain rather than just the one
# blocked item. Same load_dotenv bridge clear-cr-marker.sh uses (process env
# wins), pinned to the PRIMARY checkout's .env the same way.
if [ -f "$SCRIPT_DIR/../lib/load-dotenv.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    # A load_dotenv READ FAILURE here is advisory-only (unlike clear-cr-marker's
    # fail-closed refusal): this WARN can only ever be over- or under-fired,
    # never wrongly clear anything, so arming must never refuse over it.
    if load_dotenv --root "$(_arm_dotenv_root)" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK; then
        case "$(printf '%s' "${CR_REQUIRE_CROSS_MODEL:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
            1|true|on|yes)
                # HIMMEL-2128 codex-2: key on the RECOGNIZED value, not mere
                # non-emptiness -- clear-cr-marker.sh only ever treats an exact
                # (trim+lowercase) "claude-only" as the fallback; any other
                # value (a typo like "claude_only", or unset) never actually
                # enables it, so the operator must still see this WARN.
                case "$(printf '%s' "${CR_FLOOR_FALLBACK:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
                    claude-only) : ;;
                    *)
                        echo "WARN arm-resume: CR_REQUIRE_CROSS_MODEL is on and CR_FLOOR_FALLBACK is not set to the recognized value \"claude-only\" -- if every non-Claude critic exhausts mid-chain, clear-cr-marker will refuse every branch until a human resets the bank or sets CR_FLOOR_FALLBACK=claude-only, PARKING the whole armed chain instead of just the one blocked item." >&2
                        ;;
                esac
                ;;
        esac
    fi
fi

# HIMMEL-1463: an unattended arm normally ends this Claude session, and the
# harness then reaps its background task tree. Lane workers are children of
# that tree, so arming while one is live silently kills it and can strand its
# shared-branch lock. For a REAL arm, reconcile dead rows first and then fail
# closed on every remaining running row whose pid is live or unprobeable. A
# dry-run stays side-effect-free and skips the external worker census entirely.
# ARM_WITH_LIVE_WORKERS=1 is deliberately loud: it accepts that data-loss risk,
# rather than making a force-like flag easy to add accidentally.
if [ "$DRY_RUN" -eq 0 ]; then
    _arm_phase_t0 "worker-census"
    _WORKER_RECONCILER="$SCRIPT_DIR/reconcile-workers.sh"
    if [ ! -f "$_WORKER_RECONCILER" ]; then
        echo "ERR arm-resume: worker reconciler missing: $_WORKER_RECONCILER — refusing because live-worker state cannot be checked" >&2
        exit 2
    fi
    _arm_worker_stderr_file() {
        local label="$1" tmp
        tmp=$(mktemp "${TMPDIR:-/tmp}/arm-resume.${label}-err.XXXXXX") || tmp=""
        if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then
            echo "ERR arm-resume: mktemp failed for worker ${label} stderr; refusing because live-worker state cannot be checked" >&2
            return 1
        fi
        printf '%s\n' "$tmp"
    }
    # shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
    _arm_worker_stderr_cleanup() {
        # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
        [ -z "${_worker_reconcile_err:-}" ] || rm -f "$_worker_reconcile_err"
        # shellcheck disable=SC2317  # Invoked indirectly by the EXIT trap.
        [ -z "${_worker_census_err:-}" ] || rm -f "$_worker_census_err"
    }
    _worker_reconcile_err=$(_arm_worker_stderr_file reconcile) || exit 2
    _worker_census_err=""
    # Chained, not a bare `trap _arm_worker_stderr_cleanup EXIT` -- bash keeps
    # only ONE handler per signal, and that would silently drop the top-of-
    # script `trap _arm_profile_report EXIT` (HIMMEL-2113 Ask B) for the rest
    # of this run, exactly the "PROFILE line missing on a real-arm refusal"
    # bug this chain fixes.
    trap '_arm_worker_stderr_cleanup; _arm_profile_report' EXIT
    _worker_census_err=$(_arm_worker_stderr_file census) || exit 2

    set +e
    bash "$_WORKER_RECONCILER" 2>"$_worker_reconcile_err"
    _worker_reconcile_rc=$?
    set -e
    if [ "$_worker_reconcile_rc" -ne 0 ]; then
        if [ "${ARM_WITH_LIVE_WORKERS:-}" = "1" ]; then
            echo "WARN arm-resume: ARM_WITH_LIVE_WORKERS=1 — worker reconciliation failed (rc=$_worker_reconcile_rc); live-worker state is uncertain but arming anyway:" >&2
            sed 's/^/    /' "$_worker_reconcile_err" >&2
        else
            echo "ERR arm-resume: worker reconciliation failed (rc=$_worker_reconcile_rc) — refusing because live-worker state is uncertain:" >&2
            sed 's/^/    /' "$_worker_reconcile_err" >&2
            echo "    Emergency override: ARM_WITH_LIVE_WORKERS=1 (accepts the uncertainty and arms anyway)." >&2
            exit 2
        fi
    else
        # Relay the reconciler's own (non-fatal) stderr -- e.g. "settling" /
        # "unprobeable" WARN lines -- exactly as the prior unredirected
        # pass-through did.
        cat "$_worker_reconcile_err" >&2
    fi
    set +e
    _live_workers=$(bash "$_WORKER_RECONCILER" --list-live 2>"$_worker_census_err")
    _worker_list_rc=$?
    set -e
    if [ "$_worker_list_rc" -ne 0 ]; then
        if [ "${ARM_WITH_LIVE_WORKERS:-}" = "1" ]; then
            echo "WARN arm-resume: ARM_WITH_LIVE_WORKERS=1 — live-worker census failed (rc=$_worker_list_rc); live-worker state is uncertain but arming anyway:" >&2
            sed 's/^/    /' "$_worker_census_err" >&2
        else
            echo "ERR arm-resume: live-worker census failed (rc=$_worker_list_rc) — refusing to arm:" >&2
            sed 's/^/    /' "$_worker_census_err" >&2
            echo "    Emergency override: ARM_WITH_LIVE_WORKERS=1 (accepts the uncertainty and arms anyway)." >&2
            exit 2
        fi
    else
        # Relay the reconciler's own (non-fatal) stderr, same as above.
        cat "$_worker_census_err" >&2
    fi
    if [ -n "$_live_workers" ]; then
        if [ "${ARM_WITH_LIVE_WORKERS:-}" = "1" ]; then
            {
                echo "WARN arm-resume: ARM_WITH_LIVE_WORKERS=1 — arming despite live or unprobeable lane workers; exiting this session may kill them:"
                printf '    %s\n' "${_live_workers//$'\n'/$'\n    '}"
            } >&2
        else
            {
                echo "ERR arm-resume: refusing to arm while lane workers are live or unprobeable (possibly alive) (rc=10):"
                printf '    %s\n' "${_live_workers//$'\n'/$'\n    '}"
                echo "    Wait for them to finish. Emergency override: ARM_WITH_LIVE_WORKERS=1"
                echo "    (the armed session exit may kill those workers and orphan their work)."
            } >&2
            exit 10
        fi
    fi
    unset _WORKER_RECONCILER _worker_reconcile_rc _worker_list_rc _live_workers
    _arm_phase_done "worker-census" "$_ARM_PT0"
fi

# 0-cost telemetry seam (HIMMEL-236): measure-during for in-use skills —
# one disk append per arm outcome, nothing into context. FAIL-OPEN both
# ways: a missing/broken lib must never block an arm (no-op fallback
# below), and telemetry_emit itself always returns 0 under our set -e.
# Format spec: docs/tool-adoption/telemetry.md.
# shellcheck source=../lib/telemetry.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/telemetry.sh" 2>/dev/null || true
command -v telemetry_emit >/dev/null 2>&1 || telemetry_emit() { return 0; }

# handover_root (HIMMEL-856): resolves the single handover root (Mode A
# inline vs Mode B external HANDOVER_DIR) so the queue-lock + arms-registry
# checks below read/write the SAME root every other scripts/handover/*.sh
# script uses -- never a hardcoded ./handovers/ (scripts/handover/CLAUDE.md
# hard rule). Same caller-side fail-open contract as telemetry.sh above
# (HIMMEL-236 T24): an absent/broken lib must never break arming -- a
# missing handover_root just means the queue-lock/arms-registry checks
# below WARN and skip (see their own guard), same as the existing dedup/
# collision checks proceed unaffected.
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null || true
command -v handover_root >/dev/null 2>&1 || handover_root() { return 2; }
# Identity helpers are optional under the same fail-open contract. If this lib
# is absent or only partially deployed, degrade to the pre-HIMMEL-1304 raw-path
# identity instead of aborting under set -e; registry probes then use an
# absolute raw key and retain their existing WARN-and-skip behaviour.
command -v _arm_realpath >/dev/null 2>&1 || _arm_realpath() { printf '%s\n' "$1"; }
command -v _arm_identity_path >/dev/null 2>&1 || _arm_identity_path() { printf '%s' "$1"; }
command -v _arm_registry_identity_root >/dev/null 2>&1 || _arm_registry_identity_root() { printf '%s' "$1"; }
command -v _arm_registry_identity_path >/dev/null 2>&1 || _arm_registry_identity_path() { printf 'absolute:%s' "$1"; }
# The registry SCAN helper needs a fallback too (HIMMEL-1344 codex-adv round).
# The scans below call it unconditionally, and a partially-deployed
# handover-path.sh that predates HIMMEL-1344 exports handover_root + the JSON
# helpers but NOT this matcher — so without this the scan aborts under set -e,
# and with an initially empty registry that abort lands AFTER the scheduler has
# already been written: an irreversible action reported as a failure, inviting a
# duplicate retry. Degrade to a raw exact-match instead: a miss only weakens
# duplicate detection back to the pre-HIMMEL-1304 behaviour, which is strictly
# safer than aborting post-schedule.
# Mirrors the real contract: the result is returned in the global
# $_HP_ARMS_MATCH (1 = this record identifies the handover), NOT the exit
# status, which is always 0. A miss degrades duplicate detection to the
# pre-HIMMEL-1304 behaviour; escaped (e.g. backslash) spellings simply do not
# match here, which is a weaker probe, never a wrong abort.
_HP_ARMS_MATCH=0
command -v _hp_arms_record_matches_path >/dev/null 2>&1 || _hp_arms_record_matches_path() {
    local _hp_raw_marker
    _HP_ARMS_MATCH=0
    _hp_json_escape "$2"; _hp_raw_marker="\"handover\":\"$_HP_ESC\""
    case "$1" in
        *"$_hp_raw_marker"*) _HP_ARMS_MATCH=1 ;;
    esac
    return 0
}

# HIMMEL_HEADROOM_PROXY flag parser (HIMMEL-901): same fail-open contract as
# the two libs above — an absent/broken lib just means the .env fallback
# never activates (the process-env check right below still works either
# way), never a broken arm. CR round: the failure WARNs once here at source
# time (not inside the stub, which would repeat) — an operator relying on
# the .env flag deserves to know the fallback is disabled.
# shellcheck source=../lib/headroom-proxy.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/headroom-proxy.sh" 2>/dev/null \
    || echo "WARN arm-resume: headroom-proxy lib failed to load -- .env HIMMEL_HEADROOM_PROXY fallback disabled (process env still honored)" >&2
command -v _headroom_proxy_env_file_active >/dev/null 2>&1 || _headroom_proxy_env_file_active() { return 1; }

# cadence_cmd_escape (HIMMEL-1281/HIMMEL-1287): the shared CMD-metachar
# escape for interpolating a value into a generated .bat INSIDE DOUBLE
# QUOTES -- % -> %% plus best-effort " handling, and deliberately NO caret
# escapes (cmd.exe treats ^ as a LITERAL character inside double quotes, so
# caret-escaping corrupts the value instead of protecting it). Same lib the
# four HIMMEL-1281 cadence emitters use; arm-resume.sh carried a fifth,
# independently-buggy copy of the over-escaping mistake until this fix.
# Sourced fail-open (matches headroom-proxy.sh above): an absent or
# syntactically broken lib WARNs but never aborts the arm -- the inline
# fallback below restores the single-parse escape so a missing dep cannot
# turn a healthy arm into rc=1 (proxy-suite T7a/T7b/T7c).
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh" 2>/dev/null \
    || echo "WARN arm-resume: cadence-format lib failed to load -- cadence_cmd_escape falls back inline (caret-free single-parse escape)" >&2
# Minimal single-parse fallback mirroring the lib's contract (% -> %% plus
# best-effort " -> \"). Used only if the source above failed; matches the
# guard idiom on handover_root / _headroom_proxy_env_file_active above.
command -v cadence_cmd_escape >/dev/null 2>&1 || cadence_cmd_escape() {
    local s="$1"
    s="${s//\"/\\\"}"
    s="${s//%/%%}"
    printf '%s' "$s"
}

# _arm_nested_cmd_escape <value> -- the ONE double-parse escape, for the
# headroom-proxy detached-start site (schedule_arm's `start "" /b cmd /c
# ""%s" ..."` ~line 3393). That line hands its argument to a NESTED cmd /c,
# which RE-PARSES the string a SECOND time, so unlike the single-parse
# cadence_cmd_escape (where carets corrupt the value), THIS site ALSO needs
# caret escapes on ^ & < > | -- an unescaped & in the proxy-bin path splits
# into a second command at task-fire time (command injection). It is the
# cadence_cmd_escape single-parse base (% -> %%, " -> \") PLUS the caret
# escapes for the inner cmd /c parse. cadence_cmd_escape is guaranteed
# defined here (lib OR the inline fallback above), so this composes safely.
# This distinction IS the HIMMEL-1281/HIMMEL-1287 bug class: 1281 over-
# escaped the single-parse sites (cd path, prompt, --channels, the curl
# livez checks -- those keep cadence_cmd_escape); do NOT route them here.
_arm_nested_cmd_escape() {
    local v
    v=$(cadence_cmd_escape "$1")
    v="${v//^/^^}"
    v="${v//&/^&}"
    v="${v//</^<}"
    v="${v//>/^>}"
    v="${v//|/^|}"
    printf '%s' "$v"
}

# _arm_realpath / _arm_identity_path live in ../lib/handover-path.sh so the
# scheduler-row identity and the cross-script arms-registry key share one
# canonicalizer (HIMMEL-1304/HIMMEL-1344).

# _arm_path_hash <canonical-path> — a short stable digest of the canonical
# identity: the collision-proof half of the task name (HIMMEL-1304). The
# readable half is built with `tr -cd '[:alnum:]_-'`, which DELETES every
# out-of-class byte, so `.../a+b.md` and `.../ab.md` both reduce to the same
# suffix — a spurious rc-3 refusal, and worse, a `--force` that replaces the
# OTHER handover's slot. Hashing the canonical path restores injectivity while
# the readable prefix keeps `schtasks /query` / `atq` rows scannable.
#
# Prints the empty string when NO hasher is available. That degrades to the
# pre-1304 (collision-prone) identity rather than bricking every arm on this
# machine — the same fail-open-on-missing-infra contract the queue-lock and
# workspace-trust checks use. The caller WARNs once when it happens.
_arm_path_hash() {
    local _h=""
    if command -v sha256sum >/dev/null 2>&1; then
        _h=$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1) || _h=""
    fi
    if [ -z "$_h" ] && command -v shasum >/dev/null 2>&1; then
        _h=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1) || _h=""
    fi
    if [ -z "$_h" ]; then
        if py_armor_capture -c 'import sys,hashlib;print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$1" 2>/dev/null; then
            _h="$PY_ARMOR_OUT"
        fi
    fi
    # Keep only hex and clip to 12 chars: enough that a collision across one
    # machine's handovers is not a practical concern, short enough to leave the
    # readable half of the name doing its job.
    _h=$(printf '%s' "$_h" | tr -cd '0-9a-f')
    printf '%s' "${_h:0:12}"
}

# _arm_own_identity_match [line-prefix] — filter stdin to the lines that are one
# of THIS arm's identities: the current $TASK_NAME or the pre-HIMMEL-1304
# $TASK_NAME_LEGACY. Exact whole-line compare.
#
# The legacy arm is the upgrade migration, and it is load-bearing rather than a
# nicety: an in-flight slot armed by the OLD derivation carries the OLD name, so
# a post-upgrade arm-resume that only matched the NEW name would not SEE it —
# `--force` would not replace it, and both the orphaned old slot and the new one
# would fire. That is precisely the double-fire this ticket is closing, so the
# fix must not open it on the way through. Matching both names makes the
# upgrade a no-op for dedup: the old slot is found and replaced as before.
#
# awk with exact `==` compares rather than `grep -Fx`: the legacy name can be
# empty, and an empty `grep -e ''` pattern matches EVERY line (it would report
# every queued job as this arm's own). awk also always exits 0, so a no-match
# read cannot abort an errexit caller.
_arm_own_identity_match() {
    local _pfx="${1:-}"
    awk -v a="${_pfx}${TASK_NAME}" -v b="${TASK_NAME_LEGACY:+${_pfx}${TASK_NAME_LEGACY}}" \
        '$0 != "" && ($0 == a || (b != "" && $0 == b))'
}

# _arm_marker_is_own_identity <marker> — true when a marker printed by
# list_existing names THIS arm's own slot (HIMMEL-1636).
#
# list_existing's output shape is per-backend, so a bare `[ "$m" = "$TASK_NAME" ]`
# own-identity exclusion is correct on ONE of the three:
#   schtasks — the task NAME itself. Exact compare works.
#   crontab  — the whole crontab LINE; the identity is its trailing `# <name>`.
#   at       — an opaque `at-job-<id>`; the identity is only inside the job body.
# On the latter two the compare can never be true, so every own slot reads as a
# foreign one — a --force re-arm of the SAME handover then emits the HIMMEL-1329
# ticket-mutex's "DIFFERENT handover" WARN against itself. Noise, not a false
# clear, but only because that site WARNs; the exclusion has to hold everywhere.
#
# Dispatch is on the marker SHAPE rather than on $PLATFORM: list_existing picks
# at vs crontab by which tool exists (not by platform alone), and re-deriving
# that choice here would be a second copy of it, free to drift out of lockstep.
# A task name is sanitized to [[:alnum:]_-], so it can hold neither whitespace
# nor the `at-job-` shape — the three cases cannot collide.
_arm_marker_is_own_identity() {
    local _m="$1" _name
    case "$_m" in
        at-job-[0-9]*)
            # Same body probe list_existing itself used to mint this marker.
            at -c "${_m#at-job-}" 2>/dev/null | _arm_own_identity_match '# ' | grep -q .
            return
            ;;
        *[[:space:]]*) _name="${_m##*# }" ;;   # crontab line -> trailing marker
        *)             _name="$_m" ;;          # schtasks task name
    esac
    [ "$_name" = "$TASK_NAME" ] && return 0
    [ -n "${TASK_NAME_LEGACY:-}" ] && [ "$_name" = "$TASK_NAME_LEGACY" ]
}

# _arm_marker_is_new_arm <marker> — true when <marker> names the job this run
# just created, rather than a superseded sibling (HIMMEL-1304). See the
# post-commit reap sweep near schedule_arm for why each arm matters.
#
# windows-only: `schtasks /create /f` overwrites a task of the SAME name in
# place, so a same-identity re-arm leaves no separate old row to reap — a
# marker equal to $TASK_NAME already IS the row schedule_arm just wrote.
# POSIX (at-job / crontab) never gets that in-place overwrite: an at-job
# always registers under a fresh job id (a captured marker is never the id
# schedule_arm is about to mint), and _crontab_schedule's `_crontab_delete`
# always APPENDS a new line rather than replacing a same-marker one already
# queued (see the comment above the post-commit sweep). So a marker captured
# BEFORE schedule_arm ran is, on POSIX, always the superseded entry and must
# always be reaped — treating a same-identity crontab marker as "already
# ours" (the pre-fix `*"# $TASK_NAME")  return 0` case) left the stale line
# unreaped while the append created a second one: a genuine double-fire, not
# just a test artifact (HIMMEL-1304 fix).
_arm_marker_is_new_arm() {
    local _m="$1"
    case "$PLATFORM" in
        windows)
            [ "$_m" = "$TASK_NAME" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# _bash_single_quote <value> — quote one value for the in-distro bash -lc
# command. The result is composed completely before CMD escaping is applied.
_bash_single_quote() {
    local v="$1"
    v="${v//\'/\'\\\'\'}"
    printf "'%s'" "$v"
}

# Derive the local clock fields the schedulers need from TARGET_EPOCH:
#   RESUME_TIME  HH:MM        — schtasks /st, at, banner
#   START_DATE   MM/DD/YYYY   — schtasks /sd. FIXES the bug where /st with no
#                /sd defaulted to TODAY, so a time already past today gave
#                "Next Run Time: N/A" and never fired (HIMMEL-204). NOTE:
#                schtasks /sd parses per the user's Windows short-date LOCALE,
#                so this MM/DD/YYYY value is only a DEFAULT — the Windows
#                branch of schedule_arm re-renders it in the machine's own
#                locale (via _win_short_date_pattern + a registry read) right
#                before /create, and verifies the registered NextRunTime
#                afterward (HIMMEL-938; a dd/MM/yyyy machine, e.g. win2,
#                previously misread MM/DD/YYYY and armed months out with no
#                error). Non-Windows platforms never read this field as a
#                schtasks /sd — it stays MM/DD/YYYY here as a harmless default.
#   AT_STAMP     YYYYMMDDhhmm — at -t, an exact datetime (replaces the
#                today/tomorrow heuristic that broke for resets >24h out).
# Capture FIRST (explicit || handler — a $(...) failure inside a heredoc
# body would not abort), then validate non-empty before arming.
# HIMMEL-708: the explicit-HH:MM branch already derived these fields in its
# single python pass (_SCHED_FIELDS_DERIVED); only the smart/auto paths (which
# get TARGET_EPOCH from a subprocess) still need this second derivation.
if [ -z "${_SCHED_FIELDS_DERIVED:-}" ]; then
    py_armor_capture -c '
import sys, datetime
dt = datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone()
print(dt.strftime("%H:%M"), dt.strftime("%m/%d/%Y"), dt.strftime("%Y%m%d%H%M"))
' "$TARGET_EPOCH" || {
        echo "ERR arm-resume: could not derive schedule fields from epoch $TARGET_EPOCH" >&2
        exit 2
    }
    read -r RESUME_TIME START_DATE AT_STAMP <<<"$PY_ARMOR_OUT"
fi
if [ -z "$RESUME_TIME" ] || [ -z "$START_DATE" ] || [ -z "$AT_STAMP" ]; then
    echo "ERR arm-resume: derived schedule fields empty (epoch=$TARGET_EPOCH) — refusing to arm" >&2
    exit 2
fi

if [ ! -f "$HANDOVER_PATH" ]; then
    echo "ERR arm-resume: --handover file not found: $HANDOVER_PATH" >&2
    exit 1
fi

# Platform detect.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)
        echo "ERR arm-resume: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (Git Bash / MSYS / Cygwin), Linux, macOS" >&2
        exit 2
        ;;
esac

if [ -n "$WSL_DISTRO" ] && [ "$PLATFORM" != windows ]; then
    echo "ERR arm-resume: --wsl-distro is a Windows-host flag" >&2
    exit 2
fi

# HIMMEL_HEADROOM_PROXY (HIMMEL-901): route the armed relaunch through the
# local headroom Anthropic-API proxy (127.0.0.1:8787) when the operator has
# opted in. Resolved ONCE here, at arm time, and baked into whichever
# launcher schedule_arm emits below — the fired relaunch never re-reads this
# flag. Only the exact value "1" activates: the process env at arm time wins
# outright (HIMMEL_HEADROOM_PROXY set-but-not-"1" is INACTIVE, same as
# unset); only when the process env carries no signal at all does the
# himmel repo-root .env get consulted as a fallback. When inactive
# (the default), every launcher below stays BYTE-IDENTICAL to pre-901
# output — this block is the only thing that can turn it on.
# Known minimal-slice limitation (CR round): the .env fallback resolves
# against the checkout THIS script physically lives in (SCRIPT_DIR/../..),
# so arming from a worktree does not see the primary checkout's untracked
# .env — the process env is the worktree-safe path.
HEADROOM_PROXY_ACTIVE=0
if [ -n "${HIMMEL_HEADROOM_PROXY+x}" ]; then
    [ "$HIMMEL_HEADROOM_PROXY" = "1" ] && HEADROOM_PROXY_ACTIVE=1
elif _headroom_proxy_env_file_active "$(cd "$SCRIPT_DIR/../.." && pwd)"; then
    HEADROOM_PROXY_ACTIVE=1
fi
if [ -n "$WSL_DISTRO" ] && [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
    echo "WARN arm-resume: headroom proxy gate skipped for a WSL-station arm (distro '$WSL_DISTRO')" >&2
    HEADROOM_PROXY_ACTIVE=0
fi
# Port fixed at 8787 for this slice — no port config (HIMMEL-901 minimal
# slice; a variable only to avoid repeating the literal across 3 platform
# launchers). HEADROOM_BIN: operator override wins; else the platform
# default venv layout. Only resolved when the flag is active, so an
# inactive arm never even looks at $HOME/.headroom-venv.
HEADROOM_PROXY_PORT=8787
# CR round (HIMMEL-901): resolve curl ONCE at arm time and bake the ABSOLUTE
# path into the launcher — scheduler contexts fire with a minimal PATH (the
# same reason claude/cygpath are resolved at arm time above), so a bare
# `curl` in the launcher could miss at fire time, fail both livez checks,
# and silently send the launch bare even with a healthy proxy. No curl at
# arm time -> one honest WARN and a plain pre-901 launcher (deactivate)
# rather than baking a known-broken check.
HEADROOM_CURL=""
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
    if ! HEADROOM_CURL=$(command -v curl 2>/dev/null) || [ -z "$HEADROOM_CURL" ]; then
        echo "WARN arm-resume: curl not on PATH -- the armed launch will fail-open to bare (proxy livez unverifiable)" >&2
        HEADROOM_PROXY_ACTIVE=0
    fi
fi
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ] && [ -z "${HEADROOM_BIN:-}" ]; then
    if [ "$PLATFORM" = windows ]; then
        HEADROOM_BIN="$HOME/.headroom-venv/Scripts/headroom.exe"
    else
        HEADROOM_BIN="$HOME/.headroom-venv/bin/headroom"
    fi
fi
# Non-blocking existence probe (CR round): a missing/non-executable headroom
# binary still arms — fail-open is the design — but the operator hears about
# it NOW instead of discovering a silently-bare session after the fire.
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
    [ -x "$HEADROOM_BIN" ] || echo "WARN arm-resume: HEADROOM_BIN '$HEADROOM_BIN' not found/executable -- fire-time start will fail-open to bare" >&2
fi

# Tool detection per platform.
case "$PLATFORM" in
    windows)
        command -v "${SCHTASKS_CMD:-schtasks}" >/dev/null 2>&1 || {
            # Name what was actually probed. Since the seam landed, this check
            # resolves ${SCHTASKS_CMD:-schtasks}, which may be an absolute path
            # — "not on PATH" would then point the reader at PATH when the real
            # fault is a bad SCHTASKS_CMD.
            echo "ERR arm-resume: scheduler binary '${SCHTASKS_CMD:-schtasks}' not found${SCHTASKS_CMD:+ (from SCHTASKS_CMD)} (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        if ! command -v at >/dev/null 2>&1 && ! command -v crontab >/dev/null 2>&1; then
            echo "ERR arm-resume: neither 'at' nor 'crontab' on PATH" >&2
            echo "    Install 'at': Debian/Ubuntu: sudo apt install at && sudo systemctl enable --now atd" >&2
            echo "    macOS:        uses crontab — ensure crontab is available" >&2
            exit 2
        fi
        ;;
esac

# True (rc 0) if PID names a live process. POSIX: `kill -0`. Windows (Git
# Bash): the bun bridge is a NATIVE win32 process whose pid MSYS `kill -0`
# can't see, so query `tasklist` by PID filter instead. (Pid reuse could
# false-positive, but the supervisor clears its pidfile on clean exit and a
# false "live" only ever errs toward the SAFE side here — refusing a risky
# --channels arm.)
_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    case "$PLATFORM" in
        windows)
            # Capture stdout+stderr together (NOT 2>/dev/null) so a broken/absent
            # tasklist is distinguishable from a clean miss (HIMMEL-228). A clean
            # miss prints "No tasks are running..." (legit dead pid); a genuine
            # tooling failure prints something else (e.g. "ERROR: ..."). If we
            # silently swallowed a malfunctioning tasklist, every pid would read
            # "dead" and bridge_poller_live would fail OPEN — the unsafe direction.
            local out rc
            out=$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>&1); rc=$?
            # A clean "No tasks" miss is an authoritative dead-pid -> return 1
            # without warning. A pid match counts as LIVE only on a clean exit
            # (rc 0): a nonzero rc that merely echoed the pid digits into stderr
            # (a tasklist error variant) must NOT short-circuit to "alive" — gate
            # the match on rc==0 so it falls through to the warn branch instead
            # of masking the failure the rc check is meant to surface (HIMMEL-228).
            case "$out" in
                *"No tasks"*) return 1 ;;
                *"$pid"*)     [ "$rc" -eq 0 ] && return 0 ;;
            esac
            # Reached when: no "No tasks" miss AND (no pid match, OR a pid match
            # with a nonzero rc). If tasklist exited nonzero it likely failed
            # (broken/absent) rather than reporting a clean dead-pid. Warn so a
            # broken toolchain is visible instead of silently disabling the guard;
            # keep returning 1 (dead).
            if [ "$rc" -ne 0 ]; then
                echo "WARN arm-resume: tasklist exited $rc with no 'No tasks' miss for PID $pid — treating as dead, but tasklist may be broken/absent (output: ${out:-<empty>})" >&2
            fi
            return 1
            ;;
        *)
            kill -0 "$pid" 2>/dev/null
            ;;
    esac
}

# rc 0 if the always-on bun Telegram bridge (HIMMEL-207/208) appears to be
# running. Liveness = the supervisor pidfile exists AND at least one recorded
# pid (supervisor or poller) is alive. ARM_BRIDGE_LIVE is a test seam (1/0
# forces the answer without a real process); BRIDGE_PIDFILE / BRIDGE_ROOT
# mirror bus.ts's resolution (`$BRIDGE_ROOT ?? ~/.claude/handover/bridge`) so a
# real check inspects the same supervisor.pid the bridge actually wrote.
bridge_poller_live() {
    case "${ARM_BRIDGE_LIVE:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local pidfile="${BRIDGE_PIDFILE:-${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/supervisor.pid}"
    # Pidfile ABSENT -> bridge not running -> not live (a --channels arm may
    # proceed). Pidfile PRESENT but unreadable/empty -> we CANNOT confirm the
    # bridge is down, and a present pidfile most likely means it IS up (the
    # supervisor wrote it; it may just be torn mid-write), so fail CLOSED: treat
    # as live and let the guard refuse. The operator's escape for a genuinely
    # stale/corrupt file is the documented ARM_CHANNELS_OK=1.
    [ -f "$pidfile" ] || return 1
    local pids parse_rc=0
    # Armored capture (HIMMEL-249): a wedged python3 stub reads as a parse
    # failure (nonzero rc -> fail-closed WARN below), never a hang. The `||`
    # also keeps this errexit-safe regardless of the call context.
    py_armor_capture -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        o = json.load(fh)
except Exception:
    sys.exit(0)
for k in ("supervisor", "poller"):
    v = o.get(k)
    if isinstance(v, int) and v > 0:
        print(v)
' "$pidfile" 2>/dev/null || parse_rc=$?
    pids="$PY_ARMOR_OUT"
    if [ "$parse_rc" -ne 0 ] || [ -z "$pids" ]; then
        echo "WARN arm-resume: bridge pidfile present but unreadable/empty ($pidfile);" >&2
        echo "    treating the Telegram bridge as LIVE (fail-closed). If it is genuinely" >&2
        echo "    down, override with ARM_CHANNELS_OK=1." >&2
        return 0
    fi
    # >=1 recorded pid parsed: live iff any is still running. ALL dead = a stale
    # pidfile from a crashed bridge -> not live (the arm may proceed).
    local pid
    while IFS= read -r pid; do
        [ -n "$pid" ] && _pid_alive "$pid" && return 0
    done <<< "$pids"
    return 1
}

# HIMMEL-225: refuse to arm a --channels relaunch while the bun Telegram
# bridge is live. Telegram reachability comes from the bun bridge, NOT from a
# session holding --channels, and a --channels relaunch alongside the live
# bridge is unattended-fatal two ways: (1) it is a 2nd getUpdates consumer ->
# 409 Conflict (neither settles); (2) --channels needs
# --dangerously-load-development-channels, whose prompt does NOT persist -> the
# scheduled relaunch HANGS on it forever. So the anti-lockout default is a
# PLAIN relaunch. ARM_CHANNELS_OK=1 overrides (also the escape for a stale
# pidfile) — use only after stopping the bridge (`bun supervisor.ts --kill`).
if [ -n "$CHANNELS" ] && [ -z "${ARM_CHANNELS_OK:-}" ] && bridge_poller_live; then
    {
        echo "ERR arm-resume: refusing --channels while the bun Telegram bridge is live."
        echo "    A --channels relaunch becomes a 2nd getUpdates consumer (409 Conflict)"
        echo "    AND --dangerously-load-development-channels prompts interactively, so an"
        echo "    unattended relaunch HANGS. The bun bridge already owns Telegram — relaunch"
        echo "    PLAIN (drop --channels)."
        echo "    To really arm --channels: stop the bridge first (bun supervisor.ts --kill),"
        echo "    then re-run with ARM_CHANNELS_OK=1. See docs/internals/telegram-bridge.md."
    } >&2
    exit 5
fi

# Ticket inference for the scheduler task name (HIMMEL-540). The task name is
# built AFTER the cwd/worktree resolution block below (so $WORKTREE_BRANCH is
# fully resolved); these helpers are defined here and used there.
#
# _validate_key <raw> — echo the canonical ticket key (uppercased) or empty.
# errexit-safe: a `case` glob (never a bare `grep -q`); the last command is the
# `case` (rc 0 on every branch), so it never aborts under `set -euo pipefail`.
_validate_key() {
    local k
    k=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')   # himmel-540 -> HIMMEL-540
    # Fully-anchored canonical shape <KEY>-<NUM> with nothing trailing, so a
    # malformed value (e.g. ABC-123-456 or trailing junk) is rejected rather than
    # truncated-and-accepted. `grep -qE` inside `if` is errexit-safe; the `if` is
    # the function's last command and returns rc 0 whether or not it matched.
    if printf '%s' "$k" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then
        printf '%s' "$k"
    fi
}

# _infer_ticket <handover_path> — echo the inferred ticket key or empty. Sources,
# most-robust-first, falling through on miss:
#   1. ticket: front-matter key (consume-if-present; forward-compat).
#   2. worktree branch type/<ticket>-slug ($WORKTREE_BRANCH; lowercase->uppercase).
#   3. first H1 (`# `) line's first canonical [A-Z][A-Z0-9]+-[0-9]+ key.
#   4. (HIMMEL-716) CHAIN FILES ONLY (basename next-session-N.md): the leading
#      canonical key of the parent dir. The handover skill's chain layout names
#      the epic dir <TICKET>-<slug>, so a chained handover whose file carries
#      no key still resolves its chain identity. Scoped to chain files so an
#      ordinary handover sitting in an odd-named dir (e.g. session-2/) cannot
#      have a junk key welded in.
# Each `grep` is `|| true`-guarded — grep exits 1 on no-match and `set -o
# pipefail` would otherwise abort the assignment. The last command (src-4's
# `if`, rc 0 whether or not it fires) keeps the function errexit-safe.
# _infer_ticket_strict <handover_path> -- HIMMEL-1329: sets the global
# $_ho_ticket_strict to _infer_ticket's src-1 (frontmatter `ticket:`) match
# ONLY, or empty on a miss. A dedicated function rather than a side-channel
# variable set from inside _infer_ticket: _infer_ticket is always invoked as
# `$(_infer_ticket ...)` (command substitution), which forks a SUBSHELL --
# any variable a subshell sets is invisible to the caller once it exits, so a
# first attempt at this that had _infer_ticket set a side-channel global
# internally silently never worked (verified: _ho_ticket_strict read back
# empty on every call). This function must therefore be invoked as a PLAIN
# statement, never via `$(...)`, so it runs in the current shell.
#
# src-2/3/4 (worktree branch, H1 title, chain-dir name) are documented as
# best-effort cosmetic naming heuristics -- "a non-conventional slug that
# merely looks keyed yields a cosmetically-wrong row name only" -- never
# meant to carry semantic weight for a BLOCKING check. The ticket-level mutex
# reads $_ho_ticket_strict, not _infer_ticket's combined return value, so a
# handover whose H1 merely MENTIONS a ticket for documentation (e.g. this
# suite's own "# HIMMEL-1304 test handover" fixtures) can't false-positive a
# refusal against an unrelated handover.
_ho_ticket_strict=""
_infer_ticket_strict() {
    local _ho="$1" _raw _key _fm _fm_rc _stem
    # HIMMEL-1640: honor a frontmatter `ticket:` ONLY from lines strictly inside
    # a well-formed YAML block -- one that OPENS at line 1 of the document
    # (optionally after a UTF-8 BOM) and CLOSES at a later `---`. The opening
    # delimiter is anchored to the document start (codex-adv r3): only NR==1
    # matching `^---[[:space:]]*$` -- after `sub(/^\xef\xbb\xbf/,"")` strips an
    # optional leading BOM -- enters frontmatter mode (c==1). A file whose first
    # line is anything else NEVER enters frontmatter mode, so a `---` horizontal
    # rule in the BODY of a plain-markdown handover is ordinary text: it can
    # neither masquerade as an opener (false ticket mutex, HIMMEL-1329) nor as a
    # lone unclosed block (false hard error on a valid handover). CRLF is
    # tolerated by the existing `[[:space:]]`. Lines buffer while c==1 and emit
    # on the close; the old one-pass `c==1` filter never closed, so an unclosed
    # block swallowed the whole body as frontmatter.
    # OPENED-but-UNTERMINATED frontmatter is a hard PARSE ERROR, not an empty
    # result (codex-adv r2): silently yielding no ticket here would let a
    # handover whose REAL frontmatter ticket lost its closing `---` bypass the
    # mutex entirely — converting malformed metadata into the exact
    # duplicate-resume race the mutex exists to prevent. The awk distinguishes
    # the three shapes by exit code: no frontmatter at all (c==0) and a closed
    # block (c==2, set before `exit` so END's c==1 check is false) are fine;
    # EOF with c==1 (opened, never closed) exits 3 and the arm refuses loudly
    # BEFORE any scheduler mutation. POSIX awk (string concat, printf,
    # exit-to-END).
    _fm_rc=0
    _fm=$(awk 'NR==1{sub(/^\xef\xbb\xbf/,"")} NR==1 && /^---[[:space:]]*$/{c=1; next} c==1 && /^---[[:space:]]*$/{printf "%s",b; c=2; exit} c==1{b=b $0 "\n"} END{if(c==1) exit 3}' "$_ho") || _fm_rc=$?
    if [ "$_fm_rc" -eq 3 ]; then
        echo "ERR arm-resume: unclosed YAML frontmatter in $_ho -- an opening --- with no closing ---. Refusing to arm: a truncated frontmatter ticket would silently bypass the ticket mutex (HIMMEL-1329/HIMMEL-1640). Close the frontmatter block (or remove the stray opening ---) and re-arm." >&2
        exit 1
    fi
    _raw=$(printf '%s' "$_fm" | sed -n 's/^ticket:[[:space:]]*//p' | head -1) || true
    _raw="${_raw%"${_raw##*[![:space:]]}"}"   # rtrim (incl trailing \r)
    _raw="${_raw#\'}" ; _raw="${_raw%\'}"
    _raw="${_raw#\"}" ; _raw="${_raw%\"}"
    _key=$(_validate_key "$_raw")
    # HIMMEL-2113 (codex-1 CONFIRMED): frontmatter-only was too strict for a
    # CHAIN file (next-session-N.md) that carries no `ticket:` frontmatter --
    # it silently dropped _infer_ticket's src-4 (parent-dir name), an
    # UNAMBIGUOUS signal (the handover skill's chain layout names the epic dir
    # <TICKET>-<slug>) that is immune to the leg-header false positive this
    # narrowing targeted (that false positive was H1 TITLE text, src-3, never
    # the directory name). Fall back to the parent-dir key ONLY for chain
    # files; a non-chain handover with no frontmatter ticket stays empty --
    # that tradeoff stands.
    if [ -z "$_key" ]; then
        _stem=$(basename "${_ho//\\//}"); _stem="${_stem%.md}"
        if printf '%s' "$_stem" | grep -qE '^next-session-[0-9]+$'; then
            _raw=$(basename "$(dirname "${_ho//\\//}")")
            # HIMMEL-2113 (codex-3): require a delimiter or end-of-string
            # right after the digit run -- a bare prefix match welded
            # HIMMEL-9004 out of a dir named HIMMEL-9004foo, false-tripping
            # the shipped-work preflight against a ticket the dir name never
            # actually named. Two-step: verify the delimited shape with -q
            # first, THEN extract with the original -o pattern (safe once -q
            # has confirmed there is no trailing junk after the digits).
            if printf '%s' "$_raw" | grep -qiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+(-|$)'; then
                _raw=$(printf '%s' "$_raw" | grep -oiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+') || true
            else
                _raw=""
            fi
            _key=$(_validate_key "$_raw")
        fi
    fi
    _ho_ticket_strict="$_key"
}

_infer_ticket() {
    local _ho="$1" _raw _key _stem
    # src-1: ticket: frontmatter (same awk/sed/rtrim/unquote idiom as resume_cwd:).
    # `|| true` keeps the assignment errexit-safe even if head closes the pipe
    # early (SIGPIPE), matching the explicit guards on src-2/src-3 below.
    _raw=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$_ho" \
        | sed -n 's/^ticket:[[:space:]]*//p' | head -1) || true
    _raw="${_raw%"${_raw##*[![:space:]]}"}"   # rtrim (incl trailing \r)
    _raw="${_raw#\'}" ; _raw="${_raw%\'}"
    _raw="${_raw#\"}" ; _raw="${_raw%\"}"
    _key=$(_validate_key "$_raw")
    if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    # src-2: worktree branch type/<ticket>-slug — real branches are lowercase,
    # so _validate_key uppercases. Takes the FIRST word-digits token from the
    # slug; for the himmel convention (type/<key>-N-rest) that IS the ticket.
    # Best-effort: a non-conventional slug that merely looks keyed (e.g.
    # feat/release-2024-x) yields a cosmetically-wrong row name only — the
    # per-handover-unique path-suffix still keys dedup/collision correctly.
    if [ -n "$WORKTREE_BRANCH" ]; then
        _raw=$(printf '%s\n' "${WORKTREE_BRANCH#*/}" \
            | grep -oiE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1) || true
        _key=$(_validate_key "$_raw")
        if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    fi
    # src-3: first H1 line only, first canonical (uppercase) key. H1-only so a
    # stray ticket *mention* in the body can't be welded into the scheduler name.
    # HIMMEL-2113: skip this source entirely for chain files (basename
    # next-session-<N>.md) -- their H1 is a "# Next Session -- <epic
    # leg-header>" convention (documented at src-4 below), not a ticket
    # reference, and a project with a Done ticket numbered like the leg
    # (e.g. LUNA-64) would otherwise false-match. A chain file's ticket
    # identity comes from its PARENT DIR (src-4), never its own H1.
    _stem=$(basename "${_ho//\\//}"); _stem="${_stem%.md}"
    if ! printf '%s' "$_stem" | grep -qE '^next-session-[0-9]+$'; then
        _raw=$(sed -n '/^# /{p;q}' "$_ho")
        _raw=$(printf '%s\n' "$_raw" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1) || true
        _key=$(_validate_key "$_raw")
        if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    fi
    # src-4: chain files only (see header). Backslashes normalized first so a
    # Windows-style path still splits on its components.
    if printf '%s' "$_stem" | grep -qE '^next-session-[0-9]+$'; then
        _raw=$(basename "$(dirname "${_ho//\\//}")" \
            | grep -oiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+') || true
        _validate_key "$_raw"
    fi
}

# _infer_session_number <handover_path> - chain position N for a CHAINED
# handover (HIMMEL-716): the handover skill's auto-continuing chains write
# next-session-<N>.md files, so a stem that is (or ends in) next-session-<N>
# IS the chain sequence number. Echoes N or empty. Filename-only by design -
# a body mention of "next-session-9" can never leak into the name (the same
# scan discipline as _infer_ticket's H1-only rule). errexit-safe: the grep
# pipeline is || true-guarded and is the function's last command.
_infer_session_number() {
    local _stem
    _stem=$(basename "${1//\\//}"); _stem="${_stem%.md}"
    printf '%s\n' "$_stem" | grep -oE '(^|-)next-session-[0-9]+$' | grep -oE '[0-9]+$' || true
}

# _infer_slug <handover_path> - human slug from the handover NAME (HIMMEL-716),
# the no-ticket-system identity source (OSS adopters without Jira). The file
# stem, minus .md and minus a trailing next-session-<N> chain tail (carried
# separately as the session number); when nothing is left (a bare
# next-session-N.md chain file) fall back to the parent dir's basename (the
# <TICKET>-<slug> epic dir) unless that is a generic bucket (handovers / .),
# which would name every slot alike. Sanitized to [A-Za-z0-9._-]: a strict
# subset of the session-title class, and the task-name weld re-sanitizes for
# its own surface. errexit-safe: sed and tr always rc 0; the case has a no-op
# default arm.
_infer_slug() {
    local _p="${1//\\//}" _stem _parent
    _stem=$(basename "$_p"); _stem="${_stem%.md}"
    _stem=$(printf '%s\n' "$_stem" | sed -E 's/(^|-)next-session-[0-9]+$//')
    if [ -z "$_stem" ]; then
        _parent=$(basename "$(dirname "$_p")")
        case "$_parent" in
            handovers|.|/) : ;;
            *) _stem="$_parent" ;;
        esac
    fi
    printf '%s' "$_stem" | tr -cd 'A-Za-z0-9._-'
}

# _compose_arm_name <ticket> <handover_path> <title|task> - ONE composer for
# BOTH derived names (HIMMEL-716; subsumes HIMMEL-702's _infer_session_name so
# the `claude -n` title and the scheduler-row segment can never drift apart):
#   title -> the `claude -n` value, canonical retitle form "<TICKET> <name>"
#            (HIMMEL-432, space-joined), sanitized to [A-Za-z0-9._ -] so the
#            Windows .bat launch line can inject it quoted WITHOUT ^-escaping
#            (HIMMEL-702) and printf %q keeps it one arg for cron/at. Empty
#            tells the caller to omit -n (fail-open - let claude auto-title
#            rather than force a meaningless name).
#   task  -> the identity segment welded into TASK_NAME (dash-joined; space
#            and dot become dashes), sanitized to [:alnum:]_- so the crontab
#            self-clean ERE and the CMD launch lines stay injection-proof.
# Identity grammar (default): <ticket> + <name-half> + <s<N> chain position>.
# The name-half, by priority:
#   1. the worktree slug minus its leading ticket token (the HIMMEL-702
#      source, unchanged);
#   2. a ticket-KEYED handover slug - the file/dir is named <ticket>-<slug>,
#      so the slug is that ticket's own name-half;
#   3. ticketless only: the raw handover slug (the no-Jira adopter fallback).
# An UNKEYED slug never rides along with a ticket: the ticket alone is
# already meaningful, welding an unrelated filename in adds noise, and this
# keeps plain ticketed arms byte-identical to the pre-716 names (existing
# armed slots still dedup across the upgrade).
# ARM_NAME_TEMPLATE (HIMMEL-716; arming config, same surface as
# ARM_MAX_SLOTS): operator override with placeholders {ticket} {slug}
# {session} ({session} renders s<N> or empty; {slug} prefers the worktree
# half, else the keyed-stripped or raw handover slug). One template drives
# BOTH surfaces; the per-surface sanitize still applies afterwards, so even a
# hostile template value cannot inject into the .bat/cron launch lines.
# errexit-safe: greps || true-guarded, case arms rc 0, and each branch of the
# final if ends in a sed that returns rc 0.
_compose_arm_name() {
    local _tkt="$1" _ho="$2" _surface="$3"
    local _name="" _slug _tok _sess _hslug _up _out
    if [ -n "$WORKTREE_BRANCH" ]; then
        _slug="${WORKTREE_BRANCH#*/}"                     # feat/himmel-702-x -> himmel-702-x
        _tok=$(printf '%s\n' "$_slug" | grep -oiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1) || true
        if [ -n "$_tok" ]; then
            _name="${_slug#"$_tok"}"; _name="${_name#-}"  # strip leading <ticket>- token
        else
            _name="$_slug"
        fi
    fi
    _sess=$(_infer_session_number "$_ho")
    [ -n "$_sess" ] && _sess="s$_sess"
    _hslug=$(_infer_slug "$_ho")
    if [ -z "$_name" ]; then
        if [ -n "$_tkt" ]; then
            # keyed check is case-insensitive (real stems are usually lowercase).
            _up=$(printf '%s' "$_hslug" | tr '[:lower:]' '[:upper:]')
            case "$_up" in
                "$_tkt"-?*) _name="${_hslug:$(( ${#_tkt} + 1 ))}" ;;
            esac
        else
            _name="$_hslug"
        fi
    fi
    if [ -n "${ARM_NAME_TEMPLATE:-}" ]; then
        _out="$ARM_NAME_TEMPLATE"
        _out="${_out//\{ticket\}/$_tkt}"
        _out="${_out//\{slug\}/${_name:-$_hslug}}"
        _out="${_out//\{session\}/$_sess}"
    elif [ "$_surface" = "title" ]; then
        _out="$_tkt $_name $_sess"
    else
        _out="$_tkt-$_name-$_sess"
    fi
    # Per-surface finish: sanitize to the surface's class, squeeze separator
    # runs left by empty components, trim stray leading/trailing separators.
    # tr set args keep '-' LAST: a leading '-' in the set reads as an option
    # to GNU tr ("unknown option") and the failed pipeline would abort the
    # errexit caller.
    if [ "$_surface" = "title" ]; then
        printf '%s' "$_out" | tr -cd 'A-Za-z0-9._ -' | tr -s '. _-' \
            | sed -E 's/^[-. _]+//; s/[-. _]+$//'
    else
        printf '%s' "$_out" | tr ' .' '-' | tr -cd '[:alnum:]_-' | tr -s '_-' \
            | sed -E 's/^[-_]+//; s/[-_]+$//'
    fi
}

# HIMMEL-1719: the pointer clause names § Launch preamble (docs/handover/overnight-mode.md) — single line, quoting-safe charset; test section 1719 pins both.
RESUME_PROMPT="load $HANDOVER_PATH overnight mode. Apply the Launch preamble standing instructions in docs/handover/overnight-mode.md before Phase 1."

# Compute working directory for the relaunched claude process. Without
# this, schtasks fires .bat with CWD=C:\Windows\System32 (and at/cron
# fire with CWD=$HOME or /), so claude.exe lands outside the repo:
# relative handover paths resolve to System32\handovers\..., the
# block-edit-on-main hook can't find .git, and claude registers an
# unintended "C:\Windows\System32" project in ~/.claude/projects/.
#
# Priority:
#   1. --cwd override. hop.sh (HIMMEL-130) passes the ORIGIN repo here
#      because the handover lives in the state repo but claude must run
#      from the origin repo, not the state repo.
#   2. resume_cwd: in the handover file's YAML frontmatter. Lets a
#      handover in the state repo declare its own work-repo without
#      requiring an explicit --cwd at every arm-resume call.
#   3. Auto-detect: git toplevel containing the handover file.
#   4. Fallback: handover's parent dir if it isn't tracked by git.
#
# Priority 0 (HIMMEL-387): --worktree <branch> / 'resume_worktree:' frontmatter
# short-circuits all of the above — the relaunch runs in a FRESH himmel
# worktree instead of a shared checkout. Required when github-sync / the
# Telegram bridge run concurrently, so an autonomous code arm never mutates a
# checkout another session has open. Explicit opt-in only: vault arms
# (luna/salus) must stay single-tree, so this is never inferred.

# Resolve the worktree branch from frontmatter when not given on the CLI
# (flag wins, same precedence as --cwd over resume_cwd).
if [ -z "$WORKTREE_BRANCH" ]; then
    _fm_wt=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$HANDOVER_PATH" \
        | sed -n 's/^resume_worktree:[[:space:]]*//p' | head -1)
    _fm_wt="${_fm_wt%"${_fm_wt##*[![:space:]]}"}"   # rtrim (incl trailing \r)
    _fm_wt="${_fm_wt#\'}" ; _fm_wt="${_fm_wt%\'}"
    _fm_wt="${_fm_wt#\"}" ; _fm_wt="${_fm_wt%\"}"
    WORKTREE_BRANCH="$_fm_wt"
    unset _fm_wt
fi

if [ -n "$WORKTREE_BRANCH" ]; then
    if [ -n "$RESUME_CWD_OVERRIDE" ]; then
        echo "ERR arm-resume: --cwd and --worktree are mutually exclusive (the worktree IS the cwd)" >&2
        exit 1
    fi
    if ! printf '%s' "$WORKTREE_BRANCH" | grep -qE '^(feat|fix|chore|docs|refactor|test)/[A-Za-z0-9._-]+$'; then
        echo "ERR arm-resume: --worktree branch must be type/slug (type in feat|fix|chore|docs|refactor|test): '$WORKTREE_BRANCH'" >&2
        exit 1
    fi
    # clean-garden.sh (which worktree.sh wraps) creates the worktree under the
    # checkout's own .claude/worktrees/<type>+<slug>/. Compute that path so the
    # dry-run can report it and the pre-trust below can target it. SCRIPT_DIR is
    # scripts/handover, so ../.. is the repo root of THIS checkout (run from the
    # primary checkout per the operator rule).
    _wt_root=$(cd "$SCRIPT_DIR/../.." && pwd)
    _wt_path="$_wt_root/.claude/worktrees/${WORKTREE_BRANCH/\//+}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY arm-resume: would create worktree '$WORKTREE_BRANCH' at '$_wt_path' and resume there"
        RESUME_CWD="$_wt_path"
    else
        if [ -d "$_wt_path" ]; then
            echo "arm-resume: reusing existing worktree at '$_wt_path'"
        else
            # ARM_WORKTREE_CMD is a test seam (default: the real worktree.sh).
            # ARM_WORKTREE_PATH lets a stub create the exact computed dir; the
            # real worktree.sh ignores it (it computes the same path itself).
            _wt_cmd="${ARM_WORKTREE_CMD:-bash $SCRIPT_DIR/../worktree.sh}"
            # _wt_cmd is an intentional cmd+args split — word-splitting wanted.
            # shellcheck disable=SC2086
            if ! ARM_WORKTREE_PATH="$_wt_path" $_wt_cmd "$WORKTREE_BRANCH"; then
                echo "ERR arm-resume: worktree create failed for branch '$WORKTREE_BRANCH'" >&2
                exit 4
            fi
        fi
        if [ ! -d "$_wt_path" ]; then
            echo "ERR arm-resume: expected worktree dir not found after create: '$_wt_path'" >&2
            exit 4
        fi
        RESUME_CWD=$(_arm_realpath "$_wt_path")
    fi
    unset _wt_root _wt_path
elif [ -n "$RESUME_CWD_OVERRIDE" ]; then
    if [ -n "$WSL_DISTRO" ]; then
        RESUME_CWD="$RESUME_CWD_OVERRIDE"
    elif [ ! -d "$RESUME_CWD_OVERRIDE" ]; then
        echo "ERR arm-resume: --cwd path does not exist: $RESUME_CWD_OVERRIDE" >&2
        exit 1
    else
        RESUME_CWD=$(_arm_realpath "$RESUME_CWD_OVERRIDE")
    fi
else
    # Extract resume_cwd: from the first YAML frontmatter block only.
    # awk collects lines between the first two --- markers; sed picks
    # the resume_cwd: value; head -1 takes only the first match.
    _fm_cwd=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$HANDOVER_PATH" \
        | sed -n 's/^resume_cwd:[[:space:]]*//p' | head -1)
    # rtrim FIRST (removes trailing \r on CRLF files too), THEN strip
    # surrounding quotes. Order matters: on CRLF input the raw value is
    # `"/path"\r`; quote-strip looks for a trailing `"` but the last
    # byte is `\r` so it no-ops, leaving `/path"` after rtrim strips `\r`.
    _fm_cwd="${_fm_cwd%"${_fm_cwd##*[![:space:]]}"}"  # rtrim (incl \r)
    _fm_cwd="${_fm_cwd#\'}" ; _fm_cwd="${_fm_cwd%\'}"
    _fm_cwd="${_fm_cwd#\"}" ; _fm_cwd="${_fm_cwd%\"}"
    # Track whether the key was present (non-empty after trim+unquote)
    # so the fallback block can emit the correct discoverability message.
    _fm_cwd_found=0
    [ -n "$_fm_cwd" ] && _fm_cwd_found=1

    if [ -n "$_fm_cwd" ]; then
        if [ -n "$WSL_DISTRO" ]; then
            RESUME_CWD="$_fm_cwd"
        elif [ -d "$_fm_cwd" ]; then
            RESUME_CWD=$(_arm_realpath "$_fm_cwd")
        else
            echo "WARN arm-resume: handover resume_cwd: '$_fm_cwd' is not a directory — ignoring, falling back" >&2
            _fm_cwd=""
        fi
    fi

    if [ -z "$_fm_cwd" ]; then
        _handover_abs=$(_arm_realpath "$HANDOVER_PATH")
        _handover_dir=$(dirname "$_handover_abs")
        if ! RESUME_CWD=$(git -C "$_handover_dir" rev-parse --show-toplevel 2>/dev/null); then
            RESUME_CWD="$_handover_dir"
        fi
        unset _handover_abs _handover_dir
        # Only emit the discoverability warning when resume_cwd was genuinely
        # absent from the frontmatter. When it was present-but-invalid the
        # bad-path WARN above already explained it; emitting this too is
        # factually wrong ("no resume_cwd" when there was one).
        if [ "$_fm_cwd_found" -eq 0 ]; then
            echo "WARN arm-resume: no --cwd and no 'resume_cwd:' in handover frontmatter — defaulting cwd to '$RESUME_CWD'. For cross-repo handovers (handover in one repo, work in another) set 'resume_cwd: <work-repo>' in the handover frontmatter or pass --cwd." >&2
        fi
        # HIMMEL-1330: a handover parked inside a SINGLE-WRITER repo (the luna
        # vault, or any other repo that commits straight to main by design --
        # see the repo-root `.single-writer` marker) and carrying no explicit
        # --cwd/--worktree/resume_cwd: auto-detects its cwd as THAT repo. A
        # WARN alone is not enough here: nothing reads an unattended arm's
        # stderr until after the fact, so this has silently armed himmel work
        # INSIDE the luna vault, picking up its direct-to-main commit
        # behavior for work that was never meant to land there. Refuse
        # outright unless the operator opts in -- an explicit --cwd/--worktree/
        # resume_cwd: already skips this whole fallback block (see above), and
        # ARM_VAULT_CWD_OK=1 is the escape hatch for a genuine vault arm.
        # --dry-run stays side-effect-free (preview only, matches the
        # HIMMEL-1365 temp-path guard's own --dry-run exemption).
        if [ -f "$RESUME_CWD/.single-writer" ] && [ "${ARM_VAULT_CWD_OK:-}" != "1" ]; then
            # HIMMEL-2147 pre-refusal fallback: a handover parked under the
            # bucket layout (handovers/<user>/<repo-bucket>/...) names its own
            # work repo implicitly via that bucket segment. Look it up in the
            # handover registry (the same file resolve-active-item.sh reads)
            # BEFORE refusing outright. Fail-closed by construction: no
            # "handovers/" segment in the path, no registry file, no matching
            # bucket key, or the resolved repo is ITSELF single-writer all
            # leave _arm_2147_fb_cwd empty, falling through to the unchanged
            # refusal below. Never silently resolves into a single-writer repo.
            _arm_2147_fb_bucket=""
            case "$HANDOVER_PATH" in
                */handovers/*) _arm_2147_fb_rel="${HANDOVER_PATH#*/handovers/}" ;;
                handovers/*)   _arm_2147_fb_rel="${HANDOVER_PATH#handovers/}" ;;
                *)             _arm_2147_fb_rel="" ;;
            esac
            if [ -n "$_arm_2147_fb_rel" ]; then
                _arm_2147_fb_rel="${_arm_2147_fb_rel#*/}"       # strip <user>/
                _arm_2147_fb_bucket="${_arm_2147_fb_rel%%/*}"   # <repo-bucket>
            fi
            _arm_2147_fb_reg="${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}"
            _arm_2147_fb_cwd=""
            if [ -n "$_arm_2147_fb_bucket" ] && [ -f "$_arm_2147_fb_reg" ]; then
                _arm_2147_fb_cwd=$(REG="$_arm_2147_fb_reg" BUCKET="$_arm_2147_fb_bucket" node -e '
                    const fs=require("fs"), e=process.env;
                    let j; try{ j=JSON.parse(fs.readFileSync(e.REG,"utf8")); }catch(err){ process.exit(1); }
                    const repos=(j&&j.repos)||{};
                    for (const k of Object.keys(repos)) {
                        const bn = repos[k].bucket_name || k;
                        if (bn === e.BUCKET) { process.stdout.write(repos[k].path||""); process.exit(0); }
                    }
                    process.exit(1);
                ' 2>/dev/null) || _arm_2147_fb_cwd=""
            fi
            if [ -n "$_arm_2147_fb_cwd" ] && [ -d "$_arm_2147_fb_cwd" ] \
                && [ ! -f "$_arm_2147_fb_cwd/.single-writer" ]; then
                echo "WARN arm-resume: no --cwd/--worktree/resume_cwd: named a work repo and the auto-detected cwd is single-writer -- falling back to the handover registry's '$_arm_2147_fb_bucket' bucket: '$_arm_2147_fb_cwd' (HIMMEL-2147). Set 'resume_cwd: <work-repo>' in the handover frontmatter to avoid relying on this fallback." >&2
                RESUME_CWD=$(_arm_realpath "$_arm_2147_fb_cwd")
            elif [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY arm-resume: would REFUSE to arm -- auto-detected cwd '$RESUME_CWD' is a single-writer repo with no explicit --cwd/--worktree/resume_cwd: (HIMMEL-1330), and no registry bucket fallback resolved; a real arm exits 14 unless ARM_VAULT_CWD_OK=1 is set." >&2
            else
                {
                    echo "ERR arm-resume: refusing to arm -- the auto-detected cwd is a SINGLE-WRITER repo (HIMMEL-1330):"
                    echo "    $RESUME_CWD"
                    echo "No --cwd, --worktree, or 'resume_cwd:' frontmatter named a work repo, so this"
                    echo "arm would default INSIDE the vault/state repo -- picking up its direct-to-main"
                    echo "commit behavior for work that likely belongs in a different repo."
                    echo "Set 'resume_cwd: <work-repo>' in the handover frontmatter, pass --cwd/--worktree,"
                    echo "or set ARM_VAULT_CWD_OK=1 if arming INTO the vault is genuinely intended."
                } >&2
                exit 14
            fi
            unset _arm_2147_fb_bucket _arm_2147_fb_rel _arm_2147_fb_reg _arm_2147_fb_cwd
        fi
    fi
    unset _fm_cwd _fm_cwd_found
fi

# WSL-station cwd values live inside the selected distro. The Windows host
# must neither canonicalise nor probe them; use a login shell in-distro so
# the validation sees the same environment as the fired relaunch.
if [ -n "$WSL_DISTRO" ]; then
    _wsl_cwd_test="test -d $(_bash_single_quote "$RESUME_CWD")"
    if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        wsl.exe -d "$WSL_DISTRO" -e bash -lc "$_wsl_cwd_test"; then
        echo "ERR arm-resume: in-distro cwd does not exist: '$RESUME_CWD' (distro '$WSL_DISTRO')" >&2
        exit 4
    fi
    unset _wsl_cwd_test
fi

# ---------------------------------------------------------------------------
# HIMMEL-2383 -- base verification gate. Console ruling 66: arm a leg on a
# fence only once every merged PR that touched it already carries its
# after-report SUMMARY. Opt-in via the handover's OWN `fence:` frontmatter
# key (same convention as resume_cwd:/resume_worktree: above) -- a doc with
# no `fence:` key is unaffected, so this is silent for the common case (a
# wrap note, a status update, any handover that names no fence).
#
# Placed AFTER the HANDOVER_PATH existence check (line ~1617, well above)
# and after cwd resolution, mirroring where resume_cwd: itself is read --
# reading frontmatter from a not-yet-validated path would abort under
# `set -e` with a bare awk failure instead of the real "does not exist"
# message. --dry-run still exercises this (it exits later, at the schedule
# call itself).
_fm_fence=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$HANDOVER_PATH" \
    | sed -n 's/^fence:[[:space:]]*//p' | head -1)
_fm_fence="${_fm_fence%"${_fm_fence##*[![:space:]]}"}"  # rtrim (incl \r)
_fm_fence="${_fm_fence#\'}" ; _fm_fence="${_fm_fence%\'}"
_fm_fence="${_fm_fence#\"}" ; _fm_fence="${_fm_fence%\"}"

if [ -n "$_fm_fence" ]; then
    _base_status_sh="$SCRIPT_DIR/../console/base-status.sh"
    # Any of these three shapes means "the base cannot be certified clean":
    # the script is missing, it query-errored (gh down, rate-limited, a
    # truncated merged-PR list — base-status.sh now exits nonzero on all of
    # these), or it printed PENDING/RED lines. Per HIMMEL-2383 CR finding
    # codex-1, "cannot verify" must refuse exactly like "verified dirty" —
    # an infra hiccup at arm time is precisely the moment ruling 66 exists
    # to catch, so it gets the SAME --provisional-base-ok gate, never a
    # silent unchecked proceed.
    _base_diag=""
    if [ ! -x "$_base_status_sh" ] && [ ! -f "$_base_status_sh" ]; then
        _base_rc=127
        _base_out="base-status.sh is missing at $_base_status_sh -- cannot verify the base."
    else
        # Run FROM the resolved work repo (HIMMEL-2383 CR finding codex-2,
        # round 2), not the launching session's own cwd — base-status.sh
        # resolves its target repo via `gh repo view` off ITS cwd, and this
        # arm can be for a different repo entirely (cross-repo handovers,
        # documented above at --cwd/resume_cwd). Without the cd, the fence
        # would be certified against whatever repo the ARMING session
        # happens to be sitting in. Word-split on $_fm_fence is on purpose:
        # fence: is a space-separated list of paths, each forwarded as its
        # own base-status.sh argument. A failed cd degrades to the same
        # "cannot verify" path below (its error text becomes $_base_out).
        #
        # stdout and stderr are captured SEPARATELY (round-2 CR self-check):
        # base-status.sh now prints incidental diagnostics to stderr (e.g.
        # an unresolved gh identity) even on an otherwise-clean run — a
        # merged 2>&1 capture would make a clean fence's $_base_out
        # non-empty on that diagnostic alone and trip a false refusal. The
        # refuse/warn DECISION reads stdout (PENDING/RED lines) + exit code
        # only; stderr is surfaced for visibility but never decides.
        _base_rc=0
        _base_err_file=$(mktemp 2>/dev/null) || _base_err_file=""
        if [ -n "$_base_err_file" ]; then
            # shellcheck disable=SC2086
            _base_out=$(cd "$RESUME_CWD" 2>"$_base_err_file" && bash "$_base_status_sh" $_fm_fence 2>>"$_base_err_file") || _base_rc=$?
            _base_diag=$(cat "$_base_err_file" 2>/dev/null)
            rm -f "$_base_err_file"
        else
            # mktemp itself failed -- fall back to a merged capture (the
            # stderr-pollution risk this fix exists to close, but only on
            # the rare host where even mktemp is unavailable).
            # shellcheck disable=SC2086
            _base_out=$(cd "$RESUME_CWD" 2>&1 && bash "$_base_status_sh" $_fm_fence 2>&1) || _base_rc=$?
        fi
    fi
    [ -n "$_base_diag" ] && printf '%s\n' "$_base_diag" >&2
    if [ "$_base_rc" -ne 0 ] || [ -n "$_base_out" ]; then
        if [ "$PROVISIONAL_BASE_OK" -eq 1 ]; then
            {
                echo "WARN arm-resume: arming on a PROVISIONAL base (--provisional-base-ok) -- fence '$_fm_fence' could not be certified clean:"
                printf '%s\n' "$_base_out"
                echo "Paste this warning into the leg's first message (ruling 66): hold fence conclusions until the fix lands, or rebase past it if the after-report comes back red."
            } >&2
        else
            {
                echo "ERR arm-resume: refusing to arm -- fence '$_fm_fence' could not be certified clean (ruling 66, HIMMEL-2383):"
                printf '%s\n' "$_base_out"
                echo "Pass --provisional-base-ok to arm anyway (prints the same warning for the leg's first message), or wait for the after-report to land / the query to succeed."
            } >&2
            exit 21
        fi
    fi
    unset _base_status_sh _base_out _base_rc _base_diag _base_err_file
fi
unset _fm_fence

# Task name — ticket-aware (HIMMEL-540), extended with the full derived
# identity (HIMMEL-716): <TICKET>-<name-half>-<sN> so scheduler rows
# (schtasks /query, atq) are scannable AND chain-attributable, e.g.
# HIMMEL-Resume-HIMMEL-654-ws7-gates-s32-<path-suffix>. The HIMMEL-Resume-
# prefix AND the per-handover-unique <path-suffix> are preserved, so every
# dedup/collision/marker site that reads $TASK_NAME is unaffected - the value
# only gains a middle identity segment, recomputed deterministically from the
# same handover so a re-arm still exact-matches its own slot. Built HERE (not
# at parse time) so $WORKTREE_BRANCH (resolved above) is available to the
# inference helpers. The path-suffix matches the schedule-resume.sh:88
# convention so broad cross-route dedup (the HIMMEL-Resume- prefix grep)
# still matches between routes.
_ho_ticket=$(_infer_ticket "$HANDOVER_PATH")
# HIMMEL-1329: the strict, frontmatter-only ticket (see _infer_ticket_strict
# above) -- what the ticket-level mutex keys on, deliberately narrower than
# $_ho_ticket (which also feeds the best-effort naming/HIMMEL-1331
# ticket-status paths). Called as a PLAIN statement, NOT `$(...)` -- see the
# function's own comment for why a subshell would silently lose this.
_infer_ticket_strict "$HANDOVER_PATH"
# HIMMEL-1304: derive the identity from the CANONICAL path, not the path as
# typed, and make the suffix injective. Pre-1304 this read $HANDOVER_PATH
# directly, which broke dedup in BOTH directions at once:
#   false-negative — no canonicalization, so `x.md` / `./x.md` / an absolute
#     path / a symlink / a Windows case-or-drive-form variant each produced a
#     DIFFERENT name ⇒ two slots armed for ONE handover (the double-fire).
#   false-positive — `tr -cd` DELETES out-of-class bytes, so `a+b.md` and
#     `ab.md` collapsed to the SAME name ⇒ a spurious rc-3 refusal, and a
#     `--force` that replaced the OTHER handover's slot.
# It also silently defeated the cross-machine arms-registry dedup (rc 8), which
# keys on this same identity.
_ho_ident=$(_arm_identity_path "$HANDOVER_PATH")
_path_hash=$(_arm_path_hash "$_ho_ident")
# shellcheck disable=SC1003  # `\\` in single quotes is two backslashes which tr collapses to one literal `\` — intentional
_path_readable=$(printf '%s' "$_ho_ident" | tr '/\\' '__' | tr -cd '[:alnum:]_-')
# Keep the TAIL when clipping: the filename end of the path is what
# distinguishes sibling handovers, and a schtasks task name is length-bounded
# (the pre-1304 suffix was the whole path, unbounded). Uniqueness rides on the
# hash, so clipping the readable half is safe.
if [ "${#_path_readable}" -gt 72 ]; then
    _path_readable="${_path_readable: -72}"
fi
if [ -n "$_path_hash" ]; then
    _path_suffix="${_path_readable}-h${_path_hash}"
else
    # No hasher on this machine — degrade to the pre-1304 readable-only suffix
    # rather than refuse to arm, but say so: sanitization collisions are back
    # for this arm, so a --force here can still hit a same-suffix neighbour.
    echo "WARN arm-resume: no sha256 hasher (sha256sum/shasum/python) available -- the arm identity falls back to the sanitized path alone, so two handover paths that differ only in punctuation can still collide (HIMMEL-1304). Install one to restore collision-proof dedup." >&2
    _path_suffix="$_path_readable"
fi
# The name segment is part of the IDENTITY too, so it must come from the
# canonical path as well — deriving it from $HANDOVER_PATH while the suffix came
# from the canonical form left the two halves disagreeing: on Windows
# `.../T/alias.md` and `.../T/ALIAS.md` produced a matching suffix+hash but
# name segments `alias` vs `ALIAS`, so the whole name still differed and the
# arm still took two slots. (The directory half of the path already folded,
# which is exactly why this only showed up on a basename case variant.)
# SESSION_NAME below deliberately keeps the RAW path — it is the human-facing
# session title, where preserving the operator's own capitalisation is right.
_name_seg=$(_compose_arm_name "$_ho_ticket" "$_ho_ident" task)
if [ -n "$_name_seg" ]; then
    TASK_NAME="HIMMEL-Resume-${_name_seg}-${_path_suffix}"
else
    TASK_NAME="HIMMEL-Resume-${_path_suffix}"
fi
# The pre-HIMMEL-1304 name for this same handover. Dedup matches EITHER, so a
# slot armed before this upgrade is still found (and still replaced by --force)
# instead of being orphaned into an unseen second fire. See
# _arm_own_identity_match for why this migration is required, not optional.
# shellcheck disable=SC1003  # `\\` in single quotes is two backslashes which tr collapses to one literal `\` — intentional
_path_suffix_legacy=$(printf '%s' "$HANDOVER_PATH" | tr '/\\' '__' | tr -cd '[:alnum:]_-')
# Both halves reproduce the pre-1304 derivation, which read the RAW path — a
# legacy name built from the canonical name segment would match nothing.
_name_seg_legacy=$(_compose_arm_name "$_ho_ticket" "$HANDOVER_PATH" task)
if [ -n "$_name_seg_legacy" ]; then
    TASK_NAME_LEGACY="HIMMEL-Resume-${_name_seg_legacy}-${_path_suffix_legacy}"
else
    TASK_NAME_LEGACY="HIMMEL-Resume-${_path_suffix_legacy}"
fi
[ "$TASK_NAME_LEGACY" = "$TASK_NAME" ] && TASK_NAME_LEGACY=""
# The armed relaunch's `claude -n` session title (HIMMEL-702/716) - the same
# composer renders both surfaces from one identity, so the scheduler row name
# and the session/tab title can never disagree.
SESSION_NAME=$(_compose_arm_name "$_ho_ticket" "$HANDOVER_PATH" title)
FLOW_RUN_NOTE=$(_infer_slug "$HANDOVER_PATH")
# HIMMEL-1329/1331 fix: _ho_ticket is kept alive (NOT unset here) -- it is
# read again below by the HIMMEL-1329 ticket-level mutex and by the
# HIMMEL-1331 shipped-work preflight's ticket-status probe. Pre-fix this was
# unset right here and both later readers silently saw an empty string
# (`${_ho_ticket:-}`), so the shipped-preflight's Jira ticket-status check
# was permanently dead code — confirmed by grep: no test exercised it.
unset _path_suffix _name_seg _ho_ident _path_hash _path_readable _path_suffix_legacy _name_seg_legacy

# Pre-trust the resolved cwd (HIMMEL-386) so the fired relaunch doesn't stall
# on Claude Code's interactive workspace-trust prompt ("Is this a project you
# trust?"). An autonomous relaunch has no human to answer it and its stdin is
# closed, so an untrusted cwd silently wastes the whole run. Non-fatal: a
# pre-seed failure must never block the arm itself.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY arm-resume: would pre-trust workspace '$RESUME_CWD' in ~/.claude.json"
else
    "$SCRIPT_DIR/../lib/ensure-workspace-trust.sh" "$RESUME_CWD" \
        || echo "WARN arm-resume: workspace-trust pre-seed failed for '$RESUME_CWD' (arm continues; first relaunch may prompt to trust the folder)" >&2
fi

# Dedup: list existing HIMMEL-Resume jobs. Fail-CLOSED if the listing
# tool itself errors — silent empty result + arm = duplicate.
#
# Scope ($1, HIMMEL-340):
#   task — only the CURRENT $TASK_NAME (per-handover dedup; the default for
#          an explicit arm, so N distinct handovers each get their own slot).
#          This is the ONLY scope a --force replace ever reaps from (HIMMEL-1563).
#   all  — every HIMMEL-Resume-* job (the legacy broad behavior; used by the
#          --dedup-any safety arms and by the soft slot-cap count). READ-ONLY
#          only post-1563: the rc=3 refusal message and the cap count, never a
#          delete — a prefix-wide reap cancelled foreign chains' arms.
# Defaults to "all" so any unscoped caller keeps the pre-340 semantics.

# _crontab_list <scope> — grep the crontab for our HIMMEL-Resume markers
# (HIMMEL-594: shared by the linux crontab fallback + the macOS crontab-only
# branch so dedup reads the same store the schedule wrote).
_crontab_list() {
    local scope="${1:-all}"
    if [ "$scope" = task ]; then
        # The crontab marker is a trailing `# <TASK_NAME>` on a longer command
        # line, so this cannot use the whole-line _arm_own_identity_match the
        # other two sites share — match the anchored suffix per identity
        # instead. TASK_NAME is sanitized to [:alnum:]_- so it carries no BRE
        # specials. HIMMEL-1304: also match the legacy identity, guarded on
        # non-empty — an empty alternative would anchor to `# $` and sweep in
        # unrelated lines.
        if [ -n "${TASK_NAME_LEGACY:-}" ]; then
            crontab -l 2>/dev/null \
                | grep -E "# (${TASK_NAME}|${TASK_NAME_LEGACY})$" || true
        else
            crontab -l 2>/dev/null | grep -E "# ${TASK_NAME}$" || true
        fi
    elif [ "$scope" = ticket ]; then
        # HIMMEL-1329: any OTHER handover's slot for this same ticket. Reads
        # the STRICT (frontmatter-only) ticket, not the best-effort combined
        # one -- see _infer_ticket_strict. Ticket keys are validated by
        # _validate_key to [A-Z][A-Z0-9]*-[0-9]+ — no BRE specials, so it's
        # safe to interpolate directly. Matches the marker mid-line (not
        # anchored to EOL like the `task` case above) because this scans for
        # a SUBSTRING of the identity, not an exact one.
        [ -n "${_ho_ticket_strict:-}" ] || return 0
        crontab -l 2>/dev/null | grep -E "# HIMMEL-Resume-${_ho_ticket_strict}(-|\$)" || true
    else
        crontab -l 2>/dev/null | grep -F 'HIMMEL-Resume-' || true
    fi
}

# HIMMEL-708 spawn-tax reduction: memoize the Windows scheduler listing.
# `schtasks /query` is ~1.2s per spawn and was re-run up to 4× per arm — once
# for the dedup read, twice for the soft-slot-cap count (list_existing all +
# task), and once for the collision check — each also re-running its own CSV
# parse on top of the spawn. Populate it ONCE here so the
# $()-wrapped list_existing / list_collision_candidates readers inherit the
# result from the parent shell (a subshell that populated it could not persist
# it up). Sets, for the caller to read directly:
#   _SCHTASKS_CSV    raw `/query /fo CSV /nh` stdout — the collision check needs
#                    the Next-Run-Time column, so it reads this.
#   _SCHTASKS_RC     the query's exit code (collision skips on rc!=0, matching
#                    its prior behavior).
#   _SCHTASKS_NAMES  sorted-unique HIMMEL-Resume-* task names — dedup/soft-cap.
# Fail-CLOSED on a genuine schtasks error (same policy list_existing had: an
# error keyword in stderr → ERR + exit 2), so a silent empty result can never
# be mistaken for "no jobs" and produce a duplicate arm.
# MSYS_NO_PATHCONV=1 is per-call (HIMMEL-125): without it gitbash mangles each
# /flag into a Windows-rooted path and schtasks rejects the call; scoping it to
# this one command keeps it off the later git -C in RESUME_CWD resolution.
# HIMMEL-1337: `schtasks /query` enumerates the operator's ENTIRE Task
# Scheduler library, not just the ~9 HIMMEL-Resume-* jobs this script cares
# about. Reported live: 219 real scheduled tasks on the machine turned a
# single --dry-run into a 5+ minute wait -- schtasks.exe's per-task overhead
# scales with the TOTAL task count (a well-documented Windows quirk), and
# `/tn` does not accept a wildcard, so schtasks itself cannot filter
# server-side. `Get-ScheduledTask -TaskName 'HIMMEL-*'` CAN: it is COM-backed
# (not the legacy schtasks.exe path) and resolves the wildcard before
# returning anything, so the ~9 matches come back fast regardless of how many
# unrelated tasks share the machine. Emits lines shaped exactly like schtasks'
# own `/fo CSV /nh` output ("\Name","NextRunTime","Ready") so every downstream
# parser (list_existing / list_collision_candidates) needs no change at all.
#
# Gated on SCHTASKS_CMD being the untouched default: every existing test that
# fabricates scheduler state pins SCHTASKS_CMD to its own stub path
# (HIMMEL-1610), so this fast path never intercepts a test's simulated CSV --
# it only activates for a real, unstubbed arm. Bounded by `timeout` and
# fail-open on any error/timeout/absence: a slow or missing `powershell`
# falls straight through to the pre-1337 full schtasks scan below, never
# blocks an arm.
_win_fast_task_csv() {
    [ "${SCHTASKS_CMD:-schtasks}" = "schtasks" ] || return 1
    command -v powershell >/dev/null 2>&1 || return 1
    local _script _out _rc
    # Backtick-escaped double-quotes inside a PS double-quoted string + -f
    # formatting (no PS single-quotes anywhere): a bash single-quoted wrapper
    # cannot contain a literal `'`, and char+string concatenation semantics in
    # PowerShell are ambiguous enough to not rely on -- this sidesteps both.
    # shellcheck disable=SC2016  # single-quoted on purpose -- this is PowerShell source, not bash; $ must NOT expand here
    _script='
Get-ScheduledTask -TaskName "HIMMEL-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $nrt = "N/A"
    try {
        $info = $_ | Get-ScheduledTaskInfo -ErrorAction Stop
        if ($info.NextRunTime) { $nrt = $info.NextRunTime.ToString("M/d/yyyy h:mm:ss tt") }
    } catch {}
    Write-Output ("`"\{0}`",`"{1}`",`"Ready`"" -f $_.TaskName, $nrt)
}
'
    if command -v timeout >/dev/null 2>&1; then
        _out=$(timeout "${ARM_PREFLIGHT_TIMEOUT:-5}" powershell -NoProfile -NonInteractive -Command "$_script" 2>/dev/null)
    else
        _out=$(powershell -NoProfile -NonInteractive -Command "$_script" 2>/dev/null)
    fi
    _rc=$?
    [ "$_rc" -eq 0 ] || return 1
    printf '%s\n' "$_out"
}

_SCHTASKS_CACHE_DONE=""
_SCHTASKS_CSV=""
_SCHTASKS_RC=0
_SCHTASKS_NAMES=""
_ensure_schtasks_cache() {
    [ -n "$_SCHTASKS_CACHE_DONE" ] && return 0
    if _SCHTASKS_CSV=$(_win_fast_task_csv); then
        _SCHTASKS_RC=0
        # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from the path-prefixed task names (same construct as the schtasks-CSV branch below)
        _SCHTASKS_NAMES=$(printf '%s\n' "$_SCHTASKS_CSV" \
            | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
            | tr -d '"\\' \
            | sort -u || true)
        _SCHTASKS_CACHE_DONE=1
        return 0
    fi
    local err_file
    err_file=$(mktemp -t arm-resume.err.XXXXXX)
    _SCHTASKS_CSV=$(MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /query /fo CSV /nh 2>"$err_file")
    _SCHTASKS_RC=$?
    if [ "$_SCHTASKS_RC" -ne 0 ]; then
        # schtasks returns rc=1 when there are NO scheduled tasks at all
        # (empty scheduler) — treat as empty. Any error keyword in stderr = fail.
        if grep -qiE 'access|denied|cannot|fail' "$err_file" 2>/dev/null; then
            echo "ERR arm-resume: schtasks /query failed (rc=$_SCHTASKS_RC):" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # CSV TaskName column is path-prefixed (`\HIMMEL-Resume-...`); strip the
    # leading `\` and quotes.
    # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from schtasks's path-prefixed task names
    _SCHTASKS_NAMES=$(printf '%s\n' "$_SCHTASKS_CSV" \
        | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u || true)
    _SCHTASKS_CACHE_DONE=1
}

list_existing() {
    local scope="${1:-all}"
    case "$PLATFORM" in
        windows)
            _ensure_schtasks_cache
            if [ "$scope" = task ]; then
                # Matches the current identity OR the pre-HIMMEL-1304 one, so an
                # already-armed slot survives the upgrade as a dedup hit.
                printf '%s\n' "$_SCHTASKS_NAMES" | _arm_own_identity_match
            elif [ "$scope" = ticket ]; then
                # HIMMEL-1329: any OTHER handover's slot for this same ticket,
                # keyed on the STRICT frontmatter-only ticket (see
                # _infer_ticket_strict). _compose_arm_name always puts a
                # present ticket FIRST in the task-name segment
                # (HIMMEL-Resume-<TICKET>-...), so a prefix match right after
                # the HIMMEL-Resume- marker finds it regardless of which
                # slug/session/path-hash follows.
                if [ -n "${_ho_ticket_strict:-}" ]; then
                    printf '%s\n' "$_SCHTASKS_NAMES" | grep -E "^HIMMEL-Resume-${_ho_ticket_strict}(-|\$)" || true
                fi
            else
                printf '%s\n' "$_SCHTASKS_NAMES"
            fi
            ;;
        linux)
            if command -v atq >/dev/null 2>&1; then
                local err_file rc atq_out
                err_file=$(mktemp -t arm-resume.err.XXXXXX)
                atq_out=$(atq 2>"$err_file")
                rc=$?
                if [ "$rc" -ne 0 ]; then
                    echo "ERR arm-resume: atq failed (rc=$rc) — atd not running?" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 2
                fi
                rm -f "$err_file"
                # at jobs don't have names; we grep each job body for
                # our marker. arm-resume injects this marker into the
                # at-job body via a leading comment line (see schedule
                # block below).
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    local job_id
                    job_id=$(printf '%s' "$line" | awk '{print $1}')
                    [ -z "$job_id" ] && continue
                    # NB: use `if … then printf; fi`, NOT `grep … && printf`.
                    # A non-matching job makes grep exit 1; as the last command
                    # in this loop body that 1 would propagate out of the while
                    # loop → list_existing returns 1 → `existing=$(list_existing)`
                    # aborts under `set -e` (the multislot-on-Linux bug: arming a
                    # 2nd distinct handover failed whenever a non-matching at-job
                    # was already queued). The `if` always exits 0.
                    if [ "$scope" = task ]; then
                        # Exact whole-line marker (# $TASK_NAME) so a task
                        # whose name is a prefix of another's can't match it.
                        # HIMMEL-1304: the POSIX at-job marker is the SAME
                        # identity as the Windows task name, so it moves in
                        # lockstep — including the legacy-name migration arm.
                        if at -c "$job_id" 2>/dev/null \
                            | _arm_own_identity_match '# ' | grep -q .; then
                            printf 'at-job-%s\n' "$job_id"
                        fi
                    elif [ "$scope" = ticket ]; then
                        # HIMMEL-1329: same STRICT ticket-prefix scan as the
                        # crontab/windows cases above, applied to the at-job body.
                        if [ -n "${_ho_ticket_strict:-}" ] && at -c "$job_id" 2>/dev/null \
                            | grep -qE "# HIMMEL-Resume-${_ho_ticket_strict}(-|\$)"; then
                            printf 'at-job-%s\n' "$job_id"
                        fi
                    else
                        if at -c "$job_id" 2>/dev/null | grep -q 'HIMMEL-Resume-'; then
                            printf 'at-job-%s\n' "$job_id"
                        fi
                    fi
                done <<< "$atq_out"
            elif command -v crontab >/dev/null 2>&1; then
                _crontab_list "$scope"
            fi
            ;;
        macos)
            # macOS uses crontab only (see schedule_arm header) — read the same
            # store schedule writes so dedup operates on it, never the at queue.
            _crontab_list "$scope"
            ;;
    esac
}

# _crontab_delete <marker> [soft] — remove exactly one crontab LINE (HIMMEL-594:
# shared by the linux crontab branch + the macOS crontab-only branch). `soft`
# (HIMMEL-1304) mirrors delete_existing's windows/at-job soft handling: a
# failed delete WARNs and returns 1 instead of exiting 2, because soft mode is
# only used by the post-commit replace sweep where the new arm is already
# registered and verified -- see the `delete_existing` comment for why exiting
# there would be a lie in the operator's most decision-relevant direction.
# `hard` mode (the pre-arm dedup path, where aborting is correct) is
# byte-identical to before. Soft vs hard changes ONLY whether this function
# exits or returns -- never whether $snap is discarded once it holds real
# data (see the awk-rc comment below: an awk failure keeps $snap either way).
_crontab_delete() {
    local marker="$1" mode="${2:-hard}"
    # marker is the full matched crontab LINE — rewrite without exactly that
    # line (HIMMEL-340: scoped delete so a --force on one handover can't wipe
    # sibling slots). Snapshot first so a mid-pipeline failure doesn't wipe.
    local snap
    snap=$(mktemp -t crontab.snap.XXXXXX)
    if ! crontab -l > "$snap" 2>/dev/null; then
        rm -f "$snap"
        if [ "$mode" = soft ]; then
            echo "WARN arm-resume: the new arm is registered, but the superseded crontab entry '$marker' could NOT be removed (crontab -l failed) -- it is STILL QUEUED and will fire alongside the new one. Remove it manually: crontab -e" >&2
            return 1
        fi
        echo "ERR arm-resume: crontab -l failed; aborting before rewrite" >&2
        exit 2
    fi
    # HIMMEL-1304: drop only the FIRST line exactly matching $marker, not every
    # occurrence. _crontab_schedule always APPENDS rather than overwriting a
    # same-marker line in place, so a --force re-arm at the same time can
    # leave the superseded line and the freshly-created one byte-identical —
    # the old `grep -vxF` (whole-file, every match) would then strip BOTH,
    # deleting the arm we just made along with the one it superseded. awk
    # with a one-shot guard removes exactly the superseded copy and leaves any
    # duplicate (the new arm) standing. Reads the marker via ENVIRON, not
    # `-v m=`: a crontab entry embeds a %q-escaped session name, which can
    # contain a literal backslash-space (`load\ /path`), and POSIX awk's `-v`
    # assignment runs C-string escape processing on its value — it silently
    # drops that backslash, corrupting the comparison so it can never match
    # (verified: this is why the first attempt at this fix left both
    # duplicate lines in place). ENVIRON values are not escape-processed.
    # Capture awk's own exit status separately from "matched nothing" (CR
    # round: an unchecked awk rc let ANY awk failure -- missing binary,
    # runtime error, unreadable snapshot -- fall through with $filtered empty,
    # which `[ -z "$filtered" ]` then reads as "the crontab is now empty" and
    # installs an EMPTY crontab, wiping every entry (himmel's and the
    # operator's unrelated ones) -- and since that write "succeeded", the
    # $snap backup made for exactly this case was then deleted too. An empty
    # $filtered is legitimately correct when the removed line was the only
    # one queued, so it must stay a valid outcome -- only a nonzero awk rc is
    # the failure to abort on, same shape as the crontab-read guard above
    # (exit 2, keep $snap).
    local filtered rc=0
    filtered=$(MARKER="$marker" awk '$0 == ENVIRON["MARKER"] && !d { d = 1; next } { print }' "$snap") || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$mode" = soft ]; then
            echo "WARN arm-resume: the new arm is registered, but the superseded crontab entry '$marker' could NOT be removed (awk rc=$rc); original saved at $snap -- it is STILL QUEUED and will fire alongside the new one. Remove it manually: crontab -e" >&2
            return 1
        fi
        echo "ERR arm-resume: crontab filter failed (awk rc=$rc); original saved at $snap" >&2
        exit 2
    fi
    # $filtered empty → install an empty crontab (correct); else write the lines.
    if ! { [ -z "$filtered" ] || printf '%s\n' "$filtered"; } | crontab - 2>/dev/null; then
        if [ "$mode" = soft ]; then
            echo "WARN arm-resume: the new arm is registered, but the superseded crontab entry '$marker' could NOT be removed (crontab rewrite failed); original saved at $snap -- it is STILL QUEUED and will fire alongside the new one. Remove it manually: crontab -e" >&2
            return 1
        fi
        echo "ERR arm-resume: crontab rewrite failed; original saved at $snap" >&2
        exit 2
    fi
    rm -f "$snap"
    echo "arm-resume: removed crontab entry: $marker"
}

# delete_existing <marker> [soft]
#
# `soft` (HIMMEL-1304) turns the hard `exit 2` on a failed delete into a WARN +
# return 1. It is used ONLY by the post-commit replace sweep, which runs AFTER
# the new job is registered and verified: at that point exiting 2 would be a lie
# in the operator's most decision-relevant direction — it reads as "the arm
# failed" when in fact the arm SUCCEEDED and all that remains is an
# un-reaped sibling. A stale extra slot is a much smaller harm than believing
# you have no arm when you do, and it is still surfaced loudly.
delete_existing() {
    local marker="$1" mode="${2:-hard}"
    case "$PLATFORM" in
        windows)
            # MSYS_NO_PATHCONV=1: see HIMMEL-125 note in list_existing.
            if MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /delete /tn "$marker" /f >/dev/null 2>&1; then
                echo "arm-resume: deleted scheduled task: $marker"
            elif [ "$mode" = soft ]; then
                echo "WARN arm-resume: the new arm is registered, but the superseded task '$marker' could NOT be deleted -- it is STILL SCHEDULED and will fire alongside the new one. Remove it manually: schtasks /delete /tn \"$marker\" /f" >&2
                return 1
            else
                echo "ERR arm-resume: failed to delete scheduled task: $marker" >&2
                exit 2
            fi
            ;;
        linux)
            if [[ "$marker" == at-job-* ]]; then
                local job_id="${marker#at-job-}"
                if atrm "$job_id" 2>/dev/null; then
                    echo "arm-resume: removed at job: $job_id"
                elif [ "$mode" = soft ]; then
                    echo "WARN arm-resume: the new arm is registered, but the superseded at job $job_id could NOT be removed -- it is STILL QUEUED and will fire alongside the new one. Remove it manually: atrm $job_id" >&2
                    return 1
                else
                    echo "ERR arm-resume: failed to atrm $job_id" >&2
                    exit 2
                fi
            else
                _crontab_delete "$marker" "$mode"
            fi
            ;;
        macos)
            # macOS: crontab-only, so the marker is always a crontab line
            # (the at-job-* arm is unreachable here).
            _crontab_delete "$marker" "$mode"
            ;;
    esac
}

# HIMMEL-407: time-collision check against all other HIMMEL-* scheduled tasks.
#
# list_collision_candidates(): query the scheduler for all HIMMEL-* tasks
# (broader than the HIMMEL-Resume- filter used by list_existing), parse each
# next-run datetime, and emit "<name><TAB><HH:MM>" lines. Excludes the Resume
# slot being armed (already handled by dedup above — no double-reporting).
# ARM_COLLISION_CANDIDATES is a test seam: when set, its content replaces the
# real scheduler query (one "<name><TAB><HH:MM>" per line; empty = no others).
list_collision_candidates() {
    if [ -n "${ARM_COLLISION_CANDIDATES+x}" ]; then
        printf '%s' "$ARM_COLLISION_CANDIDATES"
        return 0
    fi
    case "$PLATFORM" in
        windows)
            # HIMMEL-708: reuse the memoized `schtasks /query` from
            # _ensure_schtasks_cache instead of a 2nd (identical) spawn. This
            # tightens ONE narrow case in the safe direction: a GENUINE schtasks
            # error now fail-closes (exit 2) at the earlier dedup read rather
            # than only WARN-skipping the collision check here — and the dedup
            # read already fail-closed on that same error before this branch was
            # reachable. What still reaches here is the benign rc!=0 "no tasks"
            # case, which WARNs and skips the collision check exactly as before.
            _ensure_schtasks_cache
            local out rc
            out="$_SCHTASKS_CSV"
            rc="$_SCHTASKS_RC"
            if [ "$rc" -ne 0 ]; then
                echo "WARN arm-resume: schtasks /query returned rc=$rc — skipping collision check" >&2
                return 0
            fi
            # Parse all HIMMEL-* tasks from CSV, excluding our own Resume slot.
            # CSV format (from /fo CSV /nh): "TaskName","Next Run Time","Status"
            # TaskName is path-prefixed: "\HIMMEL-Pipeline-Harvest"
            # Next Run Time is locale datetime: "6/20/2026 2:00:00 AM" or "N/A"
            local raw_lines line name datetime hhmm
            local _cc_names=() _cc_dts=() _cc_i
            # shellcheck disable=SC1003  # `"\\\?HIMMEL-"` — BRE \? = optional backslash; matches both "\HIMMEL-" and "HIMMEL-" (same style as list_existing)
            raw_lines=$(printf '%s\n' "$out" | grep -i '"\\\?HIMMEL-' 2>/dev/null || true)
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                # Extract task name (field 1, strip quotes + leading backslash)
                # shellcheck disable=SC1003  # `'\\'` strips the literal backslash schtasks path-prefixes task names with
                name=$(printf '%s' "$line" | cut -d'"' -f2 | tr -d '\\')
                [ -z "$name" ] && continue
                # Skip our own Resume task (dedup already handles it)
                [ "$name" = "$TASK_NAME" ] && continue
                # Only check HIMMEL-* tasks (all are toolchain-owned; any that
                # launches claude could collide — we don't inspect the body)
                case "$name" in HIMMEL-*) ;; *) continue ;; esac
                # Extract Next Run Time (field 4 = 4th quoted token)
                datetime=$(printf '%s' "$line" | cut -d'"' -f4)
                # "N/A" or empty = never fires / already ran → skip
                case "$datetime" in N/A|"") continue ;; esac
                _cc_names+=("$name")
                _cc_dts+=("$datetime")
            done <<< "$raw_lines"
            # HIMMEL-2125: parse every queued datetime in ONE armored python
            # invocation instead of one py_armor_capture (mktemp x2 + interpreter
            # + rm x2) per candidate task -- a machine with several HIMMEL-*
            # cadences armed used to pay that ~4-spawn cost once per row here.
            # Locale-safe: datetime module parses M/D/YYYY H:MM:SS AM/PM.
            # Failure = WARN + skip (never block an arm on parse errors).
            if [ "${#_cc_dts[@]}" -gt 0 ]; then
                if py_armor_capture -c '
import sys, datetime as dt
fmts = ("%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M:%S", "%d/%m/%Y %H:%M:%S", "%Y-%m-%dT%H:%M:%S")
for s in sys.argv[1:]:
    out = ""
    for fmt in fmts:
        try:
            out = dt.datetime.strptime(s, fmt).strftime("%H:%M")
            break
        except ValueError:
            pass
    print(out)
' "${_cc_dts[@]}" 2>/dev/null; then
                    # One output line per candidate, in order (same order the
                    # loop above appended them); an unparseable-but-non-crashing
                    # entry prints an EMPTY line here, same as the old per-item
                    # `hhmm=""` case -- silently skipped, no WARN (only a hard
                    # python failure below warns).
                    _cc_i=0
                    while IFS= read -r hhmm; do
                        [ -n "$hhmm" ] && printf '%s\t%s\n' "${_cc_names[$_cc_i]}" "$hhmm"
                        _cc_i=$((_cc_i + 1))
                    done <<< "$PY_ARMOR_OUT"
                else
                    _cc_i=0
                    while [ "$_cc_i" -lt "${#_cc_names[@]}" ]; do
                        echo "WARN arm-resume: could not parse next-run time '${_cc_dts[$_cc_i]}' for task '${_cc_names[$_cc_i]}' — skipping in collision check" >&2
                        _cc_i=$((_cc_i + 1))
                    done
                fi
            fi
            ;;
        linux|macos)
            # crontab: grep all HIMMEL-* marker lines, parse HH:MM from the
            # cron fields (minute=$1, hour=$2 in standard crontab format).
            if command -v crontab >/dev/null 2>&1; then
                local crontab_out line mm hh name
                crontab_out=$(crontab -l 2>/dev/null || true)
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    case "$line" in *HIMMEL-*) ;; *) continue ;; esac
                    # Extract task name from trailing # HIMMEL-... marker
                    name=$(printf '%s' "$line" | grep -o 'HIMMEL-[^[:space:]]*$' || true)
                    [ -z "$name" ] && continue
                    [ "$name" = "$TASK_NAME" ] && continue
                    # Parse minute (field 1) and hour (field 2) from cron entry
                    mm=$(printf '%s' "$line" | awk '{print $1}')
                    hh=$(printf '%s' "$line" | awk '{print $2}')
                    # Skip wildcard or complex expressions (only plain numbers)
                    case "$mm$hh" in *[^0-9]*) continue ;; esac
                    printf '%s\t%02d:%02d\n' "$name" "$hh" "$mm"
                done <<< "$crontab_out"
            fi
            # at queue: inspect each job body for a HIMMEL- marker;
            # at doesn't expose the fire time per-job via atq in a reliable
            # parsed format across platforms → skip (collision guard is
            # best-effort on POSIX; the crontab branch covers the common case).
            ;;
    esac
}

# _minutes_from_midnight <HH:MM>: convert HH:MM to minutes since midnight (pure bash).
_minutes_from_midnight() {
    local t="$1" hh mm
    # HIMMEL-2177: strip a trailing CR first. py_armor_capture's python round-
    # trip writes through a Windows-native python.exe to a redirected FILE
    # (not a console), which text-mode-translates its \n to \r\n; cat reads
    # those bytes back raw (no CRLF translation under Git Bash), so a `\r`
    # rides along on the LAST field a multi-line `read` loop pulls out of
    # $PY_ARMOR_OUT -- here, every candidate HH:MM from the windows collision-
    # candidate scan. Left in place it glues onto `mm` below (t="00:40\r" ->
    # mm="40\r"), and `$(( hh * 60 + mm ))` chokes on the embedded CR: bash
    # parses "40" as a legit operand, then hits it expecting another operator
    # and finds nothing printable to name, hence the empty error token.
    t="${t%$'\r'}"
    hh="${t%:*}"; mm="${t#*:}"
    # strip leading zeros to avoid octal interpretation
    hh="${hh#0}"; hh="${hh:-0}"
    mm="${mm#0}"; mm="${mm:-0}"
    printf '%d' $(( hh * 60 + mm ))
}

# suggest_free_slot <requested_HH:MM> <candidates_block>:
# Step outward from the requested time in ±WINDOW increments until a minute
# clear of all candidates ±window. Print "Suggested free slots: HH:MM or HH:MM"
# plus a re-run hint. candidates_block is the output of list_collision_candidates.
suggest_free_slot() {
    local req_hhmm="$1" candidates="$2"
    local window="${ARM_COLLISION_WINDOW:-${COLLISION_WINDOW_MINUTES:-5}}"
    case "$window" in ''|*[!0-9]*) window=5 ;; esac
    local req_min
    req_min=$(_minutes_from_midnight "$req_hhmm")

    # Collect candidate minutes
    local cand_mins=""
    while IFS=$'\t' read -r _cname chhmm; do
        [ -z "$chhmm" ] && continue
        cand_mins="$cand_mins $(_minutes_from_midnight "$chhmm")"
    done <<< "$candidates"

    # _is_free <minute>: rc 0 if that minute is clear of all candidates ±window
    _is_free() {
        local m="$1" cm diff
        for cm in $cand_mins; do
            diff=$(( m - cm ))
            [ "$diff" -lt 0 ] && diff=$(( -diff ))
            # Midnight wrap: if abs diff > 720, use 1440-diff
            [ "$diff" -gt 720 ] && diff=$(( 1440 - diff ))
            [ "$diff" -le "$window" ] && return 1
        done
        return 0
    }

    local slots="" step
    for step in 1 2 3 4 5 6 7 8 9 10 11 12; do
        local try_plus try_minus
        try_plus=$(( (req_min + step * (window + 1)) % 1440 ))
        try_minus=$(( (req_min - step * (window + 1) + 1440) % 1440 ))
        if _is_free "$try_plus"; then
            local hh mm
            hh=$(( try_plus / 60 )); mm=$(( try_plus % 60 ))
            local s
            s=$(printf '%02d:%02d' "$hh" "$mm")
            case "$slots" in *"$s"*) ;; *) slots="${slots:+$slots or }$s" ;; esac
        fi
        if _is_free "$try_minus" && [ "$try_minus" -ne "$try_plus" ]; then
            local hh2 mm2
            hh2=$(( try_minus / 60 )); mm2=$(( try_minus % 60 ))
            local s2
            s2=$(printf '%02d:%02d' "$hh2" "$mm2")
            case "$slots" in *"$s2"*) ;; *) slots="${slots:+$slots or }$s2" ;; esac
        fi
        # Stop once we have two suggestions
        local count=0
        case "$slots" in *" or "*) count=2 ;; *) [ -n "$slots" ] && count=1 ;; esac
        [ "$count" -ge 2 ] && break
    done

    if [ -n "$slots" ]; then
        echo "    Suggested free slots: $slots"
        echo "    Re-run: bash scripts/handover/arm-resume.sh --time <HH:MM> --handover <path>"
    fi
    echo "    Or pass --force to arm at $req_hhmm anyway (HIMMEL-407)."
}

# check_collision(): compare RESUME_TIME against all other HIMMEL-* tasks.
# Exact-minute match → HARD-REFUSE rc=6 (unless --force or --dedup-any → WARN).
# Within ±window → WARN (continue).
# Outside window → silent.
check_collision() {
    local window="${ARM_COLLISION_WINDOW:-${COLLISION_WINDOW_MINUTES:-5}}"
    case "$window" in ''|*[!0-9]*) window=5 ;; esac
    local candidates
    candidates=$(list_collision_candidates)
    [ -z "$candidates" ] && return 0

    local req_min
    req_min=$(_minutes_from_midnight "$RESUME_TIME")

    local exact_hits="" near_hits=""
    while IFS=$'\t' read -r cname chhmm; do
        [ -z "$cname" ] || [ -z "$chhmm" ] && continue
        local cm diff
        cm=$(_minutes_from_midnight "$chhmm")
        diff=$(( req_min - cm ))
        [ "$diff" -lt 0 ] && diff=$(( -diff ))
        [ "$diff" -gt 720 ] && diff=$(( 1440 - diff ))
        if [ "$diff" -eq 0 ]; then
            exact_hits="${exact_hits:+$exact_hits, }$cname ($chhmm)"
        elif [ "$diff" -le "$window" ]; then
            near_hits="${near_hits:+$near_hits, }$cname ($chhmm, ${diff}min away)"
        fi
    done <<< "$candidates"

    if [ -n "$exact_hits" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "WARN arm-resume: --force: ignoring exact time collision at $RESUME_TIME with: $exact_hits" >&2
        elif [ "$DEDUP_ANY" -eq 1 ]; then
            # --dedup-any (unattended watchdog): WARN-ONLY, never refuse
            echo "WARN arm-resume: exact time collision at $RESUME_TIME with: $exact_hits (continuing — --dedup-any watchdog path; pass --force to suppress)" >&2
        else
            {
                echo "ERR arm-resume: time collision — $RESUME_TIME exactly matches another HIMMEL-* task:"
                echo "    $exact_hits"
                echo "Two concurrent claude sessions would launch at $RESUME_TIME, risking hung harvests,"
                echo "doubled API spend, and ~/.claude.json write races."
                suggest_free_slot "$RESUME_TIME" "$candidates"
            } >&2
            return 6
        fi
    fi

    if [ -n "$near_hits" ]; then
        echo "WARN arm-resume: near time collision (within ${window}min of $RESUME_TIME): $near_hits — two claude sessions may overlap. Pass --force to suppress." >&2
    fi

    return 0
}

# HIMMEL-340: dedup against the CURRENT handover's $TASK_NAME by default
# (so N distinct handovers each arm their own slot), or against ANY
# HIMMEL-Resume job under --dedup-any (the safety-arm semantics the
# auto-arm watchdogs rely on — defer to whatever is already queued).
DEDUP_SCOPE=task
[ "$DEDUP_ANY" -eq 1 ] && DEDUP_SCOPE=all
# HIMMEL-708: warm the Windows scheduler-listing cache in THIS (parent) shell so
# the $()-wrapped list_existing / list_collision_candidates readers below inherit
# it — a subshell populating it could not persist the globals up. Fail-closed
# (exit 2 on a genuine schtasks error) happens here, at the first read, exactly
# as before. Windows-only: POSIX still lists per-call (atq/crontab, cheap).
if [ "$PLATFORM" = windows ]; then
    _ensure_schtasks_cache
fi
existing=$(list_existing "$DEDUP_SCOPE")
# HIMMEL-1304: markers a --force replace must reap, deleted only AFTER the new
# job is registered and verified. Pre-1304 the deletion happened right here,
# BEFORE the rc-7 queue-lock refusal, the rc-8 cross-host refusal, and
# schedule_arm itself — so an arm that deleted and then refused (or failed
# inside schedule_arm, or failed partway through a multi-job deletion) left the
# previous slot(s) destroyed with no replacement and no rollback. Deferring the
# deletion makes the replace transactional in the direction that matters — the
# old arm is only given up once a new one demonstrably exists.
#
# HIMMEL-1563: the reap list is THIS invocation's OWN identity only (the
# current $TASK_NAME + the pre-1304 legacy one) — NEVER the broad --dedup-any
# enumeration in $existing. Pre-1563 the force loop reaped straight out of
# $existing, so under `--dedup-any --force` (scope = every HIMMEL-Resume-* job)
# a single arm cancelled EVERY parallel chain's armed resume by prefix
# wildcard — a foreign chain's task this invocation did not create, destroyed
# as collateral (leg 44 deleted HIMMEL-Resume-trust-envelope-chain-06). This
# box routinely runs four+ autonomous chains under the same HIMMEL-Resume-
# prefix, so a prefix match is never safe for a delete. $existing (the broad
# list) is still used for the rc=3 refusal below and the soft-cap count — both
# READ-ONLY — but a DELETE/replace may never reach beyond the caller's own
# task(s). Read-only enumeration (the refusal message, the cap count) is fine;
# the invariant is about DELETE/Unregister/replace.
ARM_REPLACE_MARKERS=""
if [ -n "$existing" ]; then
    if [ "$FORCE" -eq 1 ]; then
        # HIMMEL-1563: reap only THIS handover's own job(s). list_existing task
        # is the exact-identity match (current + legacy); the broad $existing
        # above is deliberately NOT the reap source.
        _force_reap_list=$(list_existing task)
        if [ -n "$_force_reap_list" ]; then
            echo "arm-resume: --force set; replacing THIS handover's own job(s) AFTER the new one is registered:" >&2
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "  $marker" >&2
                if [ "$DRY_RUN" -eq 0 ]; then
                    ARM_REPLACE_MARKERS="${ARM_REPLACE_MARKERS}${marker}"$'\n'
                else
                    echo "DRY arm-resume: would delete $marker (after the new job is registered)"
                fi
            done <<< "$_force_reap_list"
        elif [ "$DEDUP_SCOPE" = all ]; then
            # Own-identity list empty but broad list non-empty: every queued
            # resume job belongs to a DIFFERENT chain. Say so explicitly so the
            # rc=0 silence is not read as "nothing else was queued" — foreign
            # arms are left untouched (HIMMEL-1563).
            echo "arm-resume: --force set; no job of THIS handover to replace — leaving other chains' resume job(s) untouched (HIMMEL-1563)." >&2
        fi
    else
        {
            if [ "$DEDUP_SCOPE" = task ]; then
                echo "ERR arm-resume: a resume job for THIS handover is already scheduled:"
            else
                echo "ERR arm-resume: a HIMMEL-Resume-* job is already scheduled:"
            fi
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "    $marker"
            done <<< "$existing"
            echo ""
            # Scope-accurate reason (HIMMEL-1297): the default per-handover scope
            # and the --dedup-any broad scope refuse for DIFFERENT reasons, and a
            # single "same handover" blurb misdescribes the broad one — the same
            # doc-overstates-the-guard drift this ticket fixed in the runbooks.
            if [ "$DEDUP_SCOPE" = task ]; then
                echo "Dedup safeguard — never want two claude sessions cron-relaunched"
                echo "for the SAME handover. A DIFFERENT handover normally"
                echo "arms concurrently with no flag at all. To replace, use --force."
                echo "The match is on the DERIVED task name, which since HIMMEL-1304 is"
                echo "the CANONICAL handover path plus a hash of it — so a different"
                echo "spelling of this same file matches (as it should), and two distinct"
                echo "paths no longer collide just because punctuation was stripped."
                echo "Inspect:"
            else
                echo "--dedup-any safety-arm semantics — defer to whatever resume slot is"
                echo "already queued, whichever handover it points at. To arm this handover"
                echo "alongside it, drop --dedup-any. Adding --force replaces only THIS"
                echo "handover's own job(s) (HIMMEL-1563) — sibling chains' arms are never"
                echo "touched by a force replace. Since HIMMEL-1304 that deletion is"
                echo "TRANSACTIONAL: it happens only AFTER the new job is registered and"
                echo "verified, so a later refusal or failure leaves the existing slot(s)"
                echo "untouched rather than wiping them with no replacement. Inspect:"
            fi
            case "$PLATFORM" in
                windows) echo "    schtasks /query /tn \"<task-name>\"" ;;
                *)       echo "    atq && at -c <job-id>   (or: crontab -l)" ;;
            esac
        } >&2
        # Telemetry (HIMMEL-236): dedup friction signal. Guarded so a
        # --dry-run that hits the block keeps the touch-nothing contract
        # (this else-branch is reachable under --dry-run without --force).
        if [ "$DRY_RUN" -eq 0 ]; then
            telemetry_emit handover-arm-resume dedup-block "time=$RESUME_TIME"
        fi
        exit 3
    fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-1879 part 3 -- idempotency against an ALREADY-FIRED arm.
#
# The dedup check above asks the SCHEDULER. That is a sound question only while
# a task still exists: every arm this script emits deletes its OWN registration
# as its first fire-time action, so a task that already fired leaves the
# scheduler reading perfectly clean. A second invocation for the same handover
# therefore re-arms and DOUBLE-FIRES -- two sessions for one seat, under one
# name (proven live 2026-07-17).
#
# The arms registry cannot answer this: queue-lock.sh's HIMMEL-882 consume DROPS
# a record when the fired session starts (and GCs any legacy '"fired":"true"'
# line), by design -- absence there means "never armed" and "armed, fired,
# consumed" indistinguishably. The flow-run ledger CAN: every runner this script
# emits appends an `armed-resume` start row carrying its own TASK_NAME
# (--append-start ... "$TASK_NAME"), and that row is durable. A start row for
# THIS task name is positive evidence that THIS arm fired.
#
# Scope is exact -- the full TASK_NAME, which folds in ticket + slug + session
# number + a hash of the canonical handover path. The normal chain (leg N writes
# handover N+1, arms it) produces a NEW task name every leg and never trips this.
#
# NARROW ON PURPOSE -- an UNFINISHED fire only. A start row with a matching end
# row means that session ran and completed; re-arming the same handover then is
# routine, not a double-fire, and refusing it would wedge every stable-handover
# caller: auto-arm-on-cap.sh re-arms the operator's SAME status.md all day, so a
# "fired once, refuse forever" rule would turn into MALFUNCTION escalation after
# MAX_ARM_FAILURES. What must never happen is a SECOND session on a seat the
# first still holds, and that is exactly a start with no end.
#   Layering: rc 7 (fresh queue lock) and rc 8 (cross-host arms registry) already
#   cover the live-session case from the LOCK side. This is the ledger side of
#   the same question, and it answers where those cannot -- a fire whose session
#   never reached its queue lock at all.
# ARM_RESUME_SAFETY_ARM=1 is exempt for the same reason the HIMMEL-1475 long-gap
# guard exempts it: an automated machine-wide safety arm cannot pass --force and
# must never be the thing that parks the machine.
# --force is the same escape hatch the dedup check documents.
#
# Fail-OPEN on everything but a positive hit: no ledger, an unreadable ledger, a
# missing path resolver -- all skip silently. Absence of evidence must never
# block an arm (the house contract for every optional probe in this file).
if [ "$FORCE" -eq 0 ] && [ -n "${TASK_NAME:-}" ] \
   && [ "${ARM_RESUME_SAFETY_ARM:-}" != "1" ] \
   && [ -f "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh" ]; then
    # shellcheck source=../lib/flow-run-ledger-path.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh"
    _arm_fr_ledger=$(flow_run_ledger_path 2>/dev/null) || _arm_fr_ledger=""
    if [ -n "$_arm_fr_ledger" ] && [ -f "$_arm_fr_ledger" ]; then
        # Both needles on ONE line: the row is a single-line JSON object, so a
        # per-line AND is an exact match for "an armed-resume start row for this
        # task". grep -F: TASK_NAME is sanitized to [[:alnum:]_-] but the flow
        # name is not a pattern either way.
        _arm_fired_row=$(grep -F '"flow":"armed-resume"' "$_arm_fr_ledger" 2>/dev/null \
            | grep -F '"ev":"start"' \
            | grep -F "\"task_name\":\"$TASK_NAME\"" \
            | tail -1) || _arm_fired_row=""
        # The LATEST fire only. An earlier completed run must not resurrect a
        # refusal once a newer fire has ended.
        _arm_fired_run=$(printf '%s' "$_arm_fired_row" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')
        _arm_fired_end=""
        if [ -n "$_arm_fired_run" ]; then
            _arm_fired_end=$(grep -F "\"run_id\":\"$_arm_fired_run\"" "$_arm_fr_ledger" 2>/dev/null \
                | grep -F '"ev":"end"' | tail -1) || _arm_fired_end=""
        fi
        if [ -n "$_arm_fired_row" ] && [ -z "$_arm_fired_end" ]; then
            {
                echo "ERR arm-resume: this handover's arm ALREADY FIRED and that run has NOT ended -- refusing to re-arm (HIMMEL-1879)."
                echo "    task:   $TASK_NAME"
                echo "    fired:  $(printf '%s' "$_arm_fired_row" | sed -n 's/.*"fired_at":"\([^"]*\)".*/\1/p')"
                echo "    run:    ${_arm_fired_run:-<unparseable>}  (no end row in the flow-run ledger)"
                echo ""
                echo "The scheduler reads CLEAN because a fired arm deletes its own"
                echo "registration -- absence there is not evidence it never ran. The"
                echo "flow-run ledger recorded the fire and no completion, so a session"
                echo "may still hold this seat; arming again would put a SECOND one on"
                echo "it (single-writer violation)."
                echo ""
                echo "Normally the resumed session writes the NEXT handover and arms THAT"
                echo "(new session number -> new task name -> no refusal), and a run that"
                echo "COMPLETED never reaches this check at all. If that session is gone"
                echo "(crashed before writing its end row), re-run with --force."
                echo "Ledger: $_arm_fr_ledger"
            } >&2
            if [ "$DRY_RUN" -eq 0 ]; then
                telemetry_emit handover-arm-resume fired-block "time=$RESUME_TIME"
            fi
            exit 15
        fi
    fi
    unset _arm_fr_ledger _arm_fired_row _arm_fired_run _arm_fired_end
fi

# ---------------------------------------------------------------------------
# HIMMEL-1830 -- ONE FILE PER LEG.
#
# A leg can write TWO numbered next-session files -- one carrying STATE, one
# carrying ORDERS -- and arm the relaunch on the ORDERS half (2026-08-17, leg
# 24: session-25 = state, session-26 = orders, armed on 26). Two damages: the
# leg sequence stops counting legs, and the armed session loads ONE file, so
# the STATE half is reachable only through a reference it may never chase.
#
# Detection, both conditions required:
#   1. the sibling `<prefix>-session-<N-1>.md` was last written inside this leg
#      window (ARM_SPLIT_LEG_WINDOW_SEC, default 3600s, measured to NOW) -- in a
#      normal chain that file is the PREVIOUS leg's, hours old or older; and
#   2. the flow-run ledger holds no `armed-resume` row naming the SIBLING's own
#      arm identity (the hash of its canonical path, which every task name this
#      script mints ends with), i.e. nobody was ever RELAUNCHED from it. That is
#      the difference that matters: a real leg's file is a launch point, a split
#      half never becomes one. Condition 1 alone would refuse a legitimately
#      short leg (leg 28 -> leg 29 was 47 minutes apart in the audited
#      sequence); condition 2 clears it.
#
# Deliberately NOT keyed on mtime PROXIMITY between the two files: a later leg
# routinely edits its predecessor (a SUPERSEDED banner), which would make an
# innocent pair look simultaneous. Both conditions are heuristics over a naming
# convention, so ARM_SPLIT_LEG_OK=1 (and --force) opt out in one step; the
# canonical leg->file mapping for the audited chain lives next to the files, in
# HIMMEL-654-dispatch-session-legs.md.
if [ "${ARM_SPLIT_LEG_OK:-}" != "1" ] && [ "$FORCE" -eq 0 ] \
   && [ "${ARM_RESUME_SAFETY_ARM:-}" != "1" ]; then
    _sl_base=$(basename "$HANDOVER_PATH")
    _sl_n=""; _sl_raw=""
    case "$_sl_base" in
        *-session-[0-9]*.md)
            _sl_raw="${_sl_base##*-session-}"; _sl_raw="${_sl_raw%.md}"
            case "$_sl_raw" in ''|*[!0-9]*) _sl_raw="" ;; esac
            # 10#: a ZERO-PADDED number (session-08.md) is a legal filename but
            # OCTAL to bash arithmetic -- bare $((08 - 1)) is a fatal "value too
            # great for base" that would abort the whole arm under set -e
            # (panel r3 [codex-1]).
            [ -n "$_sl_raw" ] && _sl_n=$((10#$_sl_raw))
            ;;
    esac
    if [ -n "$_sl_n" ] && [ "$_sl_n" -ge 2 ]; then
        _sl_prev=$((_sl_n - 1))
        _sl_dir=$(dirname "$HANDOVER_PATH")
        _sl_prefix="${_sl_base%-session-*}"
        _sl_sib="$_sl_dir/$_sl_prefix-session-$_sl_prev.md"
        # A padded chain names the sibling with the SAME width (…-07.md).
        if [ ! -f "$_sl_sib" ]; then
            _sl_pad=$(printf '%s/%s-session-%0*d.md' "$_sl_dir" "$_sl_prefix" "${#_sl_raw}" "$_sl_prev")
            [ -f "$_sl_pad" ] && _sl_sib="$_sl_pad"
        fi
        # Leg 1 of a chain is conventionally the UNNUMBERED file.
        if [ ! -f "$_sl_sib" ] && [ "$_sl_prev" -eq 1 ]; then
            _sl_sib="$_sl_dir/$_sl_prefix-session.md"
        fi
        if [ -f "$_sl_sib" ]; then
            _sl_window="${ARM_SPLIT_LEG_WINDOW_SEC:-3600}"
            case "$_sl_window" in ''|*[!0-9]*) _sl_window=3600 ;; esac
            # HIMMEL-2125: py_armor_mtime tries GNU/BSD `stat` before falling
            # back to this same python one-liner -- skips the python spawn
            # entirely on every host where `stat` is available.
            _sl_mtime=$(py_armor_mtime "$_sl_sib")
            case "$_sl_mtime" in ''|*[!0-9]*) _sl_mtime="" ;; esac
            _sl_age=""
            [ -n "$_sl_mtime" ] && _sl_age=$(( $(date +%s) - _sl_mtime ))
            if [ -n "$_sl_age" ] && [ "$_sl_age" -ge 0 ] && [ "$_sl_age" -le "$_sl_window" ]; then
                # Was anything ever relaunched FROM the sibling? Asked by the
                # sibling's OWN arm identity -- the hash of its canonical path,
                # the trailing component of every task name this script mints
                # (see $_path_suffix). Not by ticket+leg number (a second chain
                # on the same ticket at the same leg number would clear a real
                # split -- panel r1 [codex-1]) and not by the `-s<N>` segment
                # either, which only exists for `next-session-N.md` chains and
                # is absent from every other numbered naming style.
                # No hasher on this machine -> no reliable sibling identity, so
                # treat it as launched and do not refuse (the house fail-open
                # contract for optional probes).
                _sl_launched=1
                _sl_hash=$(_arm_path_hash "$(_arm_identity_path "$_sl_sib")")
                if [ -n "$_sl_hash" ] && [ -f "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh" ]; then
                    # shellcheck source=../lib/flow-run-ledger-path.sh
                    # shellcheck disable=SC1091
                    . "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh"
                    _sl_ledger=$(flow_run_ledger_path 2>/dev/null) || _sl_ledger=""
                    if [ -n "$_sl_ledger" ] && [ -f "$_sl_ledger" ]; then
                        _sl_launched=0
                        # Both needles on ONE line (same shape as the rc-15
                        # probe above): a row is a single-line JSON object, so
                        # this is "an armed-resume row for the sibling" rather
                        # than "any flow that happens to carry that task name"
                        # (panel r2 [codex-1]). The hash is [0-9a-f]{,12} -- no
                        # regex metacharacters.
                        if grep -F '"flow":"armed-resume"' "$_sl_ledger" 2>/dev/null \
                            | grep -E "\"task_name\":\"HIMMEL-Resume-[^\"]*-h${_sl_hash}\"" >/dev/null 2>&1; then
                            _sl_launched=1
                        fi
                    fi
                fi
                if [ "$_sl_launched" -eq 0 ]; then
                    {
                        echo "ERR arm-resume: refusing to arm -- this looks like a SPLIT LEG (HIMMEL-1830)."
                        echo "    arming:  $_sl_base"
                        echo "    sibling: $(basename "$_sl_sib") (written ${_sl_age}s ago; nothing was ever relaunched from it)"
                        echo "One leg writes ONE numbered handover file: recovery/state first, then the"
                        echo "ordered task list. Two files for one leg inflate the leg sequence AND orphan"
                        echo "the half the relaunch does not load -- the resumed session then redoes work"
                        echo "and repeats errors it was never told about."
                        echo "Fix: fold the two files into ONE (keep the sibling's state, append these"
                        echo "orders) and arm that file. If the sibling really is a previous leg's file"
                        echo "that simply never armed, set ARM_SPLIT_LEG_OK=1 (or pass --force)."
                    } >&2
                    if [ "$DRY_RUN" -eq 0 ]; then
                        telemetry_emit handover-arm-resume split-leg-block "file=$_sl_base"
                    fi
                    exit 17
                fi
            fi
        fi
    fi
    unset _sl_base _sl_n _sl_raw _sl_prev _sl_dir _sl_prefix _sl_sib _sl_pad _sl_window _sl_mtime _sl_age _sl_launched _sl_ledger _sl_hash
fi

# ---------------------------------------------------------------------------
# HIMMEL-1329 -- ticket-level mutex.
#
# The dedup block above matches on the DERIVED task name, which folds in the
# handover's own slug and a hash of its canonical path (HIMMEL-1304). Two
# DIFFERENT handover files naming the SAME ticket -- a worktree handover and a
# state-repo handover both for HIMMEL-999, say -- therefore produce two
# DIFFERENT task names and sail straight past the check above: each arms its
# own slot for work that, underneath, is the same ticket. Since
# _compose_arm_name always places a present ticket FIRST in the task-name
# segment, a broader "does any OTHER slot's name start with this ticket"
# scan catches it regardless of which slug/session/path-hash follows.
#
# Own-identity matches (this handover's own prior slot, on a --force re-arm)
# are excluded here -- those were already resolved by the dedup/--force block
# above; this check only fires on a slot belonging to a genuinely DIFFERENT
# handover.
#
# Keyed on the STRICT frontmatter-only ticket ($_ho_ticket_strict), not the
# best-effort combined one ($_ho_ticket also used for naming/HIMMEL-1331):
# _infer_ticket's other sources (worktree branch, H1 title, chain-dir name)
# are documented as cosmetic-only best-effort guesses, and a handover whose
# H1 merely MENTIONS a ticket for documentation purposes (not as a real work
# association) must not false-positive a blocking refusal against an
# unrelated handover that happens to share the same mention.
if [ -n "${_ho_ticket_strict:-}" ]; then
    _ticket_hits=""
    while IFS= read -r _tmarker; do
        [ -z "$_tmarker" ] && continue
        # HIMMEL-1636: per-backend own-identity compare — a crontab LINE and an
        # `at-job-N` id never equal $TASK_NAME, so a raw compare here excluded
        # nothing on POSIX and this arm saw its own slot as a foreign one.
        if _arm_marker_is_own_identity "$_tmarker"; then continue; fi
        _ticket_hits="${_ticket_hits:+$_ticket_hits
}    $_tmarker"
    done <<< "$(list_existing ticket)"
    if [ -n "$_ticket_hits" ]; then
        if [ "$FORCE" -eq 1 ] || [ "${ARM_TICKET_DUP_OK:-}" = "1" ]; then
            {
                echo "WARN arm-resume: ticket $_ho_ticket_strict already has another armed resume slot under a DIFFERENT handover -- arming anyway:"
                printf '%s\n' "$_ticket_hits"
            } >&2
        else
            {
                echo "ERR arm-resume: refusing to arm -- ticket $_ho_ticket_strict already has another armed resume slot under a DIFFERENT handover (HIMMEL-1329):"
                printf '%s\n' "$_ticket_hits"
                echo "Arming the same ticket twice from two handover files risks two concurrent"
                echo "sessions racing the same work. If this is a deliberate second leg (e.g. a"
                echo "parallel sub-task on the same ticket), pass --force or set ARM_TICKET_DUP_OK=1."
            } >&2
            exit 13
        fi
    fi
    unset _ticket_hits _tmarker
fi

# Soft slot cap (HIMMEL-340): WARN — never block — when arming would push the
# machine past ARM_MAX_SLOTS concurrent resume slots. Each fired slot is
# another concurrent claude process + API spend, so the operator gets a
# heads-up while still being allowed to proceed. Skipped under --dedup-any
# (such arms add at most one slot and only when none exists, so they can't be
# the arm that pushes past the cap) and when ARM_MAX_SLOTS=0 (disabled).
# Reached only on a net-change path: a new arm (no same-handover job) or a
# --force replace (the no-force same-handover case already exited rc 3 above),
# so the predicted total is computed as "every OTHER slot, plus this one" —
# robust whether or not --force already deleted the old job.
if [ "$DEDUP_ANY" -eq 0 ]; then
    _max_slots="${ARM_MAX_SLOTS:-4}"
    case "$_max_slots" in ''|*[!0-9]*) _max_slots=4 ;; esac
    if [ "$_max_slots" -gt 0 ]; then
        # Bare assignments (not <<< "$(list_existing …)" here-strings) so a
        # list_existing fail-closed `exit 2` propagates and aborts rather than
        # being swallowed by the command-substitution subshell — the soft-cap
        # count inherits the same fail-closed contract as the dedup check.
        _all_list=$(list_existing all)
        _same_list=$(list_existing task)
        _all_count=0
        while IFS= read -r _l; do
            [ -n "$_l" ] && _all_count=$((_all_count + 1))
        done <<< "$_all_list"
        _same_count=0
        while IFS= read -r _l; do
            [ -n "$_l" ] && _same_count=$((_same_count + 1))
        done <<< "$_same_list"
        _predicted=$((_all_count - _same_count + 1))
        if [ "$_predicted" -gt "$_max_slots" ]; then
            echo "WARN arm-resume: arming this slot brings the total to $_predicted concurrent resume slots (soft cap ARM_MAX_SLOTS=$_max_slots). Each fired slot is another concurrent claude process + API spend. Proceeding anyway — raise ARM_MAX_SLOTS or prune stale jobs to silence this." >&2
        fi
    fi
fi

# HIMMEL-856: queue-lock FRESH-holder refusal + cross-machine arms-registry
# dedup -- the two double-fire vectors from the 2026-07-10 00:51 incident
# that the existing same-machine dedup above cannot see: (a) a LIVE session
# is actively working this queue right now (scripts/handover/queue-lock.sh),
# and (b) this SAME handover already has a PENDING arm recorded on ANOTHER
# host (schtasks/cron are per-machine, so win2 arming a handover was
# invisible to main arming the same handover until this registry). Both
# checks are skipped -- WARN, never fail-closed -- when the handover root
# can't be resolved (HANDOVER_DIR unset and no inline handovers/ dir yet):
# this mechanism is additive infrastructure and must never brick every arm.
#
# LAYERED DEFENSE -- why check-then-append is acceptable here (HIMMEL-856
# CR, codex-1): the registry is a git-synced FILE shared across machines,
# so the pre-arm check and the append below cannot be made atomic across
# hosts -- two hosts arming in the same sync window can both pass the
# check. That is BY DESIGN: the registry is the ADVISORY EARLY-WARNING
# layer (catch the double-arm before either session fires); the queue lock
# taken at session start (overnight step 0 / queue-lock.sh acquire) is the
# ENFORCING layer -- a double-arm that slips through the registry still
# serializes there, with exactly one winner. The cheap mitigation for the
# window is the post-append re-read at the bottom of this script: after
# recording our own arm we re-scan the registry and, if another host's arm
# for the same handover became visible, print a LOUD operator warning
# naming the hosts (no non-zero exit -- the arm already happened; the
# warning is the value). Do not re-raise this as a race bug.

# _arm_registry_foreign_hits <registry-file> <handover-path> <handover-key>
# <handover-root> <this-host> -- print a "; "-joined summary of every registry
# line recording an arm for this canonical handover on a host OTHER than
# <this-host> (empty = none). HIMMEL-1344: new lines match the durable
# root-relative handover-key; legacy raw-only lines match exact raw or a
# best-effort canonicalized raw path through the shared migration helper.
# HIMMEL-882: consumed records are dropped, and legacy fired-marked lines are
# skipped here until the next locked rewrite garbage-collects them.
_arm_registry_foreign_hits() {
    local _reg="$1" _ho="$2" _key="$3" _root="$4" _this_host="$5"
    local _this_esc _hits="" _line _rhost _rfire _rtask
    _hp_json_escape "$_this_host"; _this_esc="$_HP_ESC"
    [ -f "$_reg" ] || { printf '%s' ""; return 0; }
    # `|| [ -n "$_line" ]`: read returns 1 at EOF-without-newline while
    # still filling the variable -- without the guard a final record
    # lacking a trailing newline would be invisible to this scan.
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -z "$_line" ] && continue
        case "$_line" in
            *'"fired":"true"'*) continue ;;
        esac
        _hp_arms_record_matches_path "$_line" "$_ho" "$_key" "$_root"
        [ "$_HP_ARMS_MATCH" -eq 1 ] || continue
        _hp_json_field "$_line" host; _rhost="$_HP_FIELD"
        [ -z "$_rhost" ] && continue
        [ "$_rhost" = "$_this_esc" ] && continue
        _hp_json_field "$_line" fire-at;   _rfire="$_HP_FIELD"
        _hp_json_field "$_line" task-name; _rtask="$_HP_FIELD"
        _hits="${_hits:+$_hits; }host=$_rhost fire-at=$_rfire task=$_rtask"
    done < "$_reg"
    printf '%s' "$_hits"
}

# _arm_registry_mutex_acquire <registry-file> -- HIMMEL-882 CR round-2/3:
# acquire the short-lived mkdir-CAS mutex (<registry>.lock, a DIRECTORY)
# that serializes every arms.jsonl read-filter-rewrite writer. MUST stay
# path- and protocol-identical to queue-lock.sh's _ql_arms_mutex_acquire --
# the consume there and the prune-and-append here race each other on the
# same file (one registry per handover ROOT, so an arm on handover A and a
# session start on handover B are concurrent writers; last mv would win and
# drop the other's update). On success the lock dir carries an `owner`
# token file and $_ARM_REGISTRY_MUTEX_TOKEN names it -- release/mv are
# compare-then-act against that token (round-3: a holder reclaimed after
# the 60s staleness expiry must not blind-rmdir the reclaimer's lock or mv
# a stale snapshot over its rewrite). Bounded: nominal ~4s of 0.1s retries
# (platform-dependent -- measured ~2x that, ~8.7s, on Windows/Git-Bash from
# per-iteration mkdir+sleep overhead), then rc 1 -- the caller keeps the
# fail-open contract (WARN + skip, never fail the arm). A mutex stranded by
# a crashed writer is cleared when its dir mtime is >=60s old, re-probed
# every 10th iteration across the retry budget (round-4: NOT every
# iteration -- py_armor_mtime forks python and Windows python startup is
# ~100-300ms; probing every 10th yields ~4 probes across the ~40-iteration
# budget, bounding the extra forks while still catching a lock that crosses
# the 60s threshold mid-wait -- a lock that was, say, 56s old when this
# contender started is not yet stale at _tries==0 but would previously
# never be re-checked, burning the whole retry budget instead of
# reclaiming it; a failed probe never clears). errexit-safe: every probe is
# guarded, the loop exits only via return.
_ARM_REGISTRY_MUTEX_TOKEN=""
_arm_registry_mutex_acquire() {
    local _reg="$1" _lockd _tries=0 _m _now _tok
    _lockd="$_reg.lock"
    while :; do
        if mkdir "$_lockd" 2>/dev/null; then
            # Brand the lock (see queue-lock.sh's twin for the full uutils
            # rationale, HIMMEL-966): mkdir is NOT a reliable mutex primitive
            # on uutils coreutils (concurrent mkdir can BOTH return rc=0), so
            # the OWNER create via set -C (noclobber) -- a single kernel
            # open(O_CREAT|O_EXCL) by bash itself -- is the real arbiter.
            # A losing co-winner leaves the winner's lock alone and falls
            # through to the spin/reclaim path.
            _tok="pid$$-r$RANDOM"
            if ( set -C; printf '%s' "$_tok" > "$_lockd/owner" ) 2>/dev/null; then
                _ARM_REGISTRY_MUTEX_TOKEN="$_tok"
                return 0
            fi
        fi
        if [ $(( _tries % 10 )) -eq 0 ]; then
            _m=$(py_armor_mtime "$_lockd") || _m=""
            _now=$(date -u +%s 2>/dev/null) || _now=""
            if [ -n "$_m" ] && [ -n "$_now" ] && [ $(( _now - _m )) -ge 60 ]; then
                rm -rf "$_lockd" 2>/dev/null
            fi
        fi
        _tries=$((_tries + 1))
        if [ "$_tries" -ge 40 ]; then
            return 1
        fi
        sleep 0.1
    done
}

# _arm_registry_mutex_release <registry-file> <token> -- compare-then-delete
# (round-3, twin of queue-lock.sh's _ql_arms_mutex_release): release the
# arms mutex ONLY if its owner token is still ours. A mismatch means the
# lock was reclaimed from under us mid-rewrite -- WARN loudly and leave the
# reclaimer's lock alone (rc 1); the caller has already skipped its stale
# mv on the same comparison. Residual (accepted): a reclaim landing between
# the token read and the rmdir can still lose its lock -- a microsecond
# window vs the whole-rewrite window this closes.
_arm_registry_mutex_release() {
    local _reg="$1" _tok="$2" _cur=""
    _cur=$(cat "$_reg.lock/owner" 2>/dev/null) || _cur=""
    if [ "$_cur" != "$_tok" ]; then
        echo "WARN arm-resume: the arms-registry mutex ($_reg.lock) was reclaimed by another writer mid-rewrite (owner token mismatch: now '${_cur:-none}') -- leaving their lock in place; this rewrite was discarded" >&2
        return 1
    fi
    rm -f "$_reg.lock/owner" 2>/dev/null
    rmdir "$_reg.lock" 2>/dev/null
    return 0
}

# _arm_registry_replace_and_append <registry-file> <host> <handover-path>
# <handover-key> <handover-root> <new-record-line> -- HIMMEL-882/HIMMEL-1344:
# drop any existing line whose host AND canonical handover identity match
# (this host's own prior record(s) for this same handover),
# GC any legacy '"fired":"true"'-marked line in passing (retention, round
# 3 -- fired records are inert; both rewriters drop them so the registry
# stays O(active arms)), then append <new-record-line>. Without the prune,
# a re-arm or --force replace of the SAME handover on the SAME host left
# the superseded line sitting in arms.jsonl forever: harmless to THIS host
# (the dedup check above only looks at foreign hosts) but a permanent rc=8
# trap for the NEXT host that tries to arm this handover. CRASH-atomic:
# filtered+new content goes to a same-dir temp file, then mv into place --
# a mid-write crash never leaves a torn arms.jsonl. Temp+mv alone does NOT
# cover a CONCURRENT rewriter, so the whole read-filter-rewrite runs under
# the OWNER-TOKENED _arm_registry_mutex_acquire mkdir-CAS mutex shared with
# queue-lock.sh's consume, and the mv happens only while the owner token
# still names us. Path matching delegates to the shared dual-format helper:
# canonical handover-key for new lines, exact/canonicalized raw fallback for
# legacy lines already on disk. rc 1 on mutex timeout, mid-rewrite theft, or
# any write failure
# (caller WARNs and moves on); rc 0 on success. Single unlock point:
# failures only set _rc and fall through to the token-checked release
# (which WARNs about a theft). round-4 (sfh-2): on a write failure (not a
# mutex timeout/theft) $_ARM_REGISTRY_REPLACE_ERR carries the first line of
# the OS error (disk full / permission denied / RO-fs / AV lock, ...) so
# the caller's WARN can name it instead of reading identically to a mutex
# timeout; empty on success or on a mutex-timeout/theft failure.
_ARM_REGISTRY_REPLACE_ERR=""
_arm_registry_replace_and_append() {
    local _reg="$1" _host="$2" _ho="$3" _key="$4" _root="$5" _new="$6"
    local _tmp="$_reg.tmp.$$" _tok _cur _line _l_host _host_esc _rc=0 _werr=""
    _ARM_REGISTRY_REPLACE_ERR=""
    if ! _arm_registry_mutex_acquire "$_reg"; then
        echo "WARN arm-resume: could not lock the arms registry ($_reg.lock) -- skipping the registry rewrite for this arm (a mutex stuck from a crashed writer self-expires after 60s)" >&2
        return 1
    fi
    _tok="$_ARM_REGISTRY_MUTEX_TOKEN"
    _hp_json_escape "$_host"; _host_esc="$_HP_ESC"
    # round-4 (sfh-2): capture stderr instead of discarding it -- see
    # queue-lock.sh's twin for the rationale (2>/dev/null made a real write
    # failure read identically to a mutex timeout/theft).
    if _werr=$( { : > "$_tmp"; } 2>&1 ); then
        if [ -f "$_reg" ]; then
            # `|| [ -n "$_line" ]`: read returns 1 at EOF-without-newline
            # while still filling the variable -- without the guard the
            # rewrite silently DELETES a final record lacking a trailing
            # newline (round-2 Critical). Blank lines are dropped on
            # rewrite. ZERO forks per line (round-3 Critical):
            # _hp_json_field returns via $_HP_FIELD, no $().
            while IFS= read -r _line || [ -n "$_line" ]; do
                [ -z "$_line" ] && continue
                case "$_line" in
                    *'"fired":"true"'*) continue ;;   # GC legacy fired-marked line
                esac
                _hp_json_field "$_line" host; _l_host="$_HP_FIELD"
                if [ "$_l_host" = "$_host_esc" ]; then
                    _hp_arms_record_matches_path "$_line" "$_ho" "$_key" "$_root"
                    if [ "$_HP_ARMS_MATCH" -eq 1 ]; then
                        continue   # superseded by $_new -- drop
                    fi
                fi
                printf '%s\n' "$_line" >> "$_tmp" || { _rc=1; break; }
            done < "$_reg"
        fi
        if [ "$_rc" -eq 0 ]; then
            printf '%s\n' "$_new" >> "$_tmp" || _rc=1
        fi
        if [ "$_rc" -eq 0 ]; then
            # OWNER-TOKEN verify (round-3): mv only while the mutex still
            # names us -- see queue-lock.sh's twin for the rationale. The
            # cat->mv window below is residual (accepted), same class as
            # _arm_registry_mutex_release's token-read->rmdir gap.
            _cur=$(cat "$_reg.lock/owner" 2>/dev/null) || _cur=""
            if [ "$_cur" = "$_tok" ]; then
                _werr=$(mv -f "$_tmp" "$_reg" 2>&1) || _rc=1
            else
                _rc=1   # reclaimed mid-rewrite: snapshot stale, skip the mv
            fi
        fi
    else
        _rc=1
    fi
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp" 2>/dev/null
        [ -n "$_werr" ] && _ARM_REGISTRY_REPLACE_ERR="${_werr%%$'\n'*}"
    fi
    _arm_registry_mutex_release "$_reg" "$_tok" || true
    return "$_rc"
}

# _arm_hostname -- this machine's identity for registry records/compares.
_arm_hostname() {
    local _h=""
    _h=$(hostname 2>/dev/null) || _h=""
    [ -z "$_h" ] && _h="${COMPUTERNAME:-${HOSTNAME:-unknown-host}}"
    printf '%s' "$_h"
}

# ---------------------------------------------------------------------------
# HIMMEL-1365 -- do not arm a REAL scheduled task against a throwaway path.
#
# A hand-run HIMMEL-1304 repro created a real schtasks entry pointing at a
# scratchpad fixture, set to fire at 23:59, launching an unattended
# `claude.exe ... OVERNITE MODE` session mid-chain. It was found still armed
# days later. The blast radius was small only because that fixture repo had no
# remotes -- nothing confines an overnight session to its starting cwd, so the
# next one need not be so lucky.
#
# The identity suite is NOT the culprit and never was: it stubs the scheduler
# (SCHED_DB + a PATH stub) so no real task is ever created. The exposure is the
# hand-run repro, which uses the real scheduler with a temp target.
#
# So the guard keys on the TARGET, not on the caller. Arming a temp path is a
# legitimate thing for a test harness to do and an almost-certainly-wrong thing
# for a human to do at a prompt, which is why the opt-out is an explicit env
# var rather than a silent heuristic: the suite DECLARES that it means it,
# alongside its existing WORKSPACE_TRUST_CONFIG / SCHED_DB / BRIDGE_ROOT shields.
# (_arm_is_temp_path is defined right after the arg loop -- it is also the
# --list-temp-arms sweep's predicate, and that sweep answers before any of this
# preamble runs.)
#
# Sits after the dedup check (rc=3) rather than before it. That ordering costs
# nothing in safety: when dedup blocks, NOTHING is armed either, so a real task
# against a temp target is prevented on both paths -- only the diagnostic code
# differs in the rare overlap. --force skips dedup but NOT this: a forced arm at
# a throwaway target is precisely the incident shape.
#
# BOTH halves of the fired session's identity are checked (HIMMEL-1879 round):
# the cwd it lands in AND the handover it loads. The 2026-07 incident task was
# HIMMEL-Resume-ho1-...scratchpad_repro_work2_ho1md -- a scratchpad HANDOVER; a
# cwd-only predicate misses the shape where a fixture handover names a real repo
# as its resume_cwd, which is just as unattended and just as unintended.
# ARM_FIXTURE_OK is the ticket-named spelling of the same opt-in; ARM_TEMP_CWD_OK
# is the original and stays valid (every existing suite exports it).
if [ "${ARM_TEMP_CWD_OK:-}" != "1" ] && [ "${ARM_FIXTURE_OK:-}" != "1" ] && [ "${DRY_RUN:-0}" -ne 1 ]; then
    _arm_temp_what=""
    # Explicit `if`, not `_arm_is_temp_path … && _arm_temp_what=…`: under this
    # file's `set -e` a failing AND-list head is exempt only by a subtlety of
    # the shell's rules, and the NORMAL (non-temp) arm is exactly the case that
    # would rely on it.
    if _arm_is_temp_path "${RESUME_CWD:-}"; then
        _arm_temp_what="target work directory: $RESUME_CWD"
    fi
    if _arm_is_temp_path "${HANDOVER_PATH:-}"; then
        _arm_temp_what="${_arm_temp_what:+$_arm_temp_what
    }handover file: $HANDOVER_PATH"
    fi
    if [ -n "$_arm_temp_what" ]; then
        {
            echo "ERR arm-resume: refusing to arm -- a fixture target is under a TEMP/scratch path (HIMMEL-1365):"
            echo "    $_arm_temp_what"
            echo "This creates a REAL scheduled task that will launch an UNATTENDED session"
            echo "against a throwaway directory, and nothing confines that session to it."
            echo "The 2026-07 incident armed exactly this shape from a hand-run repro."
            echo "If you mean it (a test harness arming its own fixture), set ARM_FIXTURE_OK=1"
            echo "(ARM_TEMP_CWD_OK=1 is the original spelling and still works)."
        } >&2
        exit 12
    fi
    unset _arm_temp_what
fi

# ---------------------------------------------------------------------------
# HIMMEL-1331 -- shipped-work preflight.
#
# arm-resume had NO notion of whether the work it is re-arming still exists as
# work. Confirmed by grep against this script at 3386 lines: zero references to
# a ticket status, a merge state, or a PR. It armed on the clock and nothing
# else. Two real instances on 2026-07-28: HIMMEL-1296 re-armed at 23:40 after
# shipping and merging at 21:25, and HIMMEL-1286 re-armed while PR #1428 was
# open and mergeable. Each burns a full autonomous session and produces rework
# -- the same loss class as a worker that loses its commit, arriving through
# the scheduler instead of the spawner.
#
# ONLY POSITIVE EVIDENCE REFUSES. Every probe here is best-effort: a missing
# gh, a missing Jira CLI, no network, a detached HEAD, an unparseable answer --
# all of those SKIP the check with a WARN. An arm that fails because the
# machine is offline would be a worse failure than the one this prevents, and
# fail-open is the house contract for every other optional probe in this file
# (telemetry, handover_root, queue-lock).
#
# --force is the documented escape hatch per the ticket; ARM_SHIPPED_OK=1 is
# the env twin, matching ARM_DUP_OK / QUEUE_LOCK_TAKEOVER / ARM_WITH_LIVE_WORKERS.
_ARM_SHIPPED_REASONS=""
_arm_shipped_note() {
    _ARM_SHIPPED_REASONS="${_ARM_SHIPPED_REASONS}${_ARM_SHIPPED_REASONS:+
}    - $1"
}

# _arm_branch_for_preflight -- the branch whose ship-state we should ask about.
# --worktree/resume_worktree wins (it names the branch the session works on);
# otherwise HEAD in the resume cwd. Empty on a detached HEAD or a non-repo,
# which simply skips the branch-side checks.
_arm_branch_for_preflight() {
    local _b=""
    if [ -n "${WORKTREE_BRANCH:-}" ]; then printf '%s' "$WORKTREE_BRANCH"; return 0; fi
    [ -n "${RESUME_CWD:-}" ] && [ -d "${RESUME_CWD:-}" ] || return 0
    _b=$(git -C "$RESUME_CWD" symbolic-ref --quiet --short HEAD 2>/dev/null) || _b=""
    printf '%s' "$_b"
}

# _arm_probe -- run a preflight probe under a hard wall-clock bound.
#
# Both probes below reach the NETWORK, and this preflight sits on the arm path,
# which is TIME-SENSITIVE: --time takes an HH:MM, so any second spent here eats
# into the lead, and an arm whose target minute passes mid-flight gets rolled to
# TOMORROW by the past-time rule -- turning a 30-second lead into a 24-hour one.
# Caught by V6 (which arms at the next whole minute) failing rc=9 once this
# preflight started calling a real gh.
#
# So every probe is bounded and fails OPEN on timeout, which costs nothing: an
# unanswered probe was already treated as "no evidence" by design. `timeout` is
# absent on some hosts; there the call runs unbounded rather than not at all.
_arm_probe() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "${ARM_PREFLIGHT_TIMEOUT:-5}" "$@" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

_arm_shipped_preflight() {
    local _ticket="$1" _branch _jira _status _prs _num _state _mergeable

    # (a) TICKET STATUS. The Jira CLI is an untracked build artifact
    # (scripts/jira/dist/index.js), so it is routinely absent in a worktree --
    # skip quietly rather than nag on every arm. ARM_JIRA_CLI is a test seam
    # (same shape as SCHTASKS_CMD/GH_CMD elsewhere in this file): a worktree
    # never has dist/ built, so a test exercising this branch has no other way
    # to point it at a fixture CLI.
    _jira="${ARM_JIRA_CLI:-$SCRIPT_DIR/../jira/dist/index.js}"
    if [ -n "$_ticket" ] && [ -f "$_jira" ] && command -v node >/dev/null 2>&1; then
        _status=$(_arm_probe node "$_jira" get "$_ticket" | head -1 | awk -F'\t' '{print $3}') || _status=""
        case "$_status" in
            Done|Closed|"wont do"|"wont fix")
                _arm_shipped_note "ticket $_ticket is '$_status'" ;;
        esac
    fi

    # (b) PR / MERGE STATE. Asked from inside the resume cwd so gh resolves the
    # right repo. `--state all` deliberately: a MERGED pr is the strongest
    # signal, and an OPEN+MERGEABLE one means the work is finished and waiting
    # on a human, which is the HIMMEL-1286 shape.
    # GH_CMD is the house seam for this (scripts/graphify/graph-publish.sh,
    # scripts/cr/*): invoked DIRECTLY rather than found on PATH, because a
    # PATH-shadowing stub does not work on Windows -- an extensionless `gh`
    # script loses to gh.exe even when its directory comes first, so a test
    # that stubs via PATH silently exercises the REAL gh. Verified here.
    _branch=$(_arm_branch_for_preflight)
    if [ -n "$_branch" ] && [ -n "${RESUME_CWD:-}" ] && [ -d "${RESUME_CWD:-}" ] \
       && command -v "${GH_CMD:-gh}" >/dev/null 2>&1; then
        _prs=$(cd "$RESUME_CWD" && _arm_probe "${GH_CMD:-gh}" pr list --head "$_branch" --state all \
                 --json number,state,mergeable \
                 --jq '.[] | [(.number|tostring), .state, (.mergeable // "UNKNOWN")] | @tsv') || _prs=""
        while IFS=$'\t' read -r _num _state _mergeable; do
            [ -n "$_state" ] || continue
            case "$_state" in
                MERGED) _arm_shipped_note "PR #$_num for branch '$_branch' is MERGED" ;;
                OPEN)
                    [ "$_mergeable" = "MERGEABLE" ] && \
                        _arm_shipped_note "PR #$_num for branch '$_branch' is OPEN and MERGEABLE" ;;
            esac
        done <<EOF
$_prs
EOF
    fi
}

if [ "${FORCE:-0}" -eq 1 ] || [ "${ARM_SHIPPED_OK:-}" = "1" ]; then
    :   # explicitly sanctioned -- re-arming shipped work is sometimes right
        # (a follow-up leg on the same ticket), so the override is first-class.
elif [ "${DRY_RUN:-0}" -eq 1 ]; then
    :   # --dry-run touches nothing and must stay side-effect-free + fast;
        # the network probes above are neither.
else
    # HIMMEL-2113: use the STRICT ticket (frontmatter, plus the parent-dir
    # src-4 fallback for chain files), not the loose combined _ho_ticket --
    # src-3 (H1 leg-header match) is documented
    # (:1406-1413) as a cosmetic-only heuristic never meant to carry semantic
    # weight for a BLOCKING check, same rationale the HIMMEL-1329 ticket-mutex
    # check already applies. A chain handover's "# Next Session -- LUNA-64"
    # leg header was matching an unrelated Done ticket and false-positiving
    # this refusal.
    _arm_phase_t0 "shipped-work-preflight"
    _arm_shipped_preflight "${_ho_ticket_strict:-}"
    _arm_phase_done "shipped-work-preflight" "$_ARM_PT0"
    if [ -n "$_ARM_SHIPPED_REASONS" ]; then
        {
            echo "ERR arm-resume: refusing to arm -- this work looks ALREADY SHIPPED (HIMMEL-1331):"
            printf '%s\n' "$_ARM_SHIPPED_REASONS"
            echo "Re-arming shipped work burns a full autonomous session and produces rework."
            echo "If this is a deliberate follow-up leg, pass --force or set ARM_SHIPPED_OK=1."
        } >&2
        exit 11
    fi
fi

# _arm_root_from_handover_path <handover-file> -- HIMMEL-1603 fallback root
# resolver. handover_root() answers from HANDOVER_DIR or <cwd's git root>
# /handovers -- i.e. from WHERE WE ARE, never from WHAT WE ARE ARMING. Arm from
# a cwd that maps to neither and it returns nothing, and the caller below used
# to skip the queue-lock check, the cross-host dedup AND the registry write, so
# the arm existed only in the scheduler. Observed live 2026-08-06: an arm fired
# at 08:12 whose handover has no arms.jsonl record and never did (`git log -S`
# over the registry: no commit, ever), while two arms that fired the same minute
# were recorded normally.
#
# The handover path itself carries the answer. Both modes put handovers under a
# directory literally named `handovers` (Mode A `<repo>/handovers`, Mode B
# HANDOVER_DIR pointing at one), so walk the file's ancestors and take the first
# such directory. Prints nothing and returns 1 when there is none -- a handover
# kept outside that layout (e.g. a repo-root HANDOVER.md) is a real, supported
# shape, so "no match" is not an error here, just no fallback available.
_arm_root_from_handover_path() {
    local _d
    _d=$(dirname "$1" 2>/dev/null) || return 1
    while [ -n "$_d" ] && [ "$_d" != "/" ] && [ "$_d" != "." ]; do
        case "$_d" in
            */handovers)
                [ -d "$_d" ] || return 1
                ( cd "$_d" && pwd ) && return 0
                return 1
                ;;
        esac
        case "$_d" in
            */*) _d=${_d%/*} ;;
            *)   return 1 ;;
        esac
    done
    return 1
}

HIMMEL_856_HR_ROOT=""
HIMMEL_856_HR_ROOT=$(handover_root 2>/dev/null) || HIMMEL_856_HR_ROOT=""
if [ -z "$HIMMEL_856_HR_ROOT" ]; then
    # HIMMEL-1603: before giving up (and silently arming unregistered), derive
    # the root from the handover being armed.
    HIMMEL_856_HR_ROOT=$(_arm_root_from_handover_path "$HANDOVER_PATH" 2>/dev/null) || HIMMEL_856_HR_ROOT=""
    [ -n "$HIMMEL_856_HR_ROOT" ] && \
        echo "WARN arm-resume: handover_root did not resolve from the cwd/HANDOVER_DIR -- using the root derived from the handover path instead: $HIMMEL_856_HR_ROOT (HIMMEL-1603)" >&2
fi
if [ -z "$HIMMEL_856_HR_ROOT" ]; then
    # HIMMEL-1603: this branch arms WITHOUT a registry record, so every later
    # reader -- the census, the double-arm detector, any staleness guard -- is
    # blind to this arm. A WARN on a session's stderr does not survive that
    # session, which is why the gap went unnoticed until an unrecorded arm was
    # caught firing. Emit it to telemetry too, so the trail outlives the shell.
    telemetry_emit handover-arm-resume unregistered-arm "handover=$HANDOVER_PATH" "reason=handover-root-unresolved"
    echo "WARN arm-resume: could not resolve the handover root -- skipping queue-lock + arms-registry checks (HIMMEL-856). This arm will NOT appear in arms.jsonl and is invisible to the census + double-arm detection (HIMMEL-1603); set HANDOVER_DIR or arm from inside the state repo to record it." >&2
else
    _arm_phase_t0 "queue-lock-probe"
    QUEUE_LOCK_SH="$SCRIPT_DIR/queue-lock.sh"
    if [ -f "$QUEUE_LOCK_SH" ]; then
        # `|| _ql_status_rc=$?` (not a bare assignment) -- under `set -e`,
        # `var=$(cmd)` where cmd exits non-zero (rc=11/12 = held here, a
        # normal outcome, not a script error) would otherwise abort the
        # whole arm right here instead of reaching the rc-7 refusal below.
        _ql_status_rc=0
        # HIMMEL-1603: hand the resolved root DOWN. queue-lock.sh re-resolves
        # via its own handover_root, i.e. from the same cwd that just failed us,
        # so without this it answers "could not resolve handover root" and the
        # check degrades to a WARN even though we know exactly which root to
        # look in. Scoped to this one invocation -- the parent's own
        # HANDOVER_DIR (set or unset) is deliberately left alone.
        _ql_status_out=$(HANDOVER_DIR="$HIMMEL_856_HR_ROOT" bash "$QUEUE_LOCK_SH" status "$HANDOVER_PATH" 2>&1) || _ql_status_rc=$?
        if [ "$_ql_status_rc" -eq 11 ]; then
            if [ "${QUEUE_LOCK_TAKEOVER:-}" = "1" ]; then
                {
                    echo "WARN arm-resume: queue lock is FRESH for this handover -- arming anyway (QUEUE_LOCK_TAKEOVER=1):"
                    printf '%s\n' "$_ql_status_out" | sed 's/^/    /'
                } >&2
            else
                {
                    echo "ERR arm-resume: refusing to arm -- a session is LIVE on this handover's queue right now:"
                    printf '%s\n' "$_ql_status_out" | sed 's/^/    /'
                    echo "Two live sessions on the same queue is exactly the 2026-07-10 00:51 double-fire (HIMMEL-856)."
                    echo "Override with QUEUE_LOCK_TAKEOVER=1 if you are certain the holder is gone/stale."
                } >&2
                exit 7
            fi
        elif [ "$_ql_status_rc" -ne 0 ] && [ "$_ql_status_rc" -ne 12 ]; then
            # rc 0 = free, 12 = held-but-STALE (arming over a stale lock is
            # fine -- the session-start acquire supersedes it). Anything
            # else means the status check itself broke -- say so instead of
            # silently proceeding as if the queue were verified free.
            echo "WARN arm-resume: queue-lock status failed (rc=$_ql_status_rc) -- proceeding WITHOUT the queue-lock check:" >&2
            printf '%s\n' "$_ql_status_out" | sed 's/^/    /' >&2
        fi
        unset _ql_status_out _ql_status_rc
    else
        # Missing script is a skipped check, not a silent pass -- same WARN
        # contract as the unresolvable-handover-root branch above.
        echo "WARN arm-resume: queue-lock.sh not found at '$QUEUE_LOCK_SH' -- skipping the queue-lock check (HIMMEL-856)" >&2
    fi
    _arm_phase_done "queue-lock-probe" "$_ARM_PT0"

    _arm_phase_t0 "arms-registry-cross-host"
    HIMMEL_856_ARMS_REGISTRY="$HIMMEL_856_HR_ROOT/.locks/arms.jsonl"
    _arm_registry_root=$(_arm_registry_identity_root "$HIMMEL_856_HR_ROOT")
    _arm_registry_key=$(_arm_registry_identity_path "$HANDOVER_PATH" "$HIMMEL_856_HR_ROOT")
    if [ -f "$HIMMEL_856_ARMS_REGISTRY" ]; then
        _arm_dup_hits=$(_arm_registry_foreign_hits "$HIMMEL_856_ARMS_REGISTRY" "$HANDOVER_PATH" "$_arm_registry_key" "$_arm_registry_root" "$(_arm_hostname)")
        if [ -n "$_arm_dup_hits" ]; then
            if [ "${ARM_DUP_OK:-}" = "1" ]; then
                echo "WARN arm-resume: this handover already has a PENDING arm on another host ($_arm_dup_hits) -- arming anyway (ARM_DUP_OK=1)" >&2
            else
                {
                    echo "ERR arm-resume: refusing to arm -- this handover already has a PENDING arm recorded on another host:"
                    echo "    $_arm_dup_hits"
                    echo "This is the win2+main-both-arming shape from the 2026-07-10 00:51 incident (HIMMEL-856)."
                    echo "Override with ARM_DUP_OK=1 if you are certain the other host's arm is stale/cancelled."
                } >&2
                exit 8
            fi
        fi
        unset _arm_dup_hits
    fi
    _arm_phase_done "arms-registry-cross-host" "$_ARM_PT0"
fi

# HIMMEL-407: time-collision check — runs AFTER the same-handover dedup block
# and BEFORE schedule_arm. Runs even under --dry-run (it mutates nothing).
# On exact-minute collision: rc=6 (HARD-REFUSE) unless --force or --dedup-any.
# Near collision (within window): WARN only. Outside window: silent.
_collision_rc=0
check_collision || _collision_rc=$?
if [ "$_collision_rc" -eq 6 ]; then
    exit 6
fi

# Build and execute the scheduler command directly — no round-trip
# through schedule-resume.sh's mixed-prose stdout (the v1 bug).
# _crontab_schedule — install the one-shot crontab entry (HIMMEL-594: shared by
# the linux crontab fallback + the macOS crontab-only branch). Uses the script
# globals RESUME_TIME/RESUME_PROMPT/RESUME_CWD/CHANNELS/TASK_NAME/DRY_RUN only.
# A `return 0` here (dry-run) returns to the schedule_arm case, which then ends
# and returns 0 — equivalent to the pre-extraction inline `return 0`.
_crontab_schedule() {
    # crontab fallback — crontab entries are RECURRING, so the
    # entry SELF-REMOVES as its first action (the cron analogue of
    # the schtasks .bat self-/delete above): it rewrites the
    # crontab without its own marker line before running cd+claude,
    # turning the recurring entry into a one-shot. The running
    # /bin/sh -c continues after the rewrite, so claude still
    # launches. The marker match is ANCHORED at end-of-line
    # (grep -vE '# <TASK_NAME>$'), mirroring the dedup detector's
    # crontab branch in list_existing so a sibling slot whose
    # TASK_NAME is a strict PREFIX of this one is not cross-matched
    # and survives. TASK_NAME is sanitized to [:alnum:]_- so it
    # carries no ERE specials. The terminal `crontab -` is NOT
    # error-suppressed: a silently-failed rewrite would leave the
    # entry RECURRING (a daily relaunch loop) while we told the
    # operator it is one-shot, so let cron surface the failure
    # (mail/log) — the manual-prune hint printed below is the
    # backstop. printf '%q' shell-quotes the prompt so cron's
    # /bin/sh -c can't re-interpret $/backticks/etc in a handover
    # path.
    local hh="${RESUME_TIME%:*}" mm="${RESUME_TIME#*:}"
    local q_prompt q_cwd q_channels="" q_name="" q_model=""
    # HIMMEL-2199: \%-escape AFTER %q-quoting, same shape as q_model below --
    # a handover path, cwd, or prompt containing % otherwise survives %q
    # untouched and crontab (unlike /bin/sh) reads an unescaped % as
    # end-of-command + stdin, silently truncating the entry at fire time.
    # q_cwd needs it too (CR round on this ticket): it sits in the SAME
    # `cd $q_cwd && ...` entry as q_prompt/q_channels, so a % anywhere in
    # RESUME_CWD (the git-toplevel-derived working directory) truncates the
    # entry exactly like an unescaped prompt/channels would. q_name is
    # exempt: SESSION_NAME only ever comes from _compose_arm_name(), whose
    # "title" surface sanitizes to [A-Za-z0-9._ -], which cannot contain %.
    q_prompt=$(printf '%q' "$RESUME_PROMPT")
    q_prompt=${q_prompt//%/\\%}
    q_cwd=$(printf '%q' "$RESUME_CWD")
    q_cwd=${q_cwd//%/\\%}
    [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") " && q_channels=${q_channels//%/\\%}
    # -n <session name> (HIMMEL-702): %q-quote so a space in "<TICKET> <name>"
    # stays ONE arg through the /bin/sh re-parse at fire time. Empty -> omit.
    [ -n "$SESSION_NAME" ] && q_name="-n $(printf '%q' "$SESSION_NAME") "
    # Optional --model passthrough (HIMMEL-2192), same %q-quote shape as
    # --channels above. %q leaves a literal % untouched, and crontab (unlike
    # /bin/sh) treats an unescaped % as end-of-command + stdin even inside
    # shell quoting -- so `\%`-escape AFTER %q-quoting to survive crontab's
    # own parse before /bin/sh ever sees the line.
    [ -n "$MODEL" ] && q_model="--model $(printf '%q' "$MODEL") " && q_model=${q_model//%/\\%}
    local self_clean="crontab -l 2>/dev/null | grep -vE '# ${TASK_NAME}\$' | crontab -;"
    # HIMMEL_HEADROOM_PROXY (HIMMEL-901): a crontab entry is ONE line, so the
    # livez-check-then-launch logic (same shape as the `at` branch's
    # $launch_lines) has to be a single ';'-joined compound wrapped in its
    # own `{ ; }` group — `cd ... && { ...; }` keeps `cd` a hard gate (plain
    # `&&`/`||` chaining without the group would let a failed cd fall
    # through into starting the proxy, since `&&`/`||` are left-associative
    # at equal precedence). Inactive -> $tail is byte-identical to the
    # pre-901 line (zero behavior change).
    # CR round: absolute curl path ($q_curl) + one mode-marker echo per
    # branch (HIMMEL-897 trail). The marker uses `echo "\$(date) ..."`, NOT
    # printf: cron treats an unescaped % in the command as end-of-command +
    # stdin, so a printf format string would truncate the entry. `\$(date)`
    # lands literally and evaluates at fire time.
    local q_automerge=""
    [ "$AUTOMERGE" -eq 1 ] && q_automerge="ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 "
    # HIMMEL-1382 fix round: unset both vars unconditionally before the
    # (possibly empty) grant prefix — same always-clear contract as the
    # `at`/Windows/WSL launch bodies, so a crontab entry never depends on
    # whatever env cron happened to run it under. `&&`, not `;`, so a failed
    # unset (should never happen) can't fall through to an ungated claude
    # launch outside the entry's `cd ... && $tail` gate.
    # HIMMEL-1475: also unset ARM_RESUME_SAFETY_ARM — a crontab entry fired by
    # an automated safety arm (auto-arm-on-cap/spawn-glm set the var in their
    # child env) must NOT hand the long-gap exemption to the resumed session,
    # or a later far HH:MM arm it makes silently bypasses the guard.
    # HIMMEL-2545: the same always-clear contract, for the vars claude
    # itself injects. claude exports CLAUDE_CODE_CHILD_SESSION=1 (and
    # CLAUDE_PID) into every process it spawns, so an arm made from inside a
    # claude tool call hands the relaunch a THROWAWAY-CHILD marker: transcript
    # saving off, `context-fill.sh` rc=4 ("blind fill"), no armed-resume
    # archaeology, nothing for the luna session-capture hook. An armed resume
    # is the session that most needs its transcript, so the launch body clears
    # both and forces persistence ON rather than depending on the ambient env
    # the arm happened to be submitted from. CLAUDE_PID is the HIMMEL-2514
    # sibling: the relaunch must not inherit the arming session's pid either.
    # CLAUDE_CODE_SESSION_ID is a round-6 addition to the same clear: claude
    # generates its own id and exports the correct one to its own tool
    # subprocesses regardless, so this never affected context-fill.sh - but
    # the relaunched claude PROCESS's own environ otherwise still carried the
    # ARMING session's stale id, misleading anyone inspecting
    # /proc/<claude pid>/environ, exactly the surface this ticket taught
    # people to check.
    local tail="unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID && export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 && ${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model"
    if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
        local q_hb q_log q_curl
        q_hb=$(printf '%q' "$HEADROOM_BIN")
        q_log=$(printf '%q' "$HOME/.headroom-proxy.log")
        q_curl=$(printf '%q' "$HEADROOM_CURL")
        tail="{ unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID; export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1; $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1 || { $q_hb proxy --port $HEADROOM_PROXY_PORT >> $q_log 2>&1 & sleep 3; }; if $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1; then echo \"\$(date) arm=$TASK_NAME mode=proxied\" >> $q_log; ANTHROPIC_BASE_URL=http://127.0.0.1:$HEADROOM_PROXY_PORT HEADROOM_OFFLINE=1 ${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model; else echo \"\$(date) arm=$TASK_NAME mode=bare-fallback\" >> $q_log; ${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model; fi; }"
    fi
    local q_flow_lib q_task q_note
    q_flow_lib=$(printf '%q' "$SCRIPT_DIR/../lib/flow-run-ledger.sh")
    q_task=$(printf '%q' "$TASK_NAME")
    q_note=$(printf '%q' "$FLOW_RUN_NOTE")
    tail="{ _flow_run_id=\$($q_flow_lib --append-start armed-resume \"\" \"\" claude \"\" $q_task \"\" \"\$\$\" 2>/dev/null) || _flow_run_id=; _flow_rc=0; $tail || _flow_rc=\$?; _flow_outcome=\$($q_flow_lib --classify \"\$_flow_rc\" \"\" 2>/dev/null) || _flow_outcome=complete; test \"\$_flow_outcome\" != \"\" || _flow_outcome=complete; test \"\$_flow_run_id\" != \"\" && $q_flow_lib --append-end armed-resume \"\$_flow_run_id\" \"\" \"\$_flow_rc\" \"\$_flow_outcome\" \"\" $q_note >/dev/null 2>&1 || true; exit \"\$_flow_rc\"; }"
    # HIMMEL-812: --safety-child marks the relaunch as the child of an auto-arm
    # SAFETY escalation. Exported once here, ahead of $tail, so it covers the
    # plain and the headroom-proxy launch bodies alike (both hang off the same
    # `cd ... &&` gate) instead of being threaded through every claude line.
    # Always-clear then conditionally grant (see the `at` twin): the entry must
    # be governed by its own text, not by whatever env cron hands it.
    local q_safety_child="unset AUTO_ARM_SAFETY_CHILD && "
    [ "$SAFETY_CHILD" -eq 1 ] && q_safety_child="export AUTO_ARM_SAFETY_CHILD=1 && "
    local entry="$mm $hh * * * $self_clean cd $q_cwd && ${q_safety_child}$tail # $TASK_NAME"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY arm-resume: would add crontab entry:"
        echo "    $entry"
        echo "DRY arm-resume: NOTE: entry self-removes on first fire (one-shot)."
        return 0
    fi
    local snap
    snap=$(mktemp -t crontab.snap.XXXXXX)
    if ! crontab -l > "$snap" 2>/dev/null; then
        : > "$snap"
    fi
    {
        cat "$snap"
        echo "$entry"
    } | crontab - || {
        echo "ERR arm-resume: crontab rewrite failed; snapshot at $snap" >&2
        exit 4
    }
    rm -f "$snap"
    echo "arm-resume: NOTE: crontab entry self-removes on first fire (one-shot)."
    echo "    If it never fires, prune manually with:"
    echo "    crontab -l | grep -v 'HIMMEL-Resume' | crontab -"
}

# _win_short_date_pattern (HIMMEL-938): read the machine's Windows short-date
# format from the registry so schedule_arm's Windows branch can render
# `schtasks /sd` in the LOCALE schtasks itself will parse it with — schtasks
# reads /sd per-locale, and a hardcoded MM/dd/yyyy silently misreads as
# day-first on a dd/MM/yyyy machine (win2, 4 recurrences), arming the task
# months out with no error. MSYS_NO_PATHCONV=1 is the same idiom every other
# schtasks/reg call in this file uses (HIMMEL-125) — without it gitbash
# mangles the /v flag into a Windows-rooted path. ANY failure (missing reg,
# unreadable key, empty/unparseable value) falls back to "MM/dd/yyyy" —
# byte-identical to the pre-HIMMEL-938 hardcoded behavior. Returns 0 when
# the pattern came from the registry, 1 when the fallback was used -- the
# caller must know the difference: a fallback pattern on a day-first
# machine re-opens the misarm class, so when the post-arm verify is ALSO
# unavailable the arm must fail closed instead of standing unverified
# (codex-adv-8). Either way a usable pattern is printed.
_win_short_date_pattern() {
    local _reg_out _pat
    _reg_out=$(MSYS_NO_PATHCONV=1 reg query "HKCU\Control Panel\International" /v sShortDate 2>/dev/null) || {
        printf '%s\n' "MM/dd/yyyy"
        return 1
    }
    # Everything after the REG_SZ column, NOT $NF — some locales' sShortDate
    # legitimately contains spaces (e.g. "yyyy. MM. dd."), and a last-field
    # grab would truncate the pattern to its final token.
    _pat=$(printf '%s\n' "$_reg_out" | sed -n 's/.*sShortDate[[:space:]]\{1,\}REG_SZ[[:space:]]\{1,\}//p' | head -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')
    if [ -z "$_pat" ]; then
        printf '%s\n' "MM/dd/yyyy"
        return 1
    fi
    printf '%s\n' "$_pat"
}

# _win_delete_bad_task <task-name> (HIMMEL-938, codex-adv-11): delete a task
# the post-arm verify rejected, LOUDLY surfacing a failed delete -- a
# known-mistimed task left scheduled would relaunch at the wrong moment
# while the ERR above implied it was cleaned up. Callers exit 2 either way;
# this only controls what the operator is told.
_win_delete_bad_task() {
    if MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /delete /tn "$1" /f >/dev/null 2>&1; then
        return 0
    fi
    echo "ERR arm-resume: FAILED to delete the rejected task '$1' -- a known-mistimed task is STILL SCHEDULED. Remove it manually: schtasks /delete /tn \"$1\" /f" >&2
    return 1
}

# _win_restore_backup_task <task-name> <backup-xml> (HIMMEL-1304 finding 2):
# `schtasks /create /f` overwrites a same-named task IN PLACE, so a
# same-identity re-arm leaves no separate old row for the post-commit reap
# sweep to defer deleting (see _arm_marker_is_new_arm above) -- the
# :1714-1722 "old arm only given up once a new one demonstrably exists"
# guarantee does not hold here on its own. Call this after
# _win_delete_bad_task removes a verify-rejected new task, so the PREVIOUS
# registration (exported to <backup-xml> before the overwrite) comes back
# instead of leaving nothing armed. Returns 1 when restoration fails so callers
# retain <backup-xml>; no-op when it is empty/missing (normal first-arm case).
_win_restore_backup_task() {
    local _tn="$1" _xml="$2"
    [ -n "$_xml" ] && [ -s "$_xml" ] || return 0
    if MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /create /tn "$_tn" /xml "$_xml" /f >/dev/null 2>&1; then
        echo "arm-resume: restored the previous arm for '$_tn' after the new registration was rejected." >&2
        return 0
    fi
    echo "ERR arm-resume: FAILED to restore the previous arm for '$_tn' after the new registration was rejected -- the PREVIOUS arm is ALSO LOST. Backup XML retained at '$_xml'; restore it manually with: schtasks /create /tn \"$_tn\" /xml \"$_xml\" /f" >&2
    return 1
}

# _win_render_short_date <epoch> <pattern> (HIMMEL-938): render TARGET_EPOCH
# as a schtasks-parseable date string in the given Windows short-date
# pattern (e.g. "dd/MM/yyyy", "M/d/yyyy", "yyyy-MM-dd"). Scans the pattern
# for runs of d/M/y: a `d`/`M` run always zero-pads to >=2 digits (even a
# single-letter token like the real Windows en-US DEFAULT "M/d/yyyy" —
# verified live on the operator's own box, which is NOT "MM/dd/yyyy" as
# originally assumed). HIMMEL-938 is about the day/month ORDER a locale
# implies, not digit width, and schtasks parses "7/2/2026" and "07/02/2026"
# identically — so fixing width at >=2 keeps a same-order locale's /sd value
# byte-identical to the pre-HIMMEL-938 hardcoded render (only a genuinely
# reordered pattern, e.g. dd/MM/yyyy, changes the emitted string). A `y` run
# of length <=2 renders a 2-digit year, longer renders 4-digit; a `d` run of
# length >=3 is a day-NAME token (e.g. "dddd" in a locale whose short-date
# pattern embeds a weekday) — schtasks /sd takes a numeric date only, so
# that token is DROPPED along with one adjacent separator (preferring the
# separator right after it, else the one already emitted before it) rather
# than emitted literally. Any other character (separators: /, -, ., space,
# comma) passes through unchanged. On render failure (bad pattern/args)
# prints nothing — the caller falls back to the existing MM/dd/yyyy
# START_DATE.
_win_render_short_date() {
    py_armor_capture -c '
import sys, datetime, re
epoch = int(sys.argv[1])
pattern = sys.argv[2]
# Month-NAME pictures (MMM/MMMM) and era pictures (g/gg) cannot be rendered
# numerically -- a dd-MMM-yy locale expects a month NAME in /sd, so a
# numeric render would misparse (coderabbit-4). Print nothing = render
# failure; the caller falls back to MM/dd/yyyy AND marks the locale path
# degraded, which the post-arm verify / dual-failure logic covers.
if re.search(r"M{3,}|g", pattern):
    sys.exit(0)
dt = datetime.datetime.fromtimestamp(epoch).astimezone()
out = []
i, n = 0, len(pattern)
while i < n:
    c = pattern[i]
    if c in "dMy":
        j = i
        while j < n and pattern[j] == c:
            j += 1
        run_len = j - i
        if c == "d" and run_len >= 3:
            # Day-name token -- drop it (numeric /sd only) plus one
            # adjacent separator so the rendered string stays parseable.
            if j < n and not pattern[j].isalpha():
                j += 1
            elif out and not out[-1].isalnum():
                out.pop()
        else:
            if c == "y":
                val = dt.year % 100 if run_len <= 2 else dt.year
                width = 2 if run_len <= 2 else 4
            else:
                val = dt.day if c == "d" else dt.month
                width = max(run_len, 2)
            out.append(str(val).zfill(width))
        i = j
    else:
        out.append(c)
        i += 1
print("".join(out))
' "$1" "$2"
}

# _arm_fired_evidence -- did THIS arm's task actually fire?
#
# "No task, and the target has passed" has TWO causes that look identical to the
# scheduler: the arm FIRED and deleted its own registration (every runner this
# script emits self-deletes as its first action), or the create registered
# nothing and the clock simply ran out while we armed. Only the first leaves
# positive evidence -- the runner's own `armed-resume` start row carrying this
# TASK_NAME, the same row the rc 15 guard reads.
#
# Two conditions, both required (r4 round):
#   1. a start row for this exact TASK_NAME, and
#   2. stamped at or after THIS arm started. rc 15 deliberately lets a handover
#      whose previous run COMPLETED re-arm all day, so an old row for the same
#      task name is not just possible, it is the normal steady state -- and
#      without the recency test a later no-op create would inherit that ancient
#      row as proof of a fire that happened hours ago. The fire we are asking
#      about happened DURING this arm or not at all.
#
# Answers NO on every doubt -- no ledger, unreadable ledger, missing resolver,
# unparseable stamp. Absence of evidence must never buy a success line: the
# caller then reports a failed arm, which is the fail-safe direction (an
# operator who re-arms is caught by rc 15; one told CONSUMED waits forever for a
# session that never started).
#
# Defined here, above schedule_arm, because BOTH consumed-detections need it --
# the Windows NextRunTime branch inside schedule_arm and the generic post-arm
# existence verify after it.
# _arm_fired_row -- this task's NEWEST armed-resume start row, or empty. Split
# out of _arm_fired_evidence (HIMMEL-1999) because the pre-arm snapshot below
# needs the same read without any of the this-arm-or-not judgement.
_arm_fired_row() {
    local _fr_ledger
    [ -n "${TASK_NAME:-}" ] || return 1
    [ -f "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh" ] || return 1
    # shellcheck source=../lib/flow-run-ledger-path.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/flow-run-ledger-path.sh" || return 1
    _fr_ledger=$(flow_run_ledger_path 2>/dev/null) || return 1
    [ -n "$_fr_ledger" ] && [ -f "$_fr_ledger" ] || return 1
    # Both needles on ONE line -- a row is a single-line JSON object, so a
    # per-line AND is an exact match. grep -F: neither needle is a pattern.
    # tail -1 = the most recent such row; an older one can never rescue it.
    grep -F '"flow":"armed-resume"' "$_fr_ledger" 2>/dev/null \
        | grep -F '"ev":"start"' \
        | grep -F "\"task_name\":\"$TASK_NAME\"" | tail -1
}

_arm_fired_evidence() {
    local _fe_row _fe_at _fe_try
    [ -n "${_ARM_START_UTC:-}" ] || return 1
    # HIMMEL-1999 item 1: a short GRACE window, not one look. The fired runner
    # deletes its own registration as its FIRST action and writes its
    # armed-resume start row only after that, so a verify landing inside that
    # gap sees "no task, no evidence" and reports REGISTERED NOTHING -- which
    # sends the operator to re-arm a seat a session that is starting right now
    # already holds. Up to 3 x 1 s: long enough for the runner to reach its own
    # ledger append, short enough that a genuinely dead arm is still refused
    # promptly. Only ever reached with the target time already passed (every
    # caller gates on lead <= 0), so it cannot delay a healthy arm.
    # FOUR looks, three sleeps: the first look is immediate, so `1 2 3` would
    # have waited 2 s while claiming 3 (panel r1 codex-2).
    for _fe_try in 1 2 3 4; do
        [ "$_fe_try" -eq 1 ] || sleep 1
        _fe_row=$(_arm_fired_row) || _fe_row=""
        [ -n "$_fe_row" ] || continue
        # HIMMEL-1999 item 2: a row that ALREADY EXISTED when we armed can
        # never be this arm's fire, whatever its stamp reads. The compare below
        # is second-resolution and inclusive, so a prior run that started in
        # the same second as this arm would otherwise pass it -- and rc 15
        # deliberately lets a handover whose previous run COMPLETED re-arm all
        # day, which makes such a row the normal steady state, not an anomaly.
        if [ -n "${_ARM_PRIOR_FIRED_ROW:-}" ] && [ "$_fe_row" = "$_ARM_PRIOR_FIRED_ROW" ]; then
            continue
        fi
        _fe_at=$(printf '%s' "$_fe_row" | sed -n 's/.*"fired_at":"\([^"]*\)".*/\1/p')
        [ -n "$_fe_at" ] || continue
        # Fixed-width ISO-8601 UTC on both sides, so lexicographic >= IS
        # chronological >=. Inclusive: a fire in the same second the arm started
        # is still this arm's fire -- the snapshot compare above is what keeps
        # that inclusiveness from swallowing a PRIOR run's row.
        if [[ ! "$_fe_at" < "$_ARM_START_UTC" ]]; then return 0; fi
    done
    return 1
}

schedule_arm() {
    case "$PLATFORM" in
        windows)
            # schtasks ONETIME + a .bat indirection. We write the .bat
            # to a real path (mktemp) rather than relying on %TEMP%
            # expansion via bash, since bash leaves %TEMP% literal —
            # the v1 bug emitted %TEMP%\himmel-resume.bat which bash
            # wrote to a path NAMED %TEMP%\himmel-resume.bat instead
            # of $TEMP-resolved.
            local bat_path
            bat_path=$(mktemp -t himmel-resume.XXXXXX.bat)
            # HIMMEL-1606: prune our own leaked siblings. The .bat deletes its
            # own scheduled task on its first line but never removes ITSELF, so
            # every arm since 2026-06-28 left one behind -- 1665 files / 2.1 MB
            # measured 2026-08-06, growing with the arming cadence, i.e. in the
            # direction fan-out is pushing. Each also contains the full resume
            # command line (handover path, session name, repo path), so this is
            # a retention question as much as a disk one.
            #
            # Pruning HERE rather than in the .bat: a script cannot reliably
            # delete itself while cmd is still reading it, and arm-resume is the
            # only writer to this directory, so no new cadence or scheduled task
            # is needed. AGE-GATED at 7 days, never "every other file" -- an arm
            # can legitimately be parked hours ahead, and deleting a sibling a
            # PENDING arm still points at would break that arm. 7 days is far
            # beyond the longest legitimate park while still bounding the pile.
            # Both the prefix AND the .bat suffix are required in the match so
            # this can never widen into an unrelated temp file.
            # Best-effort throughout: a prune failure must never fail an arm.
            # HIMMEL-1624: skip the prune under --dry-run. This block runs
            # before the DRY_RUN early-return below, so without the gate a
            # dry-run arm would delete leaked .bat siblings -- a real side
            # effect that breaks the side-effect-free contract a dry run
            # promises (see the --dry-run note above the shipped-preflight).
            if [ "$DRY_RUN" -ne 1 ]; then
                find "$(dirname "$bat_path")" -maxdepth 1 -type f \
                    -name 'himmel-resume.*.bat' -mtime +7 -delete 2>/dev/null || true
            fi
            # bash mktemp on gitbash returns POSIX path; schtasks wants a
            # Windows path. cygpath converts. cygpath must exist here (Linux
            # would already have failed the platform check above).
            if ! command -v cygpath >/dev/null 2>&1; then
                echo "ERR arm-resume: cygpath not on PATH; cannot convert paths for schtasks" >&2
                echo "    Install Git for Windows (which ships cygpath)." >&2
                rm -f "$bat_path"
                exit 2
            fi
            local bat_path_win claude_cmd_win="" resume_cwd_win=""
            local claude_cmd_posix="" _cyg_out="" _cyg_rest=""
            local bash_posix
            if ! bash_posix=$(command -v bash 2>/dev/null); then
                echo "ERR arm-resume: 'bash' not on PATH at arm time" >&2
                rm -f "$bat_path"
                exit 2
            fi
            if [ -n "$WSL_DISTRO" ]; then
                # WSL owns both the executable lookup and cwd. Only the .bat
                # path crosses through cygpath; the in-distro values must not.
                if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
                    wsl.exe -d "$WSL_DISTRO" -e bash -lc 'command -v claude' >/dev/null 2>&1; then
                    echo "ERR arm-resume: 'claude' not on PATH at arm time (distro '$WSL_DISTRO')" >&2
                    rm -f "$bat_path"
                    exit 2
                fi
                if ! bat_path_win=$(cygpath -w "$bat_path" 2>&1) || [ -z "$bat_path_win" ]; then
                    echo "ERR arm-resume: cygpath -w failed converting bat=$bat_path: $bat_path_win" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
            else
                # Resolve claude.cmd to an absolute path so the .bat doesn't
                # depend on PATH being set in whatever cmd shell schtasks
                # spawns (SYSTEM context lacks npm-installed shims by default).
                if ! claude_cmd_posix=$(command -v claude 2>/dev/null); then
                    echo "ERR arm-resume: 'claude' not on PATH at arm time" >&2
                    rm -f "$bat_path"
                    exit 2
                fi
                # HIMMEL-708: convert all three paths (.bat, claude, cwd) in ONE
                # cygpath spawn instead of three — cygpath emits one Windows path
                # per input line, in argument order. Windows paths contain no
                # newlines, so split the result with pure-bash parameter expansion
                # (no extra sed/head spawns).
                if ! _cyg_out=$(cygpath -w "$bat_path" "$claude_cmd_posix" "$RESUME_CWD" 2>&1); then
                    echo "ERR arm-resume: cygpath -w failed converting one of [bat=$bat_path claude=$claude_cmd_posix cwd=$RESUME_CWD]: $_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
                bat_path_win="${_cyg_out%%$'\n'*}"
                _cyg_rest="${_cyg_out#*$'\n'}"
                claude_cmd_win="${_cyg_rest%%$'\n'*}"
                resume_cwd_win="${_cyg_rest#*$'\n'}"
                # Belt-and-suspenders (HIMMEL-708 CR): a well-behaved cygpath emits
                # exactly three non-empty lines on rc 0, so the split above is sound.
                # Guard anyway against a build that exits 0 with fewer lines —
                # otherwise resume_cwd_win would silently inherit claude_cmd_win (the
                # `#*\n` no-ops when no newline remains) and mis-target the .bat cd.
                # Mirrors the non-empty check the python-derived schedule fields get.
                if [ -z "$bat_path_win" ] || [ -z "$claude_cmd_win" ] || [ -z "$resume_cwd_win" ]; then
                    echo "ERR arm-resume: cygpath -w produced incomplete output (bat/claude/cwd): $_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
            fi
            local wsl_launch=""
            if [ -n "$WSL_DISTRO" ]; then
                local q_cwd q_name="" q_prompt q_channels="" q_model="" wsl_command
                q_cwd=$(_bash_single_quote "$RESUME_CWD")
                q_prompt=$(_bash_single_quote "$RESUME_PROMPT")
                [ -n "$SESSION_NAME" ] && q_name=" -n $(_bash_single_quote "$SESSION_NAME")"
                [ -n "$CHANNELS" ] && q_channels=" --channels $(_bash_single_quote "$CHANNELS")"
                [ -n "$MODEL" ] && q_model=" --model $(_bash_single_quote "$MODEL")"
                local q_automerge=""
                [ "$AUTOMERGE" -eq 1 ] && q_automerge="ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 "
                # HIMMEL-1382 fix round: unset both vars first (defense against
                # ambient carryover), THEN conditionally re-grant via the
                # per-command prefix — same always-clear contract as the
                # Windows/at/crontab launch bodies below. HIMMEL-1475: the same
                # unset also drops ARM_RESUME_SAFETY_ARM so the resumed in-distro
                # session does not inherit a leaked long-gap exemption.
                # HIMMEL-812: a `set` in the .bat cannot cross into the distro,
                # so the safety-child mark rides the in-distro command instead.
                local q_safety_child=""
                [ "$SAFETY_CHILD" -eq 1 ] && q_safety_child="AUTO_ARM_SAFETY_CHILD=1 "
                wsl_command="cd $q_cwd && unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM AUTO_ARM_SAFETY_CHILD CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID && export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 && ${q_safety_child}${q_automerge}claude$q_name $q_prompt$q_channels$q_model"
                # The composed command sits INSIDE the .bat line's double
                # quotes, where CMD treats ^ as a LITERAL character —
                # caret-escaping here reaches bash verbatim and shatters the
                # command (`cd` gets extra args, claude fires in the wrong
                # cwd; verified against a live .bat). Inside CMD quotes only
                # two characters stay active: % (batch expansion — double
                # it) and " (closes the quote — no safe in-quote escape
                # exists, CMD toggles on every unescaped quote regardless of
                # backslashes). So: %->%% and REFUSE a payload carrying a
                # double quote rather than emit an injectable line.
                case "$wsl_command" in
                    *'"'*)
                        echo "ERR arm-resume: a WSL-station arm cannot carry a double quote in its prompt/name/channels (CMD quote nesting is not escapable)" >&2
                        rm -f "$bat_path"
                        exit 2
                        ;;
                esac
                wsl_launch="${wsl_command//%/%%}"
            fi
            local bash_win flow_lib_m
            if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
                echo "ERR arm-resume: cygpath -w failed for bash path: $bash_win" >&2
                rm -f "$bat_path"
                exit 4
            fi
            if ! flow_lib_m=$(cygpath -m "$SCRIPT_DIR/../lib/flow-run-ledger.sh" 2>&1); then
                echo "ERR arm-resume: cygpath -m failed for flow-run-ledger.sh: $flow_lib_m" >&2
                rm -f "$bat_path"
                exit 4
            fi

            # .bat content: escape for interpolation INSIDE DOUBLE QUOTES via
            # cadence_cmd_escape (HIMMEL-1281/HIMMEL-1287) — % -> %% plus
            # best-effort " handling, deliberately NO caret escapes (cmd.exe
            # treats ^ as a LITERAL character inside double quotes, so
            # caret-escaping corrupts the value instead of protecting it).
            # Applied to the prompt, the cd path, and the bash/flow-run-ledger
            # paths — every one lands inside a quoted "%s" below.
            local p="$RESUME_PROMPT" c="$resume_cwd_win" bw="$bash_win" fl="$flow_lib_m" fr_note="$FLOW_RUN_NOTE"
            p=$(cadence_cmd_escape "$p")
            c=$(cadence_cmd_escape "$c")
            bw=$(cadence_cmd_escape "$bw")
            fl=$(cadence_cmd_escape "$fl")
            fr_note=$(cadence_cmd_escape "$fr_note")
            # Optional --channels passthrough. Same cadence_cmd_escape as the
            # prompt — the spec is operator-supplied (could carry % & ^) and
            # lands inside its own embedded double quotes (` --channels
            # "$cs"`) below.
            local ch=""
            if [ -n "$CHANNELS" ]; then
                local cs="$CHANNELS"
                cs=$(cadence_cmd_escape "$cs")
                ch=" --channels \"$cs\""
            fi
            # Optional --model passthrough (HIMMEL-2192). Same cadence_cmd_escape
            # + inline-quote shape as --channels above — MODEL is operator-
            # supplied and lands inside its own embedded double quotes.
            local mo=""
            if [ -n "$MODEL" ]; then
                local ms="$MODEL"
                ms=$(cadence_cmd_escape "$ms")
                mo=" --model \"$ms\""
            fi
            # -n <session name> (HIMMEL-702). SESSION_NAME is sanitized to
            # [A-Za-z0-9._ -] (see _compose_arm_name) so it carries no CMD
            # metacharacter and needs no ^-escaping here; quote it so the space
            # in "<TICKET> <name>" stays a single argv entry. Empty -> omit.
            local nm=""
            [ -n "$SESSION_NAME" ] && nm=" -n \"$SESSION_NAME\""
            # HIMMEL_HEADROOM_PROXY (HIMMEL-901): a SEPARATE cygpath call
            # (not folded into the batched bat/claude/cwd conversion above)
            # so the existing HIMMEL-708 3-path split logic stays untouched
            # when the flag is off — this only spawns when the flag is on.
            # CR round: curl gets the same treatment as HEADROOM_BIN (one
            # cygpath spawn for both) so the livez checks below carry an
            # ABSOLUTE curl path — see the HEADROOM_CURL resolution comment.
            local hb="" cu=""
            if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ] && [ -z "$WSL_DISTRO" ]; then
                local _hp_cyg_out _hp_cyg_rest headroom_bin_win curl_bin_win
                if ! _hp_cyg_out=$(cygpath -w "$HEADROOM_BIN" "$HEADROOM_CURL" 2>&1); then
                    echo "ERR arm-resume: cygpath -w failed converting [headroom=$HEADROOM_BIN curl=$HEADROOM_CURL]: $_hp_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
                headroom_bin_win="${_hp_cyg_out%%$'\n'*}"
                _hp_cyg_rest="${_hp_cyg_out#*$'\n'}"
                curl_bin_win="${_hp_cyg_rest%%$'\n'*}"
                # Same incomplete-output guard as the batched 3-path split
                # above (HIMMEL-708 CR): a cygpath that exits 0 with fewer
                # lines must not leave curl_bin_win aliasing headroom_bin_win.
                if [ -z "$headroom_bin_win" ] || [ -z "$curl_bin_win" ] || [ "$_hp_cyg_out" = "$_hp_cyg_rest" ]; then
                    echo "ERR arm-resume: cygpath -w produced incomplete output (headroom/curl): $_hp_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
                # hb is interpolated into the NESTED `cmd /c` detached-start
                # line below (a SECOND cmd parse), so it needs the double-
                # parse escape (_arm_nested_cmd_escape: cadence base + caret
                # escapes on ^ & < > |). cu (the curl livez checks) is a
                # single-parse top-level .bat line, so it keeps
                # cadence_cmd_escape. Do NOT unify them -- the two-parse
                # distinction is the HIMMEL-1287 contract (proxy-suite T4b
                # pins ^& on hb's line; T1287a/b/c pin NO carets on the
                # single-parse sites).
                hb=$(_arm_nested_cmd_escape "$headroom_bin_win")
                cu=$(cadence_cmd_escape "$curl_bin_win")
            fi
            # Self-clean FIRST: a /sc ONCE task lingers in Task Scheduler
            # after it fires (Ready/completed), accumulating stale jobs and
            # blocking a future same-handover arm without --force. So the
            # launcher deletes its OWN task as its first action. Deleting a
            # one-shot task's registration does NOT terminate the already-
            # spawned action process, so claude still launches below.
            # Non-fatal (>nul 2>&1, no `|| exit`): a failed cleanup must
            # never block the relaunch. TASK_NAME is sanitized to
            # [:alnum:]_- so it carries no CMD metacharacters.
            # cd /d switches drive + path in one step; quoted to survive
            # spaces. `|| exit /b 1` ensures the .bat aborts instead of
            # silently falling through to claude.exe in the wrong CWD
            # (which is the bug this fix targets — see comment above
            # RESUME_CWD computation).
            # Prompt MUST come before --channels: --channels is variadic
            # (consumes following args), so a trailing positional prompt
            # gets parsed as a bogus channel entry ("must be tagged" → exit 1).
            # HIMMEL_HEADROOM_PROXY (HIMMEL-901): when active, gate the
            # claude launch on a livez check, starting the proxy DETACHED
            # if it's down and giving it ~3s before rechecking. Fail-open:
            # if it's STILL down after the retry, fall through to a bare
            # launch (a broken proxy must never block the relaunch) — the
            # log at %USERPROFILE%\.headroom-proxy.log is the only trail.
            # `start "" /b cmd /c "..."` (not `start "" /b <exe> ... >>log`,
            # which does not reliably redirect the child) is the verified
            # detached-with-redirection form. `if errorlevel 1` reads the
            # LAST command's exit code, so the second `if errorlevel 1`
            # below correctly reflects either the original livez check (skip
            # branch never ran) or the retry livez check (skip branch ran) —
            # no delayed-expansion (!VAR!) needed anywhere. %USERPROFILE% is
            # a literal CMD env-var reference (NOT run through the %->%%
            # escaping below, which is for literal-data percents only).
            # CR round: each branch appends ONE mode-marker line to the
            # proxy log before launching (proxied vs bare-fallback) — the
            # HIMMEL-897 measurement trail; without it a fired launch is
            # indistinguishable after the fact. %DATE%/%TIME% expand when
            # CMD parses the if-block, close enough to launch time.
            # TASK_NAME is sanitized to [:alnum:]_- (no CMD metachars).
            {
                printf 'schtasks /delete /tn "%s" /f >nul 2>&1\r\n' "$TASK_NAME"
                # Capture the run_id via a temp file, NOT `for /f` — for /f
                # re-parses its backquoted command through cmd /c, whose
                # quote-stripping mangles a command that STARTS with a quoted
                # path and carries more quoted args (live-fire verified s52).
                printf 'set "FLOW_RUN_ID="
'
                printf 'set "FLOW_RUN_TMP=%%TEMP%%\\flow-run-%s.tmp"
' "$TASK_NAME"
                printf '"%s" "%s" --append-start "armed-resume" "" "%%COMPUTERNAME%%" "claude" "" "%s" "" "" > "%%FLOW_RUN_TMP%%" 2>NUL
' "$bw" "$fl" "$TASK_NAME"
                printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_ID=<"%%FLOW_RUN_TMP%%"
'
                printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1
'
                if [ -n "$WSL_DISTRO" ]; then
                    # -d value MUST be unquoted (HIMMEL-998): wsl.exe splits its
                    # pre--e command line naively and does NOT strip CMD-level
                    # double quotes, so -d "Ubuntu" resolves the five-char name
                    # plus quotes -> WSL_E_DISTRO_NOT_FOUND (rc -1, live win2
                    # fire). Interactive tests never caught it because bash/
                    # PowerShell strip the quotes before wsl.exe sees them;
                    # only the emitted .bat passes them through. Safe unquoted:
                    # WSL_DISTRO is validated ^[A-Za-z0-9._-]+$ at parse time.
                    printf 'wsl.exe -d %s -e bash -lc "%s"\r\n' "$WSL_DISTRO" "$wsl_launch"
                else
                    printf 'cd /d "%s" || exit /b 1\r\n' "$c"
                    # HIMMEL-1382 fix round: ALWAYS clear both vars first, then
                    # conditionally re-grant when --automerge was explicit on
                    # THIS arm. A cap-triggered auto re-arm never passes
                    # --automerge (auto-arm-on-cap.sh), so its generated .bat
                    # must not depend on schtasks NOT having carried an
                    # ambient ARMAUTOMERGE/CR_MERGE_GATE_OK through from
                    # whatever launched it -- the emitted text enforces its
                    # own contract regardless of ambient env.
                    # HIMMEL-1475: clear ARM_RESUME_SAFETY_ARM too, for the same
                    # reason and by symmetry with the POSIX launch bodies — the
                    # fired .bat session must not inherit a leaked long-gap
                    # exemption from the submitting safety-arm env.
                    printf 'set "ARMAUTOMERGE="\r\n'
                    printf 'set "CR_MERGE_GATE_OK="\r\n'
                    printf 'set "ARM_RESUME_SAFETY_ARM="\r\n'
                    # HIMMEL-2545: claude exports CLAUDE_CODE_CHILD_SESSION=1
                    # (and CLAUDE_PID) into every process it spawns, so a
                    # session armed FROM a claude tool call fires as a
                    # throwaway CHILD: transcript saving off, context-fill
                    # blind (rc=4), nothing for /handover-resume-armed or the
                    # luna session-capture hook. An armed resume is the
                    # opposite of a throwaway, so clear both — then force
                    # persistence ON, since claude's own default for a child
                    # is off and the .bat is what the relaunch is governed by.
                    # CLAUDE_CODE_SESSION_ID is a round-6 addition to the
                    # same clear: claude generates its own id regardless, so
                    # this never affected context-fill.sh, but the relaunched
                    # claude process's OWN environ otherwise still carried
                    # the ARMING session's stale id — the exact surface this
                    # ticket taught people to inspect.
                    printf 'set "CLAUDE_CODE_CHILD_SESSION="\r\n'
                    printf 'set "CLAUDE_PID="\r\n'
                    printf 'set "CLAUDE_CODE_SESSION_ID="\r\n'
                    printf 'set "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"\r\n'
                    if [ "$AUTOMERGE" -eq 1 ]; then
                        printf 'set "ARMAUTOMERGE=1"\r\n'
                        printf 'set "CR_MERGE_GATE_OK=1"\r\n'
                    fi
                    # HIMMEL-812: the auto-arm stale escalation's own child.
                    # auto-arm-on-cap.sh reads this out of the relaunched
                    # session's env and warns instead of arming again, which is
                    # what bounds the +5h safety-arm chain. Cleared first on the
                    # same always-clear contract as the three lines above.
                    printf 'set "AUTO_ARM_SAFETY_CHILD="\r\n'
                    if [ "$SAFETY_CHILD" -eq 1 ]; then
                        printf 'set "AUTO_ARM_SAFETY_CHILD=1"\r\n'
                    fi
                    if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
                        printf '"%s" -s -m 5 http://127.0.0.1:%s/livez >nul 2>&1\r\n' "$cu" "$HEADROOM_PROXY_PORT"
                        printf 'if errorlevel 1 (\r\n'
                        printf '    start "" /b cmd /c ""%s" proxy --port %s >> "%%USERPROFILE%%\\.headroom-proxy.log" 2>&1"\r\n' "$hb" "$HEADROOM_PROXY_PORT"
                        printf '    ping -n 4 127.0.0.1 >nul\r\n'
                        printf '    "%s" -s -m 5 http://127.0.0.1:%s/livez >nul 2>&1\r\n' "$cu" "$HEADROOM_PROXY_PORT"
                        printf ')\r\n'
                        printf 'if errorlevel 1 (\r\n'
                        printf '    echo %%DATE%% %%TIME%% arm=%s mode=bare-fallback>> "%%USERPROFILE%%\\.headroom-proxy.log"\r\n' "$TASK_NAME"
                        printf '    "%s"%s "%s"%s%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch" "$mo"
                        printf ') else (\r\n'
                        printf '    echo %%DATE%% %%TIME%% arm=%s mode=proxied>> "%%USERPROFILE%%\\.headroom-proxy.log"\r\n' "$TASK_NAME"
                        printf '    set "ANTHROPIC_BASE_URL=http://127.0.0.1:%s"\r\n' "$HEADROOM_PROXY_PORT"
                        printf '    set "HEADROOM_OFFLINE=1"\r\n'
                        printf '    "%s"%s "%s"%s%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch" "$mo"
                        printf ')\r\n'
                    else
                        printf '"%s"%s "%s"%s%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch" "$mo"
                    fi
                fi
                printf 'set "FLOW_RUN_RC=%%ERRORLEVEL%%"\r\n'
                printf 'set "FLOW_RUN_OUTCOME=complete"\r\n'
                printf '"%s" "%s" --classify "%%FLOW_RUN_RC%%" "" > "%%FLOW_RUN_TMP%%" 2>NUL\r\n' "$bw" "$fl"
                printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_OUTCOME=<"%%FLOW_RUN_TMP%%"\r\n'
                printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
                printf 'if "%%FLOW_RUN_OUTCOME%%"=="" set "FLOW_RUN_OUTCOME=complete"\r\n'
                printf 'if not "%%FLOW_RUN_ID%%"=="" "%s" "%s" --append-end "armed-resume" "%%FLOW_RUN_ID%%" "" "%%FLOW_RUN_RC%%" "%%FLOW_RUN_OUTCOME%%" "" "%s" > NUL 2>&1\r\n' "$bw" "$fl" "$fr_note"
                printf 'exit /b %%FLOW_RUN_RC%%\r\n'
            } > "$bat_path"

            # HIMMEL-938 Part A: re-render START_DATE in the MACHINE's own
            # Windows short-date locale right before it's used as /sd —
            # schtasks parses /sd per-locale, so the MM/DD/YYYY default
            # derived above is only correct on a US-format machine. Any
            # render failure (empty PY_ARMOR_OUT) falls back to the
            # original START_DATE, i.e. exactly the pre-HIMMEL-938 behavior.
            # _locale_degraded=1 when the /sd value did NOT come from a
            # successful registry-read + render (fallback used). On its own
            # that only degrades locale-correctness -- but if the post-arm
            # verify below is ALSO unavailable, BOTH safeguards are down and
            # a day-first machine is back in the original misarm class, so
            # that combination fails closed (codex-adv-8).
            local _win_pat _win_sd _locale_degraded
            _locale_degraded=0
            if ! _win_pat=$(_win_short_date_pattern); then
                _locale_degraded=1
            fi
            _win_sd=""
            if _win_render_short_date "$TARGET_EPOCH" "$_win_pat"; then
                _win_sd="$PY_ARMOR_OUT"
            fi
            if [ -z "$_win_sd" ]; then
                _win_sd="$START_DATE"
                _locale_degraded=1
            fi

            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY arm-resume: would schtasks /create /tn $TASK_NAME /tr $bat_path_win /sc ONCE /st $RESUME_TIME /sd $_win_sd /f"
                echo "DRY arm-resume: .bat content:"
                sed 's/^/    /' "$bat_path"
                rm -f "$bat_path"
                return 0
            fi

            # HIMMEL-1304 finding 2: export whatever is currently registered
            # under $TASK_NAME before the /create below overwrites it in
            # place (see _win_restore_backup_task above for why). A query
            # failure just means there was nothing to back up -- the normal
            # first-arm case, not an error.
            local _backup_xml
            _backup_xml=$(mktemp -t arm-resume.task-backup.XXXXXX.xml)
            if ! MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /query /tn "$TASK_NAME" /xml ONE > "$_backup_xml" 2>/dev/null; then
                rm -f "$_backup_xml"
                _backup_xml=""
            fi

            local err_file
            err_file=$(mktemp -t arm-resume.err.XXXXXX)
            # MSYS_NO_PATHCONV=1: see HIMMEL-125 note in list_existing.
            if ! MSYS_NO_PATHCONV=1 "${SCHTASKS_CMD:-schtasks}" /create /tn "$TASK_NAME" /tr "$bat_path_win" /sc ONCE /st "$RESUME_TIME" /sd "$_win_sd" /f 2>"$err_file"; then
                echo "ERR arm-resume: schtasks /create failed:" >&2
                cat "$err_file" >&2
                rm -f "$err_file" "$bat_path" "$_backup_xml"
                exit 4
            fi
            rm -f "$err_file"
            # Epoch at create-completion (codex-adv-3): if /create itself
            # finished AFTER the target (slow setup on a tight lead), the
            # ONCE task registers already-expired and can never fire -- a
            # later NEXTRUN-NONE must then be a refused arm, never
            # "consumed". Captured here, read in the verify branch below.
            local _create_done_epoch
            _create_done_epoch=$(date +%s)

            # HIMMEL-938 Part B: post-arm NextRunTime verify. A successful
            # schtasks /create rc=0 is not proof the task will fire at the
            # intended moment -- a misregistered /sd (wrong locale, or any
            # other silent misparse) still returns rc=0, and the task then
            # just sits Ready and never fires (or fires months out — the
            # exact HIMMEL-938 bug). Get-ScheduledTaskInfo's .NextRunTime is
            # a real DateTime (locale-independent), unlike `schtasks /query`
            # output, so it's the trustworthy cross-check. Fail-OPEN on the
            # PROBE itself (missing/broken PowerShell must never block an
            # otherwise-good arm -- WARN and let the arm stand); fail-CLOSED
            # on a bad ANSWER (a confirmed months-out registration is worse
            # than no arm at all -- delete the just-created task and refuse).
            # Skipped entirely under --dry-run (the DRY branch above already
            # returned).
            local _verify_err _ps_out _ps_rc
            _verify_err=$(mktemp -t arm-resume.verify-err.XXXXXX)
            _ps_rc=0
            # `|| _ps_rc=$?` (not a bare trailing `_ps_rc=$?`): under this
            # file's `set -e`, a failing command substitution assigned
            # straight to a variable aborts the script right there — same
            # armor idiom py_armor_capture uses to stay errexit-safe.
            # -ErrorAction Stop + try/catch (codex-adv-10): NEXTRUN-NONE must
            # mean a SUCCESSFUL query that definitively found no next run --
            # task-not-found maps to it via the locale-independent
            # ObjectNotFound category; every OTHER query error (access
            # denied, service failure, missing cmdlet) exits nonzero and
            # takes the probe-failure path instead of masquerading as an
            # authoritative answer.
            _ps_out=$(powershell -NoProfile -NonInteractive -Command "
                try {
                    \$t = Get-ScheduledTaskInfo -TaskPath '\' -TaskName '$TASK_NAME' -ErrorAction Stop
                    if (\$null -eq \$t.NextRunTime) { 'NEXTRUN-NONE' }
                    else { [int64]([DateTimeOffset]\$t.NextRunTime.ToUniversalTime()).ToUnixTimeSeconds() }
                } catch {
                    # CommandNotFoundException (ScheduledTasks module absent)
                    # ALSO carries the ObjectNotFound category -- it must
                    # stay a probe failure, not a task-not-found answer
                    # (coderabbit-1).
                    if (\$_.Exception -is [System.Management.Automation.CommandNotFoundException]) { Write-Error \$_; exit 1 }
                    elseif (\$_.CategoryInfo.Category -eq 'ObjectNotFound') { 'NEXTRUN-NONE' }
                    else { Write-Error \$_; exit 1 }
                }
            " 2>"$_verify_err") || _ps_rc=$?
            if [ "$_ps_rc" -ne 0 ] || [ -z "$_ps_out" ]; then
                if [ "$_locale_degraded" -eq 1 ]; then
                    # BOTH safeguards down: the /sd came from the US-format
                    # fallback AND the verify can't check what actually
                    # registered -- on a day-first machine this is exactly
                    # the silent months-out misarm again. Loud no-arm wins.
                    echo "ERR arm-resume: locale detection fell back to MM/dd/yyyy AND the post-arm verify could not run (rc=$_ps_rc) -- with both safeguards unavailable a mistimed arm would be silent. Deleting the task; fix 'reg'/'powershell' availability and re-arm." >&2
                    sed 's/^/    /' "$_verify_err" >&2
                    rm -f "$_verify_err"
                    _win_delete_bad_task "$TASK_NAME" || true
                    if _win_restore_backup_task "$TASK_NAME" "$_backup_xml"; then
                        rm -f "$_backup_xml"
                    fi
                    rm -f "$bat_path"
                    exit 2
                fi
                # HIMMEL-1879 (r5): fail-OPEN stands -- an unreachable probe is
                # not evidence of a bad arm, and refusing here would strand every
                # host where powershell is unavailable. But the closing banner
                # must not then claim an EARNED success: the whole point of this
                # ticket is that RESUME ARMED means "queried back and confirmed",
                # and this arm was never confirmed. Flag it; the banner says so.
                _ARM_UNVERIFIED=1
                echo "WARN arm-resume: post-arm NextRunTime verify could not run (rc=$_ps_rc) -- arm stands unverified:" >&2
                sed 's/^/    /' "$_verify_err" >&2
                rm -f "$_verify_err"
            else
                rm -f "$_verify_err"
                _ps_out=$(printf '%s' "$_ps_out" | tr -d '\r\n ')
                if [ "$_ps_out" = "NEXTRUN-NONE" ]; then
                    # Create->verify race guard (codex-adv-1/-2): the emitted
                    # .bat deletes its OWN task registration as its first
                    # action, so a target whose time ARRIVED between /create
                    # and this probe can legitimately be gone -- consumed,
                    # not misarmed. A scheduler never fires EARLY, so a
                    # missing task whose target is still in the future
                    # cannot have fired -- that is a bad registration (e.g. a
                    # past-date /sd misparse also registers with no
                    # NextRunTime), and lead time alone must not excuse it.
                    local _now_epoch _lead
                    _now_epoch=$(date +%s)
                    _lead=$((TARGET_EPOCH - _now_epoch))
                    # Consumed iff created-before-target AND verified-after-
                    # target -- a task created after its target registers
                    # expired and never fires (codex-adv-3), and one whose
                    # target is still future cannot have fired, even by a
                    # second: the scheduler never fires early and every
                    # epoch here reads the same local clock, so no skew
                    # grace is warranted (codex-adv-2/-4). Everything else
                    # refuses loudly.
                    # Strict < : a create completing WITHIN the target second
                    # is ambiguous (may have registered after the trigger
                    # instant) -- ambiguity refuses (codex-adv-6).
                    # ...and only with POSITIVE evidence that it fired (r4
                    # round). Timing alone cannot tell a self-deleted fire from
                    # a create that silently registered nothing and then had its
                    # target lapse before this probe: both leave no task and a
                    # passed target. Calling the second one CONSUMED reports an
                    # already-running session that does not exist, so nobody
                    # re-arms -- the same silent death the generic verify guards
                    # against, and the same ledger row settles it.
                    if [ "$_lead" -le 0 ] && [ "$_create_done_epoch" -lt "$TARGET_EPOCH" ] \
                       && _arm_fired_evidence; then
                        # HIMMEL-1879: consumed is NOT armed. The flag stops the
                        # generic post-arm existence verify from re-refusing a
                        # legitimately-fired task, and swaps the closing banner
                        # from "RESUME ARMED" to a CONSUMED one -- an operator
                        # who reads ARMED here will wait for a fire that already
                        # happened.
                        _ARM_CONSUMED=1
                        echo "WARN arm-resume: post-arm verify found no task '$TASK_NAME' and the target time has passed (lead=${_lead}s, created ${_create_done_epoch} <= target ${TARGET_EPOCH}) -- it fired and self-deleted during the create->verify window; treating the arm as consumed, not failed." >&2
                    else
                        echo "ERR arm-resume: post-arm verify found NO NextRunTime for '$TASK_NAME' (requested $RESUME_TIME on $_win_sd, epoch=$TARGET_EPOCH, lead=${_lead}s, create-done=$_create_done_epoch -- a still-future target cannot have fired, and a task created after its target never fires). Deleting the bad task -- this is the HIMMEL-938 silent-misarm class." >&2
                        _win_delete_bad_task "$TASK_NAME" || true
                        if _win_restore_backup_task "$TASK_NAME" "$_backup_xml"; then
                            rm -f "$_backup_xml"
                        fi
                        rm -f "$bat_path"
                        exit 2
                    fi
                else
                case "$_ps_out" in
                    *[!0-9]*|'')
                        if [ "$_locale_degraded" -eq 1 ]; then
                            # Same dual-failure class as the dead-probe path
                            # above: garbage output is no usable confirmation
                            # either (codex-adv-9).
                            echo "ERR arm-resume: locale detection fell back to MM/dd/yyyy AND the post-arm verify returned a non-numeric NextRunTime ('$_ps_out') -- with both safeguards unavailable a mistimed arm would be silent. Deleting the task; fix 'reg'/'powershell' availability and re-arm." >&2
                            _win_delete_bad_task "$TASK_NAME" || true
                            if _win_restore_backup_task "$TASK_NAME" "$_backup_xml"; then
                                rm -f "$_backup_xml"
                            fi
                            rm -f "$bat_path"
                            exit 2
                        fi
                        echo "WARN arm-resume: post-arm verify returned a non-numeric NextRunTime ('$_ps_out') -- arm stands unverified" >&2
                        ;;
                    *)
                        local _diff
                        if [ "$_ps_out" -gt "$TARGET_EPOCH" ]; then
                            _diff=$((_ps_out - TARGET_EPOCH))
                        else
                            _diff=$((TARGET_EPOCH - _ps_out))
                        fi
                        # A healthy arm registers NextRunTime on the exact
                        # requested minute, so anything beyond scheduler
                        # resolution (120s) is a real mistime -- a one-day-
                        # late registration misses the resume window just as
                        # surely as a months-out one (codex-adv-5; tightened
                        # from the ticket's original 24h sketch).
                        if [ "$_diff" -gt 120 ]; then
                            echo "ERR arm-resume: post-arm verify mismatch for '$TASK_NAME' -- requested epoch=$TARGET_EPOCH ($RESUME_TIME on $_win_sd), registered NextRunTime epoch=$_ps_out (diff=${_diff}s > 120s tolerance). Deleting the bad task -- this is the HIMMEL-938 mistimed-arm class." >&2
                            _win_delete_bad_task "$TASK_NAME" || true
                            if _win_restore_backup_task "$TASK_NAME" "$_backup_xml"; then
                                rm -f "$_backup_xml"
                            fi
                            rm -f "$bat_path"
                            exit 2
                        fi
                        ;;
                esac
                fi
            fi
            # Every path above that did NOT exit is a success (verified,
            # unverified-but-standing, or consumed) -- the new arm stands
            # and the pre-overwrite backup is no longer needed.
            rm -f "$_backup_xml"
            ;;
        linux)
            if command -v at >/dev/null 2>&1; then
                # at jobs are one-shot and atd removes them from the queue
                # after they run, so (unlike schtasks ONCE and crontab) the
                # at body needs no self-clean line — the queue cleans itself.
                # at heredoc body INCLUDES the HIMMEL-Resume-<name>
                # marker as a comment line so list_existing's grep
                # actually matches. v1 omitted this; dedup was dead.
                #
                # Heredoc delimiter is UNQUOTED on purpose — we need
                # $q_prompt / $q_cwd to expand at write time so the
                # at-job body contains the actual quoted values, not
                # literal "$q_prompt" strings. Injection protection
                # comes from `printf '%q'` applied to RESUME_PROMPT and
                # RESUME_CWD below: bash %q backslash-escapes $, `,
                # spaces, etc., so a handover path containing $(rm -rf
                # /) survives both the heredoc write AND the /bin/sh
                # re-parse at fire time as a literal string.
                local q_prompt q_cwd q_channels="" q_name="" q_model=""
                q_prompt=$(printf '%q' "$RESUME_PROMPT")
                q_cwd=$(printf '%q' "$RESUME_CWD")
                # %q shell-quotes the channels spec so /bin/sh can't
                # re-interpret it at fire time; trailing space separates
                # it from the prompt arg (empty when no --channels).
                [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") "
                # -n <session name> (HIMMEL-702): %q so "<TICKET> <name>"
                # stays one arg after the /bin/sh re-parse. Empty -> omit.
                [ -n "$SESSION_NAME" ] && q_name="-n $(printf '%q' "$SESSION_NAME") "
                # Optional --model passthrough (HIMMEL-2192), same %q-quote
                # shape as --channels above.
                [ -n "$MODEL" ] && q_model="--model $(printf '%q' "$MODEL") "
                # HIMMEL_HEADROOM_PROXY (HIMMEL-901): $launch_lines is the
                # plain 'claude ...' line unless the flag is active, in
                # which case it becomes a livez-check-then-launch block
                # (same shape as _crontab_schedule's $tail above) — built
                # ONCE so the dry-run echo and the real heredoc can't drift
                # apart. Inactive -> byte-identical to the pre-901 line.
                # CR round: absolute curl path ($q_curl — see HEADROOM_CURL)
                # + one mode-marker echo per branch (HIMMEL-897 trail).
                # `\$(date)` is escaped so it lands LITERALLY in the job
                # body and evaluates at FIRE time, not arm time.
                local q_automerge=""
                [ "$AUTOMERGE" -eq 1 ] && q_automerge="ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 "
                # HIMMEL-1382 fix round: `at` snapshots the submitting shell's
                # ambient env, so an automerge-armed session's `at -t` job
                # would otherwise silently RETAIN CR_MERGE_GATE_OK/ARMAUTOMERGE
                # even when THIS arm's generated text sets neither. Unset both
                # unconditionally as the first line of the job body so the
                # emitted text — not the ambient env it was submitted from —
                # is what governs. HIMMEL-1475: the same line also unsets
                # ARM_RESUME_SAFETY_ARM — on Linux `at` snapshots the submitter
                # env, so without this the RESUMED claude session inherits the
                # sticky long-gap exemption from the safety arm that scheduled
                # it, and every later far HH:MM arm it makes silently bypasses
                # the guard.
                # HIMMEL-2545: the same always-clear contract, for the vars claude
                # itself injects. claude exports CLAUDE_CODE_CHILD_SESSION=1 (and
                # CLAUDE_PID) into every process it spawns, so an arm made from inside a
                # claude tool call hands the relaunch a THROWAWAY-CHILD marker: transcript
                # saving off, `context-fill.sh` rc=4 ("blind fill"), no armed-resume
                # archaeology, nothing for the luna session-capture hook. An armed resume
                # is the session that most needs its transcript, so the launch body clears
                # both and forces persistence ON rather than depending on the ambient env
                # the arm happened to be submitted from. CLAUDE_PID is the HIMMEL-2514
                # sibling: the relaunch must not inherit the arming session's pid either.
                # CLAUDE_CODE_SESSION_ID is a round-6 addition to the same clear:
                # claude generates its own id and exports the correct one to its own
                # tool subprocesses regardless, so this never affected context-fill.sh
                # - but the relaunched claude PROCESS's own environ otherwise still
                # carried the ARMING session's stale id, misleading anyone inspecting
                # /proc/<claude pid>/environ, exactly the surface this ticket taught
                # people to check.
                local launch_lines="unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID
export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1
${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model"
                if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
                    local q_hb q_log q_curl
                    q_hb=$(printf '%q' "$HEADROOM_BIN")
                    q_log=$(printf '%q' "$HOME/.headroom-proxy.log")
                    q_curl=$(printf '%q' "$HEADROOM_CURL")
                    launch_lines="unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID
export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1
$q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1 || { $q_hb proxy --port $HEADROOM_PROXY_PORT >> $q_log 2>&1 & sleep 3; }
if $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1; then
    echo \"\$(date) arm=$TASK_NAME mode=proxied\" >> $q_log
    ANTHROPIC_BASE_URL=http://127.0.0.1:$HEADROOM_PROXY_PORT HEADROOM_OFFLINE=1 ${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model
else
    echo \"\$(date) arm=$TASK_NAME mode=bare-fallback\" >> $q_log
    ${q_automerge}claude ${q_name}$q_prompt $q_channels$q_model
fi"
                fi
                local q_flow_lib q_task q_note
                q_flow_lib=$(printf '%q' "$SCRIPT_DIR/../lib/flow-run-ledger.sh")
                q_task=$(printf '%q' "$TASK_NAME")
                q_note=$(printf '%q' "$FLOW_RUN_NOTE")
                # HIMMEL-812: prepended to the WRAPPED body (not to each launch
                # variant) so the dry-run echo and the real `at` heredoc below
                # cannot drift apart — both render this same $launch_lines.
                # ALWAYS-CLEAR, then conditionally grant, exactly like the
                # ARMAUTOMERGE/ARM_RESUME_SAFETY_ARM line below: `at` snapshots
                # the SUBMITTING env, so an ordinary arm made FROM a safety-child
                # session would otherwise relaunch still carrying the mark and
                # silently inherit its no-escalation rule (panel r3 [codex-2]).
                local at_safety_child="unset AUTO_ARM_SAFETY_CHILD
"
                [ "$SAFETY_CHILD" -eq 1 ] && at_safety_child="export AUTO_ARM_SAFETY_CHILD=1
"
                launch_lines="${at_safety_child}_flow_run_id=\$($q_flow_lib --append-start armed-resume \"\" \"\" claude \"\" $q_task \"\" \"\$\$\" 2>/dev/null) || _flow_run_id=
_flow_rc=0
$launch_lines || _flow_rc=\$?
_flow_outcome=\$($q_flow_lib --classify \"\$_flow_rc\" \"\" 2>/dev/null) || _flow_outcome=complete
test \"\$_flow_outcome\" != \"\" || _flow_outcome=complete
test \"\$_flow_run_id\" != \"\" && $q_flow_lib --append-end armed-resume \"\$_flow_run_id\" \"\" \"\$_flow_rc\" \"\$_flow_outcome\" \"\" $q_note >/dev/null 2>&1 || true
exit \"\$_flow_rc\""
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY arm-resume: would at -t $AT_STAMP <<'CMD'"
                    echo "    # $TASK_NAME"
                    echo "    cd $q_cwd || exit 1"
                    printf '%s\n' "$launch_lines" | sed 's/^/    /'
                    echo "    CMD"
                    return 0
                fi
                local err_file
                err_file=$(mktemp -t arm-resume.err.XXXXXX)
                # at -t takes an exact [[CC]YY]MMDDhhmm datetime, so we pass the
                # already-resolved START date+time (AT_STAMP). Avoids at's
                # impl-defined past-time handling AND the old today/tomorrow
                # heuristic that broke for resets >24h out. HIMMEL-204.
                if ! at -t "$AT_STAMP" 2>"$err_file" <<CMD
# $TASK_NAME
cd $q_cwd || exit 1
$launch_lines
CMD
                then
                    echo "ERR arm-resume: at -t $AT_STAMP failed:" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 4
                fi
                rm -f "$err_file"
            else
                _crontab_schedule
            fi
            ;;
        macos)
            # macOS deliberately uses crontab, NOT at: atrun (com.apple.atrun)
            # is off-by-default and may be unenableable under SIP, so an `at -t`
            # job would silently never fire. crontab is the per-user one-shot
            # primitive needing no privileged daemon. (HIMMEL-594)
            _crontab_schedule ;;
    esac
}

# ---------------------------------------------------------------------------
# HIMMEL-1879 part 1 -- elapsed-aware lead floor, applied at the LAST moment
# before the scheduler is touched.
#
# This is the point of maximum knowledge: every slow step (worker census, the
# shipped-work preflight's network probes, queue lock, collision scan, worktree
# creation) has already happened, so `now` here already CONTAINS the elapsed arm
# time -- no separate elapsed term is needed, and `max(floor, now + floor)` says
# exactly what the ticket asks for ("ASAP = now + max(4 min, elapsed + margin)")
# without having to predict the future.
#
# Only SENTINEL targets move. --time smart/auto mean "as soon as practical", so
# sliding to the next practical minute is faithful to the request. An explicit
# HH:MM is an operator's clock choice: moving it silently would be the worse
# failure, so a lapsed HH:MM stays lapsed and the post-arm verify below refuses
# it LOUDLY (the honest answer is a failed arm, not a different one).
#
# ARM_MIN_LEAD_SEC: the floor, in seconds (default 120 -- schtasks ONCE has
# minute granularity plus scheduler latency, so anything under ~2 min is a coin
# flip). Also the suite's seam for forcing the bump deterministically.
#
# check_collision (rc 6) already ran against the PRE-bump minute, so a bumped
# sentinel would otherwise land on another HIMMEL-* task's exact minute with the
# refusal skipped -- two concurrent sessions, which is the one thing rc 6 exists
# to prevent (codex-3, r2 round). It is re-run BELOW, but only inside the bump
# branch: on Windows list_collision_candidates reads the schtasks cache warmed
# before the dedup scan, so the re-check costs no extra scheduler query on the
# arm's time-critical path, and on POSIX it is a cheap atq/crontab read. Nothing
# is armed yet at this point, so refusing here needs no rollback.
_ARM_MIN_LEAD=${ARM_MIN_LEAD_SEC:-120}
case "$_ARM_MIN_LEAD" in ''|*[!0-9]*) _ARM_MIN_LEAD=120 ;; esac
if [ "$_ARM_SENTINEL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    _arm_now=$(date +%s)
    if [ $((TARGET_EPOCH - _arm_now)) -lt "$_ARM_MIN_LEAD" ]; then
        _arm_old_epoch="$TARGET_EPOCH"
        # Round UP to the next whole minute: schtasks /st and at -t both take
        # HH:MM, so a target mid-minute would truncate BACKWARD into the past.
        TARGET_EPOCH=$(( ((_arm_now + _ARM_MIN_LEAD) / 60 + 1) * 60 ))
        if ! py_armor_capture -c '
import sys, datetime
dt = datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone()
print(dt.strftime("%H:%M"), dt.strftime("%m/%d/%Y"), dt.strftime("%Y%m%d%H%M"))
' "$TARGET_EPOCH"; then
            echo "ERR arm-resume: the $RESUME_TIME slot lapsed during arming (arm took $((_arm_now - _ARM_START_EPOCH))s) and the pushed-forward target could not be re-derived -- refusing rather than arming a task that can never fire." >&2
            exit 2
        fi
        read -r RESUME_TIME START_DATE AT_STAMP <<<"$PY_ARMOR_OUT"
        echo "WARN arm-resume: arming took $((_arm_now - _ARM_START_EPOCH))s, leaving only $((_arm_old_epoch - _arm_now))s of lead on the $(_epoch_hhmm "$_arm_old_epoch") sentinel slot -- pushed the target forward to $RESUME_TIME (min lead ${_ARM_MIN_LEAD}s). A task registered at or after its own fire time never fires (HIMMEL-1879)." >&2
        unset _arm_old_epoch
        # The bumped minute has never been collision-checked. Re-ask, against
        # the same (cached) candidate list the pre-bump scan used, so an
        # exact-minute overlap still HARD-refuses instead of arming a second
        # session onto another chain's seat. --force/--dedup-any keep their
        # existing WARN-only semantics -- that logic lives inside the function.
        _arm_bump_collision_rc=0
        check_collision || _arm_bump_collision_rc=$?
        if [ "$_arm_bump_collision_rc" -eq 6 ]; then
            echo "ERR arm-resume: the pushed-forward target $RESUME_TIME collides with the task above (HIMMEL-1879 bump). NOT armed -- nothing was scheduled; re-run with an explicit --time." >&2
            exit 6
        fi
        unset _arm_bump_collision_rc
    fi
    unset _arm_now
fi

# HIMMEL-1999 item 2: snapshot this task's newest armed-resume start row BEFORE
# anything is registered. Nothing of ours can have fired yet, so whatever is
# here belongs to a PREVIOUS run of the same task name -- and _arm_fired_evidence
# refuses to read it as this arm's fire even when the two share a start second.
_ARM_PRIOR_FIRED_ROW=$(_arm_fired_row) || _ARM_PRIOR_FIRED_ROW=""

schedule_arm

if [ "$DRY_RUN" -eq 1 ]; then
    echo "RESUME_CWD=$RESUME_CWD"
    echo "arm-resume: dry-run complete (no changes made)"
    exit 0
fi

# ---------------------------------------------------------------------------
# HIMMEL-1879 part 1 -- the SUCCESS line must be EARNED.
#
# Everything above can print an encouraging trail and still leave nothing armed:
# schtasks /create returns rc=0 for a task whose fire time already passed, and
# the HIMMEL-938 guard then deletes it. That guard exits 2 on the Windows paths
# it can see -- but POSIX at/crontab had NO post-arm check at all (`at -t` rc=0
# went straight to the banner), and no platform re-asked the cheapest question
# of all: is the target still in the FUTURE now that we are done?
#
# So: query the arm BACK from the scheduler, by the same identity dedup matches
# on (list_existing task -- one implementation, all three platforms), and refuse
# with a named reason if it is gone or if its fire time has passed. On Windows
# the query cache was populated by the PRE-arm dedup scan, so it must be
# invalidated first or we would be reading a snapshot from before the create.
#
# Fail-OPEN on a broken PROBE, fail-CLOSED on a bad ANSWER -- the same split
# HIMMEL-938 settled on. _ARM_CONSUMED marks the one legitimate no-task case
# (the arm fired during the create->verify window); it is reported as CONSUMED,
# never as ARMED.
if [ "${_ARM_CONSUMED:-0}" -ne 1 ]; then
    _SCHTASKS_CACHE_DONE=""
    _arm_verify_found=$(list_existing task 2>/dev/null) || _arm_verify_found="__PROBE_FAILED__"
    # The clock is read AFTER the query, not before it (codex-2, r2 round). The
    # scheduler query is the slowest thing on this path, and a target that was
    # still seconds away when it started can arrive WHILE it runs -- the task
    # then fires, deletes its own registration, and the query answers "gone".
    # Computing the lead beforehand would report "still N s out, so it cannot
    # have fired" about a task that just did, i.e. exactly the untruthful
    # SUCCESS/FAILURE label this ticket exists to remove, only inverted.
    _arm_verify_now=$(date +%s)
    _arm_verify_lead=$((TARGET_EPOCH - _arm_verify_now))
    if [ "$_arm_verify_found" = "__PROBE_FAILED__" ]; then
        # Same fail-open, same honesty tax as the NextRunTime probe above.
        # NOTE: on every platform today list_existing cannot actually RETURN
        # non-zero -- _ensure_schtasks_cache and the atq branch both `exit 2` on
        # a genuine query error -- so this arm is belt-and-braces for a future
        # where that contract loosens. It stays because the alternative (a bare
        # fall-through to RESUME ARMED) is the exact untruth this ticket removes.
        _ARM_UNVERIFIED=1
        echo "WARN arm-resume: post-arm existence verify could not query the scheduler -- the arm stands unverified." >&2
    elif [ -z "$_arm_verify_found" ] && [ "$_arm_verify_lead" -le 0 ] && _arm_fired_evidence; then
        # No task, the target has arrived, AND the runner left its own start row:
        # it fired and self-deleted inside the arm->verify window. CONSUMED, not
        # failed -- a session is already running, and calling that a failed arm
        # would send the operator to re-arm a seat that is already taken.
        _ARM_CONSUMED=1
        echo "WARN arm-resume: post-arm verify found no task '$TASK_NAME' and the target time has passed (lead=${_arm_verify_lead}s), and the flow-run ledger holds this task's own armed-resume start row -- it fired and self-deleted during the arm->verify window; treating the arm as consumed, not failed (HIMMEL-1879)." >&2
    elif [ -z "$_arm_verify_found" ] && [ "$_arm_verify_lead" -le 0 ]; then
        # Same scheduler picture, opposite cause. Without a start row NOTHING
        # fired, so the create registered nothing and the clock merely ran out
        # while we armed. Reporting THIS as consumed would be the silent death
        # this ticket exists to end: the operator is told a session is already
        # running, waits for output that never comes, and nobody re-arms.
        echo "ERR arm-resume: post-arm verify found NO scheduler entry for '$TASK_NAME' and the $RESUME_TIME target has passed (lead=${_arm_verify_lead}s; the arm itself took $((_arm_verify_now - _ARM_START_EPOCH))s) -- and the flow-run ledger holds NO armed-resume start row for this task, so nothing ever fired: the create REGISTERED NOTHING. NOT armed -- re-arm with a later --time (or --time smart, which pushes the target past the lead floor)." >&2
        exit 2
    elif [ "$_arm_verify_lead" -le 0 ] && _arm_fired_evidence; then
        # The query LISTED the task, yet this arm's own start row exists: the
        # scheduler read is a snapshot, and the task fired during the query
        # itself (r6 round). This is the last member of the family -- it was the
        # one branch still deciding on timing alone, and it decided "expired",
        # which sends the operator to re-arm a seat a live session already
        # holds. Consumed, and deliberately NOT reaped: the fired runner deletes
        # its own registration as its first action, so there is nothing of ours
        # left to delete and a soft delete here could only race that.
        _ARM_CONSUMED=1
        echo "WARN arm-resume: post-arm verify listed task '$TASK_NAME' but the $RESUME_TIME target has passed (lead=${_arm_verify_lead}s) and the flow-run ledger holds this arm's own armed-resume start row -- the listing is a snapshot from before it fired. Consumed, not expired; the task's own registration is left alone (HIMMEL-1879)." >&2
    elif [ "$_arm_verify_lead" -le 0 ]; then
        # A registered-but-expired entry is worse than none: it never fires AND
        # the next dedup scan would refuse the corrective re-arm as a duplicate.
        # Reap it softly (WARN, never abort) so re-arming needs no --force.
        # No start row, so nothing fired -- this really is a dead registration.
        while IFS= read -r _arm_verify_marker; do
            [ -n "$_arm_verify_marker" ] || continue
            delete_existing "$_arm_verify_marker" soft || true
        done <<< "$_arm_verify_found"
        echo "ERR arm-resume: post-arm verify -- the $RESUME_TIME target is in the PAST now that arming finished (lead=${_arm_verify_lead}s; the arm itself took $((_arm_verify_now - _ARM_START_EPOCH))s). A scheduler entry registered at or after its own fire time NEVER fires, and the past-fire guard deletes it. NOT armed -- re-arm with a later --time (or --time smart, which now pushes the target past this floor)." >&2
        exit 2
    elif [ -z "$_arm_verify_found" ]; then
        echo "ERR arm-resume: post-arm verify found NO scheduler entry for '$TASK_NAME' after a reported-successful create (the target is still ${_arm_verify_lead}s out, so it cannot have fired). Either the create silently did nothing or the past-fire guard deleted it. NOT armed -- re-arm with a later --time." >&2
        exit 2
    fi
    unset _arm_verify_found _arm_verify_marker _arm_verify_lead _arm_verify_now
fi

# A CONSUMED arm exits HERE -- before the HIMMEL-1304 force-replace reap and
# before the HIMMEL-856 arms-registry publication (r5 round). Both of those
# blocks exist to service a NEW future arm, and on this path there is none:
#   - the reap gives up the previous slot because a replacement now exists.
#     Nothing replaced anything here, so reaping would destroy a slot and leave
#     the operator with neither.
#   - the registry publishes an "armed" record for a PENDING arm. This task has
#     already fired and self-deleted, and queue-lock's HIMMEL-882 consume
#     already dropped its record when that session started -- republishing it
#     resurrects a stale PENDING row that no fire will ever clear, which is a
#     permanent rc 8 cross-host refusal for the next host to try this handover.
if [ "${_ARM_CONSUMED:-0}" -eq 1 ]; then
    cat <<EOF

================================================================
  RESUME CONSUMED — NOT armed for a future fire (HIMMEL-1879)
  Task name: $TASK_NAME   (handover: $HANDOVER_PATH)

  The $RESUME_TIME target arrived while this arm was still being
  created: the task fired and deleted its own registration inside
  the create->verify window. A relaunched claude session is
  ALREADY RUNNING (or has already run) for this handover.

  Nothing is scheduled for later. Do NOT wait for a fire — check
  for the running session first; re-arm only if there is none.
================================================================

EOF
    exit 0
fi

# HIMMEL-1304: the second half of the transactional --force replace. Everything
# that can refuse (rc 7 queue lock, rc 8 cross-host registry, rc 6 collision)
# and schedule_arm itself — including its HIMMEL-938 post-arm NextRunTime
# verify, which DELETES a task it judges misregistered and exits 2 — has now
# run. Only here is a new arm known to exist, so only here is it safe to give up
# the old one. Reached only on the --force path; ARM_REPLACE_MARKERS is empty
# otherwise (and under --dry-run, which already printed its intent and exited).
#
# _arm_marker_is_new_arm skips a marker that names the job we JUST created —
# but that in-place-overwrite assumption is only ever TRUE on windows:
#   windows — `schtasks /create /f` FORCE-overwrites a same-named task, so a
#     same-identity re-arm replaced the old row IN PLACE and there is no
#     separate old row left to reap; deleting that name deletes the new arm.
#     _arm_marker_is_new_arm's skip is scoped to this platform for exactly
#     that reason.
#   POSIX (crontab / at) never gets that in-place overwrite: _crontab_schedule
#     always APPENDS rather than replacing a same-marker line, and an at-job
#     always registers under a fresh job id — so every marker captured here,
#     on POSIX, is genuinely superseded and _arm_marker_is_new_arm always
#     reaps it. On crontab, _crontab_delete removes only the FIRST line
#     exactly matching the marker (not every occurrence), so a byte-identical
#     re-arm's freshly-appended duplicate survives even though the superseded
#     line it was captured from gets deleted.
if [ -n "${ARM_REPLACE_MARKERS:-}" ]; then
    _arm_reap_failed=0
    while IFS= read -r _rm; do
        [ -z "$_rm" ] && continue
        if _arm_marker_is_new_arm "$_rm"; then
            echo "arm-resume: superseded '$_rm' in place (same identity) — nothing to reap"
            continue
        fi
        delete_existing "$_rm" soft || _arm_reap_failed=$((_arm_reap_failed + 1))
    done <<< "$ARM_REPLACE_MARKERS"
    if [ "$_arm_reap_failed" -gt 0 ]; then
        echo "WARN arm-resume: the arm is registered, but $_arm_reap_failed superseded job(s) could not be reaped (listed above). The new arm STANDS -- prune the leftovers manually so they do not fire alongside it." >&2
    fi
    unset _arm_reap_failed _rm
fi

# Telemetry (HIMMEL-236): a successful arm IS the re-launch signal the
# measure-during protocol wants — one append, after the dry-run gate so
# --dry-run keeps its "touch nothing" contract.
# HIMMEL-1490: emit the MEASURED gap (raw seconds, the guard's canonical
# unit — _GAP_SEC, deliberately not floored to minutes: the guard compares
# >3600 directly because a //60 floor made 60m01s-60m59s read as 60). On the
# Telegram HH:MM surface --long-gap rides every explicit arm (HIMMEL-1475),
# so long_gap=1 alone can't tell a genuine >60-min park from a near arm in
# the audit; gap_sec records how far out it actually is. Default 0 for the
# smart/auto sentinel arms, which never derive _GAP_SEC (no measured park).
telemetry_emit handover-arm-resume armed "time=$RESUME_TIME" "force=$FORCE" "long_gap=$LONG_GAP" "gap_sec=${_GAP_SEC:-0}"

# HIMMEL-856: record this arm in the cross-machine arms registry, same
# dry-run gate as telemetry above. Best-effort -- a registry write failure
# must never fail an arm that already succeeded (fail-open, loud trail).
# HIMMEL-882: prune this SAME host's prior record(s) for this SAME handover
# before appending the fresh one (see _arm_registry_replace_and_append) --
# closes the re-arm/--force accumulation gap that would otherwise block a
# later cross-host arm forever, on top of the consume queue-lock.sh does at
# session start (see its own HIMMEL-882 comment).
if [ -n "${HIMMEL_856_HR_ROOT:-}" ]; then
    _arm_host=$(_arm_hostname)
    # `|| true`: an unwritable .locks (e.g. a FILE squatting on the dir
    # path) must not errexit-abort a script whose arm ALREADY succeeded --
    # the failure surfaces as the replace-and-append WARN below instead.
    mkdir -p "$HIMMEL_856_HR_ROOT/.locks" 2>/dev/null || true
    # Values are escaped with the shared _hp_json_escape (round-3) -- the
    # SAME transform every reader's needle uses, so escaped-vs-escaped
    # comparisons hold by construction.
    _hp_json_escape "$_arm_host";         _arm_rec_host="$_HP_ESC"
    _hp_json_escape "$HANDOVER_PATH";      _arm_rec_ho="$_HP_ESC"
    _hp_json_escape "$_arm_registry_key"; _arm_rec_key="$_HP_ESC"
    _hp_json_escape "${_ho_ticket:-}";   _arm_rec_ticket="$_HP_ESC"
    _hp_json_escape "$AT_STAMP";         _arm_rec_fire="$_HP_ESC"
    _hp_json_escape "$TASK_NAME";        _arm_rec_task="$_HP_ESC"
    _arm_new_record=$(printf '{"host":"%s","handover":"%s","handover-key":"%s","ticket":"%s","fire-at":"%s","task-name":"%s"}' \
        "$_arm_rec_host" "$_arm_rec_ho" "$_arm_rec_key" "$_arm_rec_ticket" "$_arm_rec_fire" "$_arm_rec_task")
    unset _arm_rec_host _arm_rec_ho _arm_rec_key _arm_rec_ticket _arm_rec_fire _arm_rec_task
    if ! _arm_registry_replace_and_append "$HIMMEL_856_HR_ROOT/.locks/arms.jsonl" "$_arm_host" "$HANDOVER_PATH" "$_arm_registry_key" "$_arm_registry_root" "$_arm_new_record"; then
        # round-4 (sfh-2): fold the first line of the captured write error
        # (if any -- empty on a mutex timeout/theft) so this WARN reads
        # differently from those cases.
        echo "WARN arm-resume: failed to append the arms.jsonl registry record (the arm itself still succeeded)${_ARM_REGISTRY_REPLACE_ERR:+ (write error: $_ARM_REGISTRY_REPLACE_ERR)}" >&2
    fi
    unset _arm_new_record
    # Post-append re-read (HIMMEL-856 CR, codex-1 -- see the LAYERED
    # DEFENSE comment at the pre-arm check): the check-then-append pair
    # above cannot be atomic across machines, so AFTER recording our own
    # arm, re-scan the registry. If another host's arm for this same
    # handover is now visible (it landed in the check->append window, or
    # was let through with ARM_DUP_OK=1), tell the operator LOUDLY which
    # hosts double-armed. No non-zero exit -- the arm already happened;
    # the queue lock at session start is the layer that serializes the
    # actual double-fire.
    _arm_post_hits=$(_arm_registry_foreign_hits "$HIMMEL_856_HR_ROOT/.locks/arms.jsonl" "$HANDOVER_PATH" "$_arm_registry_key" "$_arm_registry_root" "$_arm_host")
    if [ -n "$_arm_post_hits" ]; then
        {
            echo "=================================================================="
            echo "  WARN arm-resume: DOUBLE-ARM DETECTED (HIMMEL-856)"
            echo "  This handover now has PENDING arms on MULTIPLE hosts:"
            echo "      this host:  $_arm_host"
            echo "      also armed: $_arm_post_hits"
            echo "  Cancel one of them (schtasks /delete on the losing host, or"
            echo "  its cron/at equivalent) -- otherwise both will fire and"
            echo "  serialize only at the queue lock, wasting a session slot."
            echo "=================================================================="
        } >&2
    fi
    unset _arm_host _arm_post_hits _arm_registry_key _arm_registry_root
fi

# The headline is the ticket's whole claim, so it states exactly what was
# established: plain RESUME ARMED only after the entry was queried back and
# confirmed to fire in the future; the UNVERIFIED spelling when a probe could
# not run and the arm was let stand on the fail-open (HIMMEL-938). Same rc
# either way -- this is a truthfulness fix, not a new refusal.
if [ "${_ARM_UNVERIFIED:-0}" -eq 1 ]; then
    _arm_headline="RESUME ARMED (UNVERIFIED — scheduler query failed) for $RESUME_TIME on $START_DATE (handover: $HANDOVER_PATH)"
else
    _arm_headline="RESUME ARMED for $RESUME_TIME on $START_DATE (handover: $HANDOVER_PATH)"
fi
cat <<EOF

================================================================
  $_arm_headline
  Task name: $TASK_NAME
  Model: $MODEL_REASON

  PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW.

  The cron/schtasks relaunch will spawn a NEW claude process at the
  scheduled time. If this session is still running then, you'll
  have two concurrent claude processes operating on the same
  handover state (file races, doubled API spend, possible
  double-pushes from auto-commit).

  Closing also gives the next session a clean prompt cache and a
  fresh handover-context read.
================================================================

EOF
exit 0
