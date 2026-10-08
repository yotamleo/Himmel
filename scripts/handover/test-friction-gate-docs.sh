#!/usr/bin/env bash
# test-friction-gate-docs.sh — HIMMEL-4935. Pins the leg-preface wording that
# cuts two friction rows measured by HIMMEL-4926:
#   1. console-ruling latency: a brief may state `default-if-no-ruling (N min)`;
#      the default is NARROWING only and never stands in for GO / a merge / a
#      token-quoting message;
#   2. one-push-per-session (claudex lane): ONE push per head, with a same-head
#      fixup (fast-forward over the already-pushed head) allowed; a rewritten or
#      different-base head stays refused.
# Docs-only reads. PLATFORM GUARD: no .ps1 twin — Bash 3.2, grep/tr only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PREFACE="$DOCS/handover/leg-preface.md"
CLAUDEX="$DOCS/handover/leg-preface-claudex.md"
TEMPLATE="$DOCS/handover/leg-brief-template.md"
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
# joined <file> <ERE> — lines joined so a wrapped sentence is one sentence
has() {
    [ -r "$1" ] || return 1
    tr '\n' ' ' < "$1" | LC_ALL=C grep -qiE "$2"
}

# 1. default-if-no-ruling grammar
if has "$PREFACE" 'default-if-no-ruling \(<N> min\)'; then
    pass "preface names the default-if-no-ruling grammar"
else
    fail "preface names the default-if-no-ruling grammar"
fi
if has "$PREFACE" 'default may only +\*\*narrow\*\*'; then
    pass "preface limits the default to narrowing"
else
    fail "preface limits the default to narrowing"
fi
# shellcheck disable=SC2016 # the backticks are literal regex text
if has "$PREFACE" 'default never +stands in for +`GO`, a merge, or a token-quoting message'; then
    pass "preface keeps GO / merge / token message outside the default"
else
    fail "preface keeps GO / merge / token message outside the default"
fi
if has "$TEMPLATE" 'default-if-no-ruling \(<N> min\)' && has "$TEMPLATE" 'NARROWING only'; then
    pass "brief template offers the narrowing-only default line"
else
    fail "brief template offers the narrowing-only default line"
fi
# control: the template must not offer an expanding default. The matcher gets a
# positive control (a planted expanding default must match) and the template
# must be readable, so a grep error or missing file cannot read as "no match".
EXPAND_RE='default-if-no-ruling[^.]*(expand|widen|grant)[^.]*(allowed|permitted|ok)'
planted="$(mktemp)" || exit 1
trap 'rm -f "$planted"' EXIT
printf 'default-if-no-ruling (5 min): expand scope, allowed.\n' > "$planted"
if ! has "$planted" "$EXPAND_RE"; then
    fail "expanding-default matcher detects a planted expanding default"
elif [ ! -r "$TEMPLATE" ]; then
    fail "brief template is readable for the expanding-default check"
elif has "$TEMPLATE" "$EXPAND_RE"; then
    fail "brief template offers an expanding default"
else
    pass "brief template offers no expanding default"
fi

# 2. same-head fixup push
if has "$CLAUDEX" 'ONE push attempt per head'; then
    pass "claudex preface scopes the one-push rule per head"
else
    fail "claudex preface scopes the one-push rule per head"
fi
if has "$CLAUDEX" 'same-head fixup[^.]*fast-forward[^.]*parent chain contains the head you already pushed'; then
    pass "claudex preface allows a same-head fixup push"
else
    fail "claudex preface allows a same-head fixup push"
fi
if has "$CLAUDEX" 'rewritten, rebased, amended or +different-base head, which stays refused'; then
    pass "claudex preface still refuses a rewritten / different-base head"
else
    fail "claudex preface still refuses a rewritten / different-base head"
fi
if has "$CLAUDEX" 'Do not retry the push or work around a refusal'; then
    pass "claudex preface still forbids retrying a refused push"
else
    fail "claudex preface still forbids retrying a refused push"
fi

if [ "$fails" -eq 0 ]; then printf 'PASS - test-friction-gate-docs.sh\n'; exit 0; fi
printf 'FAIL - test-friction-gate-docs.sh (%s failure(s))\n' "$fails"
exit 1
