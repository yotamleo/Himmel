#!/usr/bin/env bash
# test-luna-index-hygiene.sh — hermetic: a scratch vault, a scratch qmd config
# and index, no network. The qmd rows run the real qmd against the scratch
# index and SKIP when qmd is not installed.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/luna/luna-index-hygiene.sh"
PASS=0; FAIL=0; SKIP=0
W="$(mktemp -d -t luna-index-hygiene.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# The luna block is copied from the live ~/.config/qmd/index.yml (a sibling
# collection with its own ignore list included), not hand-written.
write_cfg() {
  cat > "$1" <<EOF
collections:
  himmel:
    path: /srv/himmel
    pattern: "**/*.md"
    ignore:
      - "graphify-out/**"
      - "**/fixtures/**"
  luna:
    path: $2
    pattern: "**/*.md"
  ggs-local:
    path: /srv/ggs-local
    pattern: "**/*.md"
models:
  embed: hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf
EOF
}

# The fixture the ticket names: a graph export note and a graphify report.
make_vault() {
  mkdir -p "$1/60-Maps/graph" "$1/graphify-out/d" "$1/notes"
  echo "# x" > "$1/60-Maps/graph/x.md"
  echo "# r" > "$1/graphify-out/d/GRAPH_REPORT.md"
  echo "# n" > "$1/notes/n.md"
}

indexed() {  # indexed <cfg-dir> : the collection's file list as the real qmd sees it
  QMD_CONFIG_DIR="$1" XDG_CACHE_HOME="$1/cache" qmd ls luna 2>/dev/null | sed 's|.*qmd://luna/||' | sort | tr '\n' ' '
}

# --- RED: with no ignore list both generated files are indexed ----------------
if command -v qmd >/dev/null 2>&1; then
  V="$W/qv"; C="$W/qc"; mkdir -p "$C/cache"; make_vault "$V"
  write_cfg "$C/index.yml" "$V"
  QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd update >/dev/null 2>&1
  check "RED: unconfigured luna indexes the graph export and the report" \
    "60-Maps/graph/x.md graphify-out/d/GRAPH_REPORT.md notes/n.md " "$(indexed "$C")"
  bash "$SUT" --vault "$V" --qmd-config "$C/index.yml" --apply >/dev/null 2>&1
  QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd update >/dev/null 2>&1
  check "after apply + qmd update only the note stays indexed" "notes/n.md " "$(indexed "$C")"
  # an archived doc leaves `luna` and is found through `luna-archive`
  mkdir -p "$V/handovers/u/archive/2026-01" "$V/sessions/_archive/2026-01"
  echo "# a" > "$V/handovers/u/archive/2026-01/a.md"
  echo "# s" > "$V/sessions/_archive/2026-01/s.md"
  QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd update >/dev/null 2>&1
  check "an archived doc is not in luna" "notes/n.md " "$(indexed "$C")"
  arch="$(QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd ls luna-archive 2>/dev/null | sed 's|.*qmd://luna-archive/||' | sort | tr '\n' ' ')"
  check "and luna-archive finds it" "handovers/u/archive/2026-01/a.md sessions/_archive/2026-01/s.md " "$arch"
else
  SKIP=$((SKIP+1)); echo "skip - qmd not installed: qmd-backed rows"
fi

# --- config rewrite ----------------------------------------------------------
V="$W/v1"; make_vault "$V"; CFG="$W/c1.yml"; write_cfg "$CFG" "$V"
cp "$CFG" "$W/c1.orig"
bash "$SUT" --vault "$V" --qmd-config "$CFG" >/dev/null 2>&1
check "dry-run exits 0" 0 "$?"
check "dry-run leaves the qmd config untouched" 0 "$(cmp -s "$CFG" "$W/c1.orig" && echo 0 || echo 1)"
check "dry-run adds no .graphifyignore" 0 "$([ ! -e "$V/.graphifyignore" ] && echo 0 || echo 1)"

bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
luna_ign="$(awk '/^  luna:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "luna gains the five ignore entries" \
  '"graphify-out/**" "60-Maps/graph/**" "handovers/**/verdicts/*/scratch/**" "handovers/**/archive/**" "sessions/_archive/**" ' "$luna_ign"
check "the luna-archive collection is added over the same vault" \
  "    path: $V|    pattern: \"{handovers/**/archive/**/*.md,sessions/_archive/**/*.md}\"" \
  "$(awk '/^  luna-archive:/{f=1;next} f&&/^  [^ ]|^[^ ]/{f=0} f{print}' "$CFG" | paste -sd'|' -)"
him_ign="$(awk '/^  himmel:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "himmel's own ignore list is untouched" '"graphify-out/**" "**/fixtures/**" ' "$him_ign"
check "other collections and models survive" 3 "$(grep -c -E '^  (ggs-local|himmel):$|^models:$' "$CFG")"
check "luna-archive sits before models" "luna-archive:|models:" \
  "$(grep -E '^  luna-archive:$|^models:$' "$CFG" | tr -d ' ' | paste -sd'|' -)"
