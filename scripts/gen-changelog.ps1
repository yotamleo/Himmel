# Generate CHANGELOG.md from conventional-commit history (newest first), grouped
# by version tag: `## [Unreleased]` for commits after the newest version tag,
# then one `## [<tag>] - <date>` section per release, newest release first.
# With NO version tags (the pre-first-release state) the output is a single
# `## [Unreleased]` over all history -- byte-identical to the pre-HIMMEL-2250
# generator, so a tagless repo sees no churn.
# Non-conventional/merge/revert -> ### Other.
# Fully generated; do not hand-edit. Idempotent on immediate re-run.
#
# Usage:
#   gen-changelog.ps1            regenerate CHANGELOG.md in place
#   gen-changelog.ps1 --check    write nothing; exit 1 if the committed file is
#                                 stale (prints the missing-entry count). This is
#                                 the staleness primitive the morning report and
#                                 the release step read -- HIMMEL-2250.
$ErrorActionPreference = 'Stop'
# PowerShell decodes a captured native-command's stdout using [Console]::
# OutputEncoding, which on this platform defaults to the legacy OEM codepage,
# not UTF-8 -- so every non-ASCII byte `git log` writes (em dashes, arrows,
# anything outside ASCII in a commit subject) gets silently mis-decoded on
# capture, corrupting $subjects in render() below and breaking byte-identical
# twin output for any repo whose history has non-ASCII commit subjects (this
# repo's does). Force UTF-8 before any git subprocess call.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (git rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { Write-Error "Not a git repository"; exit 1 }
$out = Join-Path $root 'CHANGELOG.md'

