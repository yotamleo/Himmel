#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell/mcp__* — GLM-lane external-write deny.
#
# WHY (HIMMEL-654 session-9 tail, operator decision #1 — "harden BEFORE
# scaling the offload"): GLM workers (scripts/telegram/spawn-glm.ts) and
# claude-glm sessions run claude against api.z.ai, usually with
# --permission-mode bypassPermissions. Third-party lanes have NO auto-mode
# classifier and bypassPermissions removes the prompt layer. The lanes used to
# also poison the worktree pushurl, but that was never a wall and it mutated
# the operator's shared git config to boot, so HIMMEL-1961 removed it: this
# hook plus the parent CR gate are now the whole story. It is the
# deterministic classifier SUBSTITUTE: on the GLM lane, hard-block
# push / PR / external-write shapes.
#
# Lane detection: ANTHROPIC_BASE_URL contains api.z.ai (set by
# scripts/telegram/glm-env.ts buildGlmEnv and the scripts/claude-glm{,.ps1}
# launcher family; inherited by hook processes). Non-GLM sessions exit 0 on
# the first case below — near-zero overhead, before the jq availability check.
#
# Blocked on-lane:
#   - ALL mcp__* tools EXCEPT the qmd KB carve-out (v1 chores are repo-local;
#     blanket beats a verb list; qmd KB reads are operator-allowed, COLLECTION-
#     SCOPED to "himmel" only — see below)
#   - git push; git remote set-url; git config …url (tripwire un-poisoning)
#   - the gh CLI EXCEPT the carve-out below — pr create/merge/edit/review/
#     comment/ready, api, repo, release, gist, … stay blocked (parent-session
#     actions)
#   - network CLIs: curl/wget/Invoke-WebRequest/Invoke-RestMethod/iwr/irm
#     (write-flag parsing is fragile post-lowercasing; chores are repo-local;
#     bun/npm installs remain allowed — dependency fetch, not external write)
#
# Allowed on-lane (operator policy 2026-07-03 — audited-action carve-out):
#   - the Jira CLI (scripts/jira/ path, or bare `jira`): writes are audited in
#     Jira history + recoverable, so GLM workers may update status/comments and
#     file followup tickets. Atlassian MCP stays blocked (mcp__* below) — Jira
#     routing is CLI-first (block-backend-tier enforces that in every session).
#   - the qmd KB (mcp__plugin_qmd_qmd__* tools): read-only knowledge-base
#     access, COLLECTION-SCOPED (HIMMEL-1239). qmd indexes salus (a PHI medical
#     vault) alongside himmel/luna/luna-curated with NO built-in isolation, so
#     a blanket allow would let the GLM lane egress PHI to api.z.ai via the qmd
#     MCP path even though egress-matrix.json hard-denies salus by file path.
#     v1 allow-list = {himmel} ONLY (widening it, e.g. adding luna-curated, is
#     a SEPARATE named operator decision):
#       - `query`: allowed only when tool_input.collections is a non-empty
#         array whose every entry is "himmel" — an absent/empty collections
#         filter falls back to the store's default collections (unknown from
#         the tool-call JSON, may include salus) and is denied as unscoped.
#       - `get` / `multi_get`: allowed only when every file/pattern segment is
#         a fully-qualified `qmd://himmel/...` virtual path. qmd's resolver
#         falls back to matching a bare/relative filename or a #docid against
#         EVERY collection in turn, so anything short of the qmd://<collection>
#         scheme cannot be positively attributed to one collection and is
#         denied fail-closed.
#       - `status` (and any other/future qmd tool): has no collection-scoping
#         input at all, so it is denied fail-closed too.
#   - gh issue <anything> (full issue surface — reads AND writes; cr-deferred
#     followups are gh issues, audited in GitHub + recoverable), plus read-only
#     PR/CI context: `gh pr view|diff|checks|status|list`, `gh run
#     view|list|watch`. Every other gh use stays blocked (counting arm below).
#
# Known limitations (accidental-shape guard, like block-read-secrets):
#   - any wrapper displacing the command from command position is missed:
#     env-prefixed `FOO=1 git push`, sudo/xargs/timeout wrappers, `git-push`,
#     and the `=`-joined global-flag form `git --git-dir=/x push` (missed too)
#   - in-process network is invisible to a command-text hook — bun/node
#     fetch, including bun-invoking the telegram bridge send path
#   - malformed/empty tool JSON -> allow (parity with sibling hooks; Claude
#     Code emits valid JSON)
#   - the gh carve-out counts command-position gh occurrences (total vs
#     allowed) and shares the wrapper gap above — a wrapper-displaced gh is
#     invisible to BOTH counts, so it is neither blocked nor credited as allowed
#   Accepted OVER-blocks (fail-closed direction, all test-pinned):
#   - newlines flatten to ';', so quoted prose whose LINE starts with a
#     blocked verb ("…\ngit push later") blocks; mid-line prose stays allowed
#   - an allowed `gh issue …` whose quoted body contains `;`/`|` followed by
#     another gh token ("--body 'step 1; gh pr merge later'") blocks (the
#     body token inflates the total count)
#   - global flags BEFORE a gh subcommand displace it from the allow anchor:
#     `gh -R o/r issue list` blocks; write flags AFTER the subcommand
#     (`gh issue list -R o/r`) — allowed
#   Backstopped by the parent CR gate, which is the load-bearing control;
#   this hook is the in-session deterministic layer. (The pushurl tripwire
#   that used to sit alongside them is gone — HIMMEL-1961.)
#
# Exit codes: 0 allow; 2 block (stderr shown to the worker).
# Bypass: GLM_EXTERNAL_WRITES_OK=1 in the env of the shell that spawns the
# worker (spawn-glm caller / claude-glm launcher). Session-sticky.
#
# BYPASS SCOPE — where the trust boundary actually is (HIMMEL-1649 round 4,
# [codex-1]). "No on-disk content ever executes" is an ENFORCEMENT-mode
# property, not a global one. Under GLM_EXTERNAL_WRITES_OK the near-miss denies
# are skipped, so a MALFORMED helper command reaches the on-disk helper and runs
# it. That is the designed contract, not a gap: bypass mode IS the no-hook
# environment scripts/glm/append-outbox.sh exists for, and round 3 made that
# helper the LOCKSTEP implementation of the same fail-closed schema enforced
# here — so a malformed payload appends NOTHING in either mode. Only the
# executor differs: the hook on-lane, the lockstep helper under operator bypass.
# Hoisting the near-miss deny above the bypass exit would block operator
# debugging in a mode the operator explicitly opted into, in order to guard
# against a worker who under bypass can already do strictly more.
#
# WHAT THIS HOOK IS AND IS NOT A TRUST ROOT FOR (HIMMEL-1649 round 5,
# [codex-adv-1] — scoping a claim rounds 3/4 stated too broadly). The honest
# invariant is narrow:
#   - Under ENFORCEMENT the report verb is executed BY THIS HOOK, never by
#     on-disk helper content. That part holds.
#   - This hook's ABSENCE now fails closed IN A DISPATCHED WORKER: it is
#     registered --fail-closed-when HIMMEL_GLM_WORKER=1, a marker minted only by
#     buildGlmEnv (the orchestrator path), so DELETING it there no longer
#     silently exits 0. The marker is WORKER-NESS, not the provider: an
#     interactive GLM session legitimately has no himmel scripts/ tree, so a
#     missing hook is NORMAL there and keeps ordinary optional semantics.
#   - It is NOT proof against a worker REWRITING project-owned hook code. The
#     worker's own envelope reaches this file: the plugin registers the hook at
#     $CLAUDE_PROJECT_DIR/scripts/hooks/, which in a worker session is the
#     worker's worktree, and composeWorkerSettings grants Edit(<worktree>/**)
#     plus Bash(node *)/Bash(bash *). A worker that replaces this file with
#     `exit 0` neuters the guard for every later tool call.
# Closing THAT is an architecture change, not a hook edit — run the guard from
# a dispatcher-owned path outside worker Edit roots, or hash-verify it at
# invocation against a dispatcher-recorded digest. Tracked in HIMMEL-1666.
# Do not restate the broad "nothing worker-reachable can affect this guard"
# claim anywhere; it was never true of the hook file itself.
#
# HIMMEL-2085 GENERALIZATION — worker-ness, not lane. record-hook-integrity.sh's
# HIMMEL-1666 pin file lives in an ordinary user-writable directory
# ($HIMMEL_HOOK_INTEGRITY_DIR, default ~/.claude/himmel/hook-integrity) —
# outside every worker's Edit(<worktree>) grant, but NOT outside its
# Bash(node *)/Bash(bash *) reach. `bash -c 'echo ... > .../hook-
# integrity/$SESSION_ID.json'` forges a pin to match a tampered guard, and
# nothing in this file used to stop that for a NATIVE (Sonnet/Opus) dispatched
# worker — only the GLM lane reached this file at all. The new pin-dir
# write-fence class below is keyed on a general "worker-ness" marker,
# HIMMEL_WORKER=1, of which the GLM-specific HIMMEL_GLM_WORKER=1 (used only by
# the --fail-closed-when wiring above) is now one instance: it is set by BOTH
# buildGlmEnv (scripts/telegram/glm-env.ts) and claudexChildEnv
# (scripts/telegram/spawn-claudex.ts) — the two lane-specific child-env
# builders every worker dispatch already funnels through — so a future third
# lane inherits this fence by setting the same var, not by editing this file.
# A headed operator session sets neither marker and still hits the near-
# zero-overhead early exit below, unchanged.
#
# Everything ELSE in this file (the outbox-report interceptor, the mcp/push/
# gh/network classifiers) stays GLM-lane-scoped exactly as it was — this adds
# ONE new class, gated on worker-ness broadly; it does not widen the rest of
# the GLM enforcement onto the native lane, which is out of this ticket's scope.
#
# HONEST RESIDUAL (kept from record-hook-integrity.sh's own note, HIMMEL-2085):
# this new class is a command-TEXT fence, same shape as every other class in
# this file — it denies a Bash/PowerShell command whose text contains the pin
# directory as a (slash/case-normalized) literal substring. It is NOT a
# filesystem permission boundary: an OS-user-level attacker (chmod the pin
# file writable first, a second process, a language runtime that builds the
# path from characters/bytes never spelled out as that substring) is OUT OF
# SCOPE — identical residual to every other command-text hook here. Bypass:
# HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1, shared with run-hook-with-bash.js's own
# mid-session-hook-edit escape hatch (the same legitimate operator situation).
set -euo pipefail

case "${ANTHROPIC_BASE_URL:-}" in
    *api.z.ai*) glm_lane=1 ;;
    *) glm_lane=0 ;;
esac
# glm_lane is the ORIGINAL GLM-specific signal (unchanged everywhere below).
# worker_lane is glm_lane OR the lane-agnostic HIMMEL_WORKER marker any
# dispatched worker's child env now carries (see the HIMMEL-2085 note above).
# A non-worker (headed operator) session sets neither and exits here — same
# near-zero overhead as before this change.
worker_lane=$glm_lane
[ "${HIMMEL_WORKER:-0}" = "1" ] && worker_lane=1
[ "$worker_lane" = 1 ] || exit 0

# HIMMEL-1649 round 3 — the bypass is recorded as a FLAG, not an early exit.
# The report interceptor below is a SERVICE (the hook performs the outbox
# append); the push/gh/network classifiers are ENFORCEMENT.
# GLM_EXTERNAL_WRITES_OK disables ENFORCEMENT, never the SERVICE. Exiting here
# used to disable both, so a bypass session executed the on-disk helper — which
# only ever writes {text} — and silently downgraded every structured escalation
# to a text note that `adjudicate list` cannot see. The interceptor therefore
# runs first, and the bypass exit sits between it and the classifiers.
glm_bypass=0
[ "${GLM_EXTERNAL_WRITES_OK:-0}" = "1" ] && glm_bypass=1

# On-lane, a TOP-LEVEL errexit abort must BLOCK (exit 2), never slip through
# as a non-blocking exit 1 (only exit 2 denies in Claude Code). Scope honesty:
# the trap cannot see failures inside `if ... grep -q ...` condition contexts
# (errexit-exempt; a grep crashing on a fixed pattern is the only such shape —
# ~impossible in practice), and the malformed-JSON path deliberately stays
# fail-OPEN above per sibling-hook parity — this clamp covers everything else.
# shellcheck disable=SC2154  # rc is assigned by rc=$? inside the same trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if ! command -v jq >/dev/null 2>&1; then
    # Without jq the tool call cannot be parsed at all, so there is neither a
    # report to service nor a command to classify. A bypass session keeps its
    # historical escape hatch (this check used to sit BELOW the bypass exit);
    # a normal on-lane session still fails closed.
    [ "$glm_bypass" = 1 ] && exit 0
    # HIMMEL-2085 CR history, both directions tried and rejected in favor of
    # this one (round 2 [codex-3] Important vs round 3 [codex-1] Critical,
    # in direct tension -- security wins): round 2 fail-OPENED here for a
    # native-only worker_lane on the theory that jq-missing denying every
    # Bash/PowerShell/mcp__* call for that lane (not just pin-dir-relevant
    # ones) was wider than the single-class scope. Round 3 correctly called
    # that a REOPENING of the exact pin-forging attack this ticket exists to
    # close: with jq absent the pin-dir class cannot evaluate ANY command, so
    # fail-open there means a worker on any jq-less host (or an operator
    # environment that simply lacks jq) gets an entirely inert fence with no
    # warning. Failing closed for jq-missing regardless of lane is also the
    # ALREADY-established posture one layer up: record-hook-integrity.sh
    # itself `exit 0`s with no pin file when jq is absent, so an environment
    # missing jq already has NO hook-integrity protection at all -- being
    # MORE cautious here, not less, is the consistent direction. The
    # documented scope note in the header still holds for every OTHER case
    # (jq present, tool_is_shell=0): this is deliberately the one exception,
    # confined to total evaluation failure.
    echo "block-glm-external-writes: jq not on PATH — refusing to evaluate on a dispatched-worker lane; install jq" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

