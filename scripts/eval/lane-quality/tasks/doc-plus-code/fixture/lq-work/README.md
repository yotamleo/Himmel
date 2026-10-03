# lq-work tools

## log-tail.sh

Print the last N lines of a log file.

### Usage

    log-tail.sh [-n N] FILE

| Option | Meaning |
|---|---|
| `-n N` | number of lines to print (default 10) |

### Exit codes

0 success, 64 usage error, 66 unreadable file.
