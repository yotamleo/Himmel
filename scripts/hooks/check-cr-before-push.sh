#!/usr/bin/env bash
# Pre-push hook: marker-only CR gate trigger.
#
# REDESIGN (HIMMEL-26, 2026-05-18): this hook used to spawn a print-mode
# claude subprocess to run the multi-agent review inline. That was architecturally
# wrong — nested Claude sessions are unreliable, contend for MCP / rate limits,
# and can hang the outer session that triggered the push.
#
# New design: this hook is a STATUS-CHECK TRIGGER, not an orchestrator.
# - It writes an untracked marker file under .git/cr-pending/<branch>
# - The actual review is run later, from inside the outer Claude session,
#   via the /pr-check slash command (which invokes /pr-review-toolkit:review-pr
#   directly — no nested CLI process).
# - The gate fires at `gh pr create` time via a Claude Code PreToolUse hook
#   (scripts/hooks/check-cr-marker-on-pr-create.sh), which blocks PR creation
#   while a marker exists for the current branch + HEAD.
# - /pr-check deletes the marker when the review is clean.
#
# Bypass:
#   - SKIP_CR=1 git push ...    (env-var skip; logs WARNING)
#   - git push --no-verify ...  (skip all pre-push hooks)
#
# ── CR MARKER IDENTITY CONTRACT (HIMMEL-1540 — the one model, defined once) ──
# The marker is a pending-review OBLIGATION for a proposed publication:
#   "local commit SHA S was proposed as destination ref R at push endpoint E
#    (known locally by alias N); a review of diff(B...S) in lane L is owed,
#    where B is the immutable SHA of the PUSHED remote's default-branch base
#    at write time."
# File:    $(git rev-parse --git-common-dir)/cr-pending/<destination-branch>
# Payload: "<iso-ts> | <S> | <lane> | <N> | <R> | <E> | <B>"
#   E = the credential-scrubbed URL git actually pushes to (pushurl-resolved,
#       so immune to later alias mutation — remote.<name>.url/pushurl can be
#       repointed after the push). N is kept for display only.
#   B = rev-parse of the diff base ref the lane classification used. The base
#       is the PUSHED remote's default-branch tracking ref — origin's history
#       is the wrong yardstick for any other remote (divergent origin/puborigin
#       histories: content already merged to origin/main diffs empty and would
#       skip the marker for a public push).
#
# PRODUCERS resolve (N, R, S, E) ONLY from git's per-push data — never from
# repo config (branch.<name>.remote / upstream: a spawn-* worktree has neither,
# and an explicitly-named `git push origin br` needs no upstream). The same
# datum arrives on a different carrier per invocation shape:
#   raw git hook / pre-push.legacy : N = argv[1]; E = scrub(argv[2]);
#                                    (S, R) = stdin ref lines
#                                    (the COMPLETE multi-ref stream)
#   pre-commit configured hook     : N = $PRE_COMMIT_REMOTE_NAME,
#                                    E = scrub($PRE_COMMIT_REMOTE_URL),
#                                    R = $PRE_COMMIT_REMOTE_BRANCH,
#                                    S = $PRE_COMMIT_TO_REF — FIRST ref only,
#                                    so this shape is a sentinel, not the gate;
#                                    the gate is the pre-push.legacy install
#   manual / legacy fallback       : worktree HEAD; no (N, R, E) binding —
#                                    such a marker cannot be cleared remotely,
#                                    only reminted by a real push
# CONSUMERS resolve identity ONLY from the marker payload:
#   scripts/cr/clear-cr-marker.sh  : deletes only when ls-remote(E, R) equals
#                                    the ledger-certified local branch tip —
#                                    the ENDPOINT, never the mutable alias N
#   check-cr-marker-on-pr-create.sh: keyed lookup by destination branch name
#                                    (--head or current branch); presence blocks
# Fail CLOSED whenever any of (N, R, E, B) is unavailable or unrelated.
# Round 5 rule: never add another resolution source — extend the marker
# payload and this contract instead.
#
# Note: the prior TTY-check landmine (silent no-op under pre-commit framework)
# is no longer relevant — there's no subprocess to gate on TTY. The whole
# subprocess block is gone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# default_branch() resolves the repo's protected default (main OR master,
# HIMMEL-297) used as the diff base below. Fail-closed: a missing guardrail
# substrate means we cannot compute the right base, so refuse the push.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ code-review: cannot source guardrails/lib.sh — refusing the push (fix the guardrail lib or bypass with SKIP_CR=1)" >&2
    exit 2