# HIMMEL-1649 round 9 (CodeRabbit, Major): the SHELL tools this hook mediates
# are Bash AND PowerShell — hooks.json registers the matcher as
# "Bash|PowerShell|mcp__.*", and both carry their command text in
# .tool_input.command. Gating the report interceptor and the near-miss deny on
# Bash ALONE left a PowerShell helper invocation neither hook-executed nor
# denied: it fell through to the generic classifiers, which do not match
# append-outbox.sh, and so executed the on-disk helper IN ENFORCEMENT MODE.
# That contradicts this branch's own charter ("under enforcement the report
# verb is executed by the hook, never by on-disk content"), so it is fixed
# rather than deferred. Severity was bounded — the push/gh/network classifiers
# already covered PowerShell, and the fall-through ran the dispatcher-minted
# LOCKSTEP helper that fail-closes the same payloads, i.e. it degraded to the
# sanctioned GLM_EXTERNAL_WRITES_OK posture — but bounded is not correct.
# One predicate, used by BOTH guards, so they can never drift apart again.
tool_is_shell=0
case "$tool" in Bash|PowerShell) tool_is_shell=1 ;; esac

# ---------------------------------------------------------- HIMMEL-2085 class
# Hook-integrity pin-dir write-fence. The ONLY class in this file that runs for
# any worker_lane (GLM or a native lane carrying HIMMEL_WORKER=1) rather than
# glm_lane specifically — see the header's HIMMEL-2085 GENERALIZATION note for
# why, and for the command-text-fence residual this accepts.
if [ "$tool_is_shell" = 1 ] && [ "${HIMMEL_HOOK_INTEGRITY_BYPASS_OK:-0}" != "1" ]; then
    pin_cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    if [ -n "$pin_cmd" ]; then
        pin_dir_raw="${HIMMEL_HOOK_INTEGRITY_DIR:-$HOME/.claude/himmel/hook-integrity}"
        # Slash+case+drive-spelling normalized SUBSTRING match, not an anchored
        # path parse: a false ALLOW here is the wrong failure direction.
        # Over-blocking a command that merely mentions the path in passing is
        # the accepted tradeoff — matches this file's existing over-block
        # posture elsewhere. Octal \134 (not a literal '\\') matches
        # path_norm()'s own spelling below — both exist to dodge the SC1003
        # false-positive shellcheck raises on a quoted single backslash.
        # Round-2 critic-panel finding [codex-1]: /c/foo and C:/foo are the SAME
        # path but do not share a substring, so a plain lower+slash normalize
        # alone still misses a Windows-drive-letter spelling of a CUSTOM
        # HIMMEL_HOOK_INTEGRITY_DIR (the default's fixed suffix check below
        # covers the default case regardless of drive-letter spelling, but a
        # custom dir has no such fixed suffix to lean on). Canonicalize EVERY
        # "<letter>:/" drive spelling (preceded by start-of-string or a
        # non-alnum char, so a value like "notdrive:/x" is still caught —
        # over-matching, the accepted direction) to the POSIX "/<letter>/"
        # form on BOTH sides before comparing, so either spelling of the same
        # path compares equal regardless of which one the operator configured
        # or the worker typed.
        drive_to_posix() {
            printf '%s' "$1" | sed -E 's#([^a-z0-9]|^)([a-z]):/#\1/\2/#g'
        }
        pin_dir_norm=$(printf '%s' "$pin_dir_raw" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')
        pin_dir_norm=${pin_dir_norm%/}
        pin_dir_norm=$(drive_to_posix "$pin_dir_norm")
        cmd_norm=$(printf '%s' "$pin_cmd" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')
        cmd_norm=$(drive_to_posix "$cmd_norm")
        # Critic-panel finding [codex-1] (round 1): matching only the RESOLVED
        # absolute path misses the shell EXPANDING an unexpanded variable
        # reference at execution time -- `echo x > "$HIMMEL_HOOK_INTEGRITY_DIR/f"`
        # or (on the default) `echo x > "$HOME/.claude/himmel/hook-integrity/f"`
        # never contains the resolved path as literal command TEXT, so the
        # substring check above alone would miss it while the shell still
        # writes there. Also deny: the env-var name itself, spelled either way
        # ($X, ${X}) -- covers a custom HIMMEL_HOOK_INTEGRITY_DIR too, since
        # the var reference is denied regardless of what it resolves to -- AND
        # PowerShell's `$env:X`/`${env:X}` scope-qualified spelling of the
        # SAME variable (critic-panel finding [codex-2], round 2: the earlier
        # pattern only matched bash-style `$X`/`${X}`) -- and the fixed
        # default-path suffix (himmel/hook-integrity), which catches
        # $HOME/${HOME}/~ expansion on the default without needing to detect
        # every HOME spelling individually. Still a command-TEXT fence (see
        # the header residual): a value built by concatenating separately-
        # obfuscated pieces evades all three checks the same way it would evade
        # any command-text hook in this file.
        # known-findings [grep-q-pipe-under-pipefail]: use a here-string, not a
        # `producer | grep -q` pipe -- under `set -euo pipefail` grep's early
        # exit on a match can SIGPIPE the producer and flip a real match into a
        # pipeline failure. $1 is a bounded command/path string, well under the
        # 64KiB here-string limit (HIMMEL-2027).
        pin_text_hit() {
            grep -qF "$pin_dir_norm" <<< "$1" ||
            grep -qE '\$\{?(env:)?himmel_hook_integrity_dir\}?' <<< "$1" ||
            grep -qF 'himmel/hook-integrity' <<< "$1"
        }
        pin_hit=0
        [ -n "$pin_dir_norm" ] && pin_text_hit "$cmd_norm" && pin_hit=1
        # Round-4 critic-panel finding [codex-1]: the checks above scan only
        # the OUTER command text, so `bash script.sh` (script.sh containing
        # the forge payload) passed every check while the SCRIPT still forged
        # the pin -- moving the payload into a file a worker already has Edit
        # access to and running it is the single most natural way to defeat a
        # command-text hook, not an exotic evasion. Extract every
        # bash/sh/./source/node <path> invocation at command position, resolve
        # it against the tool's cwd, and scan the FILE'S CONTENT with the SAME
        # three checks.
        #
        # Round-5 panel findings [codex-1]/[codex-2] first widened the round-4
        # extraction to cover `./forge.sh` (direct exec), `bash -x forge.sh`
        # (a dash-option before the path), `bash "forge.sh"` (a quoted path),
        # and `node forge.js` (Bash(node *), an explicitly documented
        # dispatched-worker grant alongside Bash(bash *)) via a second
        # grep -oE plus a $NF/sed cleanup pass.
        #
        # Round-5 re-review (fresh panel pass against that fix) then found the
        # patched-regex approach was STILL leaking on shapes outside what the
        # first patch happened to cover: [codex-2] `bash "my forge.sh"` (a
        # quoted path containing a space) truncated to the FIRST
        # whitespace-delimited token (`"my`), which then fails the file check
        # and skips scanning -- `awk '{print $NF}'` cannot recover a path with
        # an internal space it never kept together as one field.
        # [codex-3] `/bin/bash forge.sh` (an absolute/path-qualified
        # interpreter) matched the direct-exec alternative on `/bin/bash`
        # itself (it starts with `/`) instead of recognizing bash-by-basename
        # and extracting the REAL script argument, `forge.sh`, which was never
        # scanned. (A third finding, `[codex-1]`, claimed a bare newline
        # between commands wasn't a recognized boundary -- verified false:
        # grep -oE re-anchors `^` per LINE by default, so a newline already
        # behaves as a boundary; no fix needed there.)
        #
        # Two rounds of regex patches for two rounds of shell-quoting edge
        # cases is the whack-a-mole shape this class of hook always degrades
        # into. Root-caused instead with a small quote-aware tokenizer: split
        # on `;`/`&`/`|` (a newline is already a boundary -- each awk INPUT
        # RECORD is one line), tokenize each segment respecting single/double
        # quotes so a quoted path keeps its internal spaces as ONE token,
        # recognize an interpreter by its BASENAME (covers a bare `bash` and
        # an absolute/path-qualified `/bin/bash` alike), skip dash-prefixed
        # options, and take the next token as the script -- or, when the first
        # token isn't a recognized interpreter, treat it as a direct-exec
        # target when it starts with `./`, `../`, `/`, or a drive letter.
        #
        # Round-5 re-review pass #2 (fresh panel run against the tokenizer
        # above) found one more genuine gap and one already-accepted residual
        # restated:
        #   [codex-2, FIXED]: `cd subdir && bash forge.sh` resolved forge.sh
        #   against the INITIAL tool cwd (never tracking the `cd`), so the
        #   scan missed the file the script actually executes from after the
        #   directory change. The awk tokenizer already walks every `;`/`&`/`|`
        #   segment in order, so it tracks a `cd <target>` segment as a cwd
        #   update and resolves every later script path against the RUNNING
        #   cwd instead of the caller's static `tool_cwd` -- awk now emits a
        #   pre-joined path per script (still passed through the same case
        #   statement below, which is then a no-op since the path is already
        #   absolute).
        #   [codex-1, NOT a new gap]: `X=1 bash forge.sh` / `env bash
        #   forge.sh` / `command bash forge.sh` displace the interpreter word
        #   from token position 1 the same way `sudo`/`xargs`/`timeout`
        #   wrappers already do -- this is the file's own header's
        #   already-documented, file-wide "any wrapper displacing the command
        #   from command position is missed" limitation (top of this file),
        #   restated for the pin-dir class rather than a new one. It is also
        #   exactly the "further wrapper layer" this section's own residual
        #   note has accepted since round 4. Not chased further: a
        #   command-TEXT fence cannot distinguish a wrapper from a whole new
        #   class of legitimate multi-token commands without becoming a real
        #   shell parser -- backstopped by the parent CR gate per the header.
        #
        # HIMMEL-2200 (three round-5 re-review residuals, root-caused rather
        # than patched again -- same lesson as the round-5 rewrite above):
        #   [codex-1]: segment splitting on `;`/`&`/`|` used to run BEFORE
        #   quote-aware tokenization (`split($0, segs, /[;&|]/)` first, quote
        #   scanning per segment second), so a `;` inside a QUOTED path
        #   (`bash "./forge;payload.sh"`) split the command mid-token and the
        #   scanner never saw the filename whole. Fixed by collapsing the two
        #   passes into ONE character scanner that tracks quote state and only
        #   treats `;`/`&`/`|` as a segment boundary when NOT inside quotes --
        #   segment splitting is now downstream of quote-awareness, not ahead
        #   of it.
        #   [codex-2]: no backslash-escape handling, so `bash ./my\ forge.sh`
        #   (a legitimate unquoted-space escape) truncated to `./my` at the
        #   first unescaped-looking space. The same scanner now tracks an
        #   escape flag: outside quotes and inside double quotes, a backslash
        #   consumes the next character literally (including a space, which
        #   no longer ends the token) instead of acting as a token separator;
        #   inside single quotes a backslash stays literal, matching real
        #   shell semantics.
        #   [codex-3]: the round-5 cd-tracking advanced the modeled cwd
        #   unconditionally, so `cd /nonexistent; bash forge.sh` scanned
        #   forge.sh against a cwd the real shell never reached (a failed cd
        #   leaves the shell in its ORIGINAL directory).
        #
        # HIMMEL-2200 pr-check panel re-review [codex-1]: the escape handling
        # above was itself too broad in two ways. First, it fired
        # unconditionally even when the mediated tool is PowerShell (this
        # hook's matcher covers Bash AND PowerShell alike, tool_is_shell
        # above), where backslash is an ordinary literal character, not an
        # escape -- so a native Windows path like `C:\dir\forge.sh` passed via
        # PowerShell had its separators silently stripped, missing the real
        # script. Second, even for Bash, treating every backslash inside
        # double quotes as an escape is broader than real bash's own rule
        # (only `\$`, `` \` ``, `\"`, `\\` are special inside double quotes --
        # a backslash before any other character, e.g. the `d` in `"C:\dir"`,
        # stays LITERAL, both characters kept). Fixed with a `pwsh` flag
        # (derived from `$tool`, passed into awk via `-v`) that disables all
        # backslash-escape handling for a PowerShell command, plus a one-token
        # lookahead inside double quotes that only escapes the four real bash
        # metacharacters and leaves every other backslash as a literal
        # character in the token.
        #
        # HIMMEL-2200 pr-check panel re-review round 2 [codex-1], round 3
        # [codex-1] -- the [codex-3] fix above was itself iterated twice more
        # and finally ROOT-CAUSED rather than patched a third time. Round 2's
        # first attempt probed the candidate directory with `test -d` (awk
        # system()) and only committed the cwd update when it existed on
        # disk. Round 3 found that probe still wrong in the OTHER direction,
        # with a concrete repro: `rmdir real; cd real; bash forge.sh` -- at
        # HOOK-SCAN time (before any segment has executed) `real` genuinely
        # exists, so the probe says "cd succeeds" and the model follows it,
        # but the real shell's `rmdir` removes `real` FIRST, so the real `cd`
        # then FAILS and the shell stays in the ORIGINAL directory -- exactly
        # where the real `forge.sh` sits, unscanned. No `test -d` probe run at
        # scan time, before ANY segment has executed, can resolve whether a
        # cd will succeed once earlier segments in the SAME command have run.
        # Root-caused by giving up on prediction entirely: `cd` now FORKS the
        # modeled cwd into a small SET of candidates -- every existing
        # candidate survives unchanged (models "the cd fails, shell stays
        # put") AND gains a second candidate advanced to the joined target
        # (models "the cd succeeds") -- so whichever branch the real shell
        # actually takes after however many segments actually ran, one
        # tracked candidate matches it. Every later script reference resolves
        # against ALL current candidates, so a real script is caught
        # regardless of which fork corresponds to reality. This needs no
        # filesystem probing at all (the `test -d`/`system()` call is gone),
        # closes both directions (a target that never exists, from the
        # original [codex-3]; a target that exists now but won't by cd-time,
        # or vice versa, from rounds 2 and 3), and stays a bounded
        # enumeration of a small, statically-known branch count -- not a
        # general shell parser.
        #
        # HIMMEL-2214 -- SUBSUMED by the fork model above, no code change.
        # The ticket names `&&`/`||` short-circuit truthiness: the tokenizer
        # segments on a bare `;`/`&`/`|` and so models `false && cd /existing`
        # as if the cd ran, while a real shell short-circuits and stays put.
        # That was a real fail-OPEN against the round-5 model, which advanced
        # a SINGLE modeled cwd unconditionally -- advancing into /existing
        # meant the original cwd, where the real forge.sh sits, was never
        # scanned. The round-4 redesign that landed in HIMMEL-2200 closes it
        # as a side effect of its own shape: a cd never REPLACES a candidate,
        # it FORKS, and "this cd did not happen" is exactly the preserved
        # unchanged candidate. A cd skipped by short-circuit is
        # indistinguishable, to this model, from a cd that ran and failed --
        # and both are already tracked. Evaluating truthiness would only let
        # the model DROP candidates, which is the one direction a fail-closed
        # fence must never move. Pinned by a regression case in the scoped
        # suite; see that case for the both-direction proof against the
        # pre-HIMMEL-2200 tokenizer.
        #
        # HIMMEL-2218 [codex-1] (cd-existence TOCTOU) -- MOOT, no code change.
        # It describes a scan-time `test -d` probe going stale before the real
        # cd runs. That probe was round 2's attempt and the round-4 redesign
        # DELETED it (no system() call remains); the fork model needs no
        # filesystem prediction at all, so there is no probe left to be stale.
        # HIMMEL-2218 [codex-2] (PowerShell backtick escapes) and [codex-3]
        # (backslash-newline line continuation) were genuine fail-opens and
        # ARE fixed, in scan_line() and the main-block join respectively.
        #
        # PowerShell script-file indirection (dot-sourcing, the `&` call
        # operator, `-File`), an env/wrapper-displaced interpreter (above), a
        # script that computes its own forge target at runtime, `cd -`/`pushd`/
        # `popd`/a subshell `cd`, a trailing escape character inside a
        # single-quoted string joined as a line continuation (see the main
        # block), PowerShell's `""` doubled DOUBLE-quote (the twin of the
        # `''` case fixed in scan_line(); left unmodeled because the token it
        # would produce necessarily contains a `"`, which is not a legal
        # filename character on NTFS, so no reachable script path exists to
        # scan and no fixture can exercise it), or a bare relative filename
        # with no `./` (not directly executable without `.` on PATH) remain
        # the accepted command-text-fence residual documented above and in
        # the header.
        if [ "$pin_hit" = 0 ] && [ -n "$pin_dir_norm" ]; then
            tool_cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
            [ -z "$tool_cwd" ] && tool_cwd="$PWD"
            while IFS= read -r script_path; do
                [ -z "$script_path" ] && continue
                case "$script_path" in
                    /*|[A-Za-z]:*) resolved="$script_path" ;;
                    *) resolved="$tool_cwd/$script_path" ;;
                esac
                if [ ! -f "$resolved" ] || [ ! -r "$resolved" ]; then continue; fi
                script_norm=$(tr '\134' '/' < "$resolved" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
                script_norm=$(drive_to_posix "$script_norm")
                if pin_text_hit "$script_norm"; then
                    pin_hit=1
                    break
                fi
            done <<PINSCRIPTS
$(pwsh_flag=0; [ "$tool" = "PowerShell" ] && pwsh_flag=1
printf '%s' "$pin_cmd" | awk -v initcwd="$tool_cwd" -v pwsh="$pwsh_flag" '
# NOTE for future editors: everything from here to the closing quote is ONE
# single-quoted shell string, so an apostrophe anywhere inside it -- in a
# comment included -- ends that string early and the hook then fails at
# RUNTIME. bash -n does not catch it. Keep this program apostrophe-free.
#
# ESC is the DIALECT escape character: backslash for bash, backtick for
# PowerShell (HIMMEL-2218 [codex-2]). One variable drives both the
# in-token escape handling in scan_line() and the line-continuation join in
# the main block, so the two dialects share one mechanism instead of two
# parallel patches.
BEGIN { SQ = sprintf("%c", 39); NUL = sprintf("%c", 0); ESC = pwsh ? "`" : "\\"; cwd_cand[1] = initcwd; ncand = 1; MAXCAND = 32 }
function is_abs(p) {
    if (p ~ /^\//) return 1
    if (p ~ /^[A-Za-z]:[\/\\]/) return 1
    return 0
}
function join(base, rel) {
    if (is_abs(rel)) return rel
    if (base == "") return rel
    return base "/" rel
}
function is_interpreter(tok,    base, n, parts) {
    if (tok == "." || tok == "source") return 1
    n = split(tok, parts, /[\/\\]/)
    base = parts[n]
    if (base == "bash" || base == "sh" || base == "node") return 1
    return 0
}
function is_direct_exec_prefix(tok) {
    if (tok ~ /^\.\.?\//) return 1
    if (tok ~ /^\//) return 1
    if (tok ~ /^[A-Za-z]:[\/\\]/) return 1
    return 0
}
# A resolved path holding a NUL cannot name a file on ANY platform, so there
# is nothing on disk for the pin scan to read and the real command reaches no
# file either -- skip emitting it rather than emitting a lookalike. This is not
# a bypass: a worker who puts `0 in a path has written a command that executes
# nothing. It has to be filtered before PRINTING, because the bash reader below
# cannot carry a NUL in a shell variable -- `read` silently DROPS it, which
# would splice for<NUL>ge.sh back into the genuinely existing forge.sh and deny
# a command PowerShell never pointed there. Caught by the escape-grammar
# enumeration in the scoped suite.
#
# Round-4 [codex-2]: the check must sit on the EMITTED path, not on tok[]. A
# NUL can also arrive through the modeled cwd -- `cd path`0suffix` puts one in
# a candidate directory -- and a token-only test let that through to the same
# silent repair. Filtering where the value is finally produced covers both
# inputs at once, which is why the two per-input tests were replaced rather
# than added to.
function has_nul(str) { return index(str, NUL) > 0 }
function run_segment(   j, i, target, seen, n2, cand) {
    if (ntok == 0) return
    if (tok[1] == "cd" && ntok >= 2 && substr(tok[2], 1, 1) != "-") {
        # A real cd success depends on filesystem state neither this hook
        # nor the eventual real shell has resolved yet at scan time, and an
        # earlier segment in the SAME command may create or remove the target
        # before the real cd runs -- see the HIMMEL-2200 pr-check panel note
        # above this awk block for the two concrete exploit shapes. Rather
        # than guess, FORK: every candidate cwd survives unchanged (the cd
        # fails, the shell stays put) AND gains a second candidate advanced
        # to the joined target (the cd succeeds) -- so whichever branch the
        # real shell actually takes, one of our tracked candidates matches
        # it. De-duped via `seen` so a repeated/no-op cd does not grow the set.
        #
        # cwd_cand[1] is a PROTECTED invariant: it is always built by
        # advancing cwd_cand[1] from the PRIOR round, so it recursively
        # tracks "every cd so far succeeded" -- the single most realistic
        # real-shell outcome. Placing it first and truncating only from the
        # tail (below) guarantees this chain can never be evicted by the cap,
        # however many distinct cd targets a command chains -- see round 5
        # [codex-1] just below for why that guarantee matters.
        n2 = 0
        delete seen
        target = join(cwd_cand[1], tok[2])
        seen[target] = 1
        new_cand[++n2] = target
        # HIMMEL-2225: the two branches per candidate are emitted INTERLEAVED
        # (unchanged, then advanced, per candidate) rather than as an
        # unchanged block followed by an advanced block. See the round-6
        # [codex-1] note below the cap for why the block layout was a real
        # gap. This is a pure REORDER -- the de-duped SET is identical, only
        # the truncation order changes.
        for (i = 1; i <= ncand; i++) {
            if (!(cwd_cand[i] in seen)) { seen[cwd_cand[i]] = 1; new_cand[++n2] = cwd_cand[i] }
            if (i == 1) continue
            target = join(cwd_cand[i], tok[2])
            if (!(target in seen)) { seen[target] = 1; new_cand[++n2] = target }
        }
        # ponytail: de-duped fork growth is bounded by distinct paths, not by
        # cd COUNT, but a command with dozens of DISTINCT cd targets could
        # still grow large. Cap at MAXCAND (a dispatched-worker command with
        # more distinct cd targets than this is already an extreme, unusual
        # shape no other class in this file covers either) -- beyond the cap,
        # stop forking further cd segments for the rest of THIS command and
        # keep the candidates already tracked, rather than growing unbounded.
        # Upgrade path if this ever needs raising: none identified, no case
        # has hit it.
        #
        # HIMMEL-2200 pr-check panel round 5 [codex-1]: an earlier version of
        # this cap truncated with a plain "keep the first MAXCAND", which is
        # a real bug, not just an approximation -- the set used to be built
        # unchanged-block-first, advanced-block-second, so truncating from
        # the tail systematically dropped EVERY "cd succeeds" candidate once
        # enough distinct cd targets accumulated, silently reopening the
        # exact fork-model gap this class of fix exists to close. Round 5
        # answered that with the protected index-1 invariant above, which
        # closes the concrete case that finding demonstrated (chained cds
        # where every one actually succeeds) -- but left the block layout
        # itself in place.
        #
        # HIMMEL-2225 (pr-check panel round 6 [codex-1]) closes what that
        # left: with an unchanged block followed by an advanced block, the
        # advanced block IS the tail, so the FIRST thing the cap dropped was
        # every "the latest cd succeeded, but an earlier one did not"
        # candidate -- systematically, all at once, rather than as an even
        # sampling. The build loop above now interleaves the two branches per
        # candidate, so the cap degrades both evenly. Truncation still drops
        # candidates once the cap is hit, and that remains an accepted,
        # documented residual -- but it is no longer BIASED against one whole
        # branch of the fork model. Closing it completely needs a symbolic
        # (prefix-set/trie) cwd representation instead of enumerated concrete
        # paths, which is its own piece of work, not an inline expansion; the
        # alternative of removing the cap trades this bounded fail-open
        # window for an unbounded resource-exhaustion one on a hot-path hook,
        # which is worse.
        if (n2 > MAXCAND) n2 = MAXCAND
        delete cwd_cand
        for (i = 1; i <= n2; i++) cwd_cand[i] = new_cand[i]
        ncand = n2
        delete new_cand
        return
    }
    # Fail-closed by construction: every candidate cwd is resolved and
    # printed as its OWN line, and the bash caller (see the while-read loop
    # below this awk block) sets pin_hit=1 the moment ANY printed line has file
    # content matches -- i.e. the candidates combine with OR, not AND/majority.
    # One matching candidate is enough to deny; this must never change to
    # requiring agreement across candidates, which would silently reopen
    # every cd-uncertainty bypass this fork model exists to close.
    if (is_interpreter(tok[1])) {
        j = 2
        while (j <= ntok && substr(tok[j], 1, 1) == "-") j++
        if (j <= ntok) for (i = 1; i <= ncand; i++) {
            cand = join(cwd_cand[i], tok[j])
            if (!has_nul(cand)) print cand
        }
    } else if (is_direct_exec_prefix(tok[1])) {
        for (i = 1; i <= ncand; i++) {
            cand = join(cwd_cand[i], tok[1])
            if (!has_nul(cand)) print cand
        }
    }
}
# HIMMEL-2218 [codex-2], round-2 panel: PowerShell backtick escapes are not
# just "the next character, literally" -- the backtick introduces a small set of
# SEQUENCES that stand for control characters, and for anything else the
# backtick is dropped and the character stands for itself. Modelling only the
# self-escaping trio (backtick, dollar, double-quote) left `q resolving to a
# literal backtick plus q instead of plain q, so a perfectly ordinary
# PowerShell command like  bash "C:/dir/`forge.sh"  -- which really does run
# forge.sh -- produced a path matching no file and the script went unscanned.
# That is a fail-OPEN, and unlike the control-character sequences it needs no
# exotic filename at all.
# KNOWN INCOMPLETE, tracked in HIMMEL-2236: PowerShell also recognizes `e
# (ESC, 0x1B), which this resolver models as the literal letter e. Found by the
# round-5 panel AFTER this PR had claimed the grammar was enumerated -- the
# enumeration was built from a list written out by hand, so it inherited the
# author-s blind spot rather than being derived from the language reference.
# The lesson is in the ticket: enumerate a grammar from its SPEC
# (about_Special_Characters), never from memory. Not fixed here because this
# branch carries a binding rule that the escape resolver is split rather than
# iterated a fifth time; `e is deferred with the >255 codepoint issue.
function pwsh_unescape(c) {
    if (c == "n") return "\n"
    if (c == "t") return "\t"
    if (c == "r") return "\r"
    if (c == "a") return "\007"
    if (c == "b") return "\b"
    if (c == "f") return "\f"
    if (c == "v") return "\013"
    # `0 is NUL. Returning the EMPTY string here looked harmless and was not:
    # it DELETES the sequence, so for`0ge.sh collapsed onto the genuinely
    # existing forge.sh and the fence denied a command PowerShell would never
    # have pointed there -- a false positive, caught by the grammar
    # enumeration below in the test suite. Emit a real NUL instead: no filename
    # on any platform can contain one, so the modeled path correctly matches
    # nothing, which is exactly what the real command does.
    if (c == "0") return sprintf("%c", 0)
    return c
}
# HIMMEL-2218 [codex-1], pr-check panel ROUND 3: PowerShell also has a
# VARIABLE-LENGTH escape, `u{...}, which pwsh_unescape() above cannot express
# because it resolves exactly one character. Checked against a real PowerShell
# 7.6.5 rather than inferred, in BOTH contexts:
#     "`u{66}orge"  -> forge          (double-quoted)
#      `u{66}orge   -> forge          (bare argument)
# so `u{66}orge.sh really does execute forge.sh, while a model that stops at
# one-character escapes looks for a literal u{66}orge.sh, finds nothing, and
# scans nothing. A fail-OPEN, and an encoding a worker can apply to ANY path.
#
# Returns how many input characters the whole sequence occupies, counted from
# the escape character itself, or 0 when this is not one; the resolved
# character is left in PWSH_U. The hex is converted by hand because gawk
# strtonum() does not exist in mawk, and this hook must not care which awk it
# gets. Codepoints above 255 depend on the awk sprintf: gawk emits the wide
# character, mawk truncates -- the evasion class this closes is ASCII paths,
# where both are exact.
function pwsh_unicode(line, p,   rest, hex, i, c, n, d) {
    rest = substr(line, p + 1)
    if (rest !~ /^u\{[0-9A-Fa-f]+\}/) return 0
    hex = rest
    sub(/^u\{/, "", hex)
    sub(/\}.*/, "", hex)
    if (length(hex) > 6) return 0
    n = 0
    for (i = 1; i <= length(hex); i++) {
        c = tolower(substr(hex, i, 1))
        d = index("0123456789abcdef", c) - 1
        n = n * 16 + d
    }
    if (n <= 0) return 0
    PWSH_U = sprintf("%c", n)
    return length(hex) + 4
}
# HIMMEL-2218 [codex-3]: count the escape characters a line ENDS with. An
# ODD count means the last one escapes the newline (a real line continuation);
# an even count is escaped literal escape characters and the line really ends.
function trailing_escapes(s,   n, L) {
    L = length(s)
    n = 0
    while (n < L && substr(s, L - n, 1) == ESC) n++
    return n
}
function scan_line(line,   p, ch, nextch, uadv) {
    ntok = 0
    cur = ""
    inq = ""
    esc = 0
    for (p = 1; p <= length(line); p++) {
        ch = substr(line, p, 1)
        if (esc) { cur = cur (pwsh ? pwsh_unescape(ch) : ch); esc = 0; continue }
        if (inq == SQ) {
            # HIMMEL-2218 expansion: PowerShell embeds a literal quote by
            # DOUBLING it -- two quote characters in a row INSIDE a
            # single-quoted string are one literal quote character in the
            # token, not a close followed by a reopen. Reading them as
            # close-then-reopen dropped that character, producing a path that
            # matches no file on disk, so the real script was never
            # content-scanned: a fail-OPEN. pwsh-gated because bash has no
            # doubling rule -- there two adjacent single-quoted strings really
            # do concatenate, which close-then-reopen already models
            # correctly.
            if (ch == SQ) {
                if (pwsh && substr(line, p + 1, 1) == SQ) { cur = cur SQ; p++; continue }
                inq = ""
            } else { cur = cur ch }
            continue
        }
        if (inq == "\"") {
            if (ch == "\"") { inq = ""; continue }
            # HIMMEL-2218 [codex-2]: inside a double-quoted PowerShell string
            # the backtick ALWAYS escapes -- there is no "unrecognized escape
            # keeps the backtick" rule the way bash keeps a backslash before an
            # ordinary character (the bash lookahead just below is deliberately
            # narrow because real bash IS narrow there). pwsh_unescape() above
            # decides what the escaped character resolves TO.
            if (pwsh && ch == ESC) {
                uadv = pwsh_unicode(line, p)
                if (uadv > 0) { cur = cur PWSH_U; p += uadv - 1; continue }
                esc = 1
                continue
            }
            if (!pwsh && ch == ESC) {
                nextch = (p < length(line)) ? substr(line, p + 1, 1) : ""
                if (nextch == "$" || nextch == "`" || nextch == "\"" || nextch == "\\") esc = 1
                else cur = cur ch
                continue
            }
            cur = cur ch
            continue
        }
        # Unquoted: the dialect escape character consumes the next character
        # literally, so an escaped `;`/`&`/`|`/space belongs to the TOKEN and
        # is not a segment or token boundary. HIMMEL-2218 [codex-2]: before
        # this, the PowerShell arm had no escape handling of any kind, so a
        # backtick-escaped separator inside an unquoted PowerShell path split
        # the command mid-token and the real script file went unscanned.
        if (ch == ESC) {
            if (pwsh) {
                uadv = pwsh_unicode(line, p)
                if (uadv > 0) { cur = cur PWSH_U; p += uadv - 1; continue }
            }
            esc = 1
            continue
        }
        if (ch == "\"" || ch == SQ) { inq = ch; continue }
        if (ch == " " || ch == "\t") {
            if (cur != "") { ntok++; tok[ntok] = cur; cur = "" }
            continue
        }
        if (ch == ";" || ch == "&" || ch == "|") {
            if (cur != "") { ntok++; tok[ntok] = cur; cur = "" }
            run_segment()
            ntok = 0
            delete tok
            continue
        }
        cur = cur ch
    }
    if (cur != "") { ntok++; tok[ntok] = cur }
    run_segment()
    delete tok
}
{
    # HIMMEL-2218 [codex-3]: a bash backslash-newline (or PowerShell
    # backtick-newline) continuation joins two PHYSICAL lines into ONE logical
    # command before the real shell parses it. Each awk input record is one
    # physical line, so without this pre-pass a script path split across a
    # continuation extracted as two unrelated fragments and the real file was
    # never scanned -- a fail-OPEN. Join first, scan the logical line.
    #
    # Residual: a trailing escape character inside a SINGLE-quoted string is
    # literal in both dialects, not a continuation, and this pre-pass runs
    # ahead of quote tracking so it joins there too. That is not a
    # regression -- the unjoined fragments missed the path just the same --
    # and the join direction adds candidates rather than removing them.
    #
    # HIMMEL-2218, CodeRabbit review on PR #2005: strip ONE terminal carriage
    # return first. A command submitted with CRLF line endings keeps the \r in
    # each awk record (RS is \n), so the escape character that continues the
    # line is no longer the LAST character and the join below never fires --
    # the continued path splits back into two fragments and the real script
    # goes unscanned. Verified as a live fail-OPEN on both dialects before this
    # line existed. Stripping here, at the single entry point, also keeps a
    # stray \r out of every token scan_line() builds, rather than fixing it per
    # branch further down.
    line = $0
    sub(/\r$/, "", line)
    if (trailing_escapes(line) % 2 == 1) {
        pending = pending substr(line, 1, length(line) - 1)
        next
    }
    scan_line(pending line)
    pending = ""
}
END { if (pending != "") scan_line(pending) }
')
PINSCRIPTS
        fi
        if [ "$pin_hit" = 1 ]; then
            {
                echo "⛔ block-glm-external-writes: refusing a Bash/PowerShell command that"
                echo "    references the hook-integrity pin directory ($pin_dir_raw)."
                echo "    A dispatched worker's shell must never touch a pin file there — doing"
                echo "    so could forge the HIMMEL-1666 hook-integrity check (HIMMEL-2085)."
                echo "    Legitimate mid-session hook-integrity work: set"
                echo "    HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 in the LAUNCHING shell."
            } >&2
            exit 2
        fi
    fi
