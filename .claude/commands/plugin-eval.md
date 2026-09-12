---
description: On-demand, bank-preflighted `claude plugin eval` run for one suite of one plugin
argument-hint: <plugin> <suite>
---

Run exactly one eval suite for one plugin. This is on-demand, billed
(HIMMEL-128) — never wired into CI or a cadence, and never run "all suites"
in one shot.

**Usage:** `/plugin-eval <plugin> <suite>` — both arguments required.
`<plugin>` is a directory under `marketplace/plugins/` (`obsidian-triage`,
`qmd`). `<suite>` is a case directory name under that plugin's `evals/`
(`telegram-clip-basic`, `read-link-vault-first`, `collections-scoping`).
Reject any other argument shape (missing arg, or a literal `all`) without
running anything.

Steps:

1. **Preflight — bank check and version floor, before anything else.**
   `scripts/plugin-eval-preflight.sh` wraps both checks (it calls
   `bank-preflight.sh` directly, mirroring `scripts/cr/hermes-critic.sh`'s
   own direct-call convention, then checks `claude --version` against the
   2.1.269 floor `claude plugin eval` needs) and never invokes
   `claude plugin eval` itself — this command gates that invocation on its
   exit code:
   ```bash
   bash scripts/plugin-eval-preflight.sh
   ```
   Non-zero exit → the script has already printed the refusal reason on
   stderr (bank at/over cap, or the version floor unmet). Report it and
   stop — never re-run preflight "to confirm", never fall back to running
   anyway.

2. **Resolve the per-suite tool grant and scaffold flag.** `claude plugin eval`
   never stops to ask permission — a gated tool (`Bash`, `Write`, `Edit`,
   `WebFetch`, `WebSearch`) that isn't explicitly granted with `--allow-tools`
   is removed from the run entirely, so the grant IS the permission boundary
   here (this plugin subcommand has no `--permission-mode` flag at all —
   confirmed against `claude plugin eval --help` on 2.1.269 — so "explicit
   permission mode" for this command means the narrowest `--allow-tools` list
   each suite actually needs, never a blanket grant, and `--trust-plugin` only
   because the plugin's own code and suite are ours). A case whose `case.yaml`
   declares `context.scaffold_script` also needs `--scaffold` — it is not run
   otherwise (the case then executes against an unseeded workspace and every
   grader misses) — trust it here for the same reason as `--trust-plugin`: the
   script is ours. Pick the grant by `<plugin>/<suite>`:
   - `obsidian-triage/telegram-clip-basic` → `--allow-tools Bash --scaffold`
     (its `fixture.sh` seeds `vault-fixture/`)
   - `obsidian-triage/read-link-vault-first` → `--allow-tools Bash "WebFetch(domain:example.com)"`
     (no `--scaffold`: its fixture is a committed `context.add_dirs` directory,
     not a script)
   - `qmd/collections-scoping` → no `--allow-tools` at all (the suite's
     `query` call hits a mocked MCP tool, which needs no grant; default
     `--mocks record` applies)

   Any `<plugin> <suite>` pair outside this list isn't a suite this command
   knows about — refuse rather than guessing a grant.

3. **Run.** One suite, one invocation, `--trust-plugin` (the plugin and its
   suite are ours) and `--no-publish` (keep the HTML report local — this is
   a local on-demand check, not something to publish to claude.ai):
   ```bash
   # headless-claude-ok: on-demand eval, bank-preflighted, explicit permission mode (HIMMEL-2931)
   claude plugin eval marketplace/plugins/<plugin> --case <suite> --trust-plugin --no-publish <resolved-grant-and-scaffold-from-step-2>
   ```
   Substitute `<plugin>`, `<suite>`, and the resolved flags from step 2 (drop
   `--allow-tools` entirely for `qmd/collections-scoping`) — never pass a
   glob, never omit `--case` to run the whole suite tree.

4. **Report.** Print the suite's WITH / W/OUT / Δ line (or WITH-only score
   when `--ablation none` applied) and the exit code verbatim. Do not re-run
   to chase a different number — a bad result is a finding, not a retry
   loop.
