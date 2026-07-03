#!/usr/bin/env bash
# omniroute-config-lint.sh — structural WS6-dedup enforcement for the self-hosted
# OmniRoute router config (HIMMEL-654 WS2, child HIMMEL-666). himmel already runs
# its own rtk hook + caveman compression, so OmniRoute's bundled compression stack
# must be provably OFF ("one optimizer per boundary"). This lint is a POSITIVE
# assertion over the authoritative engine-key set from the WS2 Task-1 source-read
# (OmniRoute pin b729a8f / v3.8.43): every expected key must be PRESENT and
# explicitly disabled — an OMITTED default-on engine fails just like an enabled one.
#
# Input document shape (Task 2 — operator-gated — exports the deployed OmniRoute
# settings to this shape): a JSON object with the compression settings object under
# a top-level "compression" key and the free-lane flag "autoRoutingEnabled" at top
# level. An `optimization` subtree inside compression is SQLite VACUUM tuning (not
# prompt optimization) and is ignored.
#
# Usage: omniroute-config-lint.sh <config.json>
# Exit:  0 = PASS, 1 = one or more FAILs, 2 = usage / unreadable / unparseable input,
#         4 = node runtime missing (JSON parsing is delegated to node; matches the
#         claude-routed twins' node-missing=4 convention).
#
# JSON parsing is delegated to node (a himmel dependency — same precedent as
# scripts/claude-glm sanitize_settings). bash 3.2-safe.
set -u

if [ "$#" -ne 1 ]; then
  echo "usage: omniroute-config-lint.sh <config.json>" >&2
  exit 2
fi

LINT_JS=$(cat <<'NODE'
"use strict";
var fs = require("fs");
var cfgPath = process.argv[1];
var raw;
try { raw = fs.readFileSync(cfgPath, "utf8"); }
catch (e) { process.stderr.write("omniroute-config-lint: cannot read " + cfgPath + "\n"); process.exit(2); }
var doc;
try { doc = JSON.parse(raw); }
catch (e) { process.stderr.write("omniroute-config-lint: invalid JSON in " + cfgPath + "\n"); process.exit(2); }
if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
  process.stderr.write("omniroute-config-lint: config root is not a JSON object\n");
  process.exit(2);
}

var fails = [];
var asserted = 0;
function fail(m) { fails.push("FAIL: " + m); }
function isObj(x) { return x !== null && typeof x === "object" && !Array.isArray(x); }
function has(o, k) { return isObj(o) && Object.prototype.hasOwnProperty.call(o, k); }
function leaf(parent, key) { return { present: has(parent, key), value: (isObj(parent) ? parent[key] : undefined) }; }
function show(v) {
  if (v === undefined) return "<absent>";
  if (v === null) return "null";
  if (typeof v === "string") return v;
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}
function assertFalse(path, l) {
  asserted++;
  if (!l.present) { fail(path + " expected false, got <absent>"); return; }
  if (l.value !== false) fail(path + " expected false, got " + show(l.value));
}
function assertOff(path, l) {
  asserted++;
  if (!l.present) { fail(path + " expected off, got <absent>"); return; }
  if (l.value !== "off") fail(path + " expected off, got " + show(l.value));
}