fi

# SHARED line-continuation normalizer (HIMMEL-2528 round 5, codex-1), used by
# BOTH command-text fences below: the anchor-tamper class and the GLM-lane
# shape matchers. Defined once, at top level, on purpose — the two fences each
# flatten newlines to ';' with the same `tr`, and a second copy of this joiner
# is the exact defect this ticket keeps re-finding (round 3 fixed one
# quoting-normalization site and left its twin open for a whole round).
#
# WHAT IT REMOVES: bash DELETES a backslash-newline pair before it parses
# anything, so `git remote \<newline>set-url origin /tmp/evil.git` really
# executes the plain `git remote set-url …` both fences deny. Flattening the
# newline to ';' FIRST puts a segment break exactly where the verb belongs, so
# the scanners looked for a verb, found a separator, and the write measured
# rc=0 ALLOW while its plain spelling denied. This must therefore run UPSTREAM
# of every newline->';' conversion: afterwards `\`+newline has already become
# `\;` and nothing can tell it from a separator the operator typed. It is an
# AXIS REMOVAL — bash's own deletion rule, reproduced — not another spelling
# added to a pattern.
#
# PARITY: `\\`+newline is an escaped literal backslash and the line really
# ENDS, so joining there would ERASE a real command boundary (`echo x\\` +
# newline + `git fetch . x:origin/main` would stop being a command-position
# fetch and the fences would go blind). Only an ODD trailing run continues —
# the same rule the pin-dir scanner's trailing_escapes() applies above. Both
# consumers pin that direction with a case of their own.
#
# A single terminal `\r` is dropped only from the line being JOINED: a CRLF
# checkout puts it AFTER the backslash, so the backslash is no longer last and
# the join would never fire (the same byte that defeated the pin-dir scanner's
# join in PR #2005). Lines that are not continuations keep their `\r` for the
# flattening downstream to turn into a separator, exactly as before.
join_line_continuations() {
    awk '
        {
            line = $0
            cr = ""
            if (line ~ /\r$/) { cr = "\r"; sub(/\r$/, "", line) }
            n = 0
            L = length(line)
            while (n < L && substr(line, L - n, 1) == "\\") n++
            if (n % 2 == 1) {
                pend = pend substr(line, 1, L - 1)
                next
            }
            printf "%s%s%s\n", pend, line, cr
            pend = ""
        }
        END { if (pend != "") printf "%s\n", pend }
    '
}

