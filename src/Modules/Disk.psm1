<#
.SYNOPSIS
    OmniDiag diagnostic module: Disk.

.DESCRIPTION
    Reports physical disk health (HealthStatus, operational status, media type,
    size), volume free space, and SMART predictive-failure status. Raises Critical
    findings for SMART failure predictions or unhealthy disks, and Warnings for
    fixed volumes running low on free space.

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
        Name          = 'Disk'
        Category      = 'Storage'
        Description   = 'Physical disk health, volume free space, and SMART status.'
        RequiresAdmin = $false
        Order         = 300
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

    $result = New-OmniResult -ModuleName 'Disk' -Category 'Storage' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Physical disks ----------------------------------------------------
    try {
        $physical = $null
        if (Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue) {
            try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $physical = $null }
        }

        if ($null -ne $physical) {
            Set-OmniResultMetric -Result $result -Name 'PhysicalDiskCount' -Value $physical.Count
            $i = 0
            foreach ($d in $physical) {
                $sizeGb = try { [math]::Round(($d.Size / 1GB), 1) } catch { 0 }
                $prefix = "Disk${i}"
                Set-OmniResultMetric -Result $result -Name "$prefix.Model"       -Value $d.FriendlyName
                Set-OmniResultMetric -Result $result -Name "$prefix.MediaType"   -Value ("{0}" -f $d.MediaType)
                Set-OmniResultMetric -Result $result -Name "$prefix.SizeGB"      -Value $sizeGb
                Set-OmniResultMetric -Result $result -Name "$prefix.HealthStatus" -Value ("{0}" -f $d.HealthStatus)
                Set-OmniResultMetric -Result $result -Name "$prefix.OperationalStatus" -Value ("{0}" -f ($d.OperationalStatus -join ','))

                if ("$($d.HealthStatus)" -ne 'Healthy') {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title "Disk health not Healthy: $($d.FriendlyName)" -Severity 'Critical' `
                        -Component "Storage/$prefix" `
                        -Detail "Physical disk '$($d.FriendlyName)' reports HealthStatus '$($d.HealthStatus)' (operational: $($d.OperationalStatus -join ', '))." `
                        -LikelyCause 'The storage subsystem reports the drive is degrading or failing.' `
                        -Confidence 80 `
                        -Recommendation 'Back up data immediately and plan to replace the drive.')
                }
                $i++
            }
        } else {
            # Fall back to Win32_DiskDrive.
            $drives = @(Get-CimInstance -ClassName 'Win32_DiskDrive' -ErrorAction Stop)
            Set-OmniResultMetric -Result $result -Name 'PhysicalDiskCount' -Value $drives.Count
            $i = 0
            foreach ($d in $drives) {
                $sizeGb = try { [math]::Round(($d.Size / 1GB), 1) } catch { 0 }
                $prefix = "Disk${i}"
                Set-OmniResultMetric -Result $result -Name "$prefix.Model"   -Value $d.Model
                Set-OmniResultMetric -Result $result -Name "$prefix.SizeGB"  -Value $sizeGb
                Set-OmniResultMetric -Result $result -Name "$prefix.Status"  -Value $d.Status
                if ($d.Status -and $d.Status -ne 'OK') {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title "Disk status not OK: $($d.Model)" -Severity 'Critical' `
                        -Component "Storage/$prefix" `
                        -Detail "Disk '$($d.Model)' reports status '$($d.Status)'." `
                        -LikelyCause 'The drive is reporting a hardware problem.' `
                        -Confidence 75 `
                        -Recommendation 'Back up data and plan to replace the drive.')
                }
                $i++
            }
        }
    } catch {
        $log.Warn("Physical disk enumeration failed: $($_.Exception.Message)", 'Disk')
    }

    # --- SMART predictive-failure status -----------------------------------
    try {
        $smart = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop)
        $predicting = @($smart | Where-Object { $_.PredictFailure })
        Set-OmniResultMetric -Result $result -Name 'SmartPredictFailureCount' -Value $predicting.Count
        foreach ($s in $predicting) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'SMART predicts drive failure' -Severity 'Critical' `
                -Component 'Storage/SMART' `
                -Detail "SMART on instance '$($s.InstanceName)' predicts imminent failure (reason code $($s.Reason))." `
                -LikelyCause 'The drive firmware has flagged self-monitoring thresholds indicating failure.' `
                -Confidence 90 `
                -Recommendation 'Back up all data immediately and replace the drive as soon as possible.')
        }
    } catch {
        $log.Debug("SMART predict-failure query unavailable: $($_.Exception.Message)", 'Disk')
    }

    # --- Volumes -----------------------------------------------------------
    try {
        $volumes = $null
        if (Get-Command -Name 'Get-Volume' -ErrorAction SilentlyContinue) {
            try { $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter }) } catch { $volumes = $null }
        }

        if ($null -ne $volumes) {
            foreach ($v in $volumes) {
                $letter = "$($v.DriveLetter)"
                $sizeGb = try { [math]::Round(($v.Size / 1GB), 1) } catch { 0 }
                $freeGb = try { [math]::Round(($v.SizeRemaining / 1GB), 1) } catch { 0 }
                $freePct = if ($v.Size -gt 0) { [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1) } else { 0 }
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.FileSystem" -Value ("{0}" -f $v.FileSystem)
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.SizeGB"     -Value $sizeGb
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.FreeGB"     -Value $freeGb
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.FreePct"    -Value $freePct

                $isFixed = ("$($v.DriveType)" -eq 'Fixed')
                if ($isFixed -and $v.Size -gt 0 -and $freePct -lt 10) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title "Low free space on ${letter}: ($freePct%)" -Severity 'Warning' `
                        -Component "Storage/Volume/$letter" `
                        -Detail "Fixed volume ${letter}: has $freeGb GB free of $sizeGb GB ($freePct%)." `
                        -LikelyCause 'Disk is nearly full, which can degrade performance and block updates.' `
                        -Confidence 85 `
                        -Recommendation 'Free up space (Disk Cleanup, remove temp/old files) or expand the volume.')
                }
            }
        } else {
            $logical = @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3' -ErrorAction Stop)
            foreach ($v in $logical) {
                $letter = "$($v.DeviceID)".TrimEnd(':')
                $sizeGb = try { [math]::Round(($v.Size / 1GB), 1) } catch { 0 }
                $freeGb = try { [math]::Round(($v.FreeSpace / 1GB), 1) } catch { 0 }
                $freePct = if ($v.Size -gt 0) { [math]::Round(($v.FreeSpace / $v.Size) * 100, 1) } else { 0 }
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.SizeGB"  -Value $sizeGb
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.FreeGB"  -Value $freeGb
                Set-OmniResultMetric -Result $result -Name "Volume.$letter.FreePct" -Value $freePct
                if ($v.Size -gt 0 -and $freePct -lt 10) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title "Low free space on ${letter}: ($freePct%)" -Severity 'Warning' `
                        -Component "Storage/Volume/$letter" `
                        -Detail "Fixed volume ${letter}: has $freeGb GB free of $sizeGb GB ($freePct%)." `
                        -LikelyCause 'Disk is nearly full, which can degrade performance and block updates.' `
                        -Confidence 85 `
                        -Recommendation 'Free up space (Disk Cleanup, remove temp/old files) or expand the volume.')
                }
            }
        }
    } catch {
        $log.Warn("Volume enumeration failed: $($_.Exception.Message)", 'Disk')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Disks healthy' -Severity 'Pass' -Component 'Storage' `
            -Detail 'Physical disks report healthy, SMART shows no predicted failures, and volumes have adequate free space.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
