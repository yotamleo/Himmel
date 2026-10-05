#!/usr/bin/env bash
# HIMMEL-4471: scripts/luna/vault-stall-cadence.sh detects a luna vault
# auto-commit stall and remediates ONLY the known-benign classes under
# handovers/ (a shellcheck/check-json path exclude; a gitleaks finding whose
# secret fully matches a CLOSED machine-generated shape). Anything else alerts
# with no commit, and no alert, log or state file ever carries the secret.
#
# Every fixture is a scratch git repo under mktemp; the live vault is never
# touched. Its .git/hooks/pre-commit is a small stand-in for the vault's
# no-stash pre-commit wrapper: it honours each hook's `exclude:` in the
# fixture's .pre-commit-config.yaml, runs the REAL shellcheck and the REAL
# gitleaks against the fixture's .gitleaks.toml, and prints pre-commit's own
# `- hook id: <id>` failure format.
# shellcheck disable=SC2016  # fixture bodies and backtick-quoted tokens are literal on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/luna/vault-stall-cadence.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $3" ;; esac; }
assert_not_has() { case "$3" in *"$2"*) fail "$1" "unexpected '$2' in: $3" ;; *) pass "$1" ;; esac; }

for t in git jq gitleaks shellcheck python3 flock; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP all — $t not on PATH"; exit 0; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-stall-cadence.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Secret-shaped literals are assembled at runtime so this file itself never
# trips a scanner.
LOCK_TOKEN="cachyos-x8664""-pid801122"
AWS_KEY="AKIA""IOSFODNN7""EXAMPLQ"

cat >"$TMP/sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TMP/sent.log"
EOF
chmod +x "$TMP/sender.sh"

# The stand-in pre-commit wrapper.
cat >"$TMP/fake-pre-commit" <<'HOOK'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)" || exit 2
mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR)
[ "${#files[@]}" -eq 0 ] && exit 0
excl() { awk -v id="$1" '
    $0 ~ "- id: "id"$" { on = 1; next }
    /- id: / { on = 0 }
    on && /exclude:/ { sub(/^[^:]*:[ \t]*/, ""); gsub(/^'\''|'\''$/, ""); print; exit }
' .pre-commit-config.yaml; }
skipped() { case ",${SKIP:-}," in *",$1,"*) return 0 ;; esac; return 1; }
rc=0
sc_ex="$(excl shellcheck)"; cj_ex="$(excl check-json)"
sc_out=""; cj_out=""
for f in "${files[@]}"; do
    case "$f" in
        *.sh) if [ -z "$sc_ex" ] || ! printf '%s' "$f" | grep -Eq "$sc_ex"; then
                  o="$(shellcheck "$f" 2>&1)" || sc_out="$sc_out$o"$'\n'
              fi ;;
        *.json) if [ -z "$cj_ex" ] || ! printf '%s' "$f" | grep -Eq "$cj_ex"; then
                  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null \
                      || cj_out="$cj_out$f: Failed to json decode (Expecting value)"$'\n'
              fi ;;
    esac
done
if [ -n "$sc_out" ]; then
    printf 'shellcheck...Failed\n- hook id: shellcheck\n- exit code: 1\n\n%s\n' "$sc_out"; rc=1
fi
if [ -n "$cj_out" ]; then
    printf 'check json...Failed\n- hook id: check-json\n- exit code: 1\n\n%s\n' "$cj_out"; rc=1
fi
if ! gitleaks git --pre-commit --redact --staged --no-banner --log-level error --config .gitleaks.toml . >/dev/null 2>&1; then
    printf 'Detect hardcoded secrets...Failed\n- hook id: gitleaks\n- exit code: 1\n\n'; rc=1
fi
if ! skipped trailing-whitespace; then
    echo "fixer-ran" >>.git/fixer-ran.log
fi
exit "$rc"
HOOK
chmod +x "$TMP/fake-pre-commit"

