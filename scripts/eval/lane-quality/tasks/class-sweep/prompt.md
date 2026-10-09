A reviewer found this in `lq-work/sweep/a.sh`: `cd "$d"` is not checked, so
when the directory does not exist the script carries on in the wrong directory
and still prints its result.

That is a class of bug, not one line. Fix it in `lq-work/sweep/a.sh` and in
every other place under `lq-work/` where the same mistake occurs. A failed `cd`
must stop the script with a non-zero exit status before it prints anything
else. Leave code that is already correct exactly as it is.

Touch nothing outside `lq-work/`. Do not commit. When done, reply with a short
summary: which files you changed, which you deliberately left alone and why,
and what you verified.