# ----------------------------------------------------- HIMMEL-2528 class
# Anchor-tamper fence for the hook-integrity monotonic re-pin. Same gate and
# jq-extraction shape as the HIMMEL-2085 pin-dir class immediately above —
# runs for any worker_lane (GLM or native HIMMEL_WORKER=1), not glm_lane
# specifically. See that class's header for why "worker-ness, not lane" is
# the right scope; this class extends the same reasoning to a second surface.
#
# WHY THIS CLASS EXISTS: HIMMEL-2528 changed record-hook-integrity.sh's
# pin-mismatch behavior from "deny forever" to a monotonic re-pin — on a
# mismatch the launcher accepts the on-disk bytes iff they equal the blob at
# the tip of the record's stored anchor_ref (origin/<default branch>), the
# stored anchor is an ancestor of that tip, and the previously-pinned blob is
# reachable in that ref's history for the path (see docs/internals/
# enforcement.md's HIMMEL-2528 section for the exact accept condition). That
# makes refs/remotes/origin/<default> SECURITY-RELEVANT: the re-pin step now
# trusts whatever that ref currently resolves to as the definition of
# "legitimately committed hook content." A dispatched worker lane that can
# make that ref resolve to attacker-chosen history can walk the pin forward
# to a forged hook, one legitimate-looking re-pin at a time.
#
# THREAT MODEL (agent drift, not an external attacker — same posture as every
# other class in this file): a marker-bearing worker (HIMMEL_WORKER=1, or the
# GLM lane) runs a Bash/PowerShell command that repoints origin/<default> by
# one of: (a) a local-path remote fetch/push/pull with a refspec —
# `git fetch . x:origin/main`, DWIM-expanded by git itself, including via
# `git -C <dir>`; (b) direct ref-plumbing — `git update-ref`,
# `git symbolic-ref`, `git remote set-head`; (c) a remote-URL rewrite —
# `git remote set-url|add`, `git config remote.*.url`, `-c
# url.*.insteadOf=...` — which, followed by a later plain `git fetch origin`
# against a local bare clone whose "main" is a tampered feature tip, has the
# same effect as (a) without a refspec in the same call.
#
# TWO CLASSES, same deny:
#   (i)  substring/keyword match on the whole lowercased, QUOTE-NORMALIZED
#        command text — catches ref-plumbing and remote-rewrite shapes
#        regardless of the exact git invocation form: refs/remotes/,
#        remotes/origin/, symbolic-ref, remote set-head, remote set-url,
#        remote add/remove/rm/rename, update-ref, insteadOf,
#        remote.origin.url. It shares anchor_unquote() with class (ii)
#        (HIMMEL-2528 round 3): scanning raw text let every one of these
#        keywords through under an ordinary shell quoting form.
#   (ii) a command-position git-fetch/push/pull shape carrying an EXPLICIT
#        refspec whose DESTINATION lands in remote-tracking space
#        (refs/remotes/…, or the unqualified `<name>/<branch>` shorthand git
#        DWIMs onto it) — whatever the remote argument is spelled as. It
#        reuses gp_shape's "git with optional global flags" prefix idiom (see
#        count_cmd/gp_shape below) so `git -C <dir> fetch …` matches the same
#        as a bare `git fetch …`. Gating on the destination rather than on an
#        enumeration of remote spellings is what makes this class closed
#        against a remote nobody listed; see its inline comment for the four
#        measured bypasses that forced the inversion.
#
# THIS IS CHEAP COVERAGE, NOT CLOSURE — same command-TEXT-fence residual as
# every other class in this file, restated explicitly because this is the
# class that makes origin/<default> trusted:
#   - a `.git/config` edit followed by a plain `git fetch origin` is
#     invisible to a command-text fence: `git config remote.origin.url ...`
#     IS caught by class (i) above, but a hand-edit of .git/config through a
#     text-editing tool call, or a script this fence never inspects, is not —
#     the fetch command itself then names nothing suspicious;
#   - `packed-refs` / `.git/refs/remotes/` written through a path this fence
#     never sees spelled out (redirection into a file a worker's Edit grant
#     already reaches, or a script/tool-call this hook does not mediate) is
#     invisible the same way the HIMMEL-2085 pin-dir class's own residual is;
#   - anything an OS-user-level attacker does outside the tool-call surface
#     entirely is out of scope, as documented at the top of this file.
# These stay OPEN. Closure is a signed hook-generation manifest — hook
# content trusted by SIGNATURE, not by whatever origin/<default> currently
# resolves to — tracked as a follow-up ticket (see enforcement.md's
# HIMMEL-2528 section for the key).
if [ "$tool_is_shell" = 1 ] && [ "${HIMMEL_HOOK_INTEGRITY_BYPASS_OK:-0}" != "1" ]; then
    anchor_cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    if [ -n "$anchor_cmd" ]; then
        # HIMMEL-2528 round 5, codex-1: line continuations, the SEVENTH axis
        # this class's matching has been defeated on. `git remote
        # \<newline>set-url origin /tmp/evil.git` measured rc=0 ALLOW while
        # the plain spelling bash actually executes measured rc=2 — the
        # flattening on the next line turned the newline into a `;`, a segment
        # break exactly where the verb belongs, so the remote-verb tokeniser
        # found no verb after `remote`. One allowed command, then the
        # by-design-allowed `git fetch origin`, and the attacker's history IS
        # the trusted anchor.
        #
        # ORDER IS THE WHOLE FIX: the join runs BEFORE the newline->';'
        # flattening, never after, and both anchor_cmd_lc and anchor_cmd_norm
        # derive from the joined text, so it is one place rather than a
        # per-scan patch. Mechanism, parity and the `\r` rule live with the
        # shared join_line_continuations() above — the GLM-lane matchers use
        # the same function for the same reason.
        anchor_cmd_joined=$(printf '%s' "$anchor_cmd" | join_line_continuations)
        anchor_cmd_lc=$(printf '%s' "$anchor_cmd_joined" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

        # SHARED quoting normalization for BOTH classes below (HIMMEL-2528
        # round 3, codex-2). Round 1 added this to class (ii) only and left
        # class (i) scanning raw text, which closed one door and left its twin
        # open: `git "remote" "set-url" origin /tmp/decoy`,
        # `git remote 'set-url' …`, `git remote se\t-url …` and
        # `git "remote" "add" evil /tmp/d` ALL measured rc=0 ALLOW while their
        # bare spellings denied — the whole class-(i) keyword set, not just
        # `set-url`. One normalizer, used by both classes, is the point: a
        # second one could drift back apart exactly the way these two did.
        anchor_unquote() {
            # Collapses the small set of shell quoting forms bash applies to a
            # SINGLE WORD onto the same bare spelling: a backslash escaping one
            # character (`\.` -> `.`), then any remaining `"`/`'` quote
            # characters are dropped outright. Dropping quote characters
            # (rather than tracking open/close pairs) also collapses adjacent-
            # quote concatenation for free: `"".""` is four quote chars around
            # a `.`, and deleting all four leaves `.` — the same bare word bash
            # itself would concatenate it into. This is NOT a shell parser: it
            # tracks no segment/token boundaries, does not resolve `$()` /
            # backtick substitution or variable expansion, and is applied to
            # the WHOLE command text, not a single extracted word.
            #
            # That whole-text application is SAFE FOR A FENCE because it is
            # MONOTONE: it only ever DELETES quote/backslash characters, and no
            # token either class matches on contains one (class (ii)'s
            # alternatives are bare path segments of `.`, `/`, alnum, `-`, `_`;
            # class (i)'s keywords are `remote`, `-ref`, `insteadof`, `url`,
            # `refs/remotes/` and friends). So normalization can only ever WIDEN
            # a match, never narrow one — it cannot introduce a false ALLOW.
            # It CAN widen into a false DENY; see class (i)'s accepted-overmatch
            # note below for what that costs and why it is accepted.
            #
            # Residual (documented, not chased): bash ANSI-C quoting ($'...')
            # is deliberately NOT decoded here — a body like $'\056' (octal for
            # '.') or $'\x61dd' ("add") would need real escape decoding to
            # normalize correctly, and a WRONG decode could under-strip into a
            # false ALLOW. Rather than risk that, $'...' is handled by the
            # separate unconditional deny immediately below: fail CLOSED on the
            # form this function does not attempt.
            sed -E 's/\\(.)/\1/g' <<< "$1" | tr -d "\"'"
        }
        anchor_cmd_norm=$(anchor_unquote "$anchor_cmd_lc")

        # ANSI-C fail-closed arm, shared by both classes for the same reason
        # the normalizer is (HIMMEL-2528 round 3). Round 2 scoped this deny to
        # a fetch/push/pull segment, which is class (ii)'s grammar; class (i)'s
        # keywords are just as forgeable through an undecoded body
        # (`git remote $'\x61dd' evil /tmp/d`), so the shape widened from
        # `(fetch|push|pull)` to ANY command-position `git` segment. It reads
        # the UNNORMALIZED segment body on purpose: anchor_unquote() strips the
        # `'` and the `$'` marker would be gone.
        #
        # Deliberately NOT an enumeration of the git subcommands class (i)
        # fences. Enumerating a subcommand slot is the same axis class (ii)
        # abandoned after losing on it four times, and it cannot work here
        # anyway — the subcommand token is itself ANSI-C-quotable
        # (`git $'\x72emote' add …`). ACCEPTED OVERMATCH: a worker-lane
        # `git commit -m $'a\nb'` is refused. That is strictly cheaper than the
        # prose overmatch class (i) already accepts (see below), and
        # HIMMEL_HOOK_INTEGRITY_BYPASS_OK covers it. Residual: like class
        # (ii)'s own shapes this arm is COMMAND-POSITION anchored, so a git
        # call reached through a wrapper (`rtk git remote $'…'`) is not seen —
        # class (i)'s keyword scan is unanchored and still covers the wrapper
        # case for every form anchor_unquote() does normalize.
        #
        # HIMMEL-2528 round 4, codex-3: this arm used to be one regex over the
        # whole lowercased text, anchoring on a LITERAL unquoted `git` at
        # command position — `(^|[;&|(])[[:space:]]*git…`. Scanning raw text is
        # right for the `$'` marker and WRONG for the anchor, and the two
        # requirements were being served by the same read: `"git" remote
        # $'\x61'dd origin /tmp/evil.git` measured rc=0 ALLOW, walking past
        # this arm (the `"` breaks the literal anchor) AND past the normalized
        # keyword scan (the undecoded body hides the verb). One allowed
        # command, then a by-design-allowed `git fetch origin`, completes the
        # forgery.
        #
        # The split below is the fix, and it is a REMOVAL of the quoting axis,
        # not another spelling added to a list: the segment's COMMAND-POSITION
        # TOKEN is run through the same shared anchor_unquote(), so every
        # quoting form that function already collapses is covered at once
        # (`"git"`, `'git'`, `\git`, `""git""`), while the REST of the segment
        # stays raw so the `$'` marker survives to be seen. Segment splitting
        # on `;&|()` reproduces exactly what the old regex's `(^|[;&|(])` start
        # class and `[^;&|]*` body expressed.
        anchor_dollar_quote='$'"'"''
        anchor_ansi_c_hit=0
        case $anchor_cmd_lc in
            *"$anchor_dollar_quote"*)
                while IFS= read -r anchor_ansi_seg; do
                    case $anchor_ansi_seg in
                        *"$anchor_dollar_quote"*) ;;
                        *) continue ;;
                    esac
                    anchor_ansi_tok=""
                    anchor_ansi_rest=""
                    # `read` with the default IFS drops leading whitespace and
                    # splits off the first word — the command-position token —
                    # leaving the remainder byte-for-byte in anchor_ansi_rest.
                    read -r anchor_ansi_tok anchor_ansi_rest <<< "$anchor_ansi_seg" || true
                    [ "$(anchor_unquote "$anchor_ansi_tok")" = "git" ] || continue
                    case $anchor_ansi_rest in
                        *"$anchor_dollar_quote"*) anchor_ansi_c_hit=1; break ;;
                    esac
                done <<< "$(printf '%s' "$anchor_cmd_lc" | tr ';&|()' '\n')"
                ;;
        esac

        # Class (i): keyword/substring match, case-insensitive against the
        # NORMALIZED text (anchor_cmd_lc is already lowercased; anchor_cmd_norm
        # adds quote/backslash removal). Fixed-string tokens use grep -qF; the
        # "remote <verb>" family is TOKENISED (see anchor_remote_verb_hit
        # below) rather than pattern-matched, because the verb does not have to
        # be adjacent to `remote`.
        #
        # `remote remove` / `remote rm` / `remote rename` were named in this
        # ticket's own threat model but omitted from the prescribed fence list,
        # so both stayed unfenced (measured rc=0 ALLOW) while `add` and
        # `set-url` denied. They belong here for the same reason `add` does:
        # removing or renaming `origin` collapses the configured-remote set the
        # class (ii) destination gate consults, and a stale
        # refs/remotes/origin/main survives the removal and still DWIMs. `rm`
        # is a real git alias for `remove` (git-remote(1): "remove, rm";
        # `git remote rm` prints `usage: git remote remove <name>`, not
        # "unknown subcommand"), so omitting it would leave the same hole under
        # a different spelling. Only `rm` gets a trailing boundary — it is two
        # characters, short enough that a bare substring would swallow
        # unrelated words; the longer verbs follow this class's existing
        # accepted-overmatch style. Read-only `git remote`, `git remote -v`,
        # `git remote show origin` and `git remote get-url origin` match none
        # of these and stay allowed.
        #
        # ACCEPTED OVERMATCH, restated because round 3 widened it: this class
        # is an UNANCHORED substring scan, so a commit MESSAGE naming a fenced
        # phrase already denied before normalization
        # (`git commit -m "docs: note the remote set-url tripwire"`, measured
        # rc=2 pre-fix and pinned as a case). Normalizing extends that same
        # accepted cost to quoted prose (`… "the remote 'add' flow" …`); it
        # does not create a NEW category of false positive. Scoping the
        # keywords to a git-COMMAND shape instead would have shrunk the class —
        # it would stop catching `git commit -m "… remote add …"` AND
        # `bash -c 'git remote add …'` alike — so the overmatch is kept and the
        # bypass env var remains the escape hatch.
        # known-findings [grep-q-pipe-under-pipefail]: here-strings, never a
        # `producer | grep -q` pipe (set -euo pipefail SIGPIPE hazard).
        #
        # HIMMEL-2528 round 4, codex-2: the remote-verb half of this list used
        # to be six `remote[[:space:]]+<verb>` regexes, which require the verb
        # to sit IMMEDIATELY after `remote`. git does not: `git remote` accepts
        # options before its subcommand, so `git remote -v set-url origin
        # /tmp/evil.git` and `git remote --verbose add evil /tmp/d` both
        # measured rc=0 ALLOW — one allowed command away from a forged anchor,
        # since the follow-up `git fetch origin` is allowed by design.
        #
        # The fix TOKENISES instead of enumerating. After a `remote` token, any
        # number of OPTION tokens (anything shaped `-*`) are skipped and the
        # FIRST NON-OPTION token is taken as the verb. Nothing here lists which
        # options exist — that would be the same enumeration trap under a new
        # name, and git can add an option tomorrow. Whatever git adds is
        # `-`-prefixed, so it is skipped without this code changing.
        #
        # `git remote -v` with NO verb after it is a LISTING, not a metadata
        # write, and must stay allowed: with no non-option token left, nothing
        # is ever compared against the verb list and the scan simply ends. Same
        # for bare `git remote`. Read-only verbs (`show`, `get-url`) are
        # non-option tokens that are not in the list, so they fall through too.
        #
        # Token EQUALITY also retires the `([^a-z0-9_-]|$)` boundary hack the
        # two-character `rm` needed: a token either is `rm` or it is not.
        anchor_remote_verb_hit=0
        anchor_expect_verb=0
        while IFS= read -r anchor_word; do
            [ -n "$anchor_word" ] || continue
            if [ "$anchor_expect_verb" = 1 ]; then
                case $anchor_word in
                    -*) continue ;;
                esac
                anchor_expect_verb=0
                case $anchor_word in
                    add|remove|rm|rename|set-url|set-head)
                        anchor_remote_verb_hit=1
                        break
                        ;;
                esac
            fi
            if [ "$anchor_word" = remote ]; then anchor_expect_verb=1; fi
        done <<< "$(printf '%s' "$anchor_cmd_norm" | tr ' \t' '\n')"

        anchor_kw_hit=0
        if [ "$anchor_remote_verb_hit" = 1 ] ||
           grep -qF 'refs/remotes/' <<< "$anchor_cmd_norm" ||
           grep -qF 'remotes/origin/' <<< "$anchor_cmd_norm" ||
           grep -qF 'symbolic-ref' <<< "$anchor_cmd_norm" ||
           grep -qF 'update-ref' <<< "$anchor_cmd_norm" ||
           grep -qF 'insteadof' <<< "$anchor_cmd_norm" ||
           grep -qF 'remote.origin.url' <<< "$anchor_cmd_norm"; then
            anchor_kw_hit=1
        fi

        # Class (ii): git [global-flags] (fetch|push|pull) [dash-opts]
        # <local-path-remote> <token-containing-:>, anchored at command
        # position (^|[;&|(]). The global/subcommand-flag alternatives reuse
        # gp_shape's own idiom verbatim (see below) — that is what makes
        # `git -C <dir> fetch . x:origin/main` match the same as
        # `git fetch . x:origin/main`.
        #
        # codex-6 (reproduced): the remote-argument alternatives below are
        # literal bare spellings (`.`, `./...`, `../...`, `/...`). Shell quote
        # removal has already happened by the time the real git process sees
        # its argv, but this fence reads the RAW command text before that
        # removal, so `git fetch "." x:origin/main` never contains a bare `.`
        # token and the bare-only pattern missed it — a proven bypass, not a
        # theoretical one (measured rc=0 ALLOW pre-fix). Fixed by running the
        # SAME regex against a quoting-normalized copy of the command text
        # instead of widening the regex with `"`-shaped alternatives, so any
        # spelling of the same bare word still collapses to one match. See
        # anchor_unquote() (defined above, shared with class (i) since round 3)
        # for exactly which quoting forms this normalizes and what stays open.

        # DESTINATION-GATED, not remote-enumerating (HIMMEL-2528 round 2).
        # This used to match on the REMOTE argument: a finite alternation of
        # local-path spellings (`.`, `..`, `./…`, `../…`, `/…`). That axis lost
        # four times running — quoted remotes (codex-6), bare `..`, then bare
        # relative directory names (`git fetch evil.git x:origin/main`,
        # `git fetch sub/dir x:origin/main`, both measured rc=0 ALLOW), and
        # finally the *configured* remote itself (`git fetch origin
        # x:origin/main`, also measured rc=0 ALLOW), which forges the tracking
        # ref exactly as well as a local path does. Adding a fifth alternative
        # would only have bought the fifth bypass.
        #
        # The invariant that actually matters is not WHICH remote is named, it
        # is that no worker-lane command may WRITE a remote-tracking ref. So
        # the match moved to the refspec's DESTINATION side, and the remote
        # argument stopped being load-bearing: any command-position
        # `git … fetch|push|pull` carrying an explicit `<src>:<dst>` whose
        # <dst> resolves into remote-tracking space is denied, whatever the
        # remote is spelled as. That single rule subsumes every historical
        # bypass above plus every spelling nobody has thought of yet.
        #
        # <dst> is classified by prefix, not by an allowlist of remote names:
        #   refs/remotes/…  -> DENY (explicit tracking write)
        #   refs/…          -> allow (refs/heads/, refs/tags/, … are ordinary
        #                     local/remote-side namespaces, not the anchor)
        #   <a>/<b>         -> DENY iff <a> names remote-tracking space in THIS
        #                     repo (see anchor_load_remote_set) — git's own
        #                     DWIM resolves `origin/main` to the EXISTING
        #                     refs/remotes/origin/main, which is precisely the
        #                     ref record-hook-integrity.sh anchors on
        #   <a>             -> allow (a bare local branch/tag name)
        #
        # The `<a>/<b>` arm needs that repo lookup because `origin/main` and a
        # slash-bearing BRANCH name are the same shape, and himmel mandates
        # `type/slug` branches — a blanket deny would refuse
        # `git push origin head:feat/x`, the single most common push in the
        # repo. Resolving <a> against the live remote set is NOT a return to
        # the remote-spelling enumeration this class abandoned: that
        # enumeration guessed at an open-ended space of ways to WRITE a remote
        # (a fifth spelling always exists), whereas this reads a small closed
        # set out of git itself. A worker cannot extend that set either —
        # `git remote add` and `git remote set-url` are both denied by class
        # (i) above — so it is fixed for the life of the lane.
        #
        # THE SENTENCE ABOVE WAS ONLY TRUE FOR BARE SPELLINGS UNTIL ROUND 3
        # (codex-2). `git "remote" "add" evil /tmp/d` and
        # `git remote 'set-url' origin /tmp/decoy` both measured rc=0 ALLOW,
        # so a worker COULD extend or repoint the remote set this arm reads
        # back out of git. Class (i) scanning anchor_cmd_norm is what makes
        # "fixed for the life of the lane" hold for every spelling — see the
        # bigger consequence of the same gap in the implicit-refspec note
        # below, which is where it was an outright anchor forgery rather than
        # a widened lookup.
        #
        # NOT over-blocked, and this is the subtle part: `git fetch origin`,
        # `git fetch origin main`, `git fetch --all`, `git push origin feat/x`
        # and `git pull` all update tracking refs too, via the remote's
        # CONFIGURED default refspec. They carry no explicit tracking-ref
        # destination in the command text, and that absence is exactly the
        # discriminator — this fence denies an EXPLICIT tracking destination,
        # never the implicit configured one. (An implicit-refspec fetch from a
        # remote whose URL was already made hostile is out of this fence's
        # reach; `git remote add` and `git remote set-url` are both denied by
        # class (i) above, which is what keeps that gap narrow.)
        #
        # THIS CLASS INHERITS ITS SAFETY FROM CLASS (i)'s NORMALIZATION —
        # the load-bearing coupling on this branch (codex-2, round 3). The
        # parenthesis above is the ONLY thing standing between an allowed
        # implicit fetch and a forged anchor, and until round 3 it held for
        # bare spellings alone. The full pre-fix attack was two commands this
        # hook allowed outright:
        #     git remote 'set-url' origin /tmp/evil.git   # rc=0 pre-fix
        #     git fetch origin                            # rc=0 BY DESIGN
        # — the second is the implicit-refspec form this class must never
        # deny, so the first was the whole defence, and quoting walked through
        # it. Class (i) is not a redundant "cheap coverage" layer here; class
        # (ii) is UNCLOSEABLE against this path on its own. Anyone
        # "simplifying" class (i) back to raw-text matching re-opens it with
        # EVERY class-(ii) case still green, because no class-(ii) case can
        # observe class (i)'s text source. That is the exact failure shape
        # this branch keeps producing, so the precondition is pinned
        # mechanically, not just in prose: see the rows labelled
        # "class (i) precondition for the destination gate" in
        # test-block-glm-external-writes.sh.
        #
        # Scanning is per SEGMENT (split on `;`, `&`, `|`, parens) so the
        # fetch/push/pull shape and the tracking destination must occur in the
        # SAME command — `git fetch origin; git commit -m "fix: origin/main
        # drift"` stays allowed. Within a segment the destination may sit
        # anywhere, which is what covers the config/flag spellings of a
        # refspec (`--refmap=<spec>`, `--refmap <spec>`, `-c
        # remote.origin.fetch=<spec>`) without a per-flag rule.
        # The names that DWIM into remote-tracking space, read out of the repo
        # the hook-integrity pin actually anchors on ($CLAUDE_PROJECT_DIR, else
        # this hook's own checkout). Two sources, unioned, because either alone
        # leaves a hole:
        #   - `git remote` — the configured remotes;
        #   - the first segment of every existing `refs/remotes/<a>/…` ref —
        #     because `git remote remove origin` is NOT fenced by class (i),
        #     and a stale refs/remotes/origin/main survives it and still DWIMs.
        # Both are lowercased to match the normalized command text.
        #
        # WHERE THIS CAN SPAWN GIT: only from the `<a>/<b>` arm of the
        # destination classifier below — i.e. only after a command-position
        # fetch/push/pull was found AND it carries an explicit `<src>:<dst>`
        # whose <dst> already has the two-segment shape. It can NOT spawn on an
        # ordinary Bash call: no colon, no refspec, a bare or refs/-qualified
        # destination, or a non-fetch/push/pull command all return before the
        # loader is ever called, and the loader runs at most once per hook
        # invocation. That matters because this hook is PreToolUse on EVERY
        # Bash/PowerShell call.
        anchor_remote_set=""
        anchor_remote_set_ready=0
        anchor_remote_set_failed=0
        anchor_load_remote_set() {
            if [ "$anchor_remote_set_ready" = 1 ]; then return 0; fi
            anchor_remote_set_ready=1
            local dir names refs
            dir="${CLAUDE_PROJECT_DIR:-}"
            if [ -z "$dir" ]; then
                dir=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P) || dir=""
            fi
            # FAIL CLOSED on any failure to establish the set (not a repo, git
            # missing, non-zero exit): this class exists to refuse what it
            # cannot prove safe, and HIMMEL_HOOK_INTEGRITY_BYPASS_OK covers the
            # rare legitimate case. Failing OPEN here would hand a bypass to
            # any worker that could make the lookup fail.
            names=$(git -C "$dir" remote 2>/dev/null) || {
                anchor_remote_set_failed=1; return 0; }
            refs=$(git -C "$dir" for-each-ref --format='%(refname:lstrip=2)' refs/remotes/ 2>/dev/null | sed 's|/.*||') || {
                anchor_remote_set_failed=1; return 0; }
            anchor_remote_set=$(printf '%s\n%s\n' "$names" "$refs" \
                | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)
        }

        anchor_seg_rw='^[[:space:]]*git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(fetch|push|pull)([[:space:]]|$)'
        anchor_refspec_hit=0
        anchor_segs=$(printf '%s' "$anchor_cmd_norm" | tr ';&|()' '\n')
        while IFS= read -r anchor_seg; do
            grep -qE "$anchor_seg_rw" <<< "$anchor_seg" || continue
            anchor_words=$(printf '%s' "$anchor_seg" | tr ' \t' '\n')
            while IFS= read -r anchor_word; do
                case $anchor_word in *:*) ;; *) continue ;; esac
                # Destination side = everything past the FIRST colon. A URL
                # remote (`https://host/repo`) leaves `//host/repo`, which
                # starts with `/` and so matches none of the DENY prefixes.
                anchor_dst=${anchor_word#*:}
                case $anchor_dst in
                    refs/remotes/*) anchor_refspec_hit=1 ;;
                    refs/*) ;;
                    */*)
                        anchor_load_remote_set
                        if [ "$anchor_remote_set_failed" = 1 ]; then
                            anchor_refspec_hit=1
                        elif grep -qxF "${anchor_dst%%/*}" <<< "$anchor_remote_set"; then
                            anchor_refspec_hit=1
                        fi
                        ;;
                esac
                if [ "$anchor_refspec_hit" = 1 ]; then break; fi
            done <<< "$anchor_words"
            if [ "$anchor_refspec_hit" = 1 ]; then break; fi
        done <<< "$anchor_segs"

        # The ANSI-C blanket deny that used to sit here (scoped to a
        # fetch/push/pull segment) moved UP next to anchor_unquote() in round 3
        # and widened to any command-position `git` segment — it is a property
        # of the normalizer's residual, not of either class, and class (i)
        # needed it too. It still covers what it covered here: the destination
        # side as well as the remote side, since $'origin\057main' would
        # survive normalization without a literal slash for the destination
        # classifier above to see.

        if [ "$anchor_kw_hit" = 1 ] || [ "$anchor_refspec_hit" = 1 ] ||
           [ "$anchor_ansi_c_hit" = 1 ]; then
            {
                echo "⛔ block-glm-external-writes: refusing a Bash/PowerShell command that could"
                echo "    repoint origin/<default branch> — a fetch/push/pull carrying an explicit"
                echo "    refspec that WRITES a remote-tracking ref (refs/remotes/… or the"
                echo "    <name>/<branch> shorthand), or a ref/remote-metadata rewrite (symbolic-ref,"
                echo "    update-ref, remote set-url/set-head/add, insteadOf, remote.origin.url)."
                echo "    HIMMEL-2528's hook-integrity re-pin trusts whatever"
                echo "    refs/remotes/origin/<default> currently resolves to as legitimately-"
                echo "    committed hook content — this command shape could redefine that."
                echo "    This is a command-TEXT fence, not closure: a .git/config edit followed"
                echo "    by a plain 'git fetch origin', or packed-refs/.git/refs/remotes/ written"
                echo "    through a path this fence never sees spelled out, are NOT caught."
                echo "    Legitimate mid-session work: set HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 in the"
                echo "    LAUNCHING shell."
            } >&2
            exit 2
        fi
    fi
