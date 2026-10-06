#!/usr/bin/env bash
# test-wizard-vm-mode.sh — hermetic tests for HIMMEL-4597 (vm.mode in himmelctl):
#
#   a. luna-config.js: `vm` is an OPTIONAL managed section; validateVm()
#      verdicts equal the resolver's (scripts/lib/vm-mode.sh mode: rc 0 vs 2)
#      for a table of fixture vm objects; an absent `vm` is never injected.
#   b. the install wizard's vm question (askVm) re-asks on invalid input with
#      that same validator, one row per mode.
#   c. the cadence menu (askCadences): a `vm_proof` row (vault-stall) is only
#      pre-selected when the vm.mode route is a VM — one row per mode
#      (local, remote, none, error).
#   d. non-interactive: --from-profile never auto-arms a vm_proof row under
#      none/error, still arms it under local/remote; a vm answer is persisted
#      only when it changes the config.
#
# Tests never read or write the real ~/.himmel/config.json: every run uses a
# temp HOME + HIMMEL_LUNA_CONFIG_PATH + HIMMEL_VM_MODE_CONFIG.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
luna_cfg="$repo_root/scripts/himmelctl/lib/luna-config.js"
resolver="$repo_root/scripts/lib/vm-mode.sh"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)
export HIMMELCTL_BASH=bash

fails=0
last=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
# a section's "ok" line prints only when no check since the last one failed
ok() { if [ "$fails" -eq "$last" ]; then echo "ok: $1"; else echo "not ok: $1"; fi; last=$fails; }

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-vm-mode.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
cd "$work"
export HOME="$work/home"; mkdir -p "$HOME/.himmel"
export HIMMEL_LUNA_CONFIG_PATH="$work/luna-config.json"
# the wizard runs the resolver on its own config file, so the two are one file
export HIMMEL_VM_MODE_CONFIG="$HIMMEL_LUNA_CONFIG_PATH"

