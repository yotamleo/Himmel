# Cloud environment recipe

The one claude.ai cloud environment that makes `claude --cloud` sessions on
`yotamleo/Himmel` start with himmel working (HIMMEL-4429). It is the plugin
profile of [`cloud-brief-template.md`](../handover/cloud-brief-template.md#one-time-operator-setup)
written out field by field. What a session in it has, and why the local shepherd
stays mandatory, is in that template. Platform reference:
[cloud environments](https://code.claude.com/docs/en/cloud-environments).

## Create it

At [claude.ai/code](https://claude.ai/code), select the cloud icon above the
message box, then **Cloud**, then **Add cloud environment** (or hover an existing
one and select its settings icon). Fill in the dialog:

| Field | Value |
|---|---|
| Name | `himmel` |
| Network access | **Trusted** |
| Environment variables | the block below |
| Setup script | the block below |

**Environment variables** (`.env` format, one per line):

```text
JIRA_PROJECT_KEY=HIMMEL
BASH_DEFAULT_TIMEOUT_MS=600000
BASH_MAX_TIMEOUT_MS=600000
```

- Everyone who uses the environment can read these values, so **never put a
  secret here**. The cloud has no Jira token on purpose: Jira goes through the
  claude.ai Atlassian connector, not the local jira CLI.
- Leave `GH_TOKEN` and `GITHUB_TOKEN` unset. The platform's GitHub proxy then
  authenticates `git` and `gh` for the session, and your token never enters the
  VM. A token set here would be readable by anyone using the environment.
- The two timeouts are the documented route. The setup script also writes them to
  `/etc/profile.d/himmel-cloud.sh`, but that only reaches shells that source it.

**Setup script:**

```bash
#!/bin/bash
# rev: 1
rm -rf /tmp/himmel-setup \
  && git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
  && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh --with-plugins || true
```

- Keep the trailing `|| true`. A setup script that exits non-zero stops the
  session from starting; a failed step should cost a tool, not the session.
- It installs shellcheck, `at` and pre-commit, builds the Jira CLI dist, installs
  the obsidian-triage tool deps, and installs the lean plugin profile
  (himmel-ops, lean-skills) into the VM's `~/.claude`. A claude.ai plugin upload
  does not do this: it never loads in a cloud session.
- The Jira dist builds inside `/tmp/himmel-setup`, not in the session's clone
  (`/home/user/Himmel`), because the clone does not exist yet when the script
  runs. Cloud sessions use the Atlassian connector for Jira anyway.

## Network policy

**Trusted** covers everything the setup script and a session reach: GitHub
(`github.com`, `codeload.github.com`, `raw.githubusercontent.com`), npm
(`registry.npmjs.org`), PyPI (`pypi.org`, `files.pythonhosted.org`) and the
Ubuntu archives (`*.ubuntu.com`) for apt. Atlassian needs no entry: MCP connector
traffic goes through Anthropic's servers, not the session's network. Pick
**Custom** only if you need a host outside that list, and tick "Also include
default list of common package managers" so the installs keep working.

## Make it the CLI default

`claude --cloud` does not use the claude.ai selector. In a local terminal run
`/remote-env` once and pick `himmel`. It saves `remote.defaultEnvironmentId` in
your user settings, so every `claude --cloud` from this machine starts in this
environment. Without it the CLI falls back to the Anthropic-hosted **Default**
environment, which has no setup script.

## Cache and refresh

- The setup script runs on the first session. If it finishes in about five
  minutes, the platform snapshots the filesystem and later sessions start from
  that snapshot without re-running it.
- The snapshot is rebuilt when the setup script text or the allowed network hosts
  change, and when it expires after about seven days. The plugins come from that
  frozen `/tmp/himmel-setup` clone, so a plugin change on `main` reaches new
  sessions only after a rebuild. To force one, bump the `# rev:` line.
- A paused session that resumes does not re-run the setup script, and keeps the
  environment variables it last read until its VM is restored or rebuilt. Start a
  new session to pick up a change at once.

## Check it

Start one session in the environment and ask it to run:

```bash
echo CLAUDE_CODE_REMOTE=$CLAUDE_CODE_REMOTE BASH_DEFAULT_TIMEOUT_MS=$BASH_DEFAULT_TIMEOUT_MS
shellcheck --version | sed -n 2p
ls ~/.claude/plugins
```

Expect `CLAUDE_CODE_REMOTE=true`, `BASH_DEFAULT_TIMEOUT_MS=600000`, a shellcheck
version, and a plugins directory. Then ask it to list its skills: the
`himmel-ops:` and `lean-skills:` skills should be there.
