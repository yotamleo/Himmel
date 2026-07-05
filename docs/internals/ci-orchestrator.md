# CI Orchestrator (HIMMEL-502)

A queue + scheduling layer over himmel's scarce CI compute (one Linux VM, a
load-contended laptop, unreliable GitHub Actions). It serializes, prioritizes,
throttles, and defers CI jobs across lanes so the Linux suite runs on every push
without exceeding the private GitHub-hosted free-tier minutes cap, and so CI
execution survives an Actions-service outage.

Package: `scripts/ci-orchestrator/` — a zero-runtime-dep npm + TypeScript (ESM,
NodeNext) + vitest package. Never bun (npm-only pre-commit gates).

> Phase status: **P2** (pure core) and **P3** (scheduler/server/client/adapters/
> reporter) are in-tree. **P0** (measurement), **P1** (`act` backbone `bin/*.sh`,
> self-hosted-runner registration, workflow edits), and **P4** (public-fork
> adapter) are separate phases — the P3 lane adapters shell to the P1 `bin/`
> scripts, which land with P1.

## Lanes (5, one adapter each — 1:1)

| Lane (`LaneName`) | Kind | Role |
|---|---|---|
| `self-hosted-runner` | native (observe-only) | VM as a GitHub self-hosted runner — free private Linux minutes when GitHub is up. GitHub schedules the native `on: pull_request` run; the orchestrator only observes it (`dispatch` is a no-op). |
| `private-gha-hosted` | dispatched (sparing) | The only pre-merge win/mac path. Observes an existing native run for the head SHA if present; else issues a `workflow_dispatch`. Gated by private-minute headroom. |
| `act-exec` | dispatched (backbone) | Runs `.github/workflows/ci.yml` Linux jobs via nektos/act in Docker on the VM — GitHub-independent. The Actions-outage backbone. |
| `public-fork` | dispatched (P4) | Post-merge / propagated-surface coverage on free GitHub-hosted runners. Never posts a private PR's required check (validates `runSha`, not `headSha`). |
| `local-exec` | dispatched (last resort) | The dev host, load-gated by the work-profile. Decided client-side by the local daemon (protect-local in `focus`). |

## Routing order (pure — `src/routing.ts`)

`route(job × lane-availability × work-profile × private-minute-headroom ×
act-matrix × github-up) → lane | defer`. Never a "skip" — only route or defer.

1. Required **light** gate → `self-hosted-runner` ▸ `private-gha-hosted`
   (fallback) ▸ `act-exec` (only if GitHub is down).
2. Everything else → `act-exec` if the job's Linux leg is `act`-eligible and
   under cap.
3. `publicSafe && !required` → `public-fork` (if GitHub is up).
4. `required && needsSecrets`, backbone unavailable, with headroom →
   `private-gha-hosted` (also the only pre-merge win/mac path).
5. `local-exec` only if the work-profile is `shared`/`drain` **and** load is
   below threshold.
6. else `defer` (backpressure — the job stays queued, never dropped).

## Architecture — VM-owned queue, two daemons

- **Ledger** (`src/ledger.ts`): a single-writer, append-only JSONL event log
  (`submit`/`claim`/`lease-renew`/`lease-expire`/`dispatch`/`verdict`/
  `status-posted`/`complete`), reduced to per-job state. Mirrors the quota-gauge
  model. The **VM daemon is the ONLY writer** — the local daemon never appends
  directly.
- **Server** (`src/server.ts`): the VM-owned queue HTTP API — `POST /submit`,
  `POST /claim`, `POST /complete`, `GET /state`. Bearer-token auth
  (`HIMMEL_CI_QUEUE_TOKEN`). Claim exclusivity is a property of the VM's single
  Node event loop handling `/claim` **sequentially** (the claim critical section
  has no `await` between read-state and append), not a distributed CAS.
- **Client** (`src/client.ts`): the local claiming client. On a VM connection
  failure it **degrades to direct-dispatch** (dispatches the required light gate
  itself, defers heavy jobs); on VM return the VM re-derives outstanding work
  from git. The client decides `local-exec` **client-side** (the VM can't see the
  local machine's load) and publishes its work-profile to the VM on each `/claim`.
- **Scheduler** (`src/scheduler.ts`): `tick()` — one pass: discover git work →
  `planSubmission` (doc-only skip + content-hash dedup) → route each queued job →
  dispatch (dispatched lanes) or observe (native lanes) → poll running jobs →
  append verdicts → post required-check verdicts (dispatched lanes only — native
  lanes are already surfaced as GitHub checks) → drain the unposted backlog.
  Priority = `W_REQUIRED*required + age/AGE_UNIT` (required head start, but aging
  guarantees an old job is selected before it starves).
- **Reporter** (`src/reporter.ts`): posts a verdict to the Checks/commit-status
  API at **`job.headSha`** (never `runSha` — a public-fork verdict can't
  masquerade as a private required check by construction). GitHub-unreachable →
  verdict kept `verdict-known, status-unposted` and retried on GitHub's return.

## Environment

| Var | Purpose |
|---|---|
| `HIMMEL_CI_QUEUE_LEDGER` | Override the ledger path (default `$HOME/.himmel/ci-queue.jsonl`). Byte-identical resolver twin: `scripts/lib/ci-queue-ledger-path.sh`. |
| `HIMMEL_CI_QUEUE_TOKEN` | Shared bearer token for the local↔VM HTTP protocol. Env only — never committed. |
| `$HOME/.himmel/ci-workprofile` | Manual work-profile toggle (`focus`/`shared`/`drain`) — wins over schedule/load inference. |

## CLI (`bin/ci-orchestrator`)

- `state` — print the reduced ledger state as JSON (empty ledger → `{}`).
- `tick` / `daemon` — require the production lane + git-discovery wiring
  (assembled from `HIMMEL_CI_*` + registered adapters); until wired they report
  the boundary rather than firing fake work.
- `measure` — the P0 baseline is `bin/measure.sh` (P0 shell artifact).

## Reading the queue

`cat $HOME/.himmel/ci-queue.jsonl` — one JSON event per line; the current state is
the reduction (`ci-orchestrator state`). Leases are events in the same log; a
`lease-expire` after a `claim` (with no verdict) returns the job to `queued`.
