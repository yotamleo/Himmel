# Per-ticket usage records (HIMMEL-3994)

One append-only record per ticket answers "what did it cost and how many review
rounds did it take". It joins two computations that previously lived apart and
is computed once; consumers read the store, never transcript JSONL. The PR/CI
join (`gh`) is deliberately not here: it is a follow-up that must fail closed
by construction.

| Input | Source |
|---|---|
| per-session tokens | `scripts/lib/bank-attribution.sh` output (HIMMEL-2764), reused not re-parsed |
| CR rounds, verdicts, estimated critic tokens | the CR critic ledger (`scripts/cr/ledger-append.sh`) |

## Commands

```
bash scripts/usage/usage-compute.sh --range HIMMEL-3990..HIMMEL-4020   # append changed records
bash scripts/usage/usage-compute.sh --tickets HIMMEL-3994 --print      # stdout only, no store
bash scripts/usage/usage-read.sh [--ticket KEY] [--all]                # latest per ticket / every version
```

Flags: `--projects` (default `~/.claude/projects`), `--ledger` (default the
repo's `cr-critic-scores.jsonl`), `--store` (default `~/.himmel/state/usage`,
or `HIMMEL_USAGE_STORE`), `--since`, and one selector, `--range` or
`--tickets` (never both). `--range` is `KEY-a..KEY-b` with one key prefix;
`--tickets` is comma-separated `KEY-n` entries and must match at least one
ticket; `--since ""` is rejected. The store is `<store>/records.jsonl`,
outside the tree.

## Join keys

- **Ticket** is the key. A session joins by its custom title starting `KEY-n`;
  a CR ledger row joins by the `KEY-n` inside its branch name.
- A session whose title contains `console` is kind `console`; `judge` is kind
  `judge`; everything else is `leg`.
- A console spans many tickets, so its title does not name one. Console
  sessions with no `KEY-n` prefix go to the pseudo-ticket `_console` as a pool,
  **with no allocation to tickets** (an allocation rule would change every
  ticket's record whenever the range changes). Sessions with no key and no
  `console` go to `_unattributed`. A console titled with a ticket key stays
  under that ticket, in `totals.console`.

## Record (one JSON object per line, keys sorted)

| Field | Meaning |
|---|---|
| `schema` | `1` |
| `ticket` | `KEY-n`, `_console` or `_unattributed` |
| `legs[]` | per session: `name`, `kind`, `turns`, `input`, `cache_read`, `cache_create`, `output`, `sub_*` (same five for its subagents) |
| `totals.leg`, `totals.console`, `totals.judge` | the same ten counters summed per kind, as separate fields |
| `cr` | `rounds` (distinct reviewed heads), `findings` (count by final verdict after amends; `open` when none), `est_tokens` (the ledger's estimated critic tokens) |
| `digest` | sha256 of the record without this field |

Numbers and ids only: the store never holds message text.

## Idempotency and append-only

A record has no compute timestamp, so the same inputs give the same bytes. The
compute step appends a ticket's record only when its `digest` differs from that
ticket's latest stored line; older versions stay (`usage-read.sh --all`). A
`--print` rerun is byte-identical. Token counts follow `bank-attribution.sh`
exactly (per-requestId dedup), and a skipped or unreadable transcript makes the
run fail rather than store incomplete totals.

## Consumers

The HIMMEL-3993 epic's readers: the effort model (HIMMEL-3992), the tool
re-audit (HIMMEL-3883), routing (HIMMEL-774), leg A/B (HIMMEL-2986), the
improvement lane (HIMMEL-1853), the tracker UI and cost reports. Siblings that
will feed it: PR-body cost aggregation (HIMMEL-4003) and the CR-loop ledger
(HIMMEL-4004).

## Limits

`--since` windows session tokens only; CR stays all-time, so use it
for token questions, not for a stored record you mean to compare across runs.
A whole compute-then-append run holds a `<store>/.lock` directory, so an older
snapshot never publishes after a newer one. Table parsing assumes session
titles contain no ` | `. Sessions are keyed by title, so distinct sessions
sharing a title merge into one `legs[]` entry. Judge calls are counted as
`judge`-titled sessions only. An explicit `--projects` or `--ledger` that is
missing or unreadable exits non-zero before anything is written; the default
projects dir and default ledger may be absent (a note on stderr, treated as
empty). `cr.rounds` counts heads with a responding review
(`unavailable` availability rows are not rounds).
