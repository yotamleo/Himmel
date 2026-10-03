Create `lq-work/semver-cmp.sh` in this repository.

Usage: `semver-cmp.sh A B`, where A and B are versions of the form
`MAJOR.MINOR.PATCH` (three non-negative decimal integers, no leading `v`, no
pre-release or build suffix). Compare them numerically, component by component,
and print exactly one of `-1`, `0` or `1` on stdout (A older, equal, newer),
then exit 0. With the wrong number of arguments, or a malformed version, print
a message to stderr and exit 64.

Also create `lq-work/test-semver-cmp.sh`: a self-contained bash test for the
script that exits non-zero when any case fails. Write the test first and run it
to show it failing before the script exists (RED), then write the script and
show the test passing (GREEN).

Touch nothing outside `lq-work/`. Do not commit. When done, reply with a short
summary of what you changed and what you verified.