fi

db=$(default_branch)
diff_base=""
# Remote identity N + push endpoint E (see the contract above). argv is git's
# carrier for the raw-hook / pre-push.legacy shapes (argv[2] is the URL git
# will actually push to — pushurl-resolved); the pre-commit configured shape
# passes NO argv (pass_filenames: false) and delivers both via
# PRE_COMMIT_REMOTE_NAME / PRE_COMMIT_REMOTE_URL instead — wired in that
# branch below.
push_remote_name="${1:-}"
push_remote_url="${2:-}"

# scrub_endpoint URL — strip http(s) userinfo (embedded tokens/passwords)
# before the URL is persisted in the plaintext marker under .git. Non-http
# URLs pass through: ssh/scp-style carry no secret in the userinfo position
# (git@ is an ssh username, not a credential) and file paths have none.
scrub_endpoint() {
    case "$1" in
        http://*|https://*) printf '%s\n' "$1" | sed -E 's#^(https?://)[^/@]*@#\1#' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

resolve_diff_base() {
    if [ -n "$diff_base" ]; then
        return 0
    fi

    # The review diff must be measured against the PUSHED remote's base (see
    # the contract header, field B): for any remote other than origin, diffing
    # against origin/$db is the wrong yardstick — with divergent histories
    # (origin vs puborigin) content already merged to origin/main diffs empty
    # and would skip the marker entirely, ungating the target-repo PR. No
    # network call — the tracking ref is local; missing/unfetched fails CLOSED.
    if [ -n "$push_remote_name" ] && [ "$push_remote_name" != "origin" ]; then
        if git rev-parse --verify --quiet "refs/remotes/$push_remote_name/$db" >/dev/null; then
            diff_base="refs/remotes/$push_remote_name/$db"
            return 0
        fi
        echo "→ code-review: no tracking ref refs/remotes/$push_remote_name/$db for pushed remote '$push_remote_name' — refusing the push (the review diff must use the TARGET's base, not origin's; run: git fetch $push_remote_name, then retry; bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi

    # Resolve diff base: prefer the more up-to-date ref.
    # 'db' is the repo's protected default (main OR master, HIMMEL-297). When both
    # the local 'db' and 'origin/db' exist and local 'db' is an ancestor of
    # 'origin/db' (i.e. origin is ahead), use 'origin/db' so we don't diff against a
    # stale local copy and generate false-positive markers. No network call — git
    # merge-base --is-ancestor uses only locally-fetched refs. If neither ref
    # exists, fail CLOSED (HIMMEL-323) — see the else arm.
    if git rev-parse --verify --quiet "$db" >/dev/null && \
       git rev-parse --verify --quiet "origin/$db" >/dev/null; then
        if git merge-base --is-ancestor "$db" "origin/$db" 2>/dev/null; then
            diff_base="origin/$db"
        else
            diff_base="$db"
        fi
    elif git rev-parse --verify --quiet "$db" >/dev/null; then
        diff_base="$db"
    elif git rev-parse --verify --quiet "origin/$db" >/dev/null; then
        diff_base="origin/$db"
    else
        # Neither '$db' nor 'origin/$db' resolves: we cannot compute a diff, so we
        # cannot write a meaningful CR marker — and skipping silently would let an
        # unreviewed change reach `gh pr create` ungated. Fail CLOSED (HIMMEL-323).
        # This hook does no fetch, so an unresolvable base is a genuinely broken
        # state (a normal clone always has origin/<default>). Bypass with SKIP_CR=1.
        echo "→ code-review: no '$db' or 'origin/$db' ref — refusing the push (cannot compute diff for review; bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi
}

write_marker_for_branch() {
    local branch="$1"
    local local_sha="$2"
    local remote_ref="${3:-}"
    local changed non_docs reviewable_docs audit_kind
    local git_dir marker_path short_sha
    local endpoint="" base_sha=""

    # Skip on the protected default (main OR master) / detached HEAD — pushing the
    # default branch is blocked elsewhere and there's no meaningful diff to review.
    if [ -z "$branch" ] || [ "$branch" = "$db" ]; then
        return 0
    fi

    # Explicit skip. Keep it after the protected-default check so the empty-stdin
    # fallback preserves the original worktree-HEAD behaviour verbatim.
    if [ "${SKIP_CR:-0}" = "1" ]; then
        echo "→ code-review: SKIP_CR=1 set — skipping marker write (WARNING: review locally with /pr-check before opening PR)" >&2
        exit 0
    fi

    # Ref-derived markers must carry the remote identity, destination ref AND
    # push endpoint that will later become the PR head. Without that binding
    # clear-cr-marker.sh cannot prove the pushed-to repository still proposes
    # the ledger-reviewed tip — and the alias alone is mutable (pushurl /
    # set-url can repoint it after the push), so the endpoint must be pinned.
    if [ -n "$remote_ref" ]; then
        if [ -z "$push_remote_name" ]; then
            echo "→ code-review: pushed ref '$remote_ref' has no remote identity — refusing the push (cannot bind the CR marker to the future PR head)" >&2
            return 2
        fi
        if [ -z "$push_remote_url" ]; then
            echo "→ code-review: pushed ref '$remote_ref' has no push endpoint URL — refusing the push (the marker must pin the exact endpoint so clearance cannot be satisfied through a mutated remote alias)" >&2
            return 2
        fi
        endpoint=$(scrub_endpoint "$push_remote_url")
        case "${push_remote_name}${remote_ref}${endpoint}" in
            *'|'*|*$'\n'*)
                echo "→ code-review: remote identity/ref/endpoint contains an unsupported marker delimiter — refusing the push" >&2
                return 2
                ;;
        esac
    fi

    resolve_diff_base || return 2

    # Immutable base snapshot B (contract header): the tracking ref is mutable,
    # so record the exact SHA the lane classification below actually uses. The
    # diff runs against this SHA, not the ref name, so certificate and
    # classification cannot diverge even if the ref moves mid-hook.
    if ! base_sha=$(git rev-parse --verify "${diff_base}^{commit}" 2>/dev/null); then
        echo "→ code-review: cannot resolve diff base '${diff_base}' to a commit SHA — refusing the push (bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi

    # Skip on docs-only / merge-only diffs to avoid pointless review gating.
    # Fail CLOSED if the diff can't be computed (HIMMEL-323) — the 3-dot range needs
    # a merge base, so an orphan/unrelated-history branch makes `git diff` exit
    # non-zero. Without the guard `set -e` would abort with git's opaque exit code;
    # refuse the push with a clear rc=2 instead so an unreviewable change can't slip
    # past the CR marker ungated. A genuinely empty diff still skips below.
    if ! changed=$(git diff --name-only "${base_sha}...${local_sha}" 2>/dev/null); then
        echo "→ code-review: cannot compute diff vs ${diff_base} (${base_sha:0:8}) for ${branch} (no merge base / git error) — refusing the push (bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi
    if [ -z "$changed" ]; then
        echo "→ code-review: no diff vs ${diff_base} for ${branch} — skipping" >&2
        return 0
    fi
    # Classify the diff to pick the CR lane (HIMMEL-303):
    #   - any non-docs code  -> "full"       marker (the 6-reviewer heavy/holistic lane via /pr-check)
    #   - reviewable docs only -> "docs-audit" marker (one code-reviewer w/ docs charter via /pr-check)
    #   - handover-state only  -> no marker (personal auto-committed state, exempt — HIMMEL-142)
    # "Reviewable docs" = .md/.txt or docs/ that are NOT under handovers/. Handover
    # state stays exempt so handover/* auto-commits don't gate on a review they
    # don't need. The marker carries the lane as a 3rd field; the PR-create hook
    # parses only field 2 (the SHA), so the extra field is backward-compatible.
    non_docs=$(echo "$changed" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)
    if [ -n "$non_docs" ]; then
        audit_kind="full"
    else
        reviewable_docs=$(echo "$changed" | grep -Ev '^handovers/' | grep -E '\.(md|txt)$|^docs/' || true)
        if [ -z "$reviewable_docs" ]; then
            echo "→ code-review: handover-state-only change — skipping marker write" >&2
            return 0
        fi
        audit_kind="docs-audit"
    fi

    # Write marker. .git/ is never tracked, so this is safe to scribble in.
    # Use --git-common-dir (shared .git) NOT --git-dir (per-worktree) so a marker
    # written from one worktree is visible to PR creation from another worktree
    # or from the main repo. One marker per branch; overwrites on re-push. Fields
    # 4-7 bind the certificate to the pushed remote alias, destination ref,
    # scrubbed push endpoint and immutable diff base (contract header); legacy
    # worktree-HEAD callers leave 4-6 blank and therefore cannot clear remotely.
    # Branch names may contain '/' (e.g. feat/foo) — mkdir -p the full parent so
    # we don't trip on missing intermediate dirs.
    git_dir=$(git rev-parse --git-common-dir)
    marker_path="${git_dir}/cr-pending/${branch}"
    mkdir -p "$(dirname "${marker_path}")"
    short_sha=$(git rev-parse --short "$local_sha")
    printf '%s | %s | %s | %s | %s | %s | %s\n' "$(date -Iseconds)" "${local_sha}" "${audit_kind}" "${push_remote_name}" "${remote_ref}" "${endpoint}" "${base_sha}" > "${marker_path}"

    if [ "$audit_kind" = "docs-audit" ]; then
        echo "→ code-review: docs-audit marker written for ${branch} (HEAD=${short_sha}). Run /pr-check (docs-audit lane: one code-reviewer with the docs charter) before opening the PR — docs are never zero-CR (HIMMEL-303)." >&2
    else
        echo "→ code-review: marker written for ${branch} (HEAD=${short_sha}). Run /pr-review-toolkit:review-pr (or /pr-check) in your Claude session before opening the PR." >&2
    fi
}

