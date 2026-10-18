<#
.SYNOPSIS
    Portable data locations for OmniDiag.

.DESCRIPTION
    OmniDiag is a portable tool: it runs from whatever folder it was extracted to
    (a Downloads folder, a network share, or a USB stick) and keeps everything it
    writes - logs, reports, registry backups, and scratch files - in an
    OmniDiagData folder next to the tool. Nothing is written to %TEMP%,
    %APPDATA%, or %LOCALAPPDATA%, so removing the tool folder (or unplugging the
    USB stick) leaves no OmniDiag files behind on the host.

    Resolution order for the data root:
      1. $env:OMNIDIAG_DATA (explicit override)
      2. <tool folder>\OmniDiagData, when the tool folder is writable
      3. %TEMP%\OmniDiag as a last resort (read-only media), flagged IsPortable=$false
#>

Set-StrictMode -Version Latest

# src/Core -> tool root (the folder holding OmniDiag.ps1 and the launchers).
$script:OmniToolRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:OmniDataRootCache = $null

function Test-OmniDirectoryWritable {
    <# .SYNOPSIS Internal: true when a probe file can be created and removed in the folder. #>
    param([Parameter(Mandatory)][string] $Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Path ('.write-test-' + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-OmniToolRoot {
    <# .SYNOPSIS Returns the folder OmniDiag is running from. #>
    [OutputType([string])]
    param()
    return $script:OmniToolRoot
}

function Get-OmniDataRoot {
    <#
    .SYNOPSIS
        Returns where OmniDiag keeps everything it writes.

    .OUTPUTS
        OmniDiag.DataRoot with Path, IsPortable (data lives with the tool), and Source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $Refresh)

    if ($script:OmniDataRootCache -and -not $Refresh) { return $script:OmniDataRootCache }

    $candidate = $null; $source = $null; $portable = $true
    if ($env:OMNIDIAG_DATA) {
        $candidate = $env:OMNIDIAG_DATA; $source = 'Environment'
        $portable = $candidate.StartsWith($script:OmniToolRoot, [System.StringComparison]::OrdinalIgnoreCase)
    } else {
        $toolData = Join-Path $script:OmniToolRoot 'OmniDiagData'
        if (Test-OmniDirectoryWritable -Path $toolData) {
            $candidate = $toolData; $source = 'ToolFolder'
        } else {
            $candidate = Join-Path ([System.IO.Path]::GetTempPath()) 'OmniDiag'; $source = 'TempFallback'; $portable = $false
        }
    }

    $script:OmniDataRootCache = [pscustomobject]@{
        PSTypeName = 'OmniDiag.DataRoot'
        Path       = $candidate
        ToolRoot   = $script:OmniToolRoot
        IsPortable = $portable
        Source     = $source
    }
    return $script:OmniDataRootCache
}

function Get-OmniDataPath {
    <#
    .SYNOPSIS
        Returns (and creates) a subfolder of the data root.

    .PARAMETER Kind
        Logs, Reports, Sessions, Backups, Temp, or Cache.

    .PARAMETER ChildPath
        Optional file name to append.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Logs', 'Reports', 'Sessions', 'Backups', 'Temp', 'Cache')][string] $Kind,
        [string] $ChildPath
    )
    $dir = Join-Path (Get-OmniDataRoot).Path $Kind.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($ChildPath) { return (Join-Path $dir $ChildPath) }
    return $dir
}

function Clear-OmniTempData {
    <# .SYNOPSIS Removes OmniDiag's scratch folder (data root\temp). Logs and reports are kept. #>
    [CmdletBinding()]
    param()
    $temp = Join-Path (Get-OmniDataRoot).Path 'temp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function @('Get-OmniToolRoot', 'Get-OmniDataRoot', 'Get-OmniDataPath', 'Clear-OmniTempData')
