<#
.SYNOPSIS
    Extracts one version's section from CHANGELOG.md as release notes.

.DESCRIPTION
    Finds the first level-2 heading for the version - '## 1.0.0', '## [1.0.0]',
    '## v1.0.0', optionally followed by a date or title ('## 1.0.0 - 2026-11-02') - and
    returns the lines after it up to the next level-2 heading, trimmed of leading and
    trailing blank lines. Throws when the version has no section or the section is empty,
    so a release cannot go out without notes.

    -RequireReleased also refuses a heading that still says 'unreleased' (the release
    workflow uses it for tag pushes).

.PARAMETER Version
    Version to look up (with or without a leading 'v').

.PARAMETER ChangelogPath
    Defaults to <repo>/CHANGELOG.md.

.PARAMETER OutputPath
    Optional file to write the notes to (UTF-8 without BOM, LF).

.PARAMETER RequireReleased
    Fail when the version's heading contains 'unreleased'.

.EXAMPLE
    ./build/Get-ReleaseNotes.ps1 -Version 1.0.0 -OutputPath release-notes.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Version,
    [string] $ChangelogPath,
    [string] $OutputPath,
    [switch] $RequireReleased
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ChangelogPath) { $ChangelogPath = Join-Path $repoRoot 'CHANGELOG.md' }
if (-not (Test-Path -LiteralPath $ChangelogPath -PathType Leaf)) { throw "Get-ReleaseNotes: changelog not found: $ChangelogPath" }

$bare = $Version.Trim()
if ($bare.StartsWith('v') -or $bare.StartsWith('V')) { $bare = $bare.Substring(1) }
$bare = Get-OmniReleaseVersion -RepoRoot $repoRoot -Version $bare

$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ChangelogPath).ProviderPath, [System.Text.Encoding]::UTF8)
$lines = $text -split "\r?\n"
# '## ' + optional '[' + optional 'v' + version + optional ']' + end of line or a non-version character.
$heading = '^##\s+\[?[vV]?' + [regex]::Escape($bare) + '\]?(?=$|[\s:(])'

$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $heading) { $start = $i; break }
}
if ($start -lt 0) { throw "Get-ReleaseNotes: CHANGELOG has no '## $bare' section." }
if ($RequireReleased -and $lines[$start] -match '(?i)unreleased') {
    throw "Get-ReleaseNotes: the CHANGELOG heading for $bare still says 'unreleased': '$($lines[$start])'. Date it before tagging."
}

$end = $lines.Count
for ($j = $start + 1; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match '^##\s') { $end = $j; break }
}
$body = @()
if ($end -gt $start + 1) { $body = @($lines[($start + 1)..($end - 1)]) }
while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[0])) { $body = @($body | Select-Object -Skip 1) }
while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) { $body = @($body | Select-Object -First ($body.Count - 1)) }
if ($body.Count -eq 0) { throw "Get-ReleaseNotes: the CHANGELOG section for $bare is empty." }

$notes = ($body -join "`n") + "`n"
if ($OutputPath) {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    Write-OmniTextFile -Path $OutputPath -Text $notes
}
return $notes
