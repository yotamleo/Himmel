---
allowed-tools: Bash, Read
description: One-time, reversible backfill (LUNA-86). Migrates the historical top-level `processed: true` clips out of the `Clippings/` inbox into the flat evidence pool `Clippings/_evidence/` — stamping `evidence_kind:` and rewriting every inbound wikilink (SIX literal forms — 3 plain + 3 `.md`-suffixed — so nothing dangles) with a fully reversible manifest. Deterministic, idempotent, resumable, folder-keyed. Driven by `tools/migrate-clip-lifecycle.mjs`. NOT a steady-state stage — run ONCE, behind a mandatory staging gate.
argument-hint: "[vault-path] [--dry-run | --apply [--month YYYY-MM] | --rollback <manifest.json>]"
---

## Your task

Backfill the historical clips: LUNA-84 made **triage** drain new `processed: true`
clips into `Clippings/_evidence/` going forward, but the ~559 clips processed
**before** that change still sit in the top-level `Clippings/` inbox. This
command is the **one-time** engine that migrates them, with a byte-identical
rollback. It is NOT a recurring pipeline stage — after the live backfill
completes once, it is never run again on that vault.

The deterministic work is done by the node engine
`tools/migrate-clip-lifecycle.mjs` (no LLM judgement, no npm deps — reuses
`tools/lib/evidence-kind.mjs`). Your job as the agent/operator is to drive it
**through the staging gate below** and never skip a step.

### What "eligible" means (the 559)

A clip is migrated iff **both** hold:
1. It is at the top level of `Clippings/` (depth 1–2 — i.e. `Clippings/<clip>.md`
   or `Clippings/<YYYY-MM>/<clip>.md`), **not** under `_evidence/`, `_done/`, or
   `_synthesis/`, and is not `_deferred.md`.
2. Its frontmatter has `processed: true`.

Unprocessed clips, already-graduated `_done/` clips, already-promoted
`_evidence/` clips, and synthesis pages are **never touched**.

### The six-form `.md` requirement (silent-dangle BLOCKER — do not miss it)

`/archive-clips` (and, since LUNA-84, `/triage-clips` when it moves a freshly
`processed: true` clip into `_evidence/`) rewrite **three** inbound link boundary
forms: `[[Clippings/<OLD>]]`, `[[Clippings/<OLD>|`, `[[Clippings/<OLD>#` — all
literal/fixed-string. But real `_synthesis/` pages cite some clips **with the
`.md` extension**:
`[[Clippings/@DataChaz – 2026-05-25T143753+0200.md]]`. The 3-form set MISSES
`.md]]` and a verify built on only those three reports clean → **silent dangle**.

This migration matches, rewrites, **and verifies SIX literal forms per clip**:

```
[[Clippings/<OLD>]]      [[Clippings/<OLD>|      [[Clippings/<OLD>#
[[Clippings/<OLD>.md]]   [[Clippings/<OLD>.md|   [[Clippings/<OLD>.md#
```

All matching is **LITERAL / fixed-string** (clip ids contain `+ ( . space`
en-dash — a regex engine reads `+` as a quantifier and mis-matches). The
rewrite keeps the `.md` on `.md`-input forms and drops it on the plain forms
(`<NEW> = _evidence/<basename>`), preserving the `|alias` / `#heading` / `]]`
tail and never clobbering a prefix-sibling (`[[Clippings/<OLD>-extra]]`).

### Headless refusal (HIMMEL-128)

<!-- headless-claude-ok: documenting the HIMMEL-128 ban; this is a prohibition note, not an invocation -->
This command makes no `claude -p` / `--print` / `--bg` / API calls. Do not wrap
the engine in a headless invocation. The engine is a deterministic node tool —
run it directly via Bash.

---

## Procedure (do these IN ORDER — the staging gate is a BLOCKER)

### 1. `--dry-run` first — review the plan + reverse manifest

```bash
node tools/migrate-clip-lifecycle.mjs "<vault>" --dry-run --manifest /tmp/migrate-plan.json
```