cp "$CFG" "$W/c1.once"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check "a second apply is a no-op" 0 "$(cmp -s "$CFG" "$W/c1.once" && echo 0 || echo 1)"

# --- the archive collection joins the collections block, whatever follows it --
V="$W/v1b"; make_vault "$V"; CFG="$W/c1b.yml"; write_cfg "$CFG" "$V"
awk '/^models:/{print "settings:"; print "  keep: 1"} {print}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check "luna-archive sits inside collections, before the next section" "collections:|luna-archive:|settings:|models:" \
  "$(grep -E '^collections:$|^  luna-archive:$|^models:$|^settings:$' "$CFG" | tr -d ' ' | paste -sd'|' -)"

# --- a pre-existing luna ignore list is merged, not replaced ------------------
V="$W/v2"; make_vault "$V"; CFG="$W/c2.yml"; write_cfg "$CFG" "$V"
awk '{print} /^  luna:/{f=1} f&&/pattern:/{print "    ignore:"; print "      - \"Clippings/_raw/**\""; f=0}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
luna_ign="$(awk '/^  luna:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "existing luna ignore entry kept, new ones appended" \
  '"Clippings/_raw/**" "graphify-out/**" "60-Maps/graph/**" "handovers/**/verdicts/*/scratch/**" "handovers/**/archive/**" "sessions/_archive/**" ' "$luna_ign"

# --- a config without the collection is refused -------------------------------
printf 'collections:\n  other:\n    path: /x\n' > "$W/c3.yml"
bash "$SUT" --vault "$V" --qmd-config "$W/c3.yml" --apply >/dev/null 2>&1
check "missing collection exits nonzero" 3 "$?"

# --- .graphifyignore: corpus exclusion, existing lines kept, idempotent -------
V="$W/v4"; make_vault "$V"; CFG="$W/c4.yml"; write_cfg "$CFG" "$V"
printf '# keep me\nsessions/\n' > "$V/.graphifyignore"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check ".graphifyignore keeps its lines and gains the four exclusions" \
  "# keep me|sessions/|60-Maps/graph/|graphify-out/|handovers/**/archive/|sessions/_archive/" "$(paste -sd'|' "$V/.graphifyignore")"
cp "$V/.graphifyignore" "$W/gi.once"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check ".graphifyignore second apply is a no-op" 0 "$(cmp -s "$V/.graphifyignore" "$W/gi.once" && echo 0 || echo 1)"

# --- offload: a move, never a delete -----------------------------------------
V="$W/v5"; make_vault "$V"; CFG="$W/c5.yml"; write_cfg "$CFG" "$V"; OFF="$W/off"
touch -t 202001010000 "$V/graphify-out/d/GRAPH_REPORT.md" || exit 1
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$OFF" >/dev/null 2>&1
check "offload dry-run leaves graphify-out in place" 0 "$([ -d "$V/graphify-out" ] && echo 0 || echo 1)"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$OFF" --apply >/dev/null 2>&1
check "offload moves graphify-out out of the vault" 1 "$([ -e "$V/graphify-out" ] && echo 0 || echo 1)"
check "the report is under graphify-snapshots" 1 "$(find "$OFF/graphify-snapshots" -name GRAPH_REPORT.md 2>/dev/null | wc -l | tr -d ' ')"

V="$W/v6"; make_vault "$V"; CFG="$W/c6.yml"; write_cfg "$CFG" "$V"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/off6" --apply >/dev/null 2>&1
check "a graphify-out written within 24h is not moved (a writer may target it)" 0 "$([ -f "$V/graphify-out/d/GRAPH_REPORT.md" ] && echo 0 || echo 1)"

V="$W/v7"; make_vault "$V"; CFG="$W/c7.yml"; write_cfg "$CFG" "$V"
touch -t 202001010000 "$V/graphify-out/d/GRAPH_REPORT.md" || exit 1; mkdir "$V/graphify-out/.promote.lock" || exit 1
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/off7" --apply >/dev/null 2>&1
check "a held promote lock blocks the offload" 0 "$([ -d "$V/graphify-out/.promote.lock" ] && echo 0 || echo 1)"

# --- an ignore list indented four spaces is refused, not corrupted ------------
V="$W/v10"; make_vault "$V"; CFG="$W/c10.yml"; write_cfg "$CFG" "$V"
awk '{print} /^  luna:/{f=1} f&&/pattern:/{print "    ignore:"; print "    - \"Clippings/_raw/**\""; f=0}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
cp "$CFG" "$W/c10.orig"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check "a four-space ignore list exits 4" 4 "$?"
check "and the config is left as it was" 0 "$(cmp -s "$CFG" "$W/c10.orig" && echo 0 || echo 1)"