N=0
# mkvault — a fresh fixture vault whose last commit is 2 h old: the clobbered
# (pre-template-fix) configs, a narrow shellcheck exclude and no lock-token
# allowlist line.
mkvault() {
    N=$((N + 1))
    V="$TMP/v$N"
    mkdir -p "$V/handovers" "$V/scripts"
    git -C "$V" init -q -b main
    git -C "$V" config user.email t@example.invalid
    git -C "$V" config user.name t
    cat >"$V/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
        files: '\.(sh|ps1|yaml|yml|json|toml)$'
      - id: check-json
        exclude: '^handovers/.*/verdicts/'

  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
        exclude: ^handovers/.*/(verdicts|logs)/

  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
EOF
    cat >"$V/.gitleaks.toml" <<'EOF'
[extend]
useDefault = true

[allowlist]
description = "fixture"
regexes = [
  '''^himmel-local-claudex$''',
]
EOF
    echo seed >"$V/README.md"
    git -C "$V" add -A
    GIT_COMMITTER_DATE="@$(($(date +%s) - 7200)) +0000" GIT_AUTHOR_DATE="@$(($(date +%s) - 7200)) +0000" \
        git -C "$V" commit -q -m seed
    cp "$TMP/fake-pre-commit" "$V/.git/hooks/pre-commit"
    : >"$TMP/sent.log"
    S="$TMP/state$N"
    rm -f "$TMP/alerts.log"; rm -rf "$TMP/dedupe"
}

run_sut() {
    HOME="$TMP/home" VAULT_STALL_STATE_DIR="$S" \
        CADENCE_ALERT_SEND_CMD="$TMP/sender.sh" CADENCE_ALERT_FILE="$TMP/alerts.log" \
        CADENCE_ALERT_DEDUPE_DIR="$TMP/dedupe" \
        bash "$SUT" run --vault "$V" "$@" 2>&1
}
head_sha() { git -C "$V" rev-parse HEAD; }
head_files() { git -C "$V" show --name-only --format= HEAD | sort | tr '\n' ' '; }
staged() { git -C "$V" diff --cached --name-only | sort | tr '\n' ' '; }
hook_rc() { (cd "$V" && SKIP=trailing-whitespace,end-of-file-fixer git hook run pre-commit >/dev/null 2>&1); echo $?; }
sent() { cat "$TMP/sent.log" 2>/dev/null; }

# --- T1 shellcheck stall under handovers/ → exclude re-applied, committed ----
mkvault
printf '#!/usr/bin/env bash\nfor f in $(cat list); do echo $f; done\n' >"$V/handovers/x.sh"
git -C "$V" add handovers/x.sh
out="$(run_sut)"; rc=$?
assert_eq "T1 run exits 0" "0" "$rc"
assert_has "T1 commit message names the ticket and class" "chore(vault): [HIMMEL-4471] remediate stall class shellcheck" "$(git -C "$V" log -1 --format=%s)"
assert_eq "T1 commit holds ONLY the config" ".pre-commit-config.yaml " "$(head_files)"
assert_eq "T1 backlog still staged, untouched" "handovers/x.sh " "$(staged)"
assert_has "T1 shellcheck exclude now covers handovers/" "exclude: '^handovers/|" "$(sed -n '/id: shellcheck/,/id: gitleaks/p' "$V/.pre-commit-config.yaml")"
assert_eq "T1 the hook now passes on the backlog" "0" "$(hook_rc)"
assert_eq "T1 no alert sent" "" "$(sent)"
assert_eq "T1 the cadence never ran the content fixers" "no" "$([ -f "$V/.git/fixer-ran.log" ] && echo yes || echo no)"

# --- T2 lock-token gitleaks stall → canonical regex added, committed ---------
mkvault
printf -- '- 10:00 LIVE — release-token: `%s`\n' "$LOCK_TOKEN" >"$V/handovers/b.md"
git -C "$V" add handovers/b.md
out="$(run_sut)"; rc=$?
assert_eq "T2 run exits 0" "0" "$rc"
assert_has "T2 commit names the gitleaks lock-token class" "remediate stall class gitleaks:lock-token" "$(git -C "$V" log -1 --format=%s)"
assert_eq "T2 commit holds ONLY the gitleaks config" ".gitleaks.toml " "$(head_files)"
assert_has "T2 canonical lock-token regex present" "'''^[a-z0-9]+-[a-z0-9]+-pid[0-9]+[.,;:)]?\$'''" "$(cat "$V/.gitleaks.toml")"
assert_eq "T2 backlog still staged" "handovers/b.md " "$(staged)"
assert_eq "T2 the hook now passes" "0" "$(hook_rc)"
assert_eq "T2 no alert sent" "" "$(sent)"

