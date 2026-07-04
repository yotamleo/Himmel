# salus Health-Series Substrate — Design Spec

- **Date:** 2026-06-17
- **Ticket:** HIMMEL-355 (epic HIMMEL-350; precursor to M3 / HIMMEL-351)
- **Status:** DRAFT design — pending operator review
- **Build discipline:** the himmel way — worktree → PR → `/pr-check` CR → merge; conventional commits +
  attestation trailers; spec lives in `docs/luna/` (HIMMEL-138 tier-1).

## 1. Goal & non-goals
**Goal.** The correlation engine (M0–M2: Kp, barometric pressure, air-quality, pollen) is built but
produces only **synthetic** output — no real `date,value` health series exist yet. The dated health data
lives in the salus vault in **mixed/unstructured** form. This sub-project builds the **health-series
substrate** that derives clean series from the vault, so the *existing* engine immediately yields real
migraine / skin-flare / sleep signals — without waiting for the broader M3 catalog.

**Build scope (this spec) = HISTORICAL backfill.** Operator decision: "historical first, then current as
we add."

**Non-goals (deferred, designed but not built here):**
- Going-forward daily capture (Telegram quick-log + obsidian daily-note) — §7, built later.
- Any change to the correlator (luna-correlate) — it already loads `date,value` series. Clean boundary.
- The M3 analytics (full factor catalog, lag sweep, dashboard) — separate spec (HIMMEL-351), downstream.

## 2. Architecture — the boundary
One new capability (**extractor**) feeding the existing one (**correlator**), meeting only at the series files:

- **Extractor** (this sub-project): reads the salus vault, writes `date,value` series CSVs. Vault-aware.
- **Correlator** (luna-correlate, unchanged): reads series CSVs, runs offline joins → candidate signals.
- They meet only at `50-Vitals/<metric>.csv`. The extractor never correlates; the correlator never reads the
  vault. Each is testable in isolation.

Everything is **local**: the extractor reads the vault and writes series, both on-box; no third-party egress
(the extraction LLM pass runs in the operator's own session, the same trust model as the existing
obsidian-second-brain tooling). Series are derived PHI and carry the correlator's never-egress floor.

## 3. Series schema + home
- **One CSV per metric:** `50-Vitals/<metric>.csv`, header `date,value`, ISO `YYYY-MM-DD` dates, numeric
  value. This is the correlator's existing format — **no correlator change**. `LUNA_SERIES_DIR` → `50-Vitals/`.
- **Registry:** `50-Vitals/_series.md` — one row per metric: name, scale/unit, meaning, provenance. Makes each
  series self-describing + auditable. Starting metrics (operator-confirmed): `migraine` (severity 0–3),
  `skin_flare` (AD, 0–3 or 0/1), `sleep_hours`, `hrv_ms`, `rhr_bpm`. Extensible.

## 4. Extraction — hybrid (two readers → one merge)
- **Deterministic parser** (`scripts/luna-vitals/` or a small TS module; unit-tested): pulls already-structured
  dated values — frontmatter fields, tables, `YYYY-MM-DD … metric: value` bullets — from `50-Vitals/`,
  `20-Timeline/`, and daily notes. Pure, reproducible, fast. Emits `(metric, date, value, source)` rows.
- **LLM extraction agent** (a skill, run per vault bucket): for prose / clinical-timeline narrative the parser
  can't reach. Locates health-relevant files via qmd / obsidian search, reads them, and proposes
  `(metric, date, value, source-quote)` tuples. Conservative: emits only **explicit dated values**, not
  relative trend statements ("worse this winter") — those are low-value and ambiguous.
- **Merge + dedup by `(metric, date)`:** precedence is deterministic-over-LLM — a structured parser value
  overrides an LLM value for the same `(metric, date)` (the parser reads ground-truth structure). The LLM only
  *fills gaps* the parser left. A conflict is **flagged** (not silently resolved) only where neither is
  authoritative: two structured sources disagree, or two LLM buckets disagree with no parser value. Identical
  values from boundary-overlap buckets simply dedup.

## 5. Human-review gate (medical accuracy)
Extraction never writes `50-Vitals/` directly. It writes a **per-metric review artifact** (proposed rows +
the source quote/file each came from + conflict flags). The operator reviews/edits; on approval the rows are
merged into the series CSV. Medical data is never silently auto-written.

## 6. Load-balanced extraction run (HIMMEL-340 multislot + single-writer)
The historical extraction over the whole vault is long and parallelizable. It runs **after** the extractor
code ships, as an operational runbook:

- **Partition** the vault into **time-range buckets** (e.g. per year / per ~18 months) with a **few-days
  overlap** at the cuts (so a boundary-dated entry isn't missed and the LLM keeps local context). Partition
  is **extraction-only** — it never touches trend analysis, which runs on the full merged series.
- **One arm slot per bucket** (HIMMEL-340: distinct handovers each hold their own scheduler slot, no clobber).
  Each armed salus session runs the extraction skill on **its** bucket and writes its **own** per-bucket
  review artifact — never a shared write (the same per-branch isolation that makes `/overnight-shift` safe).
- **Single-writer merge:** after the armed runs finish, **one** consolidation pass (deterministic parser
  output + all per-bucket LLM artifacts), dedup by `(metric, date)` → the review artifact → operator approval
  → `50-Vitals/`. Many parallel readers, one writer to the shared series.
- **Bounds:** ~3–5 buckets covers the vault span; a single-pass run is the fallback. (Overnight failure-mode
  guidance caps useful parallelism ≈6–8.)

## 7. Going-forward capture (designed, deferred — not built here)
Telegram quick-log (a parsed message / `/vitals`-style command via the bridge) and obsidian daily-note capture
**append** to the same `50-Vitals/<metric>.csv`. The §3 schema is capture-ready. Built later ("as we add");
overlaps the M4 live-monitor daily-capture sub-project.

## 8. Components & isolation
| Unit | Input | Output | Network |
|---|---|---|---|
| Deterministic parser | vault structured entries | `(metric,date,value,source)` rows | none |
| LLM extraction skill | a vault time-bucket | per-bucket review artifact | local session only |
| Merge/consolidate | parser rows + bucket artifacts | review artifact (deduped, conflicts flagged) | none |
| Review→write | approved review artifact | `50-Vitals/<metric>.csv` + registry | none |
| (existing) correlator | `50-Vitals/*.csv` | candidate signals | only gated factors.cache |

## 9. Testing
- Deterministic parser: unit-tested against **vault-shaped fixtures** (frontmatter, tables, dated bullets,
  malformed/edge rows).
- Merge/dedup: tested — deterministic-wins, gap-fill, conflict-flagging, boundary-overlap dedup.
- LLM extraction skill: validated on a small real sample via the review artifact (recall/precision sanity),
  not asserted byte-exact.
- Correlator: untouched → its 83 tests stay green; an end-to-end smoke (extracted sample series →
  `correlate`) confirms the handoff.

## 10. Sequence / payoff
1. Ship the extractor (this spec) the himmel way.
2. Run the load-balanced backfill → real `50-Vitals/*.csv`.
3. **Immediately:** `correlate({series:"migraine", factor:"pressure"|"aq"|"pollen"|"kp", lag})` on the *current*
   engine → first real signals.
4. M3 (HIMMEL-351) enriches: full factor catalog + multi-series + lag sweep + ranked dashboard, on the now-real
   series.
