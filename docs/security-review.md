# Security-review playbook (HIMMEL-176)

The `security-reviewed` pre-push hook (`scripts/hooks/check-security-reviewed.sh`) gates pushes on a `Security reviewed: <token>` attestation in a commit body or PR description whenever the diff vs `origin/main` touches non-docs code. The hook does NOT run the review itself — that would introduce a new headless-Claude call and conflict with [HIMMEL-128](../CLAUDE.md#claude-invocation-billing-himmel-128). The operator runs the review on demand using whichever mechanism fits the change, then attests the result.

This file is the recommended playbook for picking a review method and writing the attestation line. For *after* something sensitive has already been committed/pushed (token, bot username, chat/user id, PII), see the [leak-scrub runbook](leak-scrub-runbook.md).

## When does the gate fire?

Pre-push, during the pre-push stage of `.pre-commit-config.yaml` (currently registered immediately after `platforms-tested`, but execution order across the pre-push stage is not load-bearing — independent gates). Triggers when the diff vs `origin/main` contains any non-docs file (everything outside `*.md`, `*.txt`, `docs/`, `handovers/`).

Docs-only diffs are skipped — the same shape used by `check-cr-before-push.sh`.

## Attestation tokens

Pick one. Add to a commit body in the push range OR to the PR description.

| Token | Use when |
|---|---|
| `manual` | Operator did a focused security read of the diff (input handling, authn/authz, secrets exposure, command injection, SSRF, deserialization, path traversal). Best for small/medium diffs. |
| `claude-code-security-review` | Operator invoked `anthropics/claude-code-security-review` (slash command from the upstream repo, or the GitHub Action against a draft PR). Best for medium/large diffs where the focused prompt is worth the extra tokens. |
| `pr-review-toolkit` | Operator ran `/pr-check` or `/pr-review-toolkit:review-pr` and the fanout included a reviewer covering the security lens. The existing multi-agent CR already includes `silent-failure-hunter` which catches some security-class issues; this token is for cases where the operator explicitly verified the security coverage. |
| `ad-hoc` | Informal review — the diff is small, the surface is well-understood, the operator made a judgement call. Use sparingly; prefer `manual` for anything non-trivial. Also covers "no-security-surface" cases (e.g. comment-only rename, internal test fixture change, log-message wording) — use `ad-hoc` with a 1-line rationale in the same commit body. |

(`n/a` was considered as a no-surface token but rejected — the literal string `n/a` appears naturally inside file paths and gameable substrings. Use `ad-hoc` for low-risk diffs or the docs-only fast-path / `[skip security-review]` marker for clearly-not-relevant cases.)

Tokens must be followed by whitespace, end-of-line, or one of `[.,;]`. Substring gaming (`manualish`, `please-manual-do`) does NOT pass — the smoke tests cover this explicitly.

## Example commit-message attestation

```
fix(auth): HIMMEL-N escape user input in error message

User-supplied identifier was rendered into the error message via
naive string concatenation; switched to %-quoted format. Reviewed
the rest of the error-rendering surface for the same pattern.

Security reviewed: manual

Refs: HIMMEL-N
```

`Security reviewed:` is case-insensitive. Whitespace before the token is allowed.

## Example PR-body attestation

If the commit messages don't carry the line, the hook falls back to `gh pr view --json body` and matches there. Add a section to the PR description:

```
## Security review

Security reviewed: claude-code-security-review

Ran `anthropics/claude-code-security-review` against the diff
(commit `<sha>`). 0 Critical, 1 Minor (out-of-scope log-format
suggestion, filed as HIMMEL-N). Re-ran after the Minor; clean.
```

## Bypass

For emergencies or when the gate is wrong:

- **Per-push env bypass**: `SKIP_SECURITY_REVIEW=1 git push ...` — logs a `WARNING: confirm security review ran out-of-band before merge`. Document the bypass in the PR description.
- **Skip marker in commit msg**: include `[skip security-review]` in any commit message in the push range. Same warning shape.
- **All hooks**: `git push --no-verify ...` — skips every pre-push hook, including `code-review-before-push` and `platforms-tested`. Use only when no other gate matters.

## Relationship to the other gates

| Gate | Layer | What it catches |
|---|---|---|
| `gitleaks` | pre-commit | Hardcoded secrets in the diff |
| `code-review-before-push` | pre-push | Multi-agent CR (correctness, code quality, silent failures) |
| `security-reviewed` | pre-push | **THIS** — security-lens attestation (operator-driven) |
| `platforms-tested` | pre-push | Cross-platform behaviour (shell/script changes) |

Each is a self-attestation OR an in-session check — none of them runs headless Claude. The pattern is: operator decides WHEN and HOW, the gate enforces that the decision was made consciously before push.

## Recommended review checklist (when using `manual`)

For each non-docs file touched by the diff:

1. **Input handling** — does any user-supplied value (HTTP param, env var, file content, CLI flag) reach an interpolation site (SQL, shell, HTML, regex, file path, log format string) without escaping?
2. **Authn/authz** — does the change add a new code path that should require authentication or authorization? Is the check present and correctly ordered (auth before action)?
3. **Secrets exposure** — does the change log, return, or store any value derived from a credential, API token, or PII? Check log lines + error messages especially.
4. **Command injection** — does any string flow into `exec`, `system`, `shell`, `eval`, or `child_process.spawn` without `shell: false` + array args?
5. **SSRF** — does the change accept a URL/host from user input and make an outbound request? Is the host validated against an allowlist or the private-IP range checked?
6. **Deserialization** — does the change `JSON.parse`, `YAML.load`, `pickle.loads`, or equivalent on untrusted input? Is the schema validated?
7. **Path traversal** — does any user-supplied value flow into a file-system path? Is `realpath -m` (or equivalent) used to canonicalise + verify the result is inside an allowed root?
8. **Race conditions** — does any new code touch a shared resource (file, lockfile, DB row) without a lock or with a lock that has a TOCTOU window?

If any answer is "yes, and I'm not 100% sure the fix is right", file a follow-up ticket BEFORE attesting. The attestation is a record of conscious review, not a claim of perfection.

## Why this pattern (and not a literal upstream-action wrapper)?

[HIMMEL-128](../CLAUDE.md#claude-invocation-billing-himmel-128) splits headless Claude calls onto a separate Agent SDK credit bucket (announced for 2026-06-15; **currently PAUSED by Anthropic as of 2026-06-21** — the preference is kept because the split is volatile and may re-activate). Wrapping `anthropics/claude-code-security-review` as a literal pre-push hook would fire a headless Claude call on every push, against the same bucket — at scale, that bucket would be the bottleneck.

Lean-invoke (operator runs review on demand) + structural attestation gate (push blocked without the line) gives the same enforcement strength without the headless cost. The trade-off: the operator owns picking the right review method per diff. The recommended-tokens table above is the playbook.