Prints, per eligible clip, the planned move (`<old> → _evidence/<base>`), the
inferred `evidence_kind`, and the inbound-link occurrence count; writes the plan
manifest to `--manifest`; **mutates nothing** (no move, no frontmatter edit, no
link rewrite). Read the plan. The eligible count should be ~559 on the live
vault; if it is wildly off, STOP and investigate (wrong vault path, scan-guard
regression) before going further.

**Basename-collision pre-check (BLOCKER).** The evidence pool is FLAT and keyed
on `path.basename`, so two eligible clips with the same basename in different
folders/months would both target `Clippings/_evidence/<base>.md`. `--dry-run`
scans for this and, for each clash, prints a loud `COLLISION:` line **naming both
colliding source paths**, then exits with the **distinct advisory code 3** (vs `0`
clean). If you see a collision, resolve it (rename one source) before `--apply` —
do NOT proceed. `--apply` independently refuses every colliding clip (it migrates
none of a colliding set and exits 3), so a clash can never silently overwrite or
drop a clip, but catching it at dry-run keeps the live run clean.

**Performance expectation.** The engine is roughly `O(clips × vault-files)` (it
re-scans the whole vault per clip to find inbound links). On the live ~559-clip
vault a full run may take **a few minutes** — that is expected, not a hang. Per
`--month` batches are smaller and faster.

### 2. Mandatory staging gate (BLOCKER — do not skip)

Never run `--apply` on the real vault until a scratch copy proves both the
zero-dangler and the byte-identical-rollback invariants:

```bash
# a. copy the real vault to scratch and make it a git oracle
cp -r "<vault>" /tmp/vault-staging
cd /tmp/vault-staging
git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm "pre-migration oracle"

# b. dry-run then apply on the COPY
node <plugin>/tools/migrate-clip-lifecycle.mjs /tmp/vault-staging --dry-run --manifest /tmp/stage-plan.json
node <plugin>/tools/migrate-clip-lifecycle.mjs /tmp/vault-staging --apply --manifest /tmp/stage-manifest.json

# c. ASSERT zero danglers — INCLUDING the .md form — for every migrated id.
#    A blunt sweep: no inbound link may still point at a TOP-LEVEL clip path.
#    (Per-id six-form grep is what the engine's own verify already enforces;
#     this is the operator's independent cross-check.)
grep -rF '[[Clippings/' /tmp/vault-staging --include='*.md' | grep -vF '[[Clippings/_evidence/' | grep -vF '[[Clippings/_done/'
#    → inspect: every remaining hit must be a link to a clip that legitimately
#      stayed (unprocessed) — NOT a migrated clip. Migrated-clip danglers = BUG.

# d. ASSERT byte-identical rollback: roll back, then git diff vs the oracle.
node <plugin>/tools/migrate-clip-lifecycle.mjs /tmp/vault-staging --rollback /tmp/stage-manifest.json
git -C /tmp/vault-staging status --porcelain   # MUST be empty (ignoring engine state files)
git -C /tmp/vault-staging diff                  # MUST be empty
```

If (c) shows a migrated-clip dangler, or (d) is non-empty, **STOP** — the live
run is unsafe. Do not proceed. (The engine writes state files
`.migrate-clip-lifecycle.*` into the vault root. Add a
`.migrate-clip-lifecycle.*` line to the vault's `.gitignore` BEFORE the oracle
commit so they never dirty the diff check; otherwise exclude them manually.)

### 3. Live run (sole-writer, one git commit per month-batch)

Only after the staging gate passes:

1. **Become the sole writer.** Pause Obsidian-GitHub-Sync and close Obsidian —
   this command MOVES files and REWRITES links across the whole vault; a
   concurrent editor races the whole tree, not one folder.