# --- T3 AWS-key shape → NO allowlist, NO commit, alert without the secret -----
mkvault
before="$(head_sha)"; toml_before="$(cat "$V/.gitleaks.toml")"
printf 'aws_key = "%s"\n' "$AWS_KEY" >"$V/handovers/c.md"
git -C "$V" add handovers/c.md
out="$(run_sut)"; rc=$?
assert_eq "T3 run exits 0" "0" "$rc"
assert_eq "T3 no commit" "$before" "$(head_sha)"
assert_eq "T3 gitleaks config untouched" "$toml_before" "$(cat "$V/.gitleaks.toml")"
assert_has "T3 alert names the rule" "aws-access-token" "$(sent)"
assert_has "T3 alert names file:line" "handovers/c.md:1" "$(sent)"
assert_not_has "T3 alert never carries the secret" "$AWS_KEY" "$(sent)"
assert_not_has "T3 alert log never carries the secret" "$AWS_KEY" "$(cat "$TMP/alerts.log" 2>/dev/null)"
assert_not_has "T3 run output never carries the secret" "$AWS_KEY" "$out"
assert_eq "T3 no state file carries the secret" "" "$(grep -rl "$AWS_KEY" "$S" "$TMP/home" 2>/dev/null)"

# --- T4 mixed (lock token + AWS key) → all-or-nothing: nothing applied -------
mkvault
before="$(head_sha)"; toml_before="$(cat "$V/.gitleaks.toml")"
printf 'release-token: `%s`\naws_key = "%s"\n' "$LOCK_TOKEN" "$AWS_KEY" >"$V/handovers/d.md"
git -C "$V" add handovers/d.md
out="$(run_sut)"
assert_eq "T4 no commit" "$before" "$(head_sha)"
assert_eq "T4 benign half NOT applied either" "$toml_before" "$(cat "$V/.gitleaks.toml")"
assert_has "T4 alert sent" "aws-access-token" "$(sent)"

# --- T5 closed shape OUTSIDE handovers/ → alert, no commit -------------------
mkvault
before="$(head_sha)"
printf 'release-token: `%s`\n' "$LOCK_TOKEN" >"$V/notes.md"
git -C "$V" add notes.md
out="$(run_sut)"
assert_eq "T5 no commit" "$before" "$(head_sha)"
assert_has "T5 alert names the file" "notes.md:1" "$(sent)"

# --- T6 shellcheck outside handovers/ → alert, no commit ---------------------
mkvault
before="$(head_sha)"
printf '#!/usr/bin/env bash\nfor f in $(cat list); do echo $f; done\n' >"$V/scripts/y.sh"
git -C "$V" add scripts/y.sh
out="$(run_sut)"
assert_eq "T6 no commit" "$before" "$(head_sha)"
assert_has "T6 alert names hook and file" "shellcheck scripts/y.sh" "$(sent)"

# --- T7 loop cap: the same class again within 24 h → alert, no commit --------
mkvault
printf '#!/usr/bin/env bash\nfor f in $(cat list); do echo $f; done\n' >"$V/handovers/x.sh"
git -C "$V" add handovers/x.sh
cp "$V/.pre-commit-config.yaml" "$TMP/clobbered.yaml"
run_sut >/dev/null
assert_has "T7 first remediation committed" "remediate stall class shellcheck" "$(git -C "$V" log -1 --format=%s)"
# a luna-upgrade-style clobber puts the narrow exclude back (an old-dated commit)
cp "$TMP/clobbered.yaml" "$V/.pre-commit-config.yaml"
GIT_COMMITTER_DATE="@$(($(date +%s) - 7200)) +0000" git -C "$V" commit -q --only -m clobber -- .pre-commit-config.yaml
before="$(head_sha)"; : >"$TMP/sent.log"
out="$(run_sut)"
assert_eq "T7 no second remediation commit" "$before" "$(head_sha)"
assert_has "T7 alert says the fix did not hold" "did-not-hold shellcheck" "$(sent)"