fi

# Everything below this point is the ORIGINAL GLM-lane enforcement — outbox
# report interception, then the mcp/push/gh/network classifiers — unchanged
# and still scoped to glm_lane only (HIMMEL-2085 and HIMMEL-2528 add no
# native-lane behavior past the two classes above).
[ "$glm_lane" = 1 ] || exit 0

deny() {
    {
        echo "⛔ block-glm-external-writes: $1"
        echo "    This session runs on the GLM lane (ANTHROPIC_BASE_URL=api.z.ai), which has"
        echo "    no auto-mode classifier — external writes are hard-blocked (HIMMEL-654)."
        echo "    Deliver results as a committed branch diff + your session outbox summary;"
        echo "    the parent Claude session / operator pushes and opens PRs."
        echo "    Operator bypass: GLM_EXTERNAL_WRITES_OK=1 in the spawning shell."
    } >&2
    exit 2
}

# HIMMEL-1649 round 3: the report verb is EXECUTED BY THE HOOK, never by any
# on-disk content. On the exact report shape this hook decodes the payload,
# validates it, appends the record to the session outbox ITSELF, and then DENIES
# the Bash call. Deny-after-append is the semantics, and the success message
# below tells the worker its report landed so it does not retry.
#
# Why not an ALLOW of a session-dir script (the round-2 shape): pathname trust
# is the wrong shape. The worker holds Bash(node *)/Bash(bash *) and Edit on its
# own session dir, chmod is advisory on NTFS/Git-Bash, and a computed
# destination path defeats any command-text classifier — so NO worker-reachable
# file can be made trustworthy at execution time. The hook is the trust root, so
# the hook performs the write. Nothing on disk is executed through this path.
deny_recorded() {
    {
        echo "✅ block-glm-external-writes: guard recorded your report; the command is not"
        echo "    executed — no further action needed (HIMMEL-1649)."
        echo "    The hook appended the outbox record itself and then denied the Bash call"
        echo "    BY DESIGN. Your report IS saved. Do not retry, reword, or find another way."
    } >&2
    exit 2
}

