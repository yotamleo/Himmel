# preflight-adopter.ps1 — shared adopter preflight checks (HIMMEL-842 fix-batch).
#
# Dot-sourced (not executed) by both scripts/adopt.ps1 (auto-invoked from
# Require-Tools) and scripts/preflight-adopter.ps1 (the standalone check-only
# runner an adopter can run BEFORE committing to adopt.ps1 — operator answer Q4:
# "BOTH standalone check-only AND auto-invoked"). Counterpart of
# scripts/lib/preflight-adopter.sh; keep both in lockstep.
#
# FUNCTIONS ONLY — dot-sourcing this file has NO side effects (no variables are
# set, nothing runs at source time). Each Test-* check returns $true when the
# environment is clean and $false when its gap is detected (after Write-Warning).
# WARN-not-fail in the sense that a check never throws/exits — the caller decides
# severity. adopt.ps1 escalates the npm-less-node $false into a hard fail when
# there is no JS package manager at all; the standalone runner just counts. The
# detection is not duplicated between the two entry points; only the severity
# policy differs.
#
# Checks (each closes a HIMMEL-842 gap from the preflight design spec):
#   Test-PreflightUvPipx        — uv OR pipx present (gap 1: pre-commit install)
#   Test-PreflightNpmInvocable  — npm invocable when node is (gap 2: npm-less
#                                 distro node)
#   Test-PreflightJiraDist      — scripts/jira/dist/index.js + node_modules
#                                 both built (gap 3)
#
# $HimmelRoot must be set by the caller before calling Test-PreflightJiraDist —
# an unset/empty $HimmelRoot WARNs and returns $false (caller bug) rather than
# silently passing.

# uv OR pipx must be present so the luna-vault setup can install pre-commit
# (PEP 668 blocks raw pip). Neither himmel's adopt.ps1 nor ensure-tools.sh
# auto-installs uv today, so surface the gap + the same astral.sh command used
# ad hoc in 3 other places. Returns $false (advisory) on the gap.
function Test-PreflightUvPipx {
    if ((-not (Get-Command uv -ErrorAction SilentlyContinue)) -and (-not (Get-Command pipx -ErrorAction SilentlyContinue))) {
        Write-Warning "neither 'uv' nor 'pipx' found — the luna-vault setup's pre-commit install will fail. Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
        return $false
    }
    return $true
}

# Ubuntu's distro 'nodejs' ships WITHOUT npm. node-without-npm breaks the
# plugin-install workflow, the lockfile/audit pre-commit gates, and a bare node
# with no package manager can't build dist/ artifacts. Returns $false (advisory)
# when node is present but npm is not — bun covers every himmel JS build, so this
# is advisory here; adopt.ps1 escalates to a hard fail only when there is no JS
# package manager AT ALL (npm AND bun both absent).
function Test-PreflightNpmInvocable {
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (-not (Get-Command npm -ErrorAction SilentlyContinue))) {
        Write-Warning "'node' found but 'npm' is missing (Ubuntu's nodejs ships without npm). Install Node + npm via NodeSource: https://github.com/nodesource/distributions OR use bun: https://bun.sh (covers all himmel JS builds; required for qmd/handover)"
        return $false
    }
    return $true
}

# scripts/jira/dist/index.js AND scripts/jira/node_modules are gitignored
# build artifacts — a fresh clone bootstrapped via adopt.ps1 hits
# MODULE_NOT_FOUND without dist/ (CLAUDE.md's "worktrees lack dist/" warning is
# scoped too narrowly; a fresh PRIMARY clone via adopt.ps1 hits the identical
# failure), and a STALE dist/ without node_modules/ passes as "already built"
# then fails at runtime (fix-batch F3: setup.ps1's invariant checks BOTH, so
# this check now does too — naming which half is missing). Returns $false
# (advisory) when either is absent. Also returns $false (fix-batch F2) when
# $HimmelRoot is unset/empty — a caller bug, not a silent pass. adopt.ps1's
# Build-JiraCli builds both; this check only surfaces the gap so a standalone
# preflight run flags it up front.
function Test-PreflightJiraDist {
    if (-not $HimmelRoot) {
        Write-Warning "HIMMEL_ROOT not set — jira-dist check skipped (caller bug)"
        return $false
    }
    $jiraDir = Join-Path $HimmelRoot 'scripts\jira'
    $hasNodeModules = Test-Path (Join-Path $jiraDir 'node_modules')
    $hasDist = Test-Path (Join-Path $jiraDir 'dist\index.js')
    $gap = $null
    if ((-not $hasNodeModules) -and (-not $hasDist)) {
        $gap = "scripts/jira/node_modules and scripts/jira/dist/index.js not built"
    } elseif (-not $hasNodeModules) {
        $gap = "scripts/jira/node_modules not installed"
    } elseif (-not $hasDist) {
        $gap = "scripts/jira/dist/index.js not built"
    }
    if ($gap) {
        Write-Warning "$gap (gitignored build artifact) — the Jira CLI won't run until it is. Build it: (cd scripts/jira && npm install && npm run build)   [adopt.ps1 builds this automatically via Build-JiraCli]"
        return $false
    }
    return $true
}
