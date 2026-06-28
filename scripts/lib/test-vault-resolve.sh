#!/usr/bin/env bash
# Smoke test (the executable spec) for scripts/lib/vault-resolve.sh — HIMMEL-403.
# bash 3.2-safe. Run: bash scripts/lib/test-vault-resolve.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/vault-resolve.sh"
# Guard: skip-expecting (=="") tests must not pass merely because the function
# is undefined — fail loudly if the unit under test isn't loaded.
command -v resolve_vault_root >/dev/null 2>&1 || { echo "FATAL: resolve_vault_root not defined"; exit 2; }

T='~' # literal tilde for expected values the resolver leaves unexpanded
fails=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n      expected=[%s]\n      actual=  [%s]\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkcfg() { printf '%s\n' "$1" >"$SB/cfg.json"; }
NOREG="$SB/none.json" # nonexistent registry

# ---- undeclared default requires a REAL luna vault (HIMMEL-590 F7) ----
# An adopter who never configured luna has no ~/Documents/luna/.obsidian, so the
# bare convention default must SKIP (empty) — the hook never materializes a
# phantom vault. dry-run + a real .obsidian marker still resolve the convention.
mkcfg '{"enabled":true}'
FAKEHOME="$SB/fakehome"; mkdir -p "$FAKEHOME/Documents"
# USERPROFILE='' also disables the Windows USERPROFILE-form fallback so the test
# is hermetic on a real Windows box (which has its own ~/Documents/luna vault).
check "undeclared + no real luna vault -> skip" "" \
  "$(HOME="$FAKEHOME" USERPROFILE='' LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"
check "undeclared + dry-run -> convention path" "$FAKEHOME/Documents/luna" \
  "$(HOME="$FAKEHOME" USERPROFILE='' LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG" true)"
mkdir -p "$FAKEHOME/Documents/luna/.obsidian"
check "undeclared + real luna vault (.obsidian) -> convention path" "$FAKEHOME/Documents/luna" \
  "$(HOME="$FAKEHOME" USERPROFILE='' LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"

# Windows USERPROFILE-form fallback (HIMMEL-590 F7): when $HOME (MSYS) has no
# vault but a real one exists under the USERPROFILE Windows-form path, the
# convention is honored and the resolver returns the HOME-form (the hook
# reconciles). cygpath-gated — only meaningful on Windows Git Bash.
if command -v cygpath >/dev/null 2>&1; then
    mkcfg '{"enabled":true}'
    FH2="$SB/fakehome2"; mkdir -p "$FH2/Documents"
    UP_WIN="$(cygpath -w "$SB/upwin" 2>/dev/null)"
    UP_U="$(cygpath -u "$UP_WIN" 2>/dev/null)"
    mkdir -p "$UP_U/Documents/luna/.obsidian"
    check "undeclared + USERPROFILE-form real vault -> conv (HOME form)" "$FH2/Documents/luna" \
      "$(HOME="$FH2" USERPROFILE="$UP_WIN" LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"
fi

mkcfg '{"vault_path":"/tmp/explicit"}'
check "vault_path wins" "/tmp/explicit" \
  "$(LUNA_VAULT_PATH=/tmp/env resolve_vault_root "$SB/cfg.json" "$NOREG")"

mkcfg '{"enabled":true}'
check "LUNA_VAULT_PATH env" "/tmp/envvault" \
  "$(LUNA_VAULT_PATH=/tmp/envvault resolve_vault_root "$SB/cfg.json" "$NOREG")"

# F1-SC5 (HIMMEL-458): the value wire-luna-vault writes to settings.json
# .env.LUNA_VAULT_PATH is actually consumed at resolver step 3. Empty config
# object + empty registry -> falls through to LUNA_VAULT_PATH.
mkcfg '{}'
check "F1-SC5 LUNA_VAULT_PATH consumed (empty cfg+reg)" "/tmp/scaffolded" \
  "$(LUNA_VAULT_PATH=/tmp/scaffolded resolve_vault_root "$SB/cfg.json" "$NOREG")"

printf '{"vaults":{"luna":"~/Documents/luna-alt"}}\n' >"$SB/regluna.json"
mkcfg '{"enabled":true}'
check "default via registry[luna]" "$T/Documents/luna-alt" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/regluna.json")"

# ---- name validation, fail-closed (Task 2) ----
# shellcheck disable=SC2016  # the $ and other metachars are literal test inputs
for bad in "" "." ".." "../x" "a/b" "-x" "~x" "a b" 'a$b' "a;b" "a..b"; do
  mkcfg "$(printf '{"vault":"%s"}' "$bad")"
  check "invalid vault '$bad' -> skip" "" \
    "$(LUNA_VAULT_PATH=/tmp/should_not_be_used resolve_vault_root "$SB/cfg.json" "$NOREG")"
done

