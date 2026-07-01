<#
.SYNOPSIS
    OmniDiag diagnostic module: Printers.

.DESCRIPTION
    Enumerates installed printers and their status, records the default printer and
    print-driver count, and flags printers that are offline or in an error state.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Printers'
        Category      = 'Peripherals'
        Description   = 'Installed printers, default printer, and offline/error state.'
        RequiresAdmin = $false
        Order         = 290
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Printers' -Category 'Peripherals' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $printers = $null
    $usedCim = $false

    # Prefer Get-Printer, fall back to Win32_Printer.
    try {
        if (Get-Command -Name 'Get-Printer' -ErrorAction SilentlyContinue) {
            $printers = @(Get-Printer -ErrorAction Stop)
        }
    } catch {
        $log.Warn("Get-Printer failed: $($_.Exception.Message)", 'Printers')
        $printers = $null
    }

    if ($null -eq $printers) {
        try {
            $printers = @(Get-CimInstance -ClassName 'Win32_Printer' -ErrorAction Stop)
            $usedCim = $true
        } catch {
            $log.Warn("CIM query failed for Win32_Printer: $($_.Exception.Message)", 'Printers')
            $printers = @()
        }
    }

    Set-OmniResultMetric -Result $result -Name 'PrinterCount' -Value (@($printers).Count)

    # Default printer.
    try {
        if ($usedCim) {
            $default = @($printers | Where-Object { $_.Default }) | Select-Object -First 1
            Set-OmniResultMetric -Result $result -Name 'DefaultPrinter' -Value ($(if ($default) { $default.Name } else { 'None' }))
        } else {
            $def = @(Get-CimInstance -ClassName 'Win32_Printer' -ErrorAction SilentlyContinue | Where-Object { $_.Default }) | Select-Object -First 1
            Set-OmniResultMetric -Result $result -Name 'DefaultPrinter' -Value ($(if ($def) { $def.Name } else { 'Unknown' }))
        }
    } catch {
        Set-OmniResultMetric -Result $result -Name 'DefaultPrinter' -Value 'Unknown'
        $log.Debug("Default printer lookup failed: $($_.Exception.Message)", 'Printers')
    }

    # Printer names + status list.
    try {
        $list = @($printers | ForEach-Object {
            $status = if ($usedCim) { $_.PrinterStatus } else { $_.PrinterStatus }
            "{0} [{1}]" -f $_.Name, $status
        })
        Set-OmniResultMetric -Result $result -Name 'PrinterList' -Value $list
    } catch {
        $log.Debug("Printer list build failed: $($_.Exception.Message)", 'Printers')
    }

    # Flag offline / error-state printers.
    try {
        foreach ($p in $printers) {
            $offline = $false
            $bad = $false
            $reason = ''
            if ($usedCim) {
                # Win32_Printer: WorkOffline bool; PrinterStatus 7 = Offline, PrinterState errors vary.
                if ($p.PSObject.Properties['WorkOffline'] -and $p.WorkOffline) { $offline = $true; $reason = 'WorkOffline' }
                if ($p.PSObject.Properties['PrinterStatus'] -and $p.PrinterStatus -eq 7) { $offline = $true; $reason = 'PrinterStatus=Offline' }
            } else {
                # Get-Printer: PrinterStatus enum (Normal/Offline/Error/...).
                $ps = "$($p.PrinterStatus)"
                if ($ps -match 'Offline') { $offline = $true; $reason = "PrinterStatus=$ps" }
                if ($ps -match 'Error') { $bad = $true; $reason = "PrinterStatus=$ps" }
            }
            if ($offline -or $bad) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title "Printer not ready: $($p.Name)" -Severity 'Warning' `
                    -Component 'Peripherals/Printer' `
                    -Detail "Printer '$($p.Name)' appears offline or in an error state ($reason)." `
                    -LikelyCause 'Printer powered off, disconnected, out of paper/ink, or a spooler/network issue.' `
                    -Confidence 60 `
                    -Recommendation 'Verify the printer is powered on and connected; restart the Print Spooler if needed.')
            }
        }
    } catch {
        $log.Debug("Printer status scan failed: $($_.Exception.Message)", 'Printers')
    }

    # Print driver count (best-effort).
    try {
        if (Get-Command -Name 'Get-PrinterDriver' -ErrorAction SilentlyContinue) {
            $drivers = @(Get-PrinterDriver -ErrorAction Stop)
            Set-OmniResultMetric -Result $result -Name 'PrintDriverCount' -Value $drivers.Count
        }
    } catch {
        $log.Debug("Get-PrinterDriver failed: $($_.Exception.Message)", 'Printers')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Printers enumerated' -Severity 'Pass' -Component 'Peripherals/Printer' `
            -Detail 'All installed printers appear online with no reported errors.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
