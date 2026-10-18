<#
.SYNOPSIS
    OmniDiag process exit codes (v1): the table as data plus derivation helpers.

.DESCRIPTION
    Every OmniDiag entry point (OmniDiag.ps1, the omnidiag CLI router, and the .cmd
    launchers that propagate %ERRORLEVEL%) reports its outcome with the same codes,
    so automation can branch on them without parsing output:

        0  Success, no warnings or critical findings
        1  Warnings present
        2  Critical findings present
        3  Partial: one or more modules failed or timed out
        4  Requested module(s) need elevation and the process is not elevated
        5  Cancelled
       10  Usage or argument error
       11  Repair failed
       12  Repair succeeded; reboot required
       20  Internal error

    The table is data (Get-OmniExitCodeTable) so docs and tests read the same source.
#>

Set-StrictMode -Version Latest

$script:OmniExitCodes = @(
    [pscustomobject]@{ Code = 0;  Name = 'Ok';                Description = 'Success, no warnings or critical findings' }
    [pscustomobject]@{ Code = 1;  Name = 'Warnings';          Description = 'Warnings present' }
    [pscustomobject]@{ Code = 2;  Name = 'Critical';          Description = 'Critical findings present' }
    [pscustomobject]@{ Code = 3;  Name = 'Partial';           Description = 'Partial: one or more modules failed or timed out' }
    [pscustomobject]@{ Code = 4;  Name = 'ElevationRequired'; Description = "Requested module(s) need elevation and the process isn't elevated" }
    [pscustomobject]@{ Code = 5;  Name = 'Cancelled';         Description = 'Cancelled' }
    [pscustomobject]@{ Code = 10; Name = 'Usage';             Description = 'Usage or argument error' }
    [pscustomobject]@{ Code = 11; Name = 'RepairFailed';      Description = 'Repair failed' }
    [pscustomobject]@{ Code = 12; Name = 'RebootRequired';    Description = 'Repair succeeded; reboot required' }
    [pscustomobject]@{ Code = 20; Name = 'InternalError';     Description = 'Internal error' }
)

function Get-OmniExitCodeTable {
    <#
    .SYNOPSIS
        Returns the OmniDiag exit-code table (Code, Name, Description).

    .EXAMPLE
        Get-OmniExitCodeTable | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    foreach ($row in $script:OmniExitCodes) {
        [pscustomobject]@{ PSTypeName = 'OmniDiag.ExitCode'; Code = $row.Code; Name = $row.Name; Description = $row.Description }
    }
}

function Get-OmniExitCodeValue {
    <#
    .SYNOPSIS
        Returns the numeric exit code for a symbolic name (e.g. 'Usage' -> 10).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string] $Name)
    $row = @($script:OmniExitCodes | Where-Object { $_.Name -ieq $Name })
    if ($row.Count -eq 0) { throw "Unknown exit code name '$Name'. Valid: $(($script:OmniExitCodes.Name) -join ', ')." }
    return [int]$row[0].Code
}

function Get-OmniPropertyValue {
    <# .SYNOPSIS Internal: StrictMode-safe property read with a default. #>
    param($InputObject, [string] $Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Get-OmniExitCode {
    <#
    .SYNOPSIS
        Derives the process exit code (0-5) from a diagnostic session.

    .DESCRIPTION
        Precedence, first match wins:
          5  the session was cancelled
          4  modules were explicitly requested (-ExplicitSelection) and every one of
             them was skipped because the process is not elevated
          3  any module Failed (or timed out)
          2  any Error or Critical finding
          1  any Warning finding
          0  otherwise
        Skipped modules (and their informational findings) never raise the code on
        their own. Works on live sessions, imported sessions, and sessions rebuilt
        from a v1 report.

    .PARAMETER Session
        An OmniDiag.Session.

    .PARAMETER ExplicitSelection
        The caller asked for specific modules (e.g. --module). Only then does an
        all-skipped-for-elevation run report 4 instead of 0. Alias: RequestedElevation.

    .EXAMPLE
        exit (Get-OmniExitCode -Session $session)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Session,
        [Alias('RequestedElevation')] [switch] $ExplicitSelection
    )

    if ($null -eq $Session) { return 20 }
    if ([bool](Get-OmniPropertyValue $Session 'Cancelled' $false)) { return 5 }

    $results = @(Get-OmniPropertyValue $Session 'Results' @()) | Where-Object { $null -ne $_ }
    $results = @($results)

    if ($ExplicitSelection -and $results.Count -gt 0) {
        $elevationSkips = @($results | Where-Object {
            [string](Get-OmniPropertyValue $_ 'Status' '') -eq 'Skipped' -and (
                [string](Get-OmniPropertyValue $_ 'SkippedReason' '') -eq 'RequiresElevation' -or
                ([bool](Get-OmniPropertyValue $_ 'RequiresAdmin' $false) -and -not [bool](Get-OmniPropertyValue $_ 'HadAdmin' $false))
            )
        })
        if ($elevationSkips.Count -eq $results.Count) { return 4 }
    }

    if (@($results | Where-Object { [string](Get-OmniPropertyValue $_ 'Status' '') -eq 'Failed' }).Count -gt 0) { return 3 }

    $worst = 0
    foreach ($r in $results) {
        if ([string](Get-OmniPropertyValue $r 'Status' '') -eq 'Skipped') { continue }
        foreach ($f in @(Get-OmniPropertyValue $r 'Findings' @())) {
            if ($null -eq $f) { continue }
            switch ([string](Get-OmniPropertyValue $f 'Severity' '')) {
                'Critical' { if ($worst -lt 2) { $worst = 2 } }
                'Error'    { if ($worst -lt 2) { $worst = 2 } }
                'Warning'  { if ($worst -lt 1) { $worst = 1 } }
            }
        }
    }
    return $worst
}

function Get-OmniRepairExitCode {
    <#
    .SYNOPSIS
        Maps a repair session to 11 (a repair failed), 12 (reboot required), or 0.

    .PARAMETER RepairSession
        An OmniDiag.RepairSession from Invoke-OmniRepair / Invoke-OmniRepairConsole.
        $null (nothing was run) maps to 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()] [object] $RepairSession)

    if ($null -eq $RepairSession) { return 0 }
    $results = @(Get-OmniPropertyValue $RepairSession 'Results' @()) | Where-Object { $null -ne $_ }
    if (@($results | Where-Object { [string](Get-OmniPropertyValue $_ 'Status' '') -eq 'Failed' }).Count -gt 0) { return 11 }
    $reboot = [bool](Get-OmniPropertyValue $RepairSession 'RebootRequired' $false) -or
        (@($results | Where-Object { [string](Get-OmniPropertyValue $_ 'Status' '') -eq 'RebootRequired' }).Count -gt 0)
    if ($reboot) { return 12 }
    return 0
}

Export-ModuleMember -Function @('Get-OmniExitCodeTable', 'Get-OmniExitCodeValue', 'Get-OmniExitCode', 'Get-OmniRepairExitCode')
