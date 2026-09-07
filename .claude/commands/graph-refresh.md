---
description: One-shot operator refresh of the luna and/or himmel graphify graphs — one refresh-graph-map.sh run per corpus.
argument-hint: [luna|himmel|both] [--vault <path>] [--dry-run]
---

Operator one-shot graphify refresh for the **luna** and/or **himmel** corpora
(HIMMEL-1644). Fires `refresh-graph-map.sh` per corpus **serially** (luna then
himmel), with the SAME per-corpus argument sets the daily cadence
(`graphmap-cadence.sh`, HIMMEL-829) uses — the title/slug/tag literals, the
luna-vs-himmel corpus-root asymmetry (luna extracts the vault, himmel extracts
the repo, BOTH publish their curated MOC into the vault's `60-Maps/`), and the
fixed `claude-cli` backend.

This is the on-demand path the cadence is the scheduled path for. It owns NO
safety itself — the runner (`refresh-graph-map.sh`) owns the fence (scratchpad
copy, never a live vault), the per-out-dir promote lock (HIMMEL-910), the
freshness manifest (HIMMEL-907), and the host-path guard (HIMMEL-1134). This
command just resolves the vault, builds the per-corpus argv, and fires.

Run:

```bash
bash scripts/graphify/graph-refresh.sh $ARGUMENTS
```

`$ARGUMENTS` stays UNQUOTED by design — this is the established repo convention: every `bash scripts/*.sh $ARGUMENTS` invocation in `.claude/commands/` is unquoted, and `handover-commit.md` records the identical rationale ("forwarded UNQUOTED so trailing flags are parsed as flags, not appended"). Claude Code's slash-command PREPROCESSOR substitutes `$ARGUMENTS` with the literal text the operator typed (it is a preprocessor placeholder, not a shell variable — per `luna-upgrade.md`), so the operator's own quotes (`--vault "C:/my path"`) pass through verbatim and are honored by bash; the argument string therefore reaches graph-refresh.sh byte-intact, split into exactly the tokens the operator delimited. Quoting it (`"$ARGUMENTS"`) would instead collapse the whole list into ONE token and break flag parsing for the common `/graph-refresh both --dry-run` form (the wrapper would receive the single positional arg `both --dry-run` and reject it). Forward the operator arguments exactly as typed.

Common invocations:
- `/graph-refresh` — refresh BOTH graphs (luna then himmel).
- `/graph-refresh luna` — refresh only the luna graph.
- `/graph-refresh himmel` — refresh only the himmel graph.
- `/graph-refresh both --dry-run` — preview the exact `refresh-graph-map.sh` invocations without running them.
- `/graph-refresh --vault /path/to/vault` — override the vault root (default: `$LUNA_VAULT_PATH` if set, else `<user-profile>/Documents/luna`). On the luna leg the override must resolve at/under the configured luna root; set `LUNA_VAULT_PATH` to ratify a different location.

After the refresh legs, the command prints `graphmap-cadence.sh status` so
cadence drift is visible alongside the ad-hoc refresh (advisory — a cadence
query failure never fails this command). On a successful **himmel** leg it
prints a next-step hint to run `/graph-publish` (HIMMEL-1129) to ship the
refreshed tracked `graphify-out/` — it does NOT auto-run it (that commit + push
+ PR stays an explicit operator action).

Timeout calibration lives in `refresh-graph-map.sh` (HIMMEL-1645); this command
forwards the caller's environment verbatim and does not set `GRAPHIFY_API_TIMEOUT`.

Environment:
- `LUNA_VAULT_PATH=<path>` — default vault root when `--vault` is not passed, and the configured root the luna leg's `--vault` must sit at/under.
- `GRAPH_REFRESH_RUNNER=<path>` — override the `refresh-graph-map.sh` path (tests use a fake).
- `GRAPH_REFRESH_CADENCE_SCRIPT=<path>` — override the `graphmap-cadence.sh` path whose `status` is appended.

Exit codes:
- `0` all selected corpora refreshed successfully
- `1` usage error (unknown corpus / unknown flag)
- `2` environment error (`refresh-graph-map.sh` not found, `--vault` is not a directory, or the vault preflight refused it -- PHI/denylisted/root/non-vault, HIMMEL-1644)
- `3` one or more corpus refresh legs FAILED (`refresh-graph-map.sh` exited non-zero, not a bank skip) -- investigate
- `4` no failures, but one or more legs were SKIPPED (bank at/over threshold, runner exited 3) and nothing else failed -- benign, retry later
