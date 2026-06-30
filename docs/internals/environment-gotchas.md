# Environment & tool-delivery gotchas

Platform and harness-tool traps that bite when running himmel — especially on
Windows — or when authoring himmel shell scripts. These are generic (no
machine-specific config); they reproduce on any WSL-enabled Windows box, any
bash-5.1+ environment, or any Claude Code session. The Codex-specific hook
wiring trap lives in [`harness-compat.md`](harness-compat.md); guardrail-recovery
escape hatches live in [`stuck-playbook.md`](stuck-playbook.md).

## Windows: bare `bash` resolves to the System32 WSL stub

On a WSL-enabled Windows box, a bare `bash` — from PowerShell, `& bash` in a
`.ps1`, or any tool shelling out — resolves to `C:\WINDOWS\system32\bash.exe`,
the **WSL launcher**, NOT Git Bash. WSL bash cannot read `C:\…` / `C:/…` paths →
it errors `No such file or directory` and exits **127** on a Windows-style script
path (it would need `/mnt/c/…`). `Get-Command bash` confirms the source.

Resolve Git Bash explicitly anywhere a `.ps1` or PS command shells out to a bash
script:

```powershell
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $gitBash)) {
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
}
& $gitBash "C:/path/to/script.sh" arg1 arg2
```