# --- T8 busy: github-sync holds the index lock → skip, exit 0 ----------------
mkvault
printf '#!/usr/bin/env bash\nfor f in $(cat list); do echo $f; done\n' >"$V/handovers/x.sh"
git -C "$V" add handovers/x.sh
: >"$V/.git/index.lock"
before="$(head_sha)"
out="$(run_sut)"; rc=$?
assert_eq "T8 exits 0" "0" "$rc"
assert_has "T8 reports busy" "busy" "$out"
assert_eq "T8 no commit" "$before" "$(head_sha)"
rm -f "$V/.git/index.lock"

# --- T9 overlapping run: the run lock is held → skip, exit 0 -----------------
mkdir -p "$S"
exec 8>"$S/run.lock"
flock 8
out="$(run_sut)"; rc=$?
exec 8>&-
assert_eq "T9 exits 0" "0" "$rc"
assert_has "T9 reports busy" "busy" "$out"
assert_eq "T9 no commit" "$before" "$(head_sha)"

# --- T10 --dry-run: classification + plan printed, nothing written -----------
out="$(run_sut --dry-run)"; rc=$?
assert_eq "T10 exits 0" "0" "$rc"
assert_has "T10 prints the classification" "benign shellcheck shellcheck handovers/x.sh:2" "$out"
assert_has "T10 prints the planned edit" "would" "$out"
assert_eq "T10 no commit" "$before" "$(head_sha)"
assert_eq "T10 config untouched" "" "$(git -C "$V" diff -- .pre-commit-config.yaml)"
assert_eq "T10 no remediation state written" "no" "$([ -f "$S/remediated.tsv" ] && echo yes || echo no)"
assert_eq "T10 no alert" "" "$(sent)"

# --- T11 not stale: a recent commit → ok, nothing done -----------------------
mkvault
git -C "$V" commit -q --allow-empty -m fresh
printf '#!/usr/bin/env bash\nfor f in $(cat list); do echo $f; done\n' >"$V/handovers/x.sh"
git -C "$V" add handovers/x.sh
before="$(head_sha)"
out="$(run_sut)"
assert_has "T11 reports ok" "ok" "$out"
assert_eq "T11 no commit" "$before" "$(head_sha)"

# --- T12 arm/status/disarm on a stub crontab, registered for doctor C24 ------
cat >"$TMP/crontab" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then cat "$TMP/cron.tab" 2>/dev/null || { echo "no crontab for t" >&2; exit 1; }; else cat >"$TMP/cron.tab"; fi
EOF
chmod +x "$TMP/crontab"
cadence() {
    HOME="$TMP/home" VAULT_STALL_CRONTAB="$TMP/crontab" VAULT_STALL_RUNNER_DIR="$TMP/runner" \
        HIMMEL_OBSERVABILITY_CONFIG="$TMP/obs.json" bash "$SUT" "$@" 2>&1
}
out="$(cadence arm --vault "$TMP/v1")"; rc=$?
assert_eq "T12 arm exits 0" "0" "$rc"
assert_has "T12 crontab row every 15 min, tagged" "*/15 * * * *" "$(cat "$TMP/cron.tab")"
assert_has "T12 crontab row tag" "# HIMMEL-VaultStall" "$(cat "$TMP/cron.tab")"
assert_has "T12 runner bakes the vault path" "$TMP/v1" "$(cat "$TMP/runner/vault-stall-cadence.sh")"
assert_has "T12 registered for doctor C24" "HIMMEL-VaultStall" "$(cat "$TMP/obs.json" 2>/dev/null)"
assert_has "T12 status ARMED" "ARMED" "$(cadence status)"
out="$(cadence disarm)"
assert_eq "T12 disarm removes the row" "" "$(grep -F HIMMEL-VaultStall "$TMP/cron.tab")"
assert_has "T12 status not armed" "not armed" "$(cadence status)"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "PASS: vault-stall-cadence ($0)"; else echo "FAIL: vault-stall-cadence — $FAILED failed ($0)" >&2; exit 1; fi
