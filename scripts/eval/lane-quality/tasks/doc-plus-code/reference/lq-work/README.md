# lq-work tools

## log-tail.sh

Print the last N lines of a log file.

### Usage

    log-tail.sh [-n N] [--grep PATTERN] FILE

| Option | Meaning |
|---|---|
| `-n N` | number of lines to print (default 10) |
| `--grep PATTERN` | keep only lines matching the extended regex, then take the last N |

Example: `log-tail.sh --grep ERROR -n 5 app.log`

### Exit codes

0 success, 64 usage error, 66 unreadable file.