The `-notmatch 'System32'` clause is the key — it rejects the WSL stub on the
fallback path. Operator hand-off commands that call bash on Windows must use the
full Git Bash path `& "C:\Program Files\Git\bin\bash.exe" …`. (This is the same
stub Codex's hook wrapper has to skip — see `harness-compat.md`.)

## Windows: `python3` / `python` may be the WindowsApps Store stub

On a box with no classic CPython install, `python3` and `python` resolve to the
Microsoft Store WindowsApps stub (`PythonSoftwareFoundation.PythonManager`). The
stub can **wedge machine-wide**: it ignores `SIGTERM` (so GNU `timeout` without
`-k` waits forever, and its orphan child holds inherited stdout pipes so `$(…)`
command substitution blocks even after a kill), and has been observed to then
fail with "The specified disk or diskette cannot be accessed (os error 26)".

Mitigations for scripts that must call `python3`:

- Install a real interpreter (e.g. `uv python install 3.12`) and shim a wrapper
  dir onto `PATH` for test runs.
- Always wrap with `timeout -k 5 10` (the `-k` is mandatory) **and** redirect
  stdout to a file, never command substitution.

## Claude Code Bash tool strips one backslash level vs a `.sh` file

Verifying backslash-sensitive code (sed replacements, regex normalization) by
running a one-liner **through the Bash tool** is unreliable: the tool's command
delivery strips one backslash level that the same code in a written `.sh` **file**
keeps. A form that is correct in a file can look broken when poked via a Bash-tool
one-liner, and vice-versa — this has produced false-positive "Critical" review
findings where the original file form was actually correct.

Rule: never trust a Bash-tool one-liner to validate backslash counts. Write the
snippet to a real `.sh` file and run that, or rely on the script's test suite, and
add a regression test that pins the emitted pattern plus a match so the correct
form can't later be "fixed" wrong. A reviewer's shell reproduction of a backslash
bug is suspect — re-verify in-file.

Sibling MINGW gotcha: `grep -iF` aborts (SIGABRT, rc 134) on the `-i`+`-F`
combination even on pure ASCII input. Use `-F` alone.

## bash 5.1+ treats a literal `&` in `${var//pat/repl}` as the matched text

In a parameter-expansion replacement, bash 5.1+ expands a literal `&` to the
matched text:

```bash
s="${s//</&lt;}"   # yields "<lt;", NOT "&lt;" — the & became the matched "<"
```

So a naive `${//}`-based XML/HTML escaper is silently broken on bash 5.1+, and the
`&`→`&amp;` step only looks right by accident (its match *is* `&`). Pre-5.1 bash
(including the macOS 3.2 baseline) treats `&` literally, so the bug is
version-dependent — it passes on one platform and corrupts on another.

Escape with `sed`, where `\&` is an unambiguous literal ampersand on every
version, and run the `&` rule first so the entities it introduces aren't
re-escaped:

```bash
printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
```

Pin it with a unit test (e.g. `'a & b < c > d'` → `'a &amp; b &lt; c &gt; d'`).

## Windows: `schtasks /create /xml` rejects a UTF-8 prolog

`schtasks /create /xml` rejects an `encoding="UTF-8"` XML prolog with
`"(1,40):: unable to switch the encoding"`. Declaring `encoding="UTF-16"` over
plain-ASCII bytes is accepted. So: write the task XML ASCII-only and declare
UTF-16 (a genuinely non-ASCII value would need a real UTF-16LE+BOM file). The
reason to use `/xml` at all is that `schtasks /create` has no flag for
`StartWhenAvailable` (run a missed scheduled start when next available) — the only
CLI route to that setting is `/create /xml`.

## Anthropic output content-filter trips on policy text and minified blobs

The 400 "Output blocked by content filtering policy" error scans the model's
**generated** output. Two things trip it during OSS / community-health work:

1. **Generating Code-of-Conduct / anti-harassment policy text.** Documents like
   the Contributor Covenant enumerate prohibited behaviors (harassment, abuse,
   sexualized language) — a dense cluster of exactly the flagged-category
   vocabulary the filter watches, so writing the policy reads like the content it
   blocks.
2. **Large minified / obfuscated blobs in context** (e.g. a vendored plugin
   `main.js`) — high-entropy payloads read as possible malware.

Workarounds:

- For standard policy docs, **download instead of generate**:
  `curl -fsSL <canonical-url> -o CODE_OF_CONDUCT.md`, then `sed` any placeholder.
  The content lands on disk, never through model output. Don't `cat` it back —
  keep the trigger text out of context for later turns (verify with `grep`/`wc`).
- For code review over vendored bundles, feed reviewers a scoped diff that
  excludes minified js/css and any downloaded policy file.
- It's intermittent (a per-turn classifier threshold) — in an interactive
  terminal a blocked turn is usually transient and re-sending succeeds.

## Windows: pre-commit auto-fixers crash on non-ASCII filenames (and mangle the file first)

The pre-commit-hooks `trailing-whitespace` and `end-of-file-fixer` fixers print
the path of each file they touch (e.g. trailing-whitespace's
`print(f'Fixing {filename}')`). On Windows that
`print` goes to a cp1252-encoded stdout, so a filename containing non-ASCII
characters — Hebrew/CJK/accented source notes, common in luna / Salus medical
vaults — raises `UnicodeEncodeError: 'charmap' codec can't encode…` and the hook
exits non-zero. **Worse: the fixer rewrites the file (strips trailing whitespace
across the whole file) *before* it prints, so the abort leaves a silent
whitespace-only diff** — a 217-page verbatim extraction once produced a 20k-line
diff that had to be manually restored.

Two independent mitigations:

- **Repo-config (preferred, inherited):** don't let the auto-fixers run on
  non-code files at all. In a content repo (a vault), notes and ingested sources
  are user data — pre-commit should validate them (gitleaks/check-*) but never
  rewrite them. Constrain both fixers to an ASCII-named code/config **allowlist**
  rather than a denylist (a denylist can't enumerate every non-ASCII name a vault
  might hold):

  ```yaml
  - id: trailing-whitespace
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  - id: end-of-file-fixer
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  ```

  This is what the luna-second-brain template ships (HIMMEL-615). pre-commit has
  **no per-hook `env:` key**, so encoding can't be forced from the config itself.
- **Machine env (defense-in-depth, for code repos where the fixers must run on
  arbitrary paths):** export `PYTHONUTF8=1` (or `PYTHONIOENCODING=utf-8`) in the
  shell that runs `git commit`, which forces every Python hook to a UTF-8 stdout
  and stops the crash. Note this only prevents the *crash* — the fixer still
  rewrites the matched file, so it's not a substitute for the allowlist when the
  rewrite itself is unwanted.

## rtk token-proxy rewrites top-level Bash-tool commands

If you run [rtk](../setup/rtk-md.md) as a Claude Code PreToolUse rewrite hook, be
aware it rewrites **top-level** Bash-tool commands (not commands inside a script
file). Notably `git diff` becomes a compressed stat summary rather than a unified
diff, and `grep`/`cat`/`tail` with a file redirection can write rtk's summary text
into the target file. Get a real unified diff with `rtk proxy git diff …`; never
redirect an rtk-intercepted command into a file that matters (use the Read/Write/
Edit tools or run the pipeline inside a script file); and verify any file produced
by a top-level pipeline before trusting it. The benign `[rtk] /!\ No hook installed`
banner under himmel's guard wrapper is covered in
[`enforcement.md`](enforcement.md).
