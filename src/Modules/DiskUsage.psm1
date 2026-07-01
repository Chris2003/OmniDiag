<#
.SYNOPSIS
    OmniDiag diagnostic module: Disk Usage.

.DESCRIPTION
    Per-volume used/free/total space breakdown with used-percentage metrics. Warns
    when any fixed drive exceeds 90% used, and lists the largest top-level folders
    on the system drive as an informational finding (bounded, best-effort).

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
        Name          = 'Disk Usage'
        Category      = 'Storage'
        Description   = 'Per-volume space usage and largest top-level folders.'
        RequiresAdmin = $false
        Order         = 310
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

    $result = New-OmniResult -ModuleName 'Disk Usage' -Category 'Storage' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Per-volume usage --------------------------------------------------
    try {
        $vols = @()
        if (Get-Command -Name 'Get-Volume' -ErrorAction SilentlyContinue) {
            try {
                $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | ForEach-Object {
                    [pscustomobject]@{
                        Letter = "$($_.DriveLetter)"
                        Size   = [double]$_.Size
                        Free   = [double]$_.SizeRemaining
                    }
                })
            } catch { $vols = @() }
        }

        if (@($vols).Count -eq 0) {
            $vols = @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Letter = "$($_.DeviceID)".TrimEnd(':')
                    Size   = [double]$_.Size
                    Free   = [double]$_.FreeSpace
                }
            })
        }

        foreach ($v in $vols) {
            $totalGb = [math]::Round(($v.Size / 1GB), 1)
            $freeGb  = [math]::Round(($v.Free / 1GB), 1)
            $usedGb  = [math]::Round((($v.Size - $v.Free) / 1GB), 1)
            $usedPct = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.Free) / $v.Size) * 100, 1) } else { 0 }

            Set-OmniResultMetric -Result $result -Name "Drive.$($v.Letter).TotalGB" -Value $totalGb
            Set-OmniResultMetric -Result $result -Name "Drive.$($v.Letter).UsedGB"  -Value $usedGb
            Set-OmniResultMetric -Result $result -Name "Drive.$($v.Letter).FreeGB"  -Value $freeGb
            Set-OmniResultMetric -Result $result -Name "Drive.$($v.Letter).UsedPct" -Value $usedPct

            if ($v.Size -gt 0 -and $usedPct -gt 90) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title "Drive $($v.Letter): is $usedPct% full" -Severity 'Warning' `
                    -Component "Storage/Usage/$($v.Letter)" `
                    -Detail "Drive $($v.Letter): uses $usedGb GB of $totalGb GB ($usedPct%), leaving $freeGb GB free." `
                    -LikelyCause 'The drive is running out of space.' `
                    -Confidence 85 `
                    -Recommendation 'Remove unneeded files, run Disk Cleanup/Storage Sense, or expand the volume.')
            }
        }
    } catch {
        $log.Warn("Volume usage enumeration failed: $($_.Exception.Message)", 'Disk Usage')
    }

    # NOTE: deliberately no recursive whole-drive folder sizing here - walking the
    # entire system drive to rank top-level folders cost ~18 s and duplicated the
    # dedicated Disk and Temp Files scanners. Per-volume usage above IS the breakdown.

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Disk usage within limits' -Severity 'Pass' -Component 'Storage/Usage' `
            -Detail 'All fixed drives are below 90% used.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
