<#
.SYNOPSIS
    OmniDiag reporting: the Export-OmniReport coordinator.

.DESCRIPTION
    One entry point that writes any combination of HTML / JSON / CSV / ZIP from a
    session, into a target directory with a consistent, sanitized base name. The
    individual exporters remain independently callable; this just orchestrates them.
#>

Set-StrictMode -Version Latest

function Get-OmniSafeName {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'host' }
    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Export-OmniReport {
    <#
    .SYNOPSIS
        Generates one or more report formats for a session.

    .PARAMETER Session
        The OmniDiag.Session to report on.

    .PARAMETER OutputDirectory
        Folder to write into. Created if missing. Default: a 'reports' folder.

    .PARAMETER Format
        Any of Html, Json, Csv, Zip. Default: Html, Json, Csv.

    .PARAMETER BaseName
        Base file name (no extension). Default: OmniDiag-<computer>-<timestamp>.

    .PARAMETER BrandName
        Optional organization name for HTML/ZIP branding.

    .OUTPUTS
        OmniDiag.ReportSet describing the files written.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [string] $OutputDirectory = (Join-Path (Get-Location) 'reports'),
        [ValidateSet('Html', 'Json', 'Csv', 'Zip')]
        [string[]] $Format = @('Html', 'Json', 'Csv'),
        [string] $BaseName,
        [string] $BrandName
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    if (-not $BaseName) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $BaseName = "OmniDiag-$(Get-OmniSafeName $Session.Host.ComputerName)-$stamp"
    }

    $files = [System.Collections.Generic.List[string]]::new()
    $base = Join-Path $OutputDirectory $BaseName

    foreach ($fmt in ($Format | Select-Object -Unique)) {
        switch ($fmt) {
            'Html' { $files.Add((Export-OmniHtmlReport -Session $Session -Path "$base.html" -BrandName $BrandName)) }
            'Json' { $files.Add((Export-OmniJsonReport -Session $Session -Path "$base.json")) }
            'Csv'  {
                $files.Add((Export-OmniCsvReport -Session $Session -Path "$base.findings.csv"))
                $evt = Export-OmniEventCsvReport -Session $Session -Path "$base.events.csv"
                if ($evt) { $files.Add($evt) }
            }
            'Zip'  { $files.Add((Export-OmniReportPackage -Session $Session -Path "$base.zip" -BrandName $BrandName)) }
        }
    }

    return [pscustomobject]@{
        PSTypeName      = 'OmniDiag.ReportSet'
        OutputDirectory = $OutputDirectory
        BaseName        = $BaseName
        Formats         = @($Format)
        Files           = @($files)
        GeneratedAt     = (Get-Date)
    }
}

Export-ModuleMember -Function @('Export-OmniReport', 'Get-OmniSafeName')
