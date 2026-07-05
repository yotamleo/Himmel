# ADR: machine-aware concurrency budget (HIMMEL-536)

Status: proposed (operator acceptance pending)
Date: 2026-07-05
Context: HIMMEL-654 WS3 (orchestration layer), D1. Eval-shaped per HIMMEL-177
(read → decide → ADR). **No budget code ships from this ADR** — implementation
is a separate child ticket, filed operator-side, only after acceptance.

## 1. Discovery method (Win11 — the only live host)

macOS/Linux are recorded here as a future extension, not engineered now. The
eval question — *are sibling Claude sessions enumerable well enough to
distinguish LIVE sessions from dead artifacts?* — was probed on 2026-07-05
(32 logical / 16 physical cores, 47.1 GB RAM, 3 % load at probe time):

| Probe | Command | Verdict |
|---|---|---|
| Process table | `Get-Process claude,node` | Shows a **count** (5 `claude`, 53 `node`) but **cannot** distinguish a live-interactive session from an armed/background/just-exited one, and node children (MCP servers + hook subprocesses) are not attributable to a parent session. |
| Session artifacts | `~/.claude/projects/*/*` dir mtime < 12h | ~18 dirs, but mtime is written on every transcript flush → a *just-exited* session's dir is "recent" too. **Cannot** distinguish live from dead. |
| Shell-snapshots | `~/.claude/shell-snapshots` newest | Present and recent, but not an authoritative live-session heartbeat. |
| VM enumeration | `VBoxManage list runningvms` (full path `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`; not on Git Bash PATH) | Reliable: lists running VMs; per-VM reservation via `VBoxManage showvminfo <vm> --machinereadable \| grep -E 'memory\|cpus'`. 0 running at probe time. |
| Host load | `Get-CimInstance Win32_Processor` / `Win32_OperatingSystem` | Reliable: logical cores, `LoadPercentage`, `FreePhysicalMemory`/`TotalVisibleMemorySize`. These are the budget-formula raw inputs. |

**Session-enumerability answer: ENUMERABLE = no.** No OS-level probe reliably
separates LIVE Claude sessions from dead artifacts. The ADR therefore lands on
the **claim-file registry fallback** — the "claim-and-record shared state"
doctrine the orchestration evidence already prescribes (0xMorlex / Cognition):

> Each session writes `~/.claude/run/claim-<pid>.json` on start
> (`{pid, cwd, started_at, role}`), removes it on clean exit, and a
> start-of-session sweep deletes claims whose `pid` is no longer alive OR whose
> `started_at` is older than a staleness bound (crash-safety). The count of live
> claim files — not the raw process table — is the sibling-session term in §2.

VM reservations and host load ARE reliably enumerable and need no fallback.

## 2. Budget formula

```
core_budget = logical_cores
            − core_headroom
            − Σ(running-VM vCPU reservations)
            − per_session_share × (live_sibling_claim_files)
            , floored at 1

ram_budget  = free_ram
            − Σ(running-VM RAM reservations)
            − ram_headroom
            → caps worktree-heavy fan-outs (each worktree ≈ one build sandbox)
```

The effective fan-out width is `min(core_budget, ram_budget/per_worktree_ram)`,
never below 1.

**Starting-default constants (chosen from the 2026-07-05 probe output; explicitly
marked "pending §5 measurement" — the eval decides them, this ADR does not
pre-bake them):**

| Constant | Starting default | Basis |
|---|---|---|
| `core_headroom` | 4 logical | leave headroom on a 32-logical box; interactive foreground stays responsive |
| `per_session_share` | 2 logical | each counted sibling claim files gives up ~2 logical to it |
| `ram_headroom` | 8 GB | OS + editors + MCP servers baseline (probe: 31 GB in use at idle-ish load) |
| `per_worktree_ram` | 2 GB | rough worktree build-sandbox reservation |

**The GA Workflow tool's 16-concurrent / 1000-total caps are Anthropic-enforced
internals** (spec D1): a *fixed ceiling this budget lives UNDER*, never a
consumer of it. The machine budget can only ever lower the effective width; it
cannot raise it above the platform cap.

## 3. Where it lives

**Decision: a shared helper `scripts/lib/concurrency-budget.sh`** (default per
HIMMEL-177 cheapest-layer doctrine — NOT a new orchestrator daemon/layer),
consulted by **himmel-OWNED dispatch points only**:

- `/overnight-shift` fan-out (the N-ticket parallel dispatch)
- subagent fan-out scripts (build-plan / self-heal dispatch loops)
- `arm-resume.sh` scheduling (how many armed relaunches to stack)

The helper exposes one function, `concurrency_budget()`, printing the integer
width; callers clamp their intended fan-out to it. The GA Workflow caps remain
outside its reach (no external hook exists), consistent with §2.

Rationale: every consumer is already a himmel shell script; a helper library is
the lowest-cost layer that all of them can source. A daemon would add a
long-lived process, a socket, and a failure mode for zero measured benefit at
this scale (single host, ≤ low-double-digit sessions).

## 4. Throttle / queue behavior

When the budget is exhausted, dispatch **QUEUES** (bounded wait + retry) rather
than launching blind:

- A caller wanting width W but granted width B launches B now and holds W−B in a
  bounded FIFO, retrying as claim files clear (poll interval ~30 s, max wait
  capped so an overnight run never wedges).
- **e2e VMs get a standing reservation** subtracted first (their vCPU/RAM
  reservations are non-negotiable — a starved e2e VM fails the run it gates), so
  interactive fan-outs can never starve the VM lane.
- Floor of 1: a single dispatch always proceeds (no deadlock when the box is
  momentarily saturated).

## 5. Measurement plan

Before/after, once the helper ships under its child ticket:

- **A/B:** one `/overnight-shift` run using `concurrency_budget()` vs. one using
  the current doctrinal fixed 6–8-ticket ceiling.
- **Record:** host CPU-load peaks, `FreePhysicalMemory` troughs, and any VM
  starvation incident (an e2e VM that missed its reservation), per run.
- **Tune:** the §2 constants (`core_headroom`, `per_session_share`,
  `ram_headroom`, `per_worktree_ram`) are re-derived from the measured peaks —
  they are provisional until this run exists.

Acceptance + the implementation child ticket citing this ADR are operator
actions (not held against the WS3 round that produced this ADR).
