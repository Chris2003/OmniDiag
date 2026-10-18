<#
.SYNOPSIS
    OmniDiag reporting: structured JSON export (report schema v1).

.DESCRIPTION
    Writes the user-facing JSON report: the versioned, documented projection of a
    session described by schemas/omnidiag-report.v1.json (see ReportV1.psm1 and
    docs/SCHEMA.md). The text is produced by ConvertTo-OmniJsonText, so it is
    deterministic, ASCII-only, and identical on Windows PowerShell 5.1 and
    PowerShell 7. Written as UTF-8 without a BOM.

    Saved sessions (OmniDiagData\sessions) keep OmniDiag's native internal format;
    they are written by Save-OmniSession, not by this exporter. Import-OmniSession
    reads both.
#>

Set-StrictMode -Version Latest

function Write-OmniTextFile {
    <# .SYNOPSIS Internal: write text as UTF-8 (no BOM), creating the folder. #>
    param([string] $Path, [string] $Content)
    # .NET resolves relative paths against the process directory, not PowerShell's location.
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Export-OmniJsonReport {
    <#
    .SYNOPSIS
        Writes a session to a JSON report (report schema v1).

    .DESCRIPTION
        Projects the session with ConvertTo-OmniReportV1 and writes it with
        ConvertTo-OmniJsonText. To persist a session in OmniDiag's native format
        (for -FromSession / -CompareWith), use Save-OmniSession instead; both files
        load with Import-OmniSession.

    .PARAMETER Session
        The OmniDiag.Session returned by Invoke-OmniDiag.

    .PARAMETER Path
        Output file path.

    .PARAMETER Option
        Optional run options recorded under the report's 'options' object.

    .OUTPUTS
        The written file path (string).

    .EXAMPLE
        Export-OmniJsonReport -Session $session -Path .\report.json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [hashtable] $Option
    )

    $params = @{ Session = $Session }
    if ($Option) { $params.Option = $Option }
    $json = ConvertTo-OmniReportV1 @params | ConvertTo-OmniJsonText
    Write-OmniTextFile -Path $Path -Content ($json + "`n")
    return $Path
}

Export-ModuleMember -Function @('Export-OmniJsonReport', 'Write-OmniTextFile')
