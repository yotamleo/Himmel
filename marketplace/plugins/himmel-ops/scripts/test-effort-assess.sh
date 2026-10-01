#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-effort-assess.sh — HIMMEL-3995: effort_assess.py ticket + version modes.
# Expected numbers are hand-computed from the HIMMEL-3992 formulas:
#   median = kappa * (floor + sqrt(Seq(lo) * Seq(hi))) * g1_mult (non-trivial G1)
#   mean = median * exp(sigma^2/2); P80 = median * exp(0.8416 * sigma)
# S..S  : 0.681 * (1 + 1) = 1.362,  sigma 0.45 -> mean 1.5071, P80 1.9891
# M..M G1: 0.681 * (1 + 2.2) * 1.2 = 2.61504, sigma 0.85 -> mean 3.7529, P80 5.3476
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../skills/effort-assess/effort_assess.py"
td="$(mktemp -d)"; trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
# jget <file> <python expr over d> -> printed value
jget(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
near(){ python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<=float(sys.argv[3]) else 1)' "$2" "$3" "${4:-0.0005}" \
  && ok "$1" || bad "$1: [$2] not near [$3]"; }

full=(--low S --high S --g1 no --deps none --scope-file a.sh --red "test-x fails first" --goal G2 --alternative "keep midpoint")

# --- ticket mode: hand-computed record ---
python3 "$tool" ticket "${full[@]}" >"$td/ss.json" 2>"$td/ss.err"; rc=$?
check "S..S exits 0" "$rc" 0
near "S..S median" "$(jget "$td/ss.json" "d['median_seq']")" 1.362
near "S..S sigma" "$(jget "$td/ss.json" "d['sigma']")" 0.45
near "S..S mean" "$(jget "$td/ss.json" "d['mean_seq']")" 1.50713
near "S..S P80" "$(jget "$td/ss.json" "d['p80_seq']")" 1.98908
near "S..S bank mean" "$(jget "$td/ss.json" "d['bank']['mean']")" 0.0135641 0.000001
near "S..S P30" "$(jget "$td/ss.json" "d['band_seq']['p30']")" 1.07570
near "S..S P70" "$(jget "$td/ss.json" "d['band_seq']['p70']")" 1.72449
check "S..S passes DoD" "$(jget "$td/ss.json" "d['dod']['passed']")" True
check "config version recorded" "$(jget "$td/ss.json" "d['config_version']")" "B-2026-10-01"
check "alternatives carried" "$(jget "$td/ss.json" "d['alternatives']")" "['keep midpoint']"
check "goal carried" "$(jget "$td/ss.json" "d['goal']")" "G2"

python3 "$tool" ticket --low M --high M --g1 yes --deps none --scope-file a.sh --red r --goal G1 >"$td/g1.json" 2>/dev/null; rc=$?
check "M..M G1 exits 0" "$rc" 0
near "M..M G1 median" "$(jget "$td/g1.json" "d['median_seq']")" 2.61504
near "M..M G1 sigma" "$(jget "$td/g1.json" "d['sigma']")" 0.85
near "M..M G1 mean" "$(jget "$td/g1.json" "d['mean_seq']")" 3.75290
near "M..M G1 P80" "$(jget "$td/g1.json" "d['p80_seq']")" 5.34755

# --- ticket mode: G1 on an XS..XS ticket is trivial (no multiplier, base sigma) ---
python3 "$tool" ticket --low XS --high XS --g1 yes --deps none --scope-file a.sh --red r >"$td/xs.json" 2>/dev/null
near "XS..XS G1 trivial: sigma base" "$(jget "$td/xs.json" "d['sigma']")" 0.45

# --- DoD refusals: each names the failed item, exits non-zero ---
refuse(){ # <label> <expected failed item> <args...>
  local label="$1" item="$2"; shift 2
  python3 "$tool" ticket "$@" >"$td/r.json" 2>"$td/r.err"; local rc=$?
  [ "$rc" -ne 0 ] && ok "$label: non-zero exit" || bad "$label: expected non-zero exit"
  grep -q "$item" "$td/r.err" && ok "$label: stderr names $item" || bad "$label: stderr lacks $item: $(cat "$td/r.err")"
  case "$(jget "$td/r.json" "d['dod']['failed']")" in *"$item"*) ok "$label: record lists $item";; *) bad "$label: record lacks $item";; esac
}
refuse "no scope files" scope_files --low S --high S --g1 no --deps none --red r
refuse "no RED" red --low S --high S --g1 no --deps none --scope-file a.sh
refuse "range two steps" range_width --low S --high L --g1 no --deps none --scope-file a.sh --red r
refuse "G1 unstated" g1_flag --low S --high S --deps none --scope-file a.sh --red r
refuse "deps unstated" deps --low S --high S --g1 no --scope-file a.sh --red r
refuse "plan-first slice too big" plan_first_slice --plan-first-slice M --g1 no --deps none --scope-file a.sh --red r
refuse "sigma at the ceiling" sigma_ceiling --low XS --high XL --g1 no --deps none --scope-file a.sh --red r

# plan-first XS/S slice is accepted and sized by the slice
python3 "$tool" ticket --plan-first-slice S --g1 no --deps none --scope-file a.sh --red r >"$td/pf.json" 2>/dev/null; rc=$?
check "plan-first S slice exits 0" "$rc" 0
near "plan-first median = Seq(S)" "$(jget "$td/pf.json" "d['median_seq']")" 1.0
near "plan-first sigma" "$(jget "$td/pf.json" "d['sigma']")" 0.45

# --- version mode: FW vs seeded MC agree, deterministic ---
cat >"$td/ver.json" <<'EOF'
[{"median_seq": 1.362, "sigma": 0.45}, {"median_seq": 2.61504, "sigma": 0.85},
 {"median_seq": 1.362, "sigma": 0.45}, {"median_seq": 3.0, "sigma": 0.45},
 {"median_seq": 2.0, "sigma": 0.85}, {"median_seq": 1.0, "sigma": 0.45}]
EOF
python3 "$tool" version --in "$td/ver.json" >"$td/v1.json" 2>"$td/v1.err"; rc=$?
check "version mode exits 0" "$rc" 0
python3 "$tool" version --in "$td/ver.json" >"$td/v2.json" 2>/dev/null
cmp -s "$td/v1.json" "$td/v2.json" && ok "version mode deterministic across runs" || bad "version output differs between runs"
check "FW and MC agree" "$(jget "$td/v1.json" "d['agree']")" True
# hand-computed: sum of means = sum(median * exp(s^2/2)) * 0.009
near "version sum of means (bank)" "$(jget "$td/v1.json" "d['mean_bank']")" 0.126572 0.00001
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["fw_p90_bank"]>d["fw_p80_bank"]>d["mean_bank"]*0.9 and d["mc_p90_bank"]>d["mc_p80_bank"] else 1)' "$td/v1.json" \
  && ok "P90 above P80 above mean" || bad "percentile ordering"

# disagreement is detected, not hidden: a tolerance of 0 cannot be met by sampling
python3 "$tool" version --in "$td/ver.json" --tol 0 >"$td/v3.json" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "tolerance 0 -> non-zero exit" || bad "tolerance 0 should disagree"
check "tolerance 0 -> agree False" "$(jget "$td/v3.json" "d['agree']")" False

# config: no model number lives in code
if grep -nE '0\.681|0\.85|1\.2816|3992|20000' "$tool" >/dev/null; then bad "model constant hard-coded in effort_assess.py"; else ok "no model constants in code"; fi

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