2. **Apply per month-batch** so each commit is small and bisectable. `--month`
   stages only the eligible clips whose `date_clipped` (fallback `harvested_at`,
   final fallback file mtime) falls in that month:
   ```bash
   node tools/migrate-clip-lifecycle.mjs "<vault>" --apply --month 2026-05 --manifest "<vault>/.migrate-clip-lifecycle.manifest.json"
   git -C "<vault>" add -A && git -C "<vault>" commit -m "chore(luna): migrate 2026-05 clips → _evidence/ (LUNA-86)"
   # repeat for each month present in the dry-run plan
   ```
   The manifest accumulates across month-batches (it is the single authoritative
   reverse manifest for the whole backfill). Keep it — it is your rollback key.
   The `date_clipped → harvested_at → file-mtime` fallback chain only decides
   **which month-commit a clip lands in** (cosmetic batching); it does not change
   the end state — every eligible clip ends up in `_evidence/` exactly once
   regardless of which `--month` batch claims it.
3. **Resume sync** at the end (re-enable Obsidian-GitHub-Sync / reopen Obsidian).

To migrate everything in one shot instead of per-month, omit `--month`. Per-month
is preferred for the live 559 so a problem is isolated to one commit.

### 4. Rollback procedure

To reverse a completed apply (any extent — single month or the whole backfill),
feed the **authoritative apply manifest** back:

```bash
node tools/migrate-clip-lifecycle.mjs "<vault>" --rollback "<vault>/.migrate-clip-lifecycle.manifest.json"
```

Rollback reverses, in inverse order, every recorded clip: it inverse-rewrites
each recorded link edit (newForm → oldForm), strips the exact inserted
`evidence_kind` block, and moves each clip back to its original path — restoring
the working tree byte-for-byte. It refuses a dry-run plan manifest (that records
no real moves). After rollback, `git diff` vs the pre-migration commit is empty.

**Non-idempotent against an externally-modified clip.** Rollback's
`evidence_kind` strip checks that the inserted block is byte-exact where it was
written. If a clip was edited AFTER apply (e.g. Obsidian sync touched it, or the
operator hand-edited it in `_evidence/`), that check fails. Rather than leave a
torn half-revert (links reversed to the old inbox form but the file still at
`_evidence/`), the engine **re-applies that clip's forward link edits** so the
clip is left FULLY in the applied state (links → `_evidence/`, file at
`_evidence/` — self-consistent), reports it failed, and exits 4. Resolve such a
clip by hand (restore the clip to its exact post-apply bytes, then re-run
rollback, or move it back manually). This is why rollback must run on a
sole-writer vault, same as apply.

### 5. Resume / idempotency (folder-keyed)

Resume keys off **folder location**, not a flag: a clip already in `_evidence/`
is skipped. So a re-run of `--apply` is a no-op (`0 migrated`), and a run that
dies mid-way leaves a clean split — re-running `--apply` picks up exactly the
clips still in the inbox. The manifest is checkpointed after every clip, so an
interrupted run is still fully rollback-able.

### Per-clip transaction (what the engine does, atomically)

1. Infer `evidence_kind` (`type:` + source URL + `tags:` via `inferEvidenceKind`)
   and insert it as a zero-indent block-list key before the frontmatter's
   closing `---` (skipped if the clip already has the key).
2. `mkdir -p Clippings/_evidence` (once).
3. Enumerate inbound links across the whole vault with the SIX literal forms;
   record every `(file, oldForm → newForm)` edit in the manifest.
4. `mv` the clip → `Clippings/_evidence/<basename>.md`.
5. Literal-rewrite each recorded inbound edit (including the clip's own
   self-ref at its NEW path — LUNA-60), then **verify** the six forms return
   zero stale matches across the vault. On any per-clip failure the engine
   reverts that clip's half-move and continues; a non-zero exit (4) means
   ≥1 clip failed — inspect, then re-run to retry.
6. Append a ledger line (`<vault>/.migrate-clip-lifecycle.ledger.jsonl`) and
   checkpoint the manifest.

### Notes for the agent

- The ONLY destructive op is `mv` (relocate) — never `rm` a clip.
- Do not run the live migration without the staging gate passing first.
- Engine state files (`.migrate-clip-lifecycle.manifest.json`, `…ledger.jsonl`)
  should be gitignored in the vault so they never dirty the migration commits or
  the rollback oracle — add `.migrate-clip-lifecycle.*` to the vault `.gitignore`
  before the first run.
