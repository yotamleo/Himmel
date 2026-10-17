# Console section — refused shapes and their literal retry

Read on demand from `console-template.md`. A refused SHAPE runs nothing, so retry
once with the one spelling below; a second refusal goes to `himmel-ops:stuck-playbook`.
Never reshape to dodge a guard that fired on purpose.

| Refused | Why | Retry as ONE command |
|---|---|---|
| `D=<path>; bash scripts/…/append-results.sh $D "…"` (a variable, glob or `cd … &&` in front of a gate script) | `guard-pr-check-literal` cannot resolve the script by its text | the same command with the path typed out in full, no variable: `bash scripts/handover/console-kit/append-results.sh <abs doc> "<text>"` |
| `git -C <primary> fetch` / any git write aimed at the primary checkout | `block-write-into-main-checkout` | `git fetch origin main` from your own worktree (the object store is shared) |
| `git hook run <hook> --to-stdin=…` or any option that runs a program | `guard-pr-check-literal` | `git hook run <hook>` with the options dropped, as its own command |
| `grep -E '<path-a>\|<path-b>'` naming a guarded script | same | one literal `git grep -n <one path>` per call |
| jira write behind a pipe, `2>&1 \| tail`, a loop, `$J` or a heredoc | `block-jira-compound-write` | `node <primary>/scripts/jira/dist/index.js <op> … --desc-file <file>` (absolute path, bare) |
| `jira create` body refused (no Impact / What / Why / Plan / DoD / Agent detail, or a Plan or DoD with only the placeholder line) | `plain-block` | `node <primary>/scripts/jira/dist/index.js create --type Task --skeleton`, fill the printed six headings into a file, then `create … --desc-file <file>` |
| `jira create` refused with `ticket has no home` (no `--sector`, or neither `--parent` nor `--labels standalone`) | `plain-block` | add `--sector "<Sector>"` and `--parent <EPIC-KEY>` or `--labels standalone` to the same `create` |
| a command whose text names the bus root `himmel/bus` (a `himmel/*` glob that spans it, or `bus register\|bind\|rebind`) | `guard-bus-store` | name the one file you need by its full path, not a glob over `himmel/`; leave the bus store and identity verbs to the launcher |
| `JIRA_BASE_URL is not set` from a worktree | an exported empty value used to shadow `.env` | fixed; rebuild `dist/` in the primary checkout (`npm run build` in `scripts/jira`) |