# ---- registry lookup (Task 3) ----
printf '{"vaults":{"luna-medic":"~/Documents/luna-medic"}}\n' >"$SB/reg.json"
mkcfg '{"vault":"luna-medic"}'
check "registry hit (literal ~/)" "$T/Documents/luna-medic" \
  "$(resolve_vault_root "$SB/cfg.json" "$SB/reg.json")"

printf '{"vaults":{"x":"~/../../etc"}}\n' >"$SB/reg2.json"
mkcfg '{"vault":"x"}'
check "registry traversal value -> skip" "" \
  "$(resolve_vault_root "$SB/cfg.json" "$SB/reg2.json")"

printf 'not json{\n' >"$SB/bad.json"
mkcfg '{"vault":"nope"}'
check "malformed registry, no conv vault -> skip" "" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/bad.json")"

# ---- convention + .obsidian marker (Task 4) ----
mkdir -p "$SB/home/Documents/realvault/.obsidian"
mkcfg '{"vault":"realvault"}'
check "convention + .obsidian" "$SB/home/Documents/realvault" \
  "$(HOME="$SB/home" LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"

mkdir -p "$SB/home/Documents/notavault"
mkcfg '{"vault":"notavault"}'
check "convention no .obsidian -> skip" "" \
  "$(HOME="$SB/home" LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"

mkcfg '{"vault":"futurevault"}'
check "dry_run bypasses marker" "$SB/home/Documents/futurevault" \
  "$(HOME="$SB/home" resolve_vault_root "$SB/cfg.json" "$NOREG" true)"

# ---- CR follow-ups (HIMMEL-403 review) ----
# registry present but THIS key absent -> convention fallback (not the other key, not skip)
printf '{"vaults":{"other":"/somewhere"}}\n' >"$SB/reg3.json"
mkdir -p "$SB/home/Documents/medic/.obsidian"
mkcfg '{"vault":"medic"}'
check "registry missing key -> convention" "$SB/home/Documents/medic" \
  "$(HOME="$SB/home" LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/reg3.json")"

# malformed config that DECLARES a vault -> fail-closed skip (NOT default)
printf '%s\n' '{"vault":"luna-medic" BROKEN' >"$SB/cfg.json"
check "malformed config -> skip (not default)" "" \
  "$(LUNA_VAULT_PATH=/tmp/should_not_be_used resolve_vault_root "$SB/cfg.json" "$NOREG")"

# name longer than 64 chars -> skip BECAUSE of the cap, not the marker:
# dry_run bypasses the .obsidian marker, so only the length cap can force a skip
# here (without the cap this would return the convention path -> test fails).
long="$(printf '%065d' 0 | tr '0' 'a')"
mkcfg "$(printf '{"vault":"%s"}' "$long")"
check "65-char name -> skip (cap, not marker)" "" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG" true)"

# registry value not absolute -> skip
printf '{"vaults":{"rel":"relative/path"}}\n' >"$SB/reg4.json"
mkcfg '{"vault":"rel"}'
check "non-absolute registry value -> skip" "" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/reg4.json")"

# array registry value -> ignored (string-only guard) -> skip
printf '{"vaults":{"arr":["/a","/b"]}}\n' >"$SB/reg5.json"
mkcfg '{"vault":"arr"}'
check "array registry value -> skip" "" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/reg5.json")"

# valid JSON but NOT an object -> fail-closed skip (parity with PS)
# (incl. a single-element array [{...}] — PS auto-unwraps it, must still skip)
for nonobj in 'null' 'false' '[]' '"str"' '42' '[{"vault":"luna"}]'; do
  printf '%s\n' "$nonobj" >"$SB/cfg.json"
  check "non-object config '$nonobj' -> skip" "" \
    "$(LUNA_VAULT_PATH=/tmp/should_not_be_used resolve_vault_root "$SB/cfg.json" "$NOREG")"
done

# empty config file -> skip (not default)
: >"$SB/cfg.json"
check "empty config file -> skip" "" \
  "$(LUNA_VAULT_PATH=/tmp/should_not_be_used resolve_vault_root "$SB/cfg.json" "$NOREG")"

# UTF-8 BOM-prefixed config must still PARSE, not fail-closed (HIMMEL-408).
printf '\xef\xbb\xbf{"vault_path":"/tmp/bomvault"}\n' >"$SB/cfg.json"
check "BOM-prefixed config parses (not skip)" "/tmp/bomvault" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$NOREG")"

# UTF-8 BOM-prefixed registry must still resolve a name (HIMMEL-408).
printf '\xef\xbb\xbf{"vaults":{"bomreg":"/tmp/bomreg"}}\n' >"$SB/regbom.json"
mkcfg '{"vault":"bomreg"}'
check "BOM-prefixed registry resolves name" "/tmp/bomreg" \
  "$(LUNA_VAULT_PATH='' resolve_vault_root "$SB/cfg.json" "$SB/regbom.json")"

if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILED"
  exit 1
fi