# GLM_SESSION_DIR is minted by spawn-glm.ts in the dispatcher's parent process
# and inherited by the worker/hook; a per-tool-call env prefix cannot alter it.
# Validate that seam fail-closed here. append-outbox.sh keeps a self-contained
# copy of these predicates for the non-GLM-lane case where this hook is absent;
# on the GLM lane that file is never executed, so the two copies are parity for
# readers rather than a shared trust boundary — keep them lockstep anyway.
path_norm() {
    printf '%s' "$1" | tr '\134' '/'
}

valid_glm_session_dir() {
    local sd base parent parent_base
    sd=$(path_norm "${GLM_SESSION_DIR:-}")
    sd=${sd%/}
    [ -n "$sd" ] || return 1
    case "$sd" in /*|[A-Za-z]:/*) ;; *) return 1 ;; esac
    case "/$sd/" in */../*|*/./*) return 1 ;; esac
    base=${sd##*/}
    parent=${sd%/*}
    parent_base=${parent##*/}
    [ "$parent_base" = "glm-sessions" ] || return 1
    case "$base" in glm-*) ;; *) return 1 ;; esac
    [ -d "$sd" ] || return 1
    [ ! -L "$sd" ] || return 1
    GLM_SESSION_REAL=$(cd "$sd" 2>/dev/null && pwd -P) || return 1
    [ -n "$GLM_SESSION_REAL" ] || return 1
    # Node on Windows accepts C:/... paths, not Git Bash's /c/... spelling.
    # Prefer pwd -W there; Unix bash lacks it, so fall back to the physical
    # POSIX path (same convention append-outbox.sh uses).
    GLM_SESSION_NATIVE=$(cd "$sd" 2>/dev/null && pwd -W 2>/dev/null) || GLM_SESSION_NATIVE=""
    [ -n "$GLM_SESSION_NATIVE" ] || GLM_SESSION_NATIVE="$GLM_SESSION_REAL"
    return 0
}