# ── a. validateVm parity with the resolver ───────────────────────────────────
# name|vm-json (the whole config's `vm` value; `-` = key absent)
fixtures='absent|-
empty-object|{}
local|{"mode":"local"}
none|{"mode":"none"}
mode-case|{"mode":"Local"}
mode-space|{"mode":"local "}
mode-unknown|{"mode":"vagrant"}
mode-number|{"mode":1}
vm-array|[]
vm-string|"local"
remote-ok|{"mode":"remote","remote":{"ssh":"u@h"}}
remote-full|{"mode":"remote","remote":{"ssh":"u@h","port":2222,"identity":"~/.ssh/k"}}
remote-nossh|{"mode":"remote"}
remote-blank-ssh|{"mode":"remote","remote":{"ssh":"  "}}
remote-ssh-space|{"mode":"remote","remote":{"ssh":"u@h x"}}
remote-ssh-dash|{"mode":"remote","remote":{"ssh":"-oProxyCommand=x"}}
remote-port-str|{"mode":"remote","remote":{"ssh":"u@h","port":"2222"}}
remote-port-bool|{"mode":"remote","remote":{"ssh":"u@h","port":true}}
remote-port-zero|{"mode":"remote","remote":{"ssh":"u@h","port":0}}
remote-port-big|{"mode":"remote","remote":{"ssh":"u@h","port":65536}}
remote-port-neg|{"mode":"remote","remote":{"ssh":"u@h","port":-1}}
remote-ident-dash|{"mode":"remote","remote":{"ssh":"u@h","identity":"-i"}}
remote-ident-space|{"mode":"remote","remote":{"ssh":"u@h","identity":"/a b/k"}}
remote-ident-num|{"mode":"remote","remote":{"ssh":"u@h","identity":5}}
remote-ident-false|{"mode":"remote","remote":{"ssh":"u@h","identity":false}}
remote-ident-zero|{"mode":"remote","remote":{"ssh":"u@h","identity":0}}
remote-ident-empty|{"mode":"remote","remote":{"ssh":"u@h","identity":""}}
remote-ident-array|{"mode":"remote","remote":{"ssh":"u@h","identity":[]}}
remote-ident-null|{"mode":"remote","remote":{"ssh":"u@h","identity":null}}
remote-ident-star|{"mode":"remote","remote":{"ssh":"u@h","identity":"~/.ssh/k*"}}
remote-ident-qmark|{"mode":"remote","remote":{"ssh":"u@h","identity":"/k?"}}
remote-ident-bracket|{"mode":"remote","remote":{"ssh":"u@h","identity":"/keys/[ab]"}}
remote-ssh-trailing-fs|{"mode":"remote","remote":{"ssh":"u@h\u001c"}}
remote-ssh-trailing-nel|{"mode":"remote","remote":{"ssh":"u@h\u0085"}}
local-ignores-bad-remote|{"mode":"local","remote":{"ssh":"-x"}}'
n=0
while IFS='|' read -r name vmjson; do
  [ -n "$name" ] || continue
  if [ "$vmjson" = "-" ]; then echo '{"version":1}' > "$HIMMEL_VM_MODE_CONFIG"
  else printf '{"vm":%s}\n' "$vmjson" > "$HIMMEL_VM_MODE_CONFIG"; fi
  rc=0; bash "$resolver" mode >/dev/null 2>&1 || rc=$?
  want=valid; [ "$rc" -eq 0 ] || want=invalid
  got=$(node -e '
    const l = require(process.argv[1]);
    const doc = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
    process.stdout.write(l.validateVm(doc.vm).length === 0 ? "valid" : "invalid");
  ' "$luna_cfg" "$HIMMEL_VM_MODE_CONFIG")
  [ "$got" = "$want" ] || fail "a: validateVm($name) says $got, resolver says $want (mode rc=$rc)"
  n=$((n + 1))
done <<EOF
$fixtures
EOF
ok "a — validateVm verdict == resolver verdict for $n fixture vm objects"

# an absent vm is never injected by inspect()/fillDefaults()
cat > "$HIMMEL_LUNA_CONFIG_PATH" <<'JSON'
{"version":1,"luna":{"vaultPath":"/v","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"a","synthesize":"b","health":"c"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/e","whisper":{"cli":null,"model":"m"}}}
JSON
out=$(node -e '
  const l = require(process.argv[1]); const r = l.inspect();
  process.stdout.write(JSON.stringify({has: "vm" in r.doc, filled: r.filled.map((f) => f.path), unknown: r.unknown}));
' "$luna_cfg")
[ "$out" = '{"has":false,"filled":[],"unknown":[]}' ] || fail "a: inspect() on a vm-less config injected/flagged something: $out"
# a present vm is managed (not "unknown") and a bad one fails validation
jq '.vm={"mode":"remote","remote":{"ssh":"u@h"}}' "$HIMMEL_LUNA_CONFIG_PATH" > "$work/c2.json"
HIMMEL_LUNA_CONFIG_PATH="$work/c2.json" node -e '
  const r = require(process.argv[1]).inspect();
  if (r.unknown.length) { console.error(r.unknown); process.exit(1); }' "$luna_cfg" || fail "a: a valid vm was reported as an unmanaged key"
jq '.vm={"mode":"nope"}' "$HIMMEL_LUNA_CONFIG_PATH" > "$work/c3.json"
if HIMMEL_LUNA_CONFIG_PATH="$work/c3.json" node -e 'require(process.argv[1]).inspect()' "$luna_cfg" 2>/dev/null; then
  fail "a: inspect() accepted vm.mode=nope"
fi
ok "a — absent vm stays absent; present vm is managed; invalid vm fails validation"

# ── b. wizard question: one row per mode, re-asking on invalid input ─────────
askvm() { # answers (newline-separated) -> JSON of the result + count of prompts seen
  ANSWERS="$1" node -e '
    const w = require(process.argv[1]);
    const q = process.env.ANSWERS.split("\n"); let i = 0; let asked = 0;
    const ask = async () => { asked++; return i < q.length ? q[i++] : ""; };
    w.askVm(ask, undefined).then((r) => console.log(JSON.stringify({ r, asked })));
  ' "$wizard" 2>/dev/null
}
[ "$(askvm '')" = '{"r":{"mode":"local"},"asked":1}' ] || fail "b: default answer is not local: $(askvm '')"
[ "$(askvm 'none')" = '{"r":{"mode":"none"},"asked":1}' ] || fail "b: none row: $(askvm 'none')"
[ "$(askvm '3')" = '{"r":{"mode":"none"},"asked":1}' ] || fail "b: numbered none row: $(askvm '3')"
got=$(askvm $'remote\nu@h\n\n')
[ "$got" = '{"r":{"mode":"remote","remote":{"ssh":"u@h","port":22,"identity":"~/.ssh/id_ed25519"}},"asked":4}' ] || fail "b: remote defaults row: $got"
got=$(askvm $'remote\nbad host\n-x\nu@h\n99999\nabc\n2222\n-i\nid with space\n~/.ssh/k')
[ "$got" = '{"r":{"mode":"remote","remote":{"ssh":"u@h","port":2222,"identity":"~/.ssh/k"}},"asked":10}' ] || fail "b: remote re-ask row: $got"
ok "b — askVm: local/none/remote rows, re-asks ssh, port and identity on invalid input"

# ── c. cadence default reads vm.mode: one row per mode ─────────────────────
# Offer vault-stall (vault=existing); the preset defaults name it. Print which
# dispositions come back and whether the menu told the operator why.
askcad() { # extra-node-js-before (sets vm answer) -> JSON {vs, menu}
  node -e '
    const w = require(process.argv[1]);
    const prompts = [];
    const ask = async (q) => { prompts.push(q); return prompts.length > 1 ? "none" : ""; };
    const vmAns = process.env.VMANS ? JSON.parse(process.env.VMANS) : undefined;
    const doc = process.env.DOC ? JSON.parse(process.env.DOC) : undefined;
    w.askCadences(ask, [], "existing", ["pipeline", "vault-stall"], vmAns, doc).then((r) => {
      const line = prompts[0].split("\n").find((l) => l.includes(" vault-stall")) || "";
      console.log(JSON.stringify({ vs: r["vault-stall"], pipeline: r.pipeline, line }));
    });
  ' "$wizard" 2>/dev/null
}
cad_field() { printf '%s' "$1" | jq -r "$2"; }

printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(askcad)
[ "$(cad_field "$got" .vs)" = armed ] || fail "c: local — vault-stall should be pre-selected: $got"
[ "$(cad_field "$got" .pipeline)" = armed ] || fail "c: local — pipeline default lost: $got"
printf '{"vm":{"mode":"remote","remote":{"ssh":"u@h"}}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(askcad)
[ "$(cad_field "$got" .vs)" = armed ] || fail "c: remote — vault-stall should be pre-selected: $got"
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(askcad)
[ "$(cad_field "$got" .vs)" = off ] || fail "c: none — vault-stall must NOT be pre-selected: $got"
[ "$(cad_field "$got" .pipeline)" = armed ] || fail "c: none — pipeline default must be untouched: $got"
cad_field "$got" .line | grep -qF 'needs VM proof first — vm.mode=none: arm only with an operator ack after a rollback point; disarm: bash scripts/luna/vault-stall-cadence.sh disarm' || fail "c: none — menu line does not say why: $got"
printf '{"vm":{"mode":"bogus"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(askcad)
[ "$(cad_field "$got" .vs)" = off ] || fail "c: error — vault-stall must NOT be pre-selected: $got"
cad_field "$got" .line | grep -qF 'vm.mode config error — fix ~/.himmel/config.json' || fail "c: error — menu line does not say to fix the config: $got"
# the wizard's own vm answer wins over the resolver when it was asked this run
got=$(DOC='{"vm":{"mode":"none"}}' VMANS='{"mode":"local"}' askcad)
[ "$(cad_field "$got" .vs)" = armed ] || fail "c: wizard vm=local answer should win over a none config: $got"
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(DOC='{"vm":{"mode":"local"}}' VMANS='{"mode":"none"}' askcad)
[ "$(cad_field "$got" .vs)" = off ] || fail "c: wizard vm=none answer should win over a local config: $got"

# error: a vm_proof row is not armable at all — selecting it re-asks
printf '{"vm":{"mode":"bogus"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(node -e '
  const w = require(process.argv[1]);
  const seq = ["vault-stall", "none"]; let n = 0;
  w.askCadences(async () => seq[n++], [], "existing", [], undefined).then((r) => console.log(JSON.stringify({ n, vs: r["vault-stall"] })));
' "$wizard" 2>/dev/null)
[ "$got" = '{"n":2,"vs":"off"}' ] || fail "c: error — explicit vault-stall should be refused and re-asked: $got"
# none: an explicit selection is the operator's ack — armable
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
got=$(node -e '
  const w = require(process.argv[1]);
  w.askCadences(async () => "vault-stall", [], "existing", [], undefined).then((r) => console.log(JSON.stringify({ vs: r["vault-stall"] })));
' "$wizard" 2>/dev/null)
[ "$got" = '{"vs":"armed"}' ] || fail "c: none — an explicit selection should still be armable: $got"
ok "c — vault-stall pre-selected only under local/remote; none/error say why; error is not armable"

# the registry carries the flag on vault-stall only
[ "$(jq -r '[.cadences[] | select(.vm_proof == true) | .id] | join(",")' "$repo_root/scripts/himmelctl/lib/cadence-registry.json")" = vault-stall ] || fail "c: vm_proof must be set on vault-stall and nothing else"
ok "c — registry vm_proof is on vault-stall only"

# ── d. non-interactive: --from-profile ───────────────────────────────────────
fixture="$work/fixture-repo"; mkdir -p "$fixture/scripts/luna" "$fixture/scripts/lib"
cp "$resolver" "$fixture/scripts/lib/vm-mode.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/adopt.sh"
cat > "$fixture/scripts/luna/vault-stall-cadence.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MARKER"
exit 0
STUB
chmod +x "$fixture/scripts/adopt.sh" "$fixture/scripts/luna/vault-stall-cadence.sh"
git_stub="$work/stub"; mkdir -p "$git_stub"
# shellcheck disable=SC2016 # $1 belongs to the stub, not this shell
printf '#!/usr/bin/env bash\nif [ "$1" = remote ]; then echo https://github.com/someone/other.git; fi\nexit 0\n' > "$git_stub/git"
chmod +x "$git_stub/git"

mkprofile() { # <vm-json-or-empty> -> path
  local vm=""; [ -z "$1" ] || vm=", \"vm\": $1"
  cat > "$work/profile.json" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "scope": "project",
  "vault": { "mode": "default-template", "path": "$work/newvault" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "cadences": { "vault-stall": "armed" }$vm
}
JSON
}
runprofile() { # sets $rc, $out; marker removed first
  rm -f "$work/marker"
  rm -f "$HIMMEL_LUNA_CONFIG_PATH"
  [ -z "${SEED:-}" ] || printf '%s\n' "$SEED" > "$HIMMEL_LUNA_CONFIG_PATH"
  set +e
  out=$(PATH="$git_stub:$PATH" HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$fixture" \
    HIMMELCTL_CACHE_DIR="$work/cache" HIMMELCTL_BIN_DIR="$work/bin" MARKER="$work/marker" \
    HIMMEL_LUNA_CONFIG_PATH="$HIMMEL_LUNA_CONFIG_PATH" \
    "$node_bin" "$wizard" install --from-profile "$work/profile.json" </dev/null 2>&1)
  rc=$?
  set -e
}

# local / remote (via the resolver): armed, unchanged behaviour
# (SEED = the wizard's own config file, which the resolver reads at apply)
SEED='{"vm":{"mode":"local"}}'; mkprofile ""; runprofile
[ -f "$work/marker" ] || fail "d: local — vault-stall should be armed (rc=$rc): $out"
SEED='{"vm":{"mode":"remote","remote":{"ssh":"u@h"}}}'; runprofile
[ -f "$work/marker" ] || fail "d: remote — vault-stall should be armed (rc=$rc): $out"
# none: refused, with a message
SEED='{"vm":{"mode":"none"}}'; runprofile
[ ! -f "$work/marker" ] || fail "d: none — vault-stall must NOT be armed non-interactively: $out"
if ! printf '%s' "$out" | grep -qF 'vault-stall' || ! printf '%s' "$out" | grep -qF 'vm.mode=none'; then fail "d: none — no clear refusal message: $out"; fi
# error: refused (a vm the resolver rejects and validateVm accepts). The seed
# is the config this profile converges to, with its port hand-edited to 22.0:
# a run that changes nothing writes nothing, so the float stays on disk.
SEED='{"vm":{"mode":"remote","remote":{"ssh":"u@h","port":22}}}'; runprofile
float_seed=$(sed -E 's/"port": *22([^0-9]|$)/"port": 22.0\1/' "$HIMMEL_LUNA_CONFIG_PATH")
printf '%s' "$float_seed" | grep -qF '"port": 22.0' || fail "d: could not build the converged float-port seed: $float_seed"
SEED="$float_seed"; runprofile
[ ! -f "$work/marker" ] || fail "d: error — vault-stall must NOT be armed: $out"
printf '%s' "$out" | grep -qF 'vm.mode config error' || fail "d: error — no clear refusal message: $out"
# the profile's own vm answer wins over the config it changes
SEED='{"vm":{"mode":"none"}}'; mkprofile '{"mode":"local"}'; runprofile
[ -f "$work/marker" ] || fail "d: profile vm=local should arm vault-stall (rc=$rc): $out"
SEED='{"vm":{"mode":"local"}}'; mkprofile '{"mode":"none"}'; runprofile
[ ! -f "$work/marker" ] || fail "d: profile vm=none must refuse vault-stall: $out"
SEED=
ok "d — --from-profile arms vault-stall under local/remote, refuses it under none/error (profile vm answer wins)"

# persistence: remote is written; local over an absent vm writes nothing
mkprofile '{"mode":"remote","remote":{"ssh":"u@h","port":2222}}'; runprofile
[ "$(jq -c .vm "$HIMMEL_LUNA_CONFIG_PATH")" = '{"mode":"remote","remote":{"ssh":"u@h","port":2222}}' ] || fail "d: remote vm answer not persisted (rc=$rc): $(cat "$HIMMEL_LUNA_CONFIG_PATH" 2>&1) $out"
mkprofile '{"mode":"local"}'; runprofile
jq -e 'has("vm") | not' "$HIMMEL_LUNA_CONFIG_PATH" >/dev/null || fail "d: a local answer with no prior vm must not write a vm key: $(cat "$HIMMEL_LUNA_CONFIG_PATH")"
# a profile with a bad vm fails loud before any side effect
mkprofile '{"mode":"remote","remote":{"ssh":"-x"}}'; runprofile
if [ "$rc" -eq 0 ] || [ -f "$work/marker" ]; then fail "d: invalid profile vm must fail (rc=$rc): $out"; fi
ok "d — vm answer persisted only when it changes the config; invalid profile vm refused"
# a remote answer that omits port/identity means the defaults: it must not keep the previous target's
got=$(node -e '
  const d = { vm: { mode: "remote", x: 1, remote: { ssh: "a@h", port: 2222, identity: "/k" } } };
  const changed = require(process.argv[1]).applyVmAnswer(d, { mode: "remote", remote: { ssh: "b@h" } });
  console.log(JSON.stringify({ changed, vm: d.vm }));
' "$wizard" 2>&1)
[ "$got" = '{"changed":true,"vm":{"mode":"remote","x":1,"remote":{"ssh":"b@h"}}}' ] || fail "d: remote answer without port/identity kept the old ones: $got"
ok "d — a remote answer that omits port/identity drops the previous target's"

# ── e. the resolver decides, on the config as written (J1947 B1) ─────────────
# A config the JS validator accepts but the resolver rejects (rc 2): a JSON
# float port, and an ssh target with an interior \x1c (Python isspace, JS \s
# not). A vm answer equal to it leaves the file as it is, so vault-stall must
# be refused as a config error — interactively and via --from-profile.
float_cfg='{"vm":{"mode":"remote","remote":{"ssh":"u@h","port":22.0}}}'
fs_cfg='{"vm":{"mode":"remote","remote":{"ssh":"u\u001c@h"}}}'
askcad_doc() { # <answer-json> -> {n, vs}; doc = the wizard's own read of its config
  node -e '
    const w = require(process.argv[1]);
    const doc = require(process.argv[2]).inspect().doc;
    const seq = ["vault-stall", "none"]; let n = 0;
    w.askCadences(async () => seq[n++], [], "existing", [], JSON.parse(process.argv[3]), doc)
      .then((r) => console.log(JSON.stringify({ n, vs: r["vault-stall"] })));
  ' "$wizard" "$luna_cfg" "$1" 2>/dev/null
}
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
printf '%s\n' "$float_cfg" > "$HIMMEL_LUNA_CONFIG_PATH"
got=$(askcad_doc '{"mode":"remote","remote":{"ssh":"u@h","port":22,"identity":"~/.ssh/id_ed25519"}}')
[ "$got" = '{"n":2,"vs":"off"}' ] || fail "e: interactive float port — vault-stall must be refused as a config error: $got"
printf '%s\n' "$fs_cfg" > "$HIMMEL_LUNA_CONFIG_PATH"
got=$(askcad_doc '{"mode":"remote","remote":{"ssh":"u\u001c@h","port":22,"identity":"~/.ssh/id_ed25519"}}')
[ "$got" = '{"n":2,"vs":"off"}' ] || fail "e: interactive \\x1c ssh — vault-stall must be refused as a config error: $got"
# control: the same answer over an integer port arms
printf '{"vm":{"mode":"remote","remote":{"ssh":"u@h","port":22}}}\n' > "$HIMMEL_LUNA_CONFIG_PATH"
got=$(askcad_doc '{"mode":"remote","remote":{"ssh":"u@h","port":22,"identity":"~/.ssh/id_ed25519"}}')
[ "$got" = '{"n":1,"vs":"armed"}' ] || fail "e: interactive integer port control should arm: $got"
# --from-profile: the float port on disk (converged seed from d), an equal profile answer
SEED="$float_seed"; mkprofile '{"mode":"remote","remote":{"ssh":"u@h","port":22}}'; runprofile; SEED=
[ ! -f "$work/marker" ] || fail "e: --from-profile float port — vault-stall must NOT be armed: $out"
printf '%s' "$out" | grep -qF 'vm.mode config error' || fail "e: --from-profile float port — no config-error refusal: $out"
# --from-profile: a profile answer the resolver rejects once written
mkprofile '{"mode":"remote","remote":{"ssh":"u\u001c@h"}}'; runprofile
[ ! -f "$work/marker" ] || fail "e: --from-profile \\x1c ssh — vault-stall must NOT be armed: $out"
printf '%s' "$out" | grep -qF 'vm.mode config error' || fail "e: --from-profile \\x1c ssh — no config-error refusal: $out"
ok "e — vault-stall is refused when the resolver rejects the config as written (float port, \\x1c ssh)"

[ "$fails" -eq 0 ] || { echo "$fails check(s) FAILED" >&2; exit 1; }
echo "PASS"
