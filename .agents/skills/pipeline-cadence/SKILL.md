---
name: pipeline-cadence
description: Arm/inspect/remove the recurring luna clip-pipeline cadence (daily harvest+triage, daily synthesize+archive, weekly health) via schtasks/cron, each leg pinned to a cheap --model. Dedup-guarded. Use when the user asks to arm/check/disarm the clip-pipeline cadence or runs /pipeline-cadence.
---

# pipeline-cadence

When the user asks to arm/inspect/remove the clip-pipeline cadence, run:

    bash scripts/luna/pipeline-cadence.sh arm|status|disarm [--harvest-time HH:MM] [--synth-time HH:MM] [--health-day DAY] [--health-time HH:MM] [--harvest-model M] [--synth-model M] [--health-model M] [--vault PATH] [--force] [--dry-run]

Registers the luna clip-pipeline's recurring runs with the OS scheduler
(Windows `schtasks` / POSIX crontab), following the `arm-resume.sh` precedent
(direct scheduler invoke, dedup guard `# HIMMEL-Pipeline-*`, runner indirection).
Each run launches a bounded interactive claude session (`claude … < NUL` on
Windows / `< /dev/null` on POSIX, NOT `--print` — stays on Max quota). This shells the SANCTIONED cadence path —
never hand-roll `schtasks`/`cron`. See `.claude/commands/pipeline-cadence.md`.
