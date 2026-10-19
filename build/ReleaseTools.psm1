<#
.SYNOPSIS
    Shared helpers for the OmniDiag release scripts (build/Build-Portable.ps1,
    build/New-Sbom.ps1, build/New-ReleaseManifest.ps1, build/Get-ReleaseNotes.ps1).

.DESCRIPTION
    Build-time only: never shipped in the portable package (build/ is excluded).
    Everything here is deterministic for a given input, so two builds of the same commit
    produce the same bytes. Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

Set-StrictMode -Version Latest

# 1980-01-01T00:00:00Z: the earliest time a zip (MS-DOS) timestamp can hold. Used when
# neither SOURCE_DATE_EPOCH nor git is available.
$script:OmniFallbackEpoch = [long]315532800
$script:OmniVersionPattern = '^\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$'

function Get-OmniReleaseVersion {
    <# .SYNOPSIS Module version from src/OmniDiag.psd1, or a validated override. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Version
    )
    if (-not $Version) {
        $manifestPath = Join-Path $RepoRoot 'src/OmniDiag.psd1'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Cannot find the module manifest at: $manifestPath" }
        $Version = [string](Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
    }
    if ($Version -notmatch $script:OmniVersionPattern) {
        throw "Invalid version '$Version': expected MAJOR.MINOR.PATCH with an optional -prerelease suffix."
    }
    return $Version
}

function Invoke-OmniGit {
    <#
    .SYNOPSIS
        Runs git in the repository and returns stdout as one string, or $null when git is
        missing, the folder is not a work tree, or git fails. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    if (-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
    $previous = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into errors under 'Stop'.
        $ErrorActionPreference = 'Continue'
        $out = & git -C $RepoRoot @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($out) -join "`n")
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-OmniSourceDateEpoch {
    <#
    .SYNOPSIS
        The build's fixed timestamp (Unix seconds): SOURCE_DATE_EPOCH when set, else the
        HEAD commit time (git log -1 --format=%ct), else 1980-01-01T00:00:00Z.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $fromEnv = [string]$env:SOURCE_DATE_EPOCH
    if ($fromEnv) {
        if ($fromEnv.Trim() -notmatch '^\d{1,12}$') { throw "SOURCE_DATE_EPOCH must be a whole number of seconds since 1970-01-01 UTC (got '$fromEnv')." }
        $epoch = [long]$fromEnv.Trim()
    } else {
        $fromGit = Invoke-OmniGit -RepoRoot $RepoRoot -Arguments @('log', '-1', '--format=%ct')
        if ($fromGit -and $fromGit.Trim() -match '^\d{1,12}$') { $epoch = [long]$fromGit.Trim() }
        else { $epoch = $script:OmniFallbackEpoch }
    }
    # Zip timestamps cannot go below 1980 (or above 2107).
    if ($epoch -lt $script:OmniFallbackEpoch) { $epoch = $script:OmniFallbackEpoch }
    if ($epoch -gt [long]4354819198) { throw "SOURCE_DATE_EPOCH $epoch is past the zip timestamp range (2107)." }
    return $epoch
}

function ConvertFrom-OmniUnixTime {
    <# .SYNOPSIS Unix seconds -> DateTimeOffset at UTC (offset 0). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [long] $Epoch)
    return [DateTimeOffset]::new([DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($Epoch))
}

function Get-OmniZipTimestamp {
    <#
    .SYNOPSIS
        The entry timestamp for a zip: the epoch's UTC clock time, rounded down to an even
        second (MS-DOS time resolution), with a zero offset so the host time zone never
        leaks into the archive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [long] $Epoch)
    $utc = (ConvertFrom-OmniUnixTime -Epoch ($Epoch - ($Epoch % 2))).UtcDateTime
    return [DateTimeOffset]::new([DateTime]::SpecifyKind($utc, [DateTimeKind]::Unspecified), [TimeSpan]::Zero)
}

function Get-OmniSha256Hex {
    <# .SYNOPSIS Lowercase hex SHA-256 of a file (-Path) or a byte array (-Bytes). #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')] [AllowEmptyCollection()] [byte[]] $Bytes
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $stream = [System.IO.File]::OpenRead($Path)
            try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
        } else {
            $hash = $sha.ComputeHash($Bytes)
        }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Write-OmniTextFile {
    <# .SYNOPSIS Writes text exactly as given: UTF-8 without a BOM (ASCII when the text is ASCII). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-OmniJson {
    <#
    .SYNOPSIS
        Deterministic JSON writer (2-space indent, LF, ASCII with \u escapes, keys in
        insertion order). Used instead of ConvertTo-Json, whose escaping and layout differ
        between Windows PowerShell 5.1 and PowerShell 7.
    .NOTES
        Supports ordered/hashtables, arrays/lists, strings, booleans, integers, and $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowNull()] [AllowEmptyCollection()] $InputObject,
        [int] $Depth = 0
    )
    $pad = '  ' * ($Depth + 1)
    $close = '  ' * $Depth
    if ($null -eq $InputObject) { return 'null' }
    if ($InputObject -is [bool]) { if ($InputObject) { return 'true' } else { return 'false' } }
    if ($InputObject -is [int] -or $InputObject -is [long]) { return ([string]$InputObject) }
    if ($InputObject -is [string]) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($ch in $InputObject.ToCharArray()) {
            $code = [int]$ch
            switch ($code) {
                34 { [void]$sb.Append('\"'); continue }
                92 { [void]$sb.Append('\\'); continue }
                10 { [void]$sb.Append('\n'); continue }
                13 { [void]$sb.Append('\r'); continue }
                9 { [void]$sb.Append('\t'); continue }
                default {
                    if ($code -lt 32 -or $code -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                    else { [void]$sb.Append($ch) }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '{}' }
        $parts = foreach ($key in $InputObject.Keys) {
            $pad + (ConvertTo-OmniJson -InputObject ([string]$key)) + ': ' + (ConvertTo-OmniJson -InputObject $InputObject[$key] -Depth ($Depth + 1))
        }
        return "{`n" + (@($parts) -join ",`n") + "`n$close}"
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $pad + (ConvertTo-OmniJson -InputObject $item -Depth ($Depth + 1)) }
        return "[`n" + (@($parts) -join ",`n") + "`n$close]"
    }
    throw "ConvertTo-OmniJson: unsupported type $($InputObject.GetType().FullName)."
}

Export-ModuleMember -Function Get-OmniReleaseVersion, Invoke-OmniGit, Get-OmniSourceDateEpoch, ConvertFrom-OmniUnixTime,
    Get-OmniZipTimestamp, Get-OmniSha256Hex, Write-OmniTextFile, ConvertTo-OmniJson
