Create `lq-work/block-curl-pipe.sh`, a Claude Code PreToolUse hook.

It reads one JSON event on stdin, shaped like
`{"tool_name": "Bash", "tool_input": {"command": "..."}}`.

- When `tool_name` is `Bash` and the command pipes the output of `curl` or
  `wget` into a shell interpreter (`sh`, `bash`, `zsh` or `dash`, including
  through `sudo`), refuse: print a one-line reason on stderr and exit 2.
- Everything else is allowed: exit 0 and print nothing. That includes piping
  curl into a non-shell program (for example `jq` or `shellcheck`), downloading
  to a file, running a local script, and any tool other than `Bash`.
- Input that is not valid JSON is refused (exit 2): the hook fails closed.
- It may use `jq`.

Also add `lq-work/test-block-curl-pipe.sh`, a self-contained bash test that
exits non-zero when any case fails.

Touch nothing outside `lq-work/`. Do not commit. When done, reply with a short
summary of what you changed and what you verified.
