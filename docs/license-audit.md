# License audit (HIMMEL-132)

Durable record of the license decision and the housekeeping that
implemented it. Visibility (private → public) is a separate, deferred
step — see [Remaining deferred step](#remaining-deferred-step).

## Chosen license: MIT

himmel-OWN code is licensed under the **MIT License**
(see [`/LICENSE`](../LICENSE), copyright `2026 yotamleo`).

Rationale: MIT is the most-permissive widely-recognized OSI license —
minimal obligations on downstream users (attribution only), maximum reuse,
and it matches the operator's stated target license. It imposes no
copyleft and no patent-grant ceremony, which keeps adoption friction low
for a harness meant to be copied and adapted.

## License menu considered

| Family | Examples | Verdict |
| --- | --- | --- |
| Permissive | MIT, Apache-2.0, BSD-2/3-Clause, ISC | **MIT chosen.** Apache-2.0 adds an explicit patent grant + NOTICE ceremony; BSD/ISC are near-equivalent to MIT. MIT picked for ubiquity + minimalism. |
| Weak copyleft | MPL-2.0, LGPL | Rejected — file/library-level copyleft adds obligations not wanted for a permissive harness. |
| Strong copyleft | GPL, AGPL | Avoided — viral copyleft (AGPL extends to network use) is too restrictive for downstream adoption. |
| Source-available | BSL | Avoided — not OSI-approved; time/usage-gated terms conflict with the open-reuse goal. |

## Dependency audit

- All committed npm dependencies resolve to permissive licenses; nothing
  copyleft is pulled into the distributed tree.
- The `scripts/hooks/check-npm-licenses.sh` pre-push gate enforces a
  permissive-only allowlist, so a non-permissive dep cannot land silently.
- `node_modules/` is **not** committed — only `package.json` /
  lockfiles are versioned, so the audit surface is the declared deps.
- The allowlist permits **`Python-2.0`** (PSF License). It is permissive
  and GPL-compatible (no copyleft), consistent with MIT distribution.
  Added (HIMMEL-179) when the broadened gate surfaced `argparse@2.0.1`
  pulled transitively via `js-yaml` in
  `marketplace/plugins/obsidian-triage/tools`.

Result: clean. No license conflicts between MIT distribution and the
dependency graph.

## Fork handling

Two vendored plugins are upstream forks and stay under their **upstream
Apache-2.0** license — they are NOT relicensed to MIT:

- `marketplace/plugins/pr-review-toolkit-himmel/` — fork of
  `pr-review-toolkit`; upstream `LICENSE` (Apache-2.0) carried forward,
  attributed in its `README.md`.
- `marketplace/plugins/telegram-himmel/` — fork of
  `telegram@claude-plugins-official` v0.0.6; upstream `LICENSE`
  (Apache-2.0) carried forward, attributed in its `README.md`.

Each fork retains its original `LICENSE` file and documents the upstream
source + fork delta in its own `README.md`.

## Housekeeping completed by this change

- Added root [`/LICENSE`](../LICENSE) (MIT).
- Added `LICENSE` (MIT) to the three himmel-OWN marketplace plugins that
  lacked one: `handover/`, `himmel-ops/`, `obsidian-triage/`.
- Set `"license": "MIT"` in the himmel-OWN `package.json` files:
  `plugins/himmel-gh`, `plugins/himmel-jira`, `scripts/himmel-run`,
  `scripts/jira`, `marketplace/plugins/obsidian-triage/tools`
  (`himmel-run` + `jira` previously declared `UNLICENSED`, which
  contradicted the chosen license).
- Updated the README `## License` section: MIT for himmel, Apache-2.0
  note for the two vendored forks.

## Remaining deferred step

**GitHub visibility flip (private → public) is NOT done here.** It is
gated on an explicit operator decision and remains deferred under
HIMMEL-132. This change is license-metadata housekeeping only; choosing a
license does not make the repository public.
