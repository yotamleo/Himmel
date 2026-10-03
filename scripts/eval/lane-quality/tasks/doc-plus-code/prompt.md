`lq-work/log-tail.sh` prints the last N lines of a log file, and
`lq-work/README.md` documents it. Add a `--grep PATTERN` option.

- `--grep PATTERN` keeps only the lines matching the extended regular
  expression PATTERN, and the last N lines are then taken from those matches.
- Options may appear in any order before FILE. Without `--grep`, behaviour is
  unchanged.
- No matching line prints nothing and exits 0.
- `--grep` with no value, or an invalid regular expression, is a usage error:
  a message on stderr and exit 64.
- Update `lq-work/README.md`: the usage line, a row for the new option in the
  options table, and one example. Keep the rest of the README accurate.
- Add `lq-work/test-log-tail.sh`, a self-contained bash test covering the new
  option, which exits non-zero when any case fails.

Touch nothing outside `lq-work/`. Do not commit. When done, reply with a short
summary of what you changed and what you verified.
