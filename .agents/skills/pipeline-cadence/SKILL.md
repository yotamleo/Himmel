---
name: pipeline-cadence
description: Arm/inspect/remove the recurring luna clip-pipeline cadence (daily harvest+triage, weekly synthesize+archive, monthly health) via schtasks/cron. Dedup-guarded. Use when the user asks to arm/check/disarm the clip-pipeline cadence or runs /pipeline-cadence.
---

# pipeline-cadence

When the user asks to arm/inspect/remove the clip-pipeline cadence, run:

    bash scripts/luna/pipeline-cadence.sh arm|status|disarm [--harvest-time HH:MM] [--synth-day DAY] [--synth-time HH:MM] [--health-day N] [--health-time HH:MM] [--vault PATH] [--force] [--dry-run]

Registers the luna clip-pipeline's recurring runs with the OS scheduler
(Windows `schtasks` / POSIX crontab), following the `arm-resume.sh` precedent
(direct scheduler invoke, dedup guard `# HIMMEL-Pipeline-*`, runner indirection).
Each run launches a bounded interactive claude session (`claude … < /dev/null`,
NOT `--print` — stays on Max quota). This shells the SANCTIONED cadence path —
never hand-roll `schtasks`/`cron`. See `.claude/commands/pipeline-cadence.md`.
