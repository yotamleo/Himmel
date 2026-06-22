#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-setup-preflight.sh -- hermetic tests for the R6 preflight (HIMMEL-460):
# ensure-tools.sh auto-install branches (SC7) + the setup.sh ordering invariant
# (git rev-parse for REPO_ROOT must run AFTER the [0/10] preflight, since the
# preflight may auto-install git).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
ensure="$here/ensure-tools.sh"
setup_sh="$(cd "$here/.." && pwd)/setup.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
has(){ printf '%s' "$2" | grep -q "$1" && echo yes || echo no; }

# shellcheck source=ensure-tools.sh
# shellcheck disable=SC1091
. "$ensure"

td="$(mktemp -d)"

# ── SC7 branch 1: unknown platform (no apt/dnf/brew on PATH) → fail-loud, no-op.
out=$( PATH="$td/empty-nonexistent" ensure_tools git 2>&1 )
check "SC7 unknown-platform message" "$(has 'no supported package manager' "$out")" "yes"

# ── SC7 branch 2: install SUCCEEDS — a stub apt-get that "installs" git.
stub="$td/ok-bin"; mkdir -p "$stub"
cat > "$stub/apt-get" <<EOF
#!/usr/bin/env bash
# fake apt-get: 'install -y <pkg>' drops a stub <pkg> into this bin dir.
if [ "\$1" = install ]; then
  shift; while [ "\$1" = "-y" ]; do shift; done
  for pkg in "\$@"; do printf '#!/usr/bin/env bash\necho stub-\$pkg\n' > "$stub/\$pkg"; chmod +x "$stub/\$pkg"; done
fi
exit 0
EOF
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$stub/sudo"   # pass-through sudo
chmod +x "$stub/apt-get" "$stub/sudo"
out=$( PATH="$stub:$PATH" ensure_tools git 2>&1 )
present=$( PATH="$stub:$PATH" command -v git >/dev/null 2>&1 && echo yes || echo no )
check "SC7 install-succeeds installs git" "$present" "yes"

# ── SC7 branch 3a: install FAILS (apt-get returns non-zero) → fail-loud, no-op.
# Minimal PATH (only the fail-stub) so a known-package tool (git) is genuinely
# absent and the install path is actually exercised. `id` is absent here too, so
# the helper treats the run as root (sudo not needed) — fine for this branch.
fbin="$td/fail-bin"; mkdir -p "$fbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fbin/apt-get"
chmod +x "$fbin/apt-get"
out=$( PATH="$fbin" ensure_tools git 2>&1 )
check "SC7 install-fails message" "$(has "'apt-get install git' failed" "$out")" "yes"

# ── SC7 branch 3b: no root/sudo (apt-get present, sudo absent, non-root).
# Runs on Linux AND Windows (HIMMEL-469). Key insight: in the no-sudo path
# ensure_tools only `command -v`s apt-get (never executes it) and only EXECUTES
# `id` — so a self-contained PATH needs just a stub apt-get (existence only) + a
# real `id` copy, with NO sudo. That makes `command -v sudo` fail even on a Linux
# host where /usr/bin/sudo exists, exercising the branch cross-platform. (An
# earlier version put /usr/bin:/bin on PATH, which on Linux ships a real sudo, so
# the branch silently never fired — caught on the Ubuntu VM.)
nbin="$td/nosudo-bin"; mkdir -p "$nbin"
: > "$nbin/apt-get"; chmod +x "$nbin/apt-get"   # present for `command -v`; never executed here
# Fake `id` with an ABSOLUTE /bin/sh shebang: /bin/sh exists at a fixed path on
# both Linux and Git Bash, so it runs even with PATH restricted to $nbin (unlike
# `#!/usr/bin/env bash`, which needs bash ON PATH, or a copied id.exe, which needs
# msys DLLs on Windows). Reports non-root so the sudo check is reached.
printf '#!/bin/sh\necho 1000\n' > "$nbin/id"; chmod +x "$nbin/id"
out=$( PATH="$nbin" ensure_tools git 2>&1 )
check "SC7 no-sudo message" "$(has 'no root/sudo' "$out")" "yes"

