# Google Health Connector Setup Guide (alpha)

- **Ticket:** HIMMEL-609
- **Status:** ALPHA — opt-in, inert until configured
- **API surface:** Google Health API v4 (`health.googleapis.com/v4`), the Fitbit-Web-API successor

---

## What this is

The Google Health connector pulls wearable vitals directly from Google's cloud and feeds them
into the luna-vitals series pipeline (`50-Vitals/` → luna-correlate). It is **opt-in and inert**
until you supply OAuth credentials. At personal data volumes the API is free ($0).

The connector writes a **review artifact** — a JSON file of proposed `(metric, date, value)` rows.
You inspect it, then land it with the existing `cli.ts merge` + `cli.ts write` commands.
Nothing writes to `50-Vitals/` automatically.

---

## Prerequisites

- A Google account with wearable data actively syncing into **Google Health**. Two common paths:
  - **Fitbit** — syncs natively via a connected Google account (Settings → Fitbit → Link).
  - **Samsung Galaxy Watch / Galaxy Ring** — sync via **Health Connect** on Android (Samsung Health
    → Settings → Manage data → Connect apps → Health Connect). Samsung has no direct cloud API;
    Health Connect is the Android-side funnel that moves the data into Google Health.
- **Bun** installed (`bun --version` ≥ 1.0).
- The repo `.env` file (gitignored) at the project root — the connector reads from and writes
  credentials to it.

---

## One-time Google Cloud setup

Do this once per Google account. Estimated time: 15 minutes.