# Version tags only. The repo also carries non-version tags (recovery stashes
# etc.); matching them would invent phantom release sections, so the glob is
# `v` + digit -- the scheme proposed in HIMMEL-2250 (`vMAJOR.MINOR.PATCH`, with
# `-rc.N` pre-releases sorting inside the same glob).
# KEEP IN SYNC with scripts/gen-changelog.sh VERSION_TAG_GLOB.
$versionTagGlob = 'v[0-9]*'
# The glob above is a cheap pre-filter and also matches non-version tags like
# `v1-backup` or a bare `v1.2` (too few components) -- this anchored regex is
# the real gate: `vMAJOR.MINOR.PATCH` with an optional `-rc.1`-style suffix.
# KEEP IN SYNC with scripts/gen-changelog.sh VERSION_TAG_RE.
$versionTagRe = '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# render <heading> [<git-log-range>] -> [string[]] lines for one version
# section. Empty/omitted range means "all history" (the tagless case). Always
# starts with a leading blank line so the file ends with exactly one trailing
# newline (see the join note below). Twin of the .sh's render(): classification
# must match exactly.
function render([string]$heading, [string]$range = '') {
    $added = @(); $fixed = @(); $changed = @(); $other = @()

    if ($range) {
        $subjects = git log --no-merges '--format=%s' $range
    } else {
        $subjects = git log --no-merges '--format=%s'
    }
    foreach ($subj in $subjects) {
        if ($subj -match '^feat[:(]') {
            $added   += "- " + ($subj -replace '^[^:]*: ','')
        } elseif ($subj -match '^fix[:(]') {
            $fixed   += "- " + ($subj -replace '^[^:]*: ','')
        } elseif ($subj -match '^(chore|refactor|docs|test)[:(]') {
            $changed += "- $subj"
        } else {
            $other   += "- $subj"
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add($heading)
    if ($added.Count -gt 0)   { $lines.Add(''); $lines.Add('### Added');   foreach ($l in $added)   { $lines.Add($l) } }
    if ($fixed.Count -gt 0)   { $lines.Add(''); $lines.Add('### Fixed');   foreach ($l in $fixed)   { $lines.Add($l) } }
    if ($changed.Count -gt 0) { $lines.Add(''); $lines.Add('### Changed'); foreach ($l in $changed) { $lines.Add($l) } }
    if ($other.Count -gt 0)   { $lines.Add(''); $lines.Add('### Other');   foreach ($l in $other)   { $lines.Add($l) } }
    return ,$lines.ToArray()
}

# generate -> [string[]] full CHANGELOG.md content, one entry per line. Twin of
# the .sh's generate(): with zero version tags this is a single Unreleased
# section over all history (byte-identical to the pre-HIMMEL-2250 output); with
# >=1 tag, Unreleased covers <newest-tag>..HEAD then one section per tag
# newest-first, each ranged against its predecessor (the oldest tag gets the
# open-ended all-history-up-to-it range).
function generate {
    # Double @()-wrap: a single-tag `git tag --list` result collapses to a bare
    # string on the pipeline (PowerShell's single-item unwrapping), and $tags[0]
    # on a string indexes CHARACTERS ("v0.1.0"[0] -> "v"), not array elements.
    $rawTags = @(@(git tag --list $versionTagGlob) | Where-Object { $_ -and $_ -match $versionTagRe })

    # Order by ANCESTRY (commit count via `git rev-list --count`), newest
    # first -- NOT creatordate: a backfilled annotated tag on an older commit
    # can carry a newer creatordate than a tag on a later commit, which would
    # sort it first and compute `<prev>..<tag>` ranges against the wrong
    # predecessor. Assumes a linear release history (this repo's `main`,
    # squash merges) -- a tag on a side branch is not orderable this way, so
    # such tags are filtered out below (with a warning) before the count sort
    # even runs (HIMMEL-2363).
    # On an ancestry tie (two tags on the SAME commit, e.g. an rc promoted to
    # its release), a release sorts before a pre-release of the same version
    # -- semver precedence, `v0.1.0` outranks `v0.1.0-rc.1` -- via Rank (1 =
    # no `-` suffix, 0 = has one), then Tag name descending as the final
    # tie-break, so the order is total and matches the .sh twin exactly.
    # KEEP IN SYNC with scripts/gen-changelog.sh tag ordering + $rank. The
    # outer @() re-wraps a single-tag result, which a bare pipeline would
    # unwrap.
    #
    # Reachable-commit-count ordering is only valid for tags that are
    # ancestors of HEAD -- a tag on a side branch has no topological
    # relationship to HEAD's history, so its count is meaningless and sorting
    # by it corrupts every release range (HIMMEL-2363: a side-branch tag with
    # a higher count than the real latest release outranks it, and commits
    # already released reappear under both `## [Unreleased]` and their real
    # release section). Drop it, but never silently -- a dropped release tag
    # is a trap for the next operator wondering where a release went.
    # `--is-ancestor` exits 1 for "not an ancestor" but >1 for a real git
    # error (bad object, corrupt ref) -- conflating the two would silently
    # drop a release tag on an operational error instead of failing
    # generation (HIMMEL-2363 CR).
    # KEEP IN SYNC with scripts/gen-changelog.sh ancestry filter.
    $rawTags = @($rawTags | Where-Object {
        git merge-base --is-ancestor $_ HEAD 2>$null | Out-Null
        $mbRc = $LASTEXITCODE
        if ($mbRc -gt 1) {
            [Console]::Error.WriteLine("gen-changelog: ERROR: git merge-base --is-ancestor failed for tag '$_' (exit $mbRc)")
            exit 1
        }
        $isAncestor = ($mbRc -eq 0)
        if (-not $isAncestor) {
            [Console]::Error.WriteLine("gen-changelog: WARNING: version tag '$_' is not an ancestor of HEAD (side branch) -- excluded from CHANGELOG.md")
        }
        $isAncestor
    })
    $tags = @($rawTags | ForEach-Object {
        $rank = if ($_ -match '-') { 0 } else { 1 }
        [pscustomobject]@{ Tag = $_; Count = [int](git rev-list --count $_); Rank = $rank }
    } | Sort-Object -Property Count, Rank, Tag -Descending | ForEach-Object { $_.Tag })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<!-- generated by scripts/gen-changelog.sh; do not hand-edit -->')
    $lines.Add('# Changelog')

    if ($tags.Count -eq 0) {
        $lines.AddRange((render '## [Unreleased]'))
        return ,$lines.ToArray()
    }

    $lines.AddRange((render '## [Unreleased]' "$($tags[0])..HEAD"))
    for ($i = 0; $i -lt $tags.Count; $i++) {
        $t = $tags[$i]
        $prev = if ($i + 1 -lt $tags.Count) { $tags[$i + 1] } else { '' }
        $date = (git log -1 '--format=%ad' '--date=short' $t)
        $range = if ($prev) { "$prev..$t" } else { "$t" }
        $lines.AddRange((render "## [$t] - $date" $range))
    }
    return ,$lines.ToArray()
}

$lines = generate

# Blank line goes BEFORE each heading (not after each section) so the file
# ends with exactly one trailing newline -- otherwise end-of-file-fixer rewrites
# it on every commit and a freshly regenerated file never matches the committed
# one (breaking the idempotence promise).
$text = ($lines -join "`n") + "`n"

# Hoisted so both the --check byte comparison and the write path below share
# the same encoder.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ($args.Count -gt 0 -and $args[0] -eq '--check') {
    if (-not (Test-Path $out)) {
        Write-Host "STALE gen-changelog: CHANGELOG.md is missing — run scripts/gen-changelog.ps1"
        exit 1
    }
    # True byte comparison (mirrors the .sh twin's `cmp`) -- NOT Get-Content
    # -Raw, which decodes/re-encodes text and disagrees with `cmp` in both
    # directions: under Windows PowerShell 5.1 it reports a genuinely
    # byte-identical UTF-8 file as different (false STALE), and under both
    # 5.1 and pwsh 7 it reports a file that differs only by a UTF-8 BOM as
    # identical (false CURRENT) even though the bytes don't match.
    # [Convert]::ToBase64String gives an O(n) exact-bytes comparison without
    # a PowerShell-level byte-array loop.
    $oldBytes = [System.IO.File]::ReadAllBytes($out)
    $newBytes = $utf8NoBom.GetBytes($text)
    if ([Convert]::ToBase64String($oldBytes) -eq [Convert]::ToBase64String($newBytes)) {
        Write-Host "OK gen-changelog: CHANGELOG.md is current"
        exit 0
    }
    # Missing-entry count: entry lines (`- ...`) present in the regenerated
    # content but absent from the committed file -- narrowed to entry lines
    # only (not headings/blank lines) to mirror the .sh twin's
    # `diff "$OUT" "$tmp" | grep -c '^> - '`. Exact multiset semantics (a
    # dictionary of counts), NOT Compare-Object -- Compare-Object's
    # -SyncWindow positional matching produced wildly wrong counts (437 vs
    # the .sh twin's 1) on this repo's real history -- and NOT an attempt to
    # replicate diff's sequence/LCS semantics either (expensive to build in
    # PowerShell and unnecessary): CHANGELOG.md is machine-generated and
    # never hand-edited, so the only difference between the committed file
    # and a fresh regen is entries appended since the last regen -- never a
    # reorder or an edit -- and for that shape a multiset count of "new
    # entries not covered by an old one" equals diff's added-line count
    # exactly. Both twins therefore agree on the same number via two
    # different, equally exact set-based algorithms (this one O(n) via a
    # hashtable; the .sh's O(n log n) via `diff`), not two different
    # approximations. This part stays line-oriented (Get-Content, not raw
    # bytes): it is a human-facing count for the STALE message, not the
    # CURRENT/STALE correctness decision above (already a true byte
    # comparison), so text decoding here is harmless.
    $oldLines = @(Get-Content $out)
    $oldEntries = @($oldLines | Where-Object { $_ -like '- *' })
    $newEntries = @($lines | Where-Object { $_ -like '- *' })
    $oldCounts = @{}
    foreach ($e in $oldEntries) {
        if ($oldCounts.ContainsKey($e)) { $oldCounts[$e]++ } else { $oldCounts[$e] = 1 }
    }
    $missing = 0
    foreach ($e in $newEntries) {
        if ($oldCounts.ContainsKey($e) -and $oldCounts[$e] -gt 0) { $oldCounts[$e]-- } else { $missing++ }
    }
    if ($missing -eq 0) {
        # A tag-only restructure (a release tag added with no new commits)
        # moves existing entries between sections without adding any --
        # "0 entr(ies) behind" reads as a bug in the checker, not staleness.
        # Report the true shape instead; morning-report.sh's counted-line
        # regex only matches "is <digits> entr(ies) behind", so this line
        # correctly falls through to its verbatim fallback. KEEP IN SYNC
        # with scripts/gen-changelog.sh wording.
        Write-Host "STALE gen-changelog: CHANGELOG.md structure changed with no new entries — run scripts/gen-changelog.sh"
    } else {
        Write-Host "STALE gen-changelog: CHANGELOG.md is $missing entr(ies) behind — run scripts/gen-changelog.sh"
    }
    exit 1
}

# Write UTF-8 (no BOM) with LF line endings + a single trailing newline, so the
# Windows twin produces byte-identical output to the bash twin (no CRLF drift).
# ($utf8NoBom is constructed above, hoisted for reuse by the --check path.)
[System.IO.File]::WriteAllText($out, $text, $utf8NoBom)
exit 0
