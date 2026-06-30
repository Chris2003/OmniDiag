<#
.SYNOPSIS
    OmniDiag reporting: structured JSON export.

.DESCRIPTION
    Serializes a complete OmniDiag.Session (device info, per-module results,
    findings, metrics, event timeline/groups, and the scored summary) to a single
    JSON document for machine consumption or archival. Written as UTF-8 without a
    BOM via .NET so the output is clean across PowerShell 5.1 and 7.
#>

Set-StrictMode -Version Latest

function Write-OmniTextFile {
    <# .SYNOPSIS Internal: write text as UTF-8 (no BOM), creating the folder. #>
    param([string] $Path, [string] $Content)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Export-OmniJsonReport {
    <#
    .SYNOPSIS
        Writes a session to a JSON file.

    .PARAMETER Session
        The OmniDiag.Session returned by Invoke-OmniDiag.

    .PARAMETER Path
        Output file path.

    .OUTPUTS
        The written file path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path
    )

    # Depth 12 captures findings -> Data -> nested event groups/timeline entries.
    $json = $Session | ConvertTo-Json -Depth 12
    Write-OmniTextFile -Path $Path -Content $json
    return $Path
}

Export-ModuleMember -Function @('Export-OmniJsonReport', 'Write-OmniTextFile')
