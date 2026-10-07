# Version naming scheme (HIMMEL-4873)

How himmel releases are named in Jira (fix versions), tags and the tracker.

## The rule

| Part | Meaning | Example |
|---|---|---|
| patch (`v1.M.P`) | Fixes inside an already shipped minor. No new milestone scope. | `v1.1.1` fixes `v1.1.0` |
| minor (`v1.M.0`) | A milestone: a named body of planned work that ships together. | `v1.2.0` |
| major (`vN.0.0`) | A breaking change, or a new-platform line. | `v2.0.0` (the Windows line) |

A trailing letter (`v1.0.1b`) is the trail form of the original v1.0.x plan
and is not used for new versions.

## Renumber (2026-10-07)

The temporary planning versions `v1.0.3` .. `v1.0.43` were never shipped
patches; they were milestones. They became minors:

| Old | New |
|---|---|
| `v1.0.3`, `v1.0.3b` | `v1.2.0` |
| `v1.0.4` | `v1.3.0` |
| `v1.0.5` | `v1.4.0` |
| `v1.0.6` | `v1.5.0` |
| `v1.0.7`, `v1.0.8` | `v1.6.0` |
| `v1.0.22`, `23`, `25`, `32`, `34`, `37`, `38`, `42` | `v1.7.0` |

The 27 empty versions in that range were archived. `v1.1.x` (ex `v1.0.2b..h`,
HIMMEL-4872) is unchanged, and `v2/v3` stays a planning bucket: `v2.0.0` is
created only when that line starts.

## Tooling

The tracker treats every `v1.N.x` as the train and sorts minors numerically
(`v1.2.0` before `v1.10.0`). See `scripts/handover/console-kit/tracker.py`
(`TRAIN_RE`, `ver_key`).