# ── HIMMEL-548 bun branch 1: official installer SUCCEEDS (mocked, no real curl).
# bun has no homebrew-core/apt/dnf package, so it is bootstrapped via its official
# installer (`curl -fsSL https://bun.sh/install` piped to bash), which lands the
# binary in $HOME/.bun/bin. A stub curl emits a tiny installer script on stdout;
# HOME is a temp dir so the install is hermetic. The install/fail branches call the
# helper directly (calling `ensure_tools bun` would short-circuit on any ambient
# bun already on the tester's PATH); the no-curl case below covers the routing.
bbin="$td/bun-ok"; mkdir -p "$bbin"
cat > "$bbin/curl" <<'EOF'
#!/usr/bin/env bash
# fake bun installer source: emit a script that drops bun into $HOME/.bun/bin.
cat <<'INSTALLER'
mkdir -p "$HOME/.bun/bin"
printf '#!/usr/bin/env bash\necho stub-bun\n' > "$HOME/.bun/bin/bun"
chmod +x "$HOME/.bun/bin/bun"
INSTALLER
EOF
chmod +x "$bbin/curl"
bhome="$td/bun-ok-home"; mkdir -p "$bhome"
out=$( HOME="$bhome" PATH="$bbin:$PATH" _ensure_install_bun 2>&1 )
present=$( [ -x "$bhome/.bun/bin/bun" ] && echo yes || echo no )
check "bun official-installer drops bun in ~/.bun/bin" "$present" "yes"

# ── HIMMEL-548 bun branch 2: installer FAILS (curl returns non-zero) → fail-loud,
# no bun, honest manual hint.
fbun="$td/bun-fail"; mkdir -p "$fbun"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fbun/curl"; chmod +x "$fbun/curl"
fhome="$td/bun-fail-home"; mkdir -p "$fhome"
out=$( HOME="$fhome" PATH="$fbun:$PATH" _ensure_install_bun 2>&1 )
check "bun installer-fails leaves no bun" "$( [ -x "$fhome/.bun/bin/bun" ] && echo yes || echo no )" "no"
check "bun installer-fails manual hint" "$(has 'install bun manually' "$out")" "yes"

# ── HIMMEL-548 bun branch 2b: curl SUCCEEDS but the installer BODY fails (network
# OK, install script errors) — the more realistic production failure. A stub curl
# emits a non-empty installer that exits non-zero when piped to bash → fail-loud,
# no bun, same honest manual hint as the curl-fails path.
xbun="$td/bun-installerfail"; mkdir -p "$xbun"
printf '#!/usr/bin/env bash\necho exit 1\n' > "$xbun/curl"; chmod +x "$xbun/curl"
xhome="$td/bun-installerfail-home"; mkdir -p "$xhome"
out=$( HOME="$xhome" PATH="$xbun:$PATH" _ensure_install_bun 2>&1 )
check "bun installer-body-fails leaves no bun" "$( [ -x "$xhome/.bun/bin/bun" ] && echo yes || echo no )" "no"
check "bun installer-body-fails manual hint" "$(has 'install bun manually' "$out")" "yes"

# ── HIMMEL-548 bun branch 3: routed through ensure_tools, curl absent → fail-loud
# manual hint (no crash). Empty PATH guarantees no ambient bun short-circuits it.
out=$( HOME="$td/bun-nocurl-home" PATH="$td/empty-nonexistent" ensure_tools bun 2>&1 )
check "bun no-curl manual hint" "$(has 'needs curl' "$out")" "yes"

# ── HIMMEL-548 setup.sh: ~/.bun/bin is added to PATH after ensure-tools so the
# re-check + downstream see a freshly-installed bun, and a persist-PATH hint is
# printed. Assert the wiring exists in setup.sh.
check "setup.sh adds ~/.bun/bin to PATH" "$(has 'HOME/.bun/bin' "$(cat "$setup_sh")")" "yes"

# ── SC7 ordering invariant: REPO_ROOT git rev-parse runs AFTER the preflight.
# Line number of the [0/10] preflight banner vs the REPO_ROOT assignment.
pf_line=$(grep -n '\[0/10\] Verifying foundational tools' "$setup_sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # literal grep pattern -- no shell expansion wanted
rr_line=$(grep -n 'REPO_ROOT="\$(git rev-parse --show-toplevel)"' "$setup_sh" | head -1 | cut -d: -f1)
if [ -n "$pf_line" ] && [ -n "$rr_line" ] && [ "$rr_line" -gt "$pf_line" ]; then
  echo "ok - SC7 REPO_ROOT git rev-parse is after the [0/10] preflight (line $rr_line > $pf_line)"
else
  echo "FAIL - SC7 ordering: pf=$pf_line rr=$rr_line"; fails=$((fails+1))
fi

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
