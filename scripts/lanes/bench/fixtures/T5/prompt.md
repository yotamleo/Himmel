This directory holds the public-propagation exclusion lists and the
secret-scan patterns used before a repo mirror is published.

1. Add these four new entries to BOTH exclusion lists below (each list must
   end up containing all four, in addition to its existing entries):

   - `config/local-secrets/`
   - `.himmel-cache/`
   - `scripts/vault-keys/`
   - `notes/private-journal/`

   - In `propagation-config.sh`, add them to the `PRIVATE_PATHS` bash array,
     matching the existing style (one double-quoted entry per line).
   - In `propagation-config.json`, add them to the `privatePaths` JSON array,
     matching the existing style (one double-quoted, comma-separated entry
     per line), keeping the file valid JSON.

   Do not reorder, remove, or otherwise change any of the existing entries
   in either list.

2. In `secret-scan-patterns.txt`, anchor the OpenAI-style secret-key
   pattern — the line that currently reads exactly:

       sk-[A-Za-z0-9]{48}

   by adding `^` at the very start and `$` at the very end, so the line
   becomes exactly:

       ^sk-[A-Za-z0-9]{48}$

   Leave every other line in that file exactly as it is.

Do not modify `validate.sh` or any other file in this directory. After your
edit, running `bash validate.sh` from this directory must exit 0.
