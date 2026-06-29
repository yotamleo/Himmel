---
doc_kind: photo-archive-index
status: TEMPLATE — organize & surface, NOT a diagnosis
created: <scaffold-date>
tag_vocab:
  region: [hands, thighs, armpit, groin, abdomen, torso, elbow, face, eyes, ear, neck, back, knees, feet]
  state: [active-worst, active, recovery, good-baseline]
  thread: [eczema, abscess, urticaria, folliculitis, acne, pih-mark, uncertain]
---

# Skin — photo archive (timeline, region-tagged)

Master index of all skin photos in `_media/skin/<date>/`. **Dates + regions are
operator-provided.** The `thread` column is a tentative `[inferred]` morphology
read **for a clinician to confirm** — never a diagnosis.

The `medic` skill (`.claude/skills/medic/`) appends rows here when you file a
photo. This file ships with the schema only; your rows accumulate below.

| Date | Region | State | Files | Thread `[inferred]` | Visual note (not a diagnosis) |
|---|---|---|---|---|---|

## Provenance
- All photos operator-provided; dates + body regions per operator. The thread
  column is a flagged morphology impression, **not a diagnosis** — for a clinician.