# certify_pushed_ref REMOTE_REF LOCAL_SHA
# The ONE identity gate every ref-derived marker write passes through — shared
# by the stdin loop below (raw .git/hooks/pre-push install + direct-invocation
# tests) and the PRE_COMMIT_* path further down (pre-commit framework install,
# HIMMEL-1540), so the two paths cannot drift. Centralises:
#   - skip non-head refs (tags) and all-zero (delete) pushes — no marker;
#   - skip the protected default branch (gated elsewhere);
#   - honour SKIP_CR=1 (exits the whole hook);
#   - refuse a renamed refspec whose local destination is absent or diverges
#     from the pushed SHA — every clearance path resolves the destination name
#     as a LOCAL branch, so the same-named local branch must later clear it.
# Returns 0 to skip-and-continue (delete / default / non-head); returns 2 on a
# refusal (caller exits); exits 0 on SKIP_CR; writes the marker + returns 0 on
# success.
certify_pushed_ref() {
    local remote_ref="$1"
    local local_sha="$2"
    local branch destination_sha

    case "$remote_ref" in
        refs/heads/*) branch=${remote_ref#refs/heads/} ;;
        *) return 0 ;;
    esac

    # A delete push names no local object. Match any all-zero object ID so this
    # stays correct in both SHA-1 and SHA-256 repositories.
    if [ -n "$local_sha" ] && [ -z "${local_sha//0/}" ]; then
        return 0
    fi

    # Pushing the protected default is gated elsewhere; nothing to review.
    if [ "$branch" = "$db" ]; then
        return 0
    fi

    # Explicit bypass — skip the whole hook. Kept before the identity checks so
    # a refspec push short-circuits exactly as the worktree-HEAD fallback does
    # inside write_marker_for_branch.
    if [ "${SKIP_CR:-0}" = "1" ]; then
        echo "→ code-review: SKIP_CR=1 set — skipping marker write (WARNING: review locally with /pr-check before opening PR)" >&2
        exit 0
    fi

    # The marker is keyed by the destination branch, and every downstream
    # clearance path resolves that name as a LOCAL branch. Refuse a renamed
    # refspec unless that local destination exists at the exact pushed SHA;
    # otherwise evidence for the same-named local branch could clear a marker
    # whose remote destination points at different, unreviewed code.
    destination_sha=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
    if [ -z "$destination_sha" ]; then
        echo "→ code-review: pushed destination '$branch' has no matching local branch — refusing the push (push the same-named local branch so CR evidence can bind to it; bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi
    if [ "$destination_sha" != "$local_sha" ]; then
        echo "→ code-review: pushed destination '$branch' resolves locally to ${destination_sha:0:8}, not pushed SHA ${local_sha:0:8} — refusing the push (CR markers cannot safely certify a divergent renamed refspec; bypass with SKIP_CR=1 or git push --no-verify)" >&2
        return 2
    fi

    write_marker_for_branch "$branch" "$local_sha" "$remote_ref" || return $?
    return 0
}

# A pre-push hook receives the refs actually being pushed on stdin. Key markers
# on each destination branch, not on the branch checked out in this worktree: the
# sanctioned push path commonly pushes a feature refspec from a checkout on main.
saw_pushed_ref=0
if [ ! -t 0 ]; then
    while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
        if [ -z "${local_ref}${local_sha}${remote_ref}${remote_sha}" ]; then
            continue
        fi
        saw_pushed_ref=1
        certify_pushed_ref "$remote_ref" "$local_sha" || exit $?
    done
fi

if [ "$saw_pushed_ref" -eq 1 ]; then
    exit 0
fi

# ── pre-commit framework integration (HIMMEL-1540) ─────────────────────────
# This hook is installed THROUGH pre-commit: .git/hooks/pre-push is a
# pre-commit-generated shim that execs `pre_commit hook-impl`. That shim reads
# git's entire pre-push stdin ITSELF (hook_impl._run_legacy does
# sys.stdin.buffer.read()) and exposes the pushed ref to hooks ONLY through
# PRE_COMMIT_* env vars. By the time this script runs under that shim stdin is
# at EOF, so the loop above saw no refs. Without this branch the legacy
# worktree-HEAD fallback below would key the marker on the checked-out branch —
# which, on himmel's documented refspec-from-primary-on-main push path, is the
# default branch, hitting the is_on_main early-exit and writing NO marker at all
# (Direction A: fail-OPEN, the defect this ticket exists to close).
#
# Reconstruct the single ref pre-commit exposes. The complete ref stream is
# certified earlier by the Himmel-owned executable pre-push.legacy migration
# hook installed by setup. pre-commit forwards raw stdin to that hook before it
# runs configured hooks. PRE_COMMIT_REMOTE_BRANCH is the full destination ref.
if [ -n "${PRE_COMMIT_REMOTE_BRANCH:-}" ]; then
    pc_remote_ref="$PRE_COMMIT_REMOTE_BRANCH"
    # In this shape the remote identity arrives via env, not argv: pre-commit
    # sets PRE_COMMIT_REMOTE_NAME and PRE_COMMIT_REMOTE_BRANCH together under
    # one conjunction (run.py), so it is always present on this branch. Leg-44
    # regression: reading only argv here refused EVERY framework-shaped push
    # with a false "no remote identity". argv still wins when a caller set it.
    if [ -z "$push_remote_name" ]; then
        push_remote_name="${PRE_COMMIT_REMOTE_NAME:-}"
    fi
    # Same conjunction also guarantees PRE_COMMIT_REMOTE_URL — the push
    # endpoint E, pushurl-resolved by git before the hook chain ran.
    if [ -z "$push_remote_url" ]; then
        push_remote_url="${PRE_COMMIT_REMOTE_URL:-}"
    fi
    # PRE_COMMIT_TO_REF is the pushed SHA (local_sha) for the normal update /
    # new-branch cases. pre-commit OMITS to_ref only in the rare "push the whole
    # tree including the root commit" case (all_files=True), where it still sets
    # PRE_COMMIT_LOCAL_BRANCH — resolve that ref to recover the SHA instead of
    # guessing or skipping.
    pc_local_sha="${PRE_COMMIT_TO_REF:-}"
    if [ -z "$pc_local_sha" ] && [ -n "${PRE_COMMIT_LOCAL_BRANCH:-}" ]; then
        pc_local_sha=$(git rev-parse --verify "$PRE_COMMIT_LOCAL_BRANCH" 2>/dev/null || true)
    fi
    if [ -z "$pc_local_sha" ]; then
        # No pushed SHA => no meaningful certificate. Silently keying the marker
        # on a guessed SHA is the same fail-OPEN class this ticket closes, so
        # fail CLOSED (HIMMEL-323).
        echo "→ code-review: pre-commit reported a push to ${pc_remote_ref} but no pushed SHA is available (PRE_COMMIT_TO_REF unset and PRE_COMMIT_LOCAL_BRANCH unresolvable) — refusing the push (bypass with SKIP_CR=1 or git push --no-verify)" >&2
        exit 2
    fi

    legacy_git_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
    legacy_hook="${legacy_git_dir:+$legacy_git_dir/hooks/pre-push.legacy}"
    # Installation is trusted as execution here because every shim `pre-commit
    # install` generates passes --hook-dir, and hook_impl only skips the legacy
    # hook when --hook-dir is absent (a config-based git-2.54+ install shape no
    # pre-commit release generates today). If pre-commit's installer ever
    # changes, this check must demand execution EVIDENCE, not presence.
    if [ -n "$legacy_hook" ] && [ -x "$legacy_hook" ] && grep -Fq '# himmel-cr-ref-stream-v1' "$legacy_hook"; then
        echo "→ code-review: complete pushed-ref stream certified by the Himmel pre-push.legacy hook (pre-commit first ref: ${pc_remote_ref})." >&2
        exit 0
    fi

    # Without the owned migration hook, PRE_COMMIT_* describes exactly ONE ref
    # pair and there is no way to distinguish a single-ref push from a partial
    # view of a multi-ref push. Self-heal: install the ref-stream hook NOW so
    # the very next push receives the complete raw stream, still certify the
    # first ref, and refuse THIS push — its stream is already collapsed, and
    # partial evidence must never read as a complete certificate. The installer
    # refuses to overwrite a non-Himmel pre-push.legacy; that case keeps the
    # manual-merge instruction. --no-verify remains the explicit operator bypass.
    retry_hint="the Himmel pre-push.legacy ref-stream hook was just installed — retry the push and it will pass this gate"
    if ! bash "$SCRIPT_DIR/install-cr-pre-push-legacy.sh" >&2; then
        retry_hint="automatic install failed (see above) — run scripts/hooks/install-cr-pre-push-legacy.sh (or scripts/setup.sh), then retry"
    fi
    certify_pushed_ref "$pc_remote_ref" "$pc_local_sha" || exit $?
    echo "→ code-review: pre-commit exposes only the first pushed ref (${pc_remote_ref}), so this push's complete ref stream cannot be certified — refusing after certifying that first ref. ${retry_hint}; bypass with SKIP_CR=1 or git push --no-verify." >&2
    exit 2
fi

# Fallback for manual/legacy callers that provide no pushed refs: preserve the
# original worktree-HEAD behaviour.
rc=0
branch=$(_branch) || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "→ code-review: cannot resolve current branch (lib.sh::_branch rc=2) — refusing the push (fix the repo state or bypass with SKIP_CR=1)" >&2
    exit 2
fi
if [ -z "$branch" ] || is_on_main; then
    exit 0
fi
head_sha=$(git rev-parse HEAD)
write_marker_for_branch "$branch" "$head_sha" || exit $?
exit 0
