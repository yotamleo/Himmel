# Salus — the medical-vault profile

**Salus** (the Roman goddess of health, safety, and well-being) is the medical
second-brain profile of the luna template: a local, private, PHI-safe
health-record vault. It is the public-facing product name for the medical-vault
tooling (a private instance — e.g. a personal medical vault — is one
deployment of the Salus profile).

This directory is a **PHI-free overlay** applied on top of the base luna
second-brain scaffold. It contains zero personal data — only schemas, a generic
skill runbook, the egress-floor hook, and templates.

## What the overlay adds
- `.claude/skills/medic/SKILL.md` — the FILE + QUERY medic skill (non-diagnostic).
- `.claude/hooks/block-cloud-egress.sh` — the Posture-A PHI-egress floor.
- `_skin-photo-archive.md` — region-tagged skin-photo index (schema, zero rows).
- `_media/skin/.gitkeep` — the photo store.
- `_derm-visit-prep.template.md` — clinic-visit prep template.
- `_CLAUDE.salus.md` — medical posture block, appended to the vault's `_CLAUDE.md`.
- `.salus-profile` — marker dropped at the vault root so `upgrade.sh` knows this
  vault is on the medical profile and may carry medic-asset updates.

## How to create a Salus vault
Copy the base `luna-second-brain` template, then:

```bash
bash scripts/setup.sh --medical      # base setup + apply the salus overlay
```

`--medical` applies this overlay AFTER the base scaffold. The `_`-root scaffolds
(`_skin-photo-archive.md`, `_media/skin/`, the derm-prep template) are written on
**scaffold-new only** — `upgrade.sh` never overwrites them on an existing vault.

## Safety invariant
Salus and this overlay contain **zero PHI**. All personal health data lives only
in the private vault instance, never in the template.