**1. Create a Google Cloud project.**
Go to [console.cloud.google.com](https://console.cloud.google.com), create a new project
(e.g. `my-health-connector`).

**2. Enable the Google Health API.**
In the project, navigate to APIs & Services → Library, search for **Google Health API**, and enable it.

**3. Configure the OAuth consent screen.**
APIs & Services → OAuth consent screen:
- User type: **External** (even for personal use).
- App name + email: any placeholder values.
- Publishing status: leave as **Testing** (see the 7-day caveat below).
- Add yourself as a **Test user** (your own Google account email).

**4. Add the required scopes.**
In the consent screen's "Scopes" step, click **"Manually add scopes"** and paste all six:

```
https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
https://www.googleapis.com/auth/googlehealth.sleep.readonly
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
https://www.googleapis.com/auth/googlehealth.nutrition.readonly
https://www.googleapis.com/auth/googlehealth.ecg.readonly
https://www.googleapis.com/auth/googlehealth.irn.readonly
```

These are restricted scopes; Google will show a verification warning during the OAuth flow —
this is expected for a personal Testing app.

**5. Create an OAuth 2.0 client.**
APIs & Services → Credentials → Create credentials → **OAuth client ID**:
- Application type: **Web application**.
- Authorized redirect URIs: add `http://localhost` (exact, no port, no trailing slash).

Copy the **Client ID** and **Client Secret**.

---

## Get a refresh token

> **Why not the OAuth Playground?** The Playground mints tokens under Google's own client ID,
> not yours. Google Health's restricted scopes reject tokens from any client that isn't the one
> registered on your consent screen — you'll get `unauthorized_client`. Use the flow below instead.

**Step 1.** Add your credentials to the repo `.env`:

```env
GOOGLE_HEALTH_CLIENT_ID=<your-client-id>
GOOGLE_HEALTH_CLIENT_SECRET=<your-client-secret>
```

**Step 2.** Generate the authorization URL:

```sh
bun scripts/luna-vitals/connectors/google-health.ts auth-url
```

Copy the printed URL and open it in a browser. Sign in, grant all six scopes.

**Step 3.** After you approve, the browser tries to navigate to `http://localhost/?code=...` and
shows a "This site can't be reached" error. **That is expected.** Copy the full URL from the
address bar.

**Step 4.** Exchange the code for a refresh token:

```sh
bun scripts/luna-vitals/connectors/google-health.ts auth-exchange --code "<code-or-full-url>"
```

You can pass either the bare `code` value or the full `http://localhost/?code=...` URL — the
connector extracts the code either way.

On success it prints `OK: refresh token written to .env` and adds
`GOOGLE_HEALTH_REFRESH_TOKEN=...` to `.env`. The token value is never printed.

---

## The 7-day Testing-token caveat

**Testing-mode refresh tokens expire after roughly 7 days.** When the token expires the cadence
wrapper exits with code **75** and prints a re-consent reminder on stderr:

```
[pull-cadence] re-consent needed: Google Health OAuth token has expired or was revoked.
[pull-cadence] To re-auth, run auth-url then auth-exchange: ...
```

To refresh: re-run Steps 2–4 above. The `auth-exchange` command overwrites the old
`GOOGLE_HEALTH_REFRESH_TOKEN` line in `.env` in place.

Going **Production** (verified app) removes the expiry but requires a CASA Tier 2 security
assessment for restricted scopes — out of scope for alpha personal use.

---

## Pulling data

The `pull` subcommand fetches all supported data types for a date window and writes a review
artifact. It does **not** write `50-Vitals/` directly.

```sh
bun scripts/luna-vitals/connectors/google-health.ts pull \
  --from 2026-01-01 \
  --to   2026-06-29 \
  --out  /tmp/gh-vitals-2026.json
```

The connector prints a per-metric row count to stderr so you can verify coverage before landing.

**Review, then land.** Once you are satisfied with the artifact:

```sh
# 1. Merge: connector artifact FIRST so wearable values win on overlap.
bun scripts/luna-vitals/cli.ts merge \
  --det /tmp/gh-vitals-2026.json \
  --llm /path/to/llm-artifact.json \
  --out /tmp/merged.json

# 2. Write merged rows into 50-Vitals/.
bun scripts/luna-vitals/cli.ts write /tmp/merged.json --dir /path/to/50-Vitals
```

> **Precedence note:** list the connector artifact under `--det` (deterministic) and any
> LLM-extracted artifact under `--llm`. The merge engine gives deterministic sources priority
> over LLM sources on the same `(metric, date)`. Swapping them causes note-derived values to
> silently overwrite wearable readings.

---

## Scheduling (opt-in)

`scripts/luna-vitals/connectors/pull-cadence.sh` (plus a `.ps1` twin for Windows) is a
thin wrapper that:

- Defaults the pull window to yesterday → today (UTC).
- Writes the artifact to `LUNA_VITALS_ARTIFACT_DIR` (default: a `.gh-vitals/` sibling to the script).
- Exits 75 with a re-consent reminder if the OAuth token has expired.
- Exits non-zero on any other error.
- Does **not** call `write` — that remains a manual step.

Wire it into your scheduler using the **pipeline-cadence** mechanism (`/pipeline-cadence` in
himmel):

```sh
# Example: run daily at 06:00 UTC (cron)
0 6 * * * LUNA_VITALS_ARTIFACT_DIR=/path/to/artifacts \
  /path/to/scripts/luna-vitals/connectors/pull-cadence.sh

# On Windows, use pull-cadence.ps1 scheduled via Task Scheduler / schtasks.
```

**Date overrides** (useful for backfill or testing):

```sh
FROM=2026-06-01 TO=2026-06-15 pull-cadence.sh
```

---

## Coverage

The connector covers approximately 30 data streams, collapsed into the series below.
Three rollup-only types (`calories-in-heart-rate-zone`, `floors`, `total-calories`) are
scaffolded but gated — their API response shape is unverified and they are skipped at runtime
with a logged notice.
Categorical and bulky types (ECG waveforms, food database entries, activity-level enums,
HR-zone config, nutrition-log multi-nutrient arrays) are excluded from the series.

| Group | Series written to 50-Vitals/ | Notes |
|---|---|---|
| **Heart vitals** | `rhr_bpm` (derived: 5th-pctile of raw HR samples per day) | Live Samsung HR feed; Fitbit native aggregate stopped 2024-09 |
| | `daily_hrv_ms` (daily RMSSD aggregate), `hrv_ms` (sample mean) | Historical |
| | `daily_spo2_pct` (daily avg), `spo2_pct` (sample mean) | Live (Samsung) |
| | `respiratory_rate` | Historical |
| | `sleep_temp_c` | Historical |
| **Body composition** | `weight_kg`, `height_cm`, `body_fat_pct` | Point-in-time samples |
| **Activity** | `steps`, `distance_km`, `active_energy_kcal`, `active_minutes` | Sub-daily intervals, summed per day |
| | `active_zone_minutes`, `sedentary_minutes`, `altitude_gain_km` | Sub-daily intervals, summed per day |
| | `swim_strokes`, `exercise_minutes` | Rare / device-dependent |
| **Sleep** | `sleep_hours` (time in bed), `sleep_asleep_hours` (non-AWAKE stages) | Longest session per date |
| **Nutrition** | `hydration_ml` | Log entries, summed per day |
| **Scaffolded (gated)** | `calories_in_hr_zone_kcal`, `floors`, `total_calories_kcal` | Skipped at runtime; dailyRollUp shape unverified |

---

## Privacy and security

Vitals are personal health information (PHI):

- Keep `GOOGLE_HEALTH_REFRESH_TOKEN` in `.env` only. The `.env` file is gitignored — confirm
  `git check-ignore -v .env` before the first commit in a new clone.
- The connector **never prints secret values** — `auth-exchange` prints only a confirmation
  message and the granted scope string.
- Review artifacts and `50-Vitals/` CSVs contain health data. Treat them per your vault's
  privacy posture: do not commit them to a public repository, and do not sync them to
  cloud storage you do not control.
- The OAuth flow uses `http://localhost` as the redirect URI. The browser navigates to that
  address and fails to load (no local server is running) — copy the code from the URL bar
  before closing the tab.