session_metadata_ok=0
if valid_glm_session_dir; then session_metadata_ok=1; fi

if [ "$tool_is_shell" = 1 ]; then
    report_cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # shellcheck disable=SC2016  # literal inherited variable spelling is the exact command contract
    helper_var_cmd_re='^bash "\$GLM_SESSION_DIR/append-outbox\.sh" ([A-Za-z0-9_-]+)$'
    helper_path_cmd_re='^bash ([A-Za-z0-9_./:+-]+/append-outbox\.sh) ([A-Za-z0-9_-]+)$'
    report_shape_ok=0
    report_script=""
    report_payload=""

    if [[ "$report_cmd" =~ $helper_var_cmd_re ]]; then
        report_shape_ok=1
        report_payload=${BASH_REMATCH[1]}
    elif [[ "$report_cmd" =~ $helper_path_cmd_re ]]; then
        report_shape_ok=1
        report_script=${BASH_REMATCH[1]}
        report_payload=${BASH_REMATCH[2]}
    fi

    if [ "$report_shape_ok" = 1 ]; then
        if [ "${#report_payload}" -gt 16384 ]; then
            deny "the GLM outbox payload exceeds the 16384-character base64url cap (HIMMEL-1649)."
        fi
        if [ "$session_metadata_ok" != 1 ]; then
            deny "the GLM outbox helper requires a valid dispatcher-minted GLM_SESSION_DIR (HIMMEL-1649)."
        fi

        if [ -z "$report_script" ]; then
            report_script="$GLM_SESSION_REAL/append-outbox.sh"
        else
            report_script=$(path_norm "$report_script")
        fi
        report_script_base=${report_script##*/}
        report_script_dir=${report_script%/*}
        report_script_dir_real=$(cd "$report_script_dir" 2>/dev/null && pwd -P) || \
            deny "the GLM outbox helper path does not resolve inside the dispatcher-minted GLM_SESSION_DIR (HIMMEL-1649)."

        # The helper file's existence/mode is deliberately NOT checked: it is
        # never executed on this lane, so making the decision depend on it would
        # be trust theater. Only the command SHAPE and the session-dir identity
        # gate the record.
        if [ "$report_script_base" != "append-outbox.sh" ] \
           || [ "$report_script_dir_real" != "$GLM_SESSION_REAL" ]; then
            deny "the GLM outbox report path must name the dispatcher-minted GLM_SESSION_DIR/append-outbox.sh (HIMMEL-1649)."
        fi

        command -v node >/dev/null 2>&1 || \
            deny "the GLM outbox guard needs node on PATH to record the report (HIMMEL-1649)."

        report_outbox="$GLM_SESSION_NATIVE/outbox.jsonl"
        [ ! -L "$GLM_SESSION_REAL/outbox.jsonl" ] || \
            deny "refusing a symlinked GLM session outbox.jsonl (HIMMEL-1649)."

        # Fixed program, payload passed as argv DATA — never shell source.
        # Validation order is fail-closed throughout: a rejected payload appends
        # nothing and the Bash call is denied with the reason.
        report_err=$(node -e '
const fs = require("node:fs");
const payload = process.argv[1];
const outbox = process.argv[2];
let text;
try {
  if (payload.length % 4 === 1) throw new Error("invalid base64url length");
  const decoded = Buffer.from(payload, "base64url");
  if (decoded.toString("base64url") !== payload) throw new Error("non-canonical base64url");
  text = new TextDecoder("utf-8", { fatal: true }).decode(decoded);
} catch {
  console.error("payload is not canonical base64url UTF-8");
  process.exit(2);
}
let parsed = null;
let structured = false;
try {
  parsed = JSON.parse(text);
  structured = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
} catch {
  structured = false;
}
// HIMMEL-1649 round 3 (F2) — consecutive-duplicate suppression. The hook
// appends and then DENIES, which is indistinguishable from a retryable failure
// to any framework-level retry; and because a prompt-shaped escalation omits
// ts, every retry would be stamped afresh and become a DISTINCT pending
// escalation. Un-denying is not an option (it would re-open executing on-disk
// content), so idempotency lives here: a sha256 of the RAW decoded payload is
// persisted alongside each record as _sig — the digest, never the payload
// itself, so the same comparison costs nothing per record — and an identical
// payload arriving immediately after the previous one appends NOTHING while
// still reporting success. A retry storm converges to one row; the same note
// sent again LATER, after any different record, still lands.
// LIMITS — adjudication-blind BY DESIGN in v1, deferred to HIMMEL-1663
// (round 4, [codex-adv-r4-2], both halves premise-verified): the key is payload
// equality with the LAST row only, carrying no attempt identity, time bound,
// adjudication state, or lock. So (a) an escalation REFUSED in grants.jsonl and
// then re-raised VERBATIM is suppressed while the worker is still told
// "recorded" — the aggregator skips the closed row, leaving nothing pending;
// and (b) two concurrent invocations can both read the old signature and both
// append. Deferred deliberately: the (a) window is narrow (it holds only while
// the identical row remains LAST — any intervening record clears it) and every
// candidate fix reopens the contract above; (b) costs a duplicate row on a
// worker that issues Bash calls serially.
const rawSig = require("node:crypto").createHash("sha256").update(text, "utf8").digest("hex");
let lastSig = null;
// Round 4 [codex-adv-r4-1] — torn-tail boundary. If an earlier append was
// interrupted the file can end mid-line, and appending straight onto it would
// CONCATENATE the new JSON into that partial line: consumers
// (fleet-control/aggregator/escalations.ts jsonl()) skip the combined invalid
// line, while the worker is still told its report was recorded. Detect the
// missing terminator and separate the records. A torn tail also fails to parse,
// so it already yields lastSig=null and can never suppress this append.
let torn = false;
try {
  const prior = fs.readFileSync(outbox, "utf8");
  torn = prior.length > 0 && !prior.endsWith("\n");
  const lines = prior.split("\n").filter((l) => l.trim() !== "");
  if (lines.length > 0) {
    try { lastSig = JSON.parse(lines[lines.length - 1])._sig ?? null; } catch { lastSig = null; }
  }
} catch { lastSig = null; }
if (lastSig !== null && lastSig === rawSig) {
  process.exit(0);
}
let record;
if (structured) {
  const type = parsed.type;
  if (type !== "note" && type !== "escalation") {
    console.error("structured payload type must be note or escalation");
    process.exit(2);
  }
  const allowed = type === "escalation"
    ? ["type", "capability", "arm", "reason", "step", "ts"]
    : ["type", "text", "ts"];
  for (const key of Object.keys(parsed)) {
    if (!allowed.includes(key)) {
      console.error("unknown key in structured payload: " + key);
      process.exit(2);
    }
  }
  const required = type === "escalation"
    ? ["capability", "arm", "reason", "step"]
    : ["text"];
  for (const key of required) {
    if (typeof parsed[key] !== "string") {
      console.error("field must be a string: " + key);
      process.exit(2);
    }
  }
  if (parsed.ts !== undefined && typeof parsed.ts !== "string") {
    console.error("field must be a string: ts");
    process.exit(2);
  }
  record = parsed;
  if (typeof record.ts !== "string") record.ts = new Date().toISOString();
} else {
  record = { type: "note", text };
}
record._sig = rawSig;
try {
  fs.appendFileSync(outbox, (torn ? "\n" : "") + JSON.stringify(record) + "\n", "utf8");
} catch (error) {
  console.error("append failed: " + error.message);
  process.exit(2);
}
' -- "$report_payload" "$report_outbox" 2>&1) || \
            deny "the GLM outbox report was rejected: ${report_err:-invalid payload} (HIMMEL-1649)."

        deny_recorded
    fi

fi

# ---- end of the SERVICE half; everything below is ENFORCEMENT --------------
# The bypass lands HERE (HIMMEL-1649 round 3): a bypass session has already had
# its report intercepted, schema-validated and recorded by the block above with
# identical semantics, so it can no longer silently lose a structured
# escalation. What it skips is only the near-miss denies and the
# push/gh/network classifiers.
# Round 4 [codex-1] — the consequence, stated plainly: with the near-miss denies
# skipped, a MALFORMED helper command falls through to ordinary Bash handling
# and EXECUTES the on-disk helper. Designed, not leaked. The helper is the
# lockstep implementation of the schema validated above and fail-closes the very
# same payloads, so the property that survives is the one that matters — a
# malformed payload appends nothing — with the executor, not the guarantee,
# differing between the two modes. See the BYPASS SCOPE note in the header.
# Scope, round 5: "no on-disk content executes" is a claim about the HELPER,
# never about this file. A worker whose envelope includes the worktree can
# rewrite THIS hook — see the trust-root note in the header and HIMMEL-1666.
[ "$glm_bypass" = 1 ] && exit 0

if [ "$tool_is_shell" = 1 ]; then
    # Every helper mention outside the exact contract is a fail-closed near-miss,
    # never ordinary Bash handling: repo/sibling paths, env prefixes, quotes,
    # substitutions, separators, redirects, extra arguments, and write attempts.
    case "$report_cmd" in
        *append-outbox.sh*)
            deny "malformed GLM outbox helper command; use exactly: bash \"\$GLM_SESSION_DIR/append-outbox.sh\" <base64url> (HIMMEL-1649)." ;;
        node\ -e*appendFileSync*outbox.jsonl*)
            deny "the interpolated node -e outbox append is retired; use the fixed session-dir base64url helper (HIMMEL-1649)." ;;
    esac
fi

# qmd MCP collection fence (HIMMEL-1239). v1 allow-list: ONLY the "himmel"
# collection (non-sensitive, repo-local docs). Widening this list (e.g. adding
# luna-curated) is a SEPARATE named operator decision — do not add collections
# here without one. `qmd_himmel_scoped "<value>"` -> 0 iff the value is a
# fully-qualified qmd://himmel/... virtual path (see header comment above for
# why bare/relative paths and #docids are rejected instead of allowed).
qmd_himmel_scoped() {
    # Whole-STRING prefix match (CR round 5, HIMMEL-1239) — NOT grep's
    # per-line match. grep -qE '^...' anchors at the start of EACH LINE, so a
    # value with an embedded newline where any line starts with
    # qmd://himmel/ (e.g. "qmd://salus/x\nqmd://himmel/y") passed even though
    # the value itself starts with salus. Python's re.match (no MULTILINE)
    # anchors at the actual string start; this replicates that exactly via
    # parameter expansion (bash 3.2-safe, no grep/sed) — strip leading
    # whitespace, then a plain glob-prefix case match.
    _q="$1"
    _q="${_q#"${_q%%[![:space:]]*}"}"   # strip leading whitespace (\s* in the regex)
    case "$_q" in qmd://himmel/*) return 0 ;; *) return 1 ;; esac
}

case "$tool" in
    mcp__plugin_qmd_qmd__query)
        # Single authoritative jq validation (CodeRabbit PR #1353, HIMMEL-1239)
        # — do NOT round-trip collections through shell lines: the earlier
        # extract + `[ -z ]` + `grep -vxF` form let collections:["himmel",""]
        # through, because the empty entry collapses out of the newline-joined
        # jq -r output and command-substitution trailing-newline stripping, so
        # `qmd_bad` ended up empty and the deny never fired (an empty-string
        # collection can mean "all collections" to qmd — a PHI-egress path).
        # This one check subsumes: non-array (was CR round 1 codex-2),
        # unscoped/empty array, AND any non-"himmel"/blank entry — matches the
        # Python qmd_scope_reason() query branch exactly.
        if ! printf '%s' "$input" | jq -e '(.tool_input.collections) | (type=="array") and (length>0) and (all(.=="himmel"))' >/dev/null 2>&1; then
            deny "qmd query 'collections' must be a non-empty JSON array of only \"himmel\" on the GLM lane (HIMMEL-1239) — no blank/other entries."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__get)
        qmd_file=$(printf '%s' "$input" | jq -r '.tool_input.file // empty' 2>/dev/null || true)
        if [ -z "$qmd_file" ] || ! qmd_himmel_scoped "$qmd_file"; then
            deny "qmd get on the GLM lane requires a fully-qualified qmd://himmel/... path (v1 allow-list, HIMMEL-1239) — bare paths and #docids are cross-collection-ambiguous and denied fail-closed."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__multi_get)
        qmd_pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // empty' 2>/dev/null || true)
        if [ -z "$qmd_pattern" ]; then
            deny "qmd multi_get on the GLM lane requires a qmd://himmel/... pattern (HIMMEL-1239)."
        fi
        # Root-cause fix (CR round 4, HIMMEL-1239): this is the 4th finding
        # rooted in the same mismatch — bash word-splitting (the prior
        # `IFS=',' for qmd_seg in $qmd_pattern` loop) DROPS empty
        # comma-separated fields, so a trailing comma ("a.md,"), a leading
        # comma (",a.md"), and adjacent commas ("a,,b") all lost their empty
        # segment and passed despite containing one. Rather than patch the
        # split mechanism again, replace it: awk -F',' preserves empty fields
        # (NF counts them), making this PROVABLY equivalent to the Python
        # qmd_scope_reason() multi_get branch (`[s.strip() for s in
        # pattern.split(",")]` + a full-match check on every segment, denying
        # on any empty/non-"qmd://himmel/" segment). No IFS/set -f/for-loop
        # left to diverge from Python's split semantics.
        if ! printf '%s' "$qmd_pattern" | awk -F',' '{
                if (NF==0) exit 1
                for (i=1;i<=NF;i++) {
                    s=$i
                    gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
                    if (s !~ /^qmd:\/\/himmel\//) exit 1
                }
            }'; then
            deny "qmd multi_get on the GLM lane requires a non-empty comma list where EVERY segment is a fully-qualified qmd://himmel/... path (HIMMEL-1239) — no empty/blank segments."
        fi
        exit 0
        ;;
    mcp__plugin_qmd_qmd__*)
        # status (no scoping input) and any other/future qmd tool: scope
        # cannot be positively determined from the tool-call JSON -> deny
        # fail-closed (HIMMEL-1239).
        deny "qmd tool '$tool' has no collection-scoping input the GLM lane can verify — denied fail-closed (HIMMEL-1239)."
        ;;
    mcp__*) deny "MCP tool '$tool' is blocked on the GLM lane." ;;
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Lower-case + flatten newlines TO ';' — a newline separates commands exactly
# like ';' does, so flattening to spaces (the sibling hooks' shape) UNDER-blocks:
# a two-line "gh pr view 1\ngh pr merge 1" would read as one command and the
# merge would slip through as an "argument". Flattening to ';' keeps command
# boundaries visible to the (^|[;&|(]) anchor. Cost (accepted, fail-closed): a
# quoted commit-message LINE that STARTS with a blocked verb ("…\ngit push
# later") now over-blocks — pinned by test; mid-line prose stays allowed.
#
# HIMMEL-2528 round 5, codex-1 — THE TWIN. This flattening is the same `tr` the
# anchor class uses, and it had the same continuation gap: `git \<newline>push
# origin main` measured rc=0 ALLOW here while the plain `git push origin main`
# bash actually runs measured rc=2, because gp_shape/gu_shape want `git` and
# the verb in ONE segment and the `;` split them. Every shape matcher below
# (gp_/gu_/gh_/net_) reads cmd_lc, so all four were reachable this way.
#
# It is fixed with the SAME shared join_line_continuations(), placed upstream
# of the flattening exactly as in the anchor class — not a second joiner. A
# divergent copy is the defect class this ticket keeps re-finding: round 3
# normalized quoting for class (ii) and left class (i)'s identical need
# unserved for a whole round, and this PR's own design note says a fix applied
# to one member of a twin pair is HALF A FIX.
#
# FACT, not a safety argument: the GLM lane is currently dropped, so nothing
# routes through these arms today. That is why this is a twin fix and not an
# incident — it is NOT why leaving it would have been acceptable. A fence left
# rotten while its lane is dormant is simply a fence that fails the day someone
# re-enables the lane.
#
# Direction note: the join also removes a FALSE DENY. `gh \<newline>issue list`
# used to deny because the split hid the `gh issue` carve-out from gh_allow
# while gh_shape still counted the `gh`; joined, it reads as the `gh issue list`
# bash really runs and is allowed by design. Judging what the shell assembles is
# the point of the join in both directions — pinned by a case.
cmd_joined=$(printf '%s' "$cmd" | join_line_continuations)
cmd_lc=$(printf '%s' "$cmd_joined" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

# Command-position matcher: start-of-command or right after ; & | ( —
# deliberately NOT space/quote, so prose inside a commit message ("… git push
# …") does not false-block. Env-prefixed `FOO=1 git push` is therefore missed:
# accepted limitation, tripwire-backstopped (see header).
#
# Occurrence counter (same command-position wrapper). grep -c counts
# LINES, and cmd_lc is flattened to one line, so -c undercounts a compound with
# two command-position matches — count PER-MATCH via grep -oE | wc -l instead.
# grep exits 1 on zero matches; `|| true` keeps that from tripping errexit
# inside the assignment's command substitution. $(( )) strips wc's whitespace.
count_cmd() {
    local n
    n=$(printf '%s' "$cmd_lc" | grep -oE "(^|[;&|(])[[:space:]]*($1)" | wc -l) || true
    printf '%s' "$((n))"
}

# --- Deny-arm count form + session grant-consult (escalation channel, HIMMEL-654) ---
# Each command-text deny arm is a total-vs-allowed COUNT (never an inline deny):
#   git-push / git-url / network — builtin allowed 0 (no carve-out);
#   gh — builtin allowed = the issue-ops + pr/run-reads carve-out (HIMMEL-675).
# The subcommand-position shapes below are unchanged from the pre-grant arms
# (push flag-tolerant; git-url = remote set-url OR config…url OR-ed into ONE
# count; gh carve-out; network CLIs). A per-session grant in
# ${GLM_SESSION_DIR}/grants.jsonl can widen ONE arm's allowed count by folding
# its pattern into a SINGLE alternation (never a sum — F1), TTL- and use-bounded,
# fail-closed: an unset/absent grants file or any invalid grant line leaves the
# arm at its builtin allowance and it still denies.
gp_shape='git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'
gu_shape='(git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url|git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[a-z-]+)*[[:space:]]+[^[:space:];&|]*url)'
gh_shape='gh([[:space:]]|$)'
gh_allow='gh[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))'
net_shape='(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)([[:space:]]|$)'

gp_total=$(count_cmd "$gp_shape"); gp_allowed=0
gu_total=$(count_cmd "$gu_shape"); gu_allowed=0
gh_total=$(count_cmd "$gh_shape"); gh_allowed=$(count_cmd "$gh_allow")
net_total=$(count_cmd "$net_shape"); net_allowed=0

# F9 fast path: every arm satisfied by builtins alone -> allow WITHOUT reading
# grants.jsonl, so a builtin-allowed command never consults or consumes a grant.
if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    exit 0
fi

# Some arm exceeds its builtin allowance -> consult per-session grants (fail-closed).
# gp_alt/gu_alt/gh_alt/net_alt accumulate valid grant patterns per arm ('|'-joined,
# no associative arrays); valid_grants accumulates "grant_id <pattern>" lines for
# the consumption-append pass. A grant is skipped (as if absent) if it is not a
# well-formed grant line, has an unknown arm, fails the deny-shape anchor / has an
# unbounded prefix, is expired, or is used up.
gp_alt=""; gu_alt=""; gh_alt=""; net_alt=""; valid_grants=""
grants_file="${GLM_SESSION_DIR:-}/grants.jsonl"
if [ -n "${GLM_SESSION_DIR:-}" ] && [ -f "$grants_file" ]; then
    # Read the ledger ONCE and parse from the in-memory copy so the per-line loop
    # never re-opens the file; the consumption append below is a separate, later
    # pipeline, so there is no read/write overlap on grants.jsonl.
    grants_data=$(cat "$grants_file")
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%S)
    while IFS= read -r gline; do
        [ -z "$gline" ] && continue
        gobj=$(printf '%s' "$gline" | jq -c 'select(.type=="grant")' 2>/dev/null) || continue
        [ -z "$gobj" ] && continue
        garm=$(printf '%s' "$gobj" | jq -r '.arm // empty' 2>/dev/null) || continue
        gpat=$(printf '%s' "$gobj" | jq -r '.pattern // empty' 2>/dev/null) || continue
        gmax=$(printf '%s' "$gobj" | jq -r '.max_uses // empty' 2>/dev/null) || continue
        gid=$(printf '%s' "$gobj" | jq -r '.grant_id // empty' 2>/dev/null) || continue
        gexp=$(printf '%s' "$gobj" | jq -r '.expires_at // empty' 2>/dev/null) || continue
        if [ -z "$garm" ] || [ -z "$gpat" ] || [ -z "$gmax" ] || [ -z "$gid" ] || [ -z "$gexp" ]; then continue; fi
        case "$garm" in git-push|git-url|gh|network) ;; *) continue ;; esac
        case "$gmax" in ''|*[!0-9]*) continue ;; esac
        [ "$gmax" -gt 0 ] || continue
        [ "${#gexp}" -ge 19 ] || continue
        if ! [[ "$now_iso" < "${gexp:0:19}" ]]; then continue; fi          # expired
        if printf '%s' "$gpat" | grep -qE '^\.[*+]'; then continue; fi      # unbounded prefix (F2)
        # per-arm deny-shape anchor (F8): reject a grant whose pattern is not
        # anchored on THIS arm's deny shape (a git-push grant must carry a push
        # token; a git-url grant a url token; gh/network the family verb).
        case "$garm" in
            gh)
                printf '%s' "$gpat" | grep -qE '^gh(\[\[:space:\]\]|[[:space:]])' || continue ;;
            network)
                printf '%s' "$gpat" | grep -qE '^\(?(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)' || continue ;;
            git-push)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE '(\[\[:space:\]\]|[[:space:]]|\|\)|\+)push' || continue ;;
            git-url)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE 'url' || continue ;;
        esac
        gused=$(printf '%s\n' "$grants_data" | grep -c "\"type\":\"consumption\",\"grant_id\":\"$gid\"" || true)
        gused=${gused:-0}
        [ "$gused" -lt "$gmax" ] || continue                                # exhausted
        case "$garm" in
            git-push) gp_alt="${gp_alt:+$gp_alt|}$gpat" ;;
            git-url)  gu_alt="${gu_alt:+$gu_alt|}$gpat" ;;
            gh)       gh_alt="${gh_alt:+$gh_alt|}$gpat" ;;
            network)  net_alt="${net_alt:+$net_alt|}$gpat" ;;
        esac
        valid_grants="${valid_grants}${gid} ${gpat}
"
    done <<< "$grants_data"
fi

# Recompute each still-failing arm's allowed as ONE alternation (builtin|grant)
# — never a sum (F1). Arms with no builtin carve-out omit the builtin term.
if [ -n "$gp_alt" ]; then gp_allowed=$(count_cmd "$gp_alt"); fi
if [ -n "$gu_alt" ]; then gu_allowed=$(count_cmd "$gu_alt"); fi
if [ -n "$gh_alt" ]; then gh_allowed=$(count_cmd "($gh_allow)|($gh_alt)"); fi
if [ -n "$net_alt" ]; then net_allowed=$(count_cmd "$net_alt"); fi

if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    # Honored: append one consumption line per valid grant whose pattern matched
    # this command (append-only — existing lines are never rewritten).
    con_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s' "$valid_grants" | while read -r vgid vpat; do
        [ -z "$vgid" ] && continue
        if [ "$(count_cmd "$vpat")" -gt 0 ]; then
            printf '{"type":"consumption","grant_id":"%s","ts":"%s"}\n' "$vgid" "$con_ts" >> "$grants_file"
        fi
    done
    exit 0
fi

# Still over allowance after grants -> deny the offending arm (message per arm).
if [ "$gp_total" -gt "$gp_allowed" ]; then
    deny "git push is blocked on the GLM lane (commit locally; the parent session pushes)."
fi
if [ "$gu_total" -gt "$gu_allowed" ]; then
    deny "rewriting git remote/push URLs is blocked on the GLM lane: a worker repointing a remote is outside its brief, and this hook is the layer that says so (HIMMEL-1961 removed the pushurl tripwire that used to sit behind it)."
fi
if [ "$gh_total" -gt "$gh_allowed" ]; then
    deny "gh is limited on the GLM lane: issue ops + pr/run reads; PR mutations belong to the parent session."
fi
if [ "$net_total" -gt "$net_allowed" ]; then
    deny "network CLIs are blocked on the GLM lane (chores are repo-local)."
fi

exit 0
