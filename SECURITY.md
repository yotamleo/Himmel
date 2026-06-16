# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability):
open the repository's **Security** tab → **Report a vulnerability**. This
opens a private advisory visible only to you and the maintainers.

Include where relevant:

- A description of the issue and its impact.
- Steps to reproduce (a minimal proof of concept helps).
- Affected files, commands, or configuration.

## What to expect

This is a solo-operator-first project, so response is best-effort:

- **Acknowledgement** within ~7 days.
- A fix or mitigation plan for confirmed issues, with credit to the reporter
  if desired.

## Scope notes

himmel is a harness that runs Claude Code as an orchestrated agent. A few
areas are intentionally security-relevant — please pay particular attention
to them when reporting:

- **Guardrail / hook bypasses** — the PreToolUse hooks and pre-commit /
  pre-push gates in `scripts/hooks/` and `.pre-commit-config.yaml` are the
  structural enforcement layer. A way to defeat `block-read-secrets`,
  `block-edit-on-main`, or the commit/push gates is in scope.
- **Secret handling** — anything that causes credentials (`.env`, API keys,
  tokens) to be read, logged, or committed.

Vendored upstream plugins under `marketplace/plugins/` (and their forks)
carry their own upstream licenses; vulnerabilities in unmodified upstream
code are best reported to the upstream project, but feel free to flag them
here too.