var comp = doc.compression;
if (!has(doc, "compression")) {
  fail("compression object is missing (expected present with every engine disabled)");
} else if (!isObj(comp)) {
  fail("compression expected an object, got " + show(comp));
} else {
  assertFalse("compression.enabled", leaf(comp, "enabled"));
  assertOff("compression.defaultMode", leaf(comp, "defaultMode"));
  assertOff("compression.autoTriggerMode", leaf(comp, "autoTriggerMode"));
  assertFalse("compression.rtkConfig.enabled", leaf(leaf(comp, "rtkConfig").value, "enabled"));
  assertFalse("compression.cavemanConfig.enabled", leaf(leaf(comp, "cavemanConfig").value, "enabled"));
  assertFalse("compression.cavemanOutputMode.enabled", leaf(leaf(comp, "cavemanOutputMode").value, "enabled"));
  assertFalse("compression.ultra.enabled", leaf(leaf(comp, "ultra").value, "enabled"));
  assertFalse("compression.contextEditing.enabled", leaf(leaf(comp, "contextEditing").value, "enabled"));
  assertFalse("compression.languageConfig.enabled", leaf(leaf(comp, "languageConfig").value, "enabled"));
  assertFalse("compression.mcpDescriptionCompressionEnabled", leaf(comp, "mcpDescriptionCompressionEnabled"));
  assertFalse("compression.mcpAccessibilityConfig.enabled", leaf(leaf(comp, "mcpAccessibilityConfig").value, "enabled"));

  var eng = leaf(comp, "engines");
  asserted++;
  if (!eng.present) {
    fail("compression.engines missing (expected an object with every entry disabled)");
  } else if (!isObj(eng.value)) {
    fail("compression.engines expected an object, got " + show(eng.value));
  } else {
    var ek = Object.keys(eng.value);
    for (var i = 0; i < ek.length; i++) {
      var en = leaf(eng.value[ek[i]], "enabled");
      if (!(en.present && en.value === false)) {
        fail("compression.engines[\"" + ek[i] + "\"].enabled expected false, got " + (en.present ? show(en.value) : "<absent>"));
      }
    }
  }

  var agg = leaf(comp, "aggressive").value;
  assertFalse("compression.aggressive.summarizerEnabled", leaf(agg, "summarizerEnabled"));
  var ts = leaf(comp, "aggressive").present ? leaf(agg, "toolStrategies") : { present: false, value: undefined };
  asserted++;
  if (!ts.present) {
    fail("compression.aggressive.toolStrategies missing (expected an object with every entry disabled)");
  } else if (!isObj(ts.value)) {
    fail("compression.aggressive.toolStrategies expected an object, got " + show(ts.value));
  } else {
    var tk = Object.keys(ts.value);
    for (var j = 0; j < tk.length; j++) {
      var tv = ts.value[tk[j]];
      if (typeof tv === "boolean") {
        if (tv !== false) fail("compression.aggressive.toolStrategies." + tk[j] + " expected false, got true");
      } else if (isObj(tv)) {
        var te = leaf(tv, "enabled");
        if (!(te.present && te.value === false)) {
          fail("compression.aggressive.toolStrategies." + tk[j] + ".enabled expected false, got " + (te.present ? show(te.value) : "<absent>"));
        }
      } else {
        fail("compression.aggressive.toolStrategies." + tk[j] + " expected disabled, got " + show(tv));
      }
    }
  }

  var sp = leaf(comp, "stackedPipeline");
  asserted++;
  if (!sp.present) {
    fail("compression.stackedPipeline missing (expected an empty array)");
  } else if (!Array.isArray(sp.value)) {
    fail("compression.stackedPipeline expected an empty array, got " + show(sp.value));
  } else if (sp.value.length !== 0) {
    fail("compression.stackedPipeline expected an empty array, got " + sp.value.length + " entr" + (sp.value.length === 1 ? "y" : "ies"));
  }

  var cache = leaf(comp, "cache").value;
  assertFalse("compression.cache.semanticCacheEnabled", leaf(cache, "semanticCacheEnabled"));
  assertFalse("compression.cache.promptCacheEnabled", leaf(cache, "promptCacheEnabled"));

  // KEEP IN SYNC with the twin allowlist in scripts/omniroute-config-lint.ps1
  // ($known) — the recognized-key set must match, or one twin flags a key the
  // other silently accepts (a renamed/new engine sneaking past only one twin).
  var known = { enabled: 1, defaultMode: 1, autoTriggerMode: 1, rtkConfig: 1, cavemanConfig: 1, cavemanOutputMode: 1, ultra: 1, contextEditing: 1, languageConfig: 1, mcpDescriptionCompressionEnabled: 1, mcpAccessibilityConfig: 1, engines: 1, aggressive: 1, stackedPipeline: 1, cache: 1, optimization: 1 };
  var ck = Object.keys(comp);
  for (var k = 0; k < ck.length; k++) {
    if (!known[ck[k]]) fail("compression." + ck[k] + " is not a recognized key (discovered set != expected set; possible new/renamed engine)");
  }
}

asserted++;
if (!has(doc, "autoRoutingEnabled")) {
  fail("autoRoutingEnabled expected false, got <absent>");
} else if (doc.autoRoutingEnabled !== false) {
  fail("autoRoutingEnabled expected false, got " + show(doc.autoRoutingEnabled));
}

if (fails.length) {
  // FAIL diagnostics go to stderr; the PASS confirmation stays on stdout so a
  // passing lint emits exactly one stdout line (testable / pipeable), while a
  // failing one writes nothing to stdout. Exit code is unchanged (1).
  for (var f = 0; f < fails.length; f++) process.stderr.write(fails[f] + "\n");
  process.exit(1);
}
process.stdout.write("PASS: omniroute compression stack disabled (" + asserted + " keys asserted)\n");
process.exit(0);
NODE
)

# Preflight: JSON parsing is delegated to node, so a missing node would otherwise
# surface as a generic "node: command not found" (exit 127). Catch it up front with
# a clear message + exit 4, matching the claude-routed twins' node-missing=4 contract.
if ! command -v node >/dev/null 2>&1; then
  echo "omniroute-config-lint: node is required (JSON parsing is delegated to node) but was not found on PATH." >&2
  exit 4
fi
exec node -e "$LINT_JS" "$1"