V="$W/v11"; make_vault "$V"; CFG="$W/c11.yml"; write_cfg "$CFG" "$V"
awk '{print} /^  luna:/{f=1} f&&/pattern:/{print "    ignore:"; print "    # kept"; print ""; print "    - \"Clippings/_raw/**\""; f=0}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
cp "$CFG" "$W/c11.orig"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check "a four-space list behind a comment and a blank line is refused too" 4 "$?"
check "and that config is left as it was" 0 "$(cmp -s "$CFG" "$W/c11.orig" && echo 0 || echo 1)"

V="$W/v12"; make_vault "$V"; CFG="$W/c12.yml"; write_cfg "$CFG" "$V"
awk '{print} /^  luna:/{f=1} f&&/pattern:/{print "    ignore:"; print "      # kept"; print "      - \"Clippings/_raw/**\""; print "      - \"graphify-out/**\""; f=0}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
luna_ign="$(awk '/^  luna:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "a comment inside a six-space list: no duplicate, new entries after the last item" \
  '"Clippings/_raw/**" "graphify-out/**" "60-Maps/graph/**" "handovers/**/verdicts/*/scratch/**" "handovers/**/archive/**" "sessions/_archive/**" ' "$luna_ign"

# --- failure paths: a missing value, an unwritable ignore file, an unreadable tree
if command -v timeout >/dev/null 2>&1; then
  timeout 5 bash "$SUT" --vault >/dev/null 2>&1
  check "an option with no value exits 2 instead of looping" 2 "$?"
else
  SKIP=$((SKIP+1)); echo "skip - no timeout(1): the option-without-value row"
fi

if [ "$(id -u)" -eq 0 ]; then
  SKIP=$((SKIP+1)); echo "skip - running as root: permission rows"
else
  V="$W/v8"; make_vault "$V"; CFG="$W/c8.yml"; write_cfg "$CFG" "$V"
  : > "$V/.graphifyignore"; chmod 444 "$V/.graphifyignore"
  bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
  check "an unwritable .graphifyignore fails the run" 1 "$?"
  chmod 644 "$V/.graphifyignore"

  V="$W/v9"; make_vault "$V"; CFG="$W/c9.yml"; write_cfg "$CFG" "$V"
  chmod 000 "$V/graphify-out/d"
  err9="$(bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/off9" --apply 2>&1 >/dev/null)"
  chmod 755 "$V/graphify-out/d"
  check "an unreadable subtree blocks the offload" 0 "$([ -d "$V/graphify-out" ] && echo 0 || echo 1)"
  check "and it says it could not scan" 0 "$(printf '%s' "$err9" | grep -q 'could not scan' && echo 0 || echo 1)"
fi

# --- an offload root inside graphify-out is refused before anything moves -----
V="$W/v13"; make_vault "$V"; CFG="$W/c13.yml"; write_cfg "$CFG" "$V"
mkdir -p "$V/graphify-out/inner" || exit 1
touch -t 202001010000 "$V/graphify-out/inner" "$V/graphify-out/d/GRAPH_REPORT.md" || exit 1
cp "$CFG" "$W/c13.orig"
nested_gi() { [ -d "$V/graphify-out/graphify-snapshots" ] || [ -d "$V/graphify-out/inner/graphify-snapshots" ] \
  || [ -d "$V/graphify-out/new" ] || [ -d "$V/graphify-out/inner/new" ]; }
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$V/graphify-out/inner" --apply >/dev/null 2>&1
check "an offload root inside graphify-out exits 2" 2 "$?"
check "and nothing is created inside graphify-out" 1 "$(nested_gi && echo 0 || echo 1)"
check "and the qmd config is untouched (refused before any write)" 0 "$(cmp -s "$CFG" "$W/c13.orig" && echo 0 || echo 1)"
check "and .graphifyignore is not written" 1 "$([ -e "$V/.graphifyignore" ] && echo 0 || echo 1)"

(cd "$V" && bash "$SUT" --vault . --qmd-config "$CFG" --offload-root graphify-out/new --apply >/dev/null 2>&1)
check "a not-yet-existing relative root inside graphify-out exits 2" 2 "$?"
check "and nothing is created for it" 1 "$(nested_gi && echo 0 || echo 1)"

bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$V/graphify-out/../graphify-out/inner/new" --apply >/dev/null 2>&1
check "a non-canonical not-yet-existing root inside graphify-out exits 2" 2 "$?"
check "and nothing is created for it either" 1 "$(nested_gi && echo 0 || echo 1)"

ln -s "$V/graphify-out/inner" "$W/link13" || exit 1
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/link13/new" --apply >/dev/null 2>&1
check "a not-yet-existing root under a symlink into graphify-out exits 2" 2 "$?"
check "and nothing is created through the symlink" 1 "$(nested_gi && echo 0 || echo 1)"
check "and graphify-out still holds its files" 0 "$([ -f "$V/graphify-out/d/GRAPH_REPORT.md" ] && echo 0 || echo 1)"

echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
