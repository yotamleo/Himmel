# 50-Vitals series registry

| metric | scale / unit | meaning | provenance |
|---|---|---|---|
| migraine | 0–3 | headache/migraine severity that day | self-report (vault backfill HIMMEL-355) |
| skin_flare | 0–3 | atopic-dermatitis flare severity | self-report |
| sleep_hours | hours | sleep duration | device export / self-report |
| hrv_ms | ms | heart-rate variability | device export |
| rhr_bpm | bpm | resting heart rate | device export |

Series files: `<metric>.csv` (header `date,value`, ISO dates). Written only via the reviewed luna-vitals
extraction (never auto). LUNA_SERIES_DIR points here.
