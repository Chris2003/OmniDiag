<#
.SYNOPSIS
    OmniDiag diagnostic module: Storage.

.DESCRIPTION
    Reports physical-disk SMART/health, SSD wear and temperature, volume health and
    free space, and (best-effort) disk performance counters. Each result is graded
    Healthy / Warning / Critical via finding severity.

    Some reliability counters (temperature, wear) require elevation; when they are
    unavailable the module logs and continues rather than failing.

    Per-run options (via $Context.Config):
        LowSpaceWarnPct   int  Free-space warning threshold (percent). Default 10.
        LowSpaceCritPct   int  Free-space critical threshold (percent). Default 5.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Storage'
        Category      = 'Storage'
        Description   = 'Disk SMART health, SSD wear/temperature, volume health, and free space.'
        RequiresAdmin = $false
        Order         = 40
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Storage' -Category 'Storage' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = $Context.Config

    $warnPct = if ($cfg.ContainsKey('LowSpaceWarnPct')) { [int]$cfg['LowSpaceWarnPct'] } else { 10 }
    $critPct = if ($cfg.ContainsKey('LowSpaceCritPct')) { [int]$cfg['LowSpaceCritPct'] } else { 5 }

    # --- Physical disks + SMART health -----------------------------------
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'PhysicalDisks' -Value $disks.Count
        foreach ($d in $disks) {
            $sizeGb = [math]::Round($d.Size / 1GB, 0)
            $label = "$($d.FriendlyName) ($($d.MediaType), $sizeGb GB)"
            Set-OmniResultMetric -Result $result -Name "Disk: $($d.DeviceId)" -Value ("{0} - Health {1}, Op {2}" -f $label, $d.HealthStatus, ($d.OperationalStatus -join '/'))

            if ($d.HealthStatus -ne 'Healthy') {
                $sev = if ($d.HealthStatus -eq 'Unhealthy') { 'Critical' } else { 'Warning' }
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Disk health: $($d.HealthStatus) - $($d.FriendlyName)" -Severity $sev `
                    -Component "Storage/Disk$($d.DeviceId)" -Detail "Physical disk reports HealthStatus '$($d.HealthStatus)', OperationalStatus '$($d.OperationalStatus -join '/')'." `
                    -LikelyCause 'The drive is reporting a SMART/health problem.' -Confidence 80 `
                    -Recommendation 'Back up data immediately and plan to replace the drive.')
            }

            # Reliability counters (may require admin).
            try {
                $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($null -ne $rc) {
                    if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) {
                        Set-OmniResultMetric -Result $result -Name "Disk $($d.DeviceId) Temp(C)" -Value $rc.Temperature
                        if ($rc.Temperature -ge 65) {
                            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "High drive temperature ($($rc.Temperature) C)" -Severity 'Warning' `
                                -Component "Storage/Disk$($d.DeviceId)" -Detail "Drive temperature is $($rc.Temperature) C." `
                                -LikelyCause 'Inadequate cooling or sustained heavy I/O.' -Confidence 60 `
                                -Recommendation 'Improve airflow/cooling; check for runaway disk activity.')
                        }
                    }
                    if ($null -ne $rc.Wear -and $rc.Wear -gt 0) {
                        Set-OmniResultMetric -Result $result -Name "Disk $($d.DeviceId) Wear(%)" -Value $rc.Wear
                        $wearSev = if ($rc.Wear -ge 90) { 'Critical' } elseif ($rc.Wear -ge 80) { 'Warning' } else { $null }
                        if ($wearSev) {
                            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "SSD wear at $($rc.Wear)%" -Severity $wearSev `
                                -Component "Storage/Disk$($d.DeviceId)" -Detail "The SSD has consumed $($rc.Wear)% of its rated write endurance." `
                                -LikelyCause 'The drive is approaching the end of its write life.' -Confidence 75 `
                                -Recommendation 'Plan replacement; ensure backups are current.')
                        }
                    }
                }
            } catch {
                $log.Debug("Reliability counters unavailable for disk $($d.DeviceId): $($_.Exception.Message)", 'Storage')
            }
        }
    } catch {
        $log.Warn("Get-PhysicalDisk failed: $($_.Exception.Message)", 'Storage')
    }

    # --- Logical disk operational status ---------------------------------
    try {
        foreach ($disk in (Get-Disk -ErrorAction Stop)) {
            if ($disk.HealthStatus -and $disk.HealthStatus -ne 'Healthy') {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Disk $($disk.Number) health: $($disk.HealthStatus)" -Severity 'Warning' `
                    -Component "Storage/Disk$($disk.Number)" -Detail "Operational status: $($disk.OperationalStatus)." `
                    -LikelyCause 'The disk subsystem reports a non-healthy state.' -Confidence 60 `
                    -Recommendation 'Investigate the disk; check cabling and SMART data.')
            }
        }
    } catch { $log.Debug("Get-Disk failed: $($_.Exception.Message)", 'Storage') }

    # --- Volumes: health + free space ------------------------------------
    try {
        $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 })
        foreach ($v in $vols) {
            $freePct = [int][math]::Round(($v.SizeRemaining / $v.Size) * 100)
            $freeGb = [math]::Round($v.SizeRemaining / 1GB, 1)
            $sizeGb = [math]::Round($v.Size / 1GB, 1)
            Set-OmniResultMetric -Result $result -Name "Volume $($v.DriveLetter):" -Value ("{0} - {1} GB free of {2} GB ({3}%), {4}" -f $v.FileSystem, $freeGb, $sizeGb, $freePct, $v.HealthStatus)

            if ($v.HealthStatus -and $v.HealthStatus -ne 'Healthy') {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Volume $($v.DriveLetter): health is $($v.HealthStatus)" -Severity 'Error' `
                    -Component "Storage/Volume$($v.DriveLetter)" -Detail "Volume health status is '$($v.HealthStatus)'." `
                    -LikelyCause 'File-system or underlying disk problem.' -Confidence 70 `
                    -Recommendation 'Run chkdsk on the volume after backing up.')
            }

            if ($freePct -le $critPct) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Critically low disk space on $($v.DriveLetter): ($freePct% free)" -Severity 'Critical' `
                    -Component "Storage/Volume$($v.DriveLetter)" -Detail "$freeGb GB free of $sizeGb GB." `
                    -LikelyCause 'The volume is nearly full.' -Confidence 90 `
                    -Recommendation 'Free space urgently (temp files, old profiles, Disk Cleanup); low space can block updates and cause failures.')
            }
            elseif ($freePct -le $warnPct) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Low disk space on $($v.DriveLetter): ($freePct% free)" -Severity 'Warning' `
                    -Component "Storage/Volume$($v.DriveLetter)" -Detail "$freeGb GB free of $sizeGb GB." `
                    -LikelyCause 'The volume is getting full.' -Confidence 80 `
                    -Recommendation 'Clean up unused files; aim to keep at least 15% free.')
            }
        }
    } catch {
        $log.Warn("Get-Volume failed: $($_.Exception.Message)", 'Storage')
    }

    # --- Disk performance (best-effort) ----------------------------------
    try {
        $q = (Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length' -ErrorAction Stop).CounterSamples[0].CookedValue
        $q = [math]::Round($q, 2)
        Set-OmniResultMetric -Result $result -Name 'DiskQueueLength' -Value $q
        if ($q -ge 5) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "High disk queue length ($q)" -Severity 'Warning' `
                -Component 'Storage/Performance' -Detail "Current disk queue length is $q (sustained values > 2 indicate a bottleneck)." `
                -LikelyCause 'Disk is a performance bottleneck under the current load.' -Confidence 50 `
                -Recommendation 'Identify heavy I/O processes; consider an SSD upgrade if on HDD.')
        }
    } catch { $log.Debug("Disk performance counter unavailable: $($_.Exception.Message)", 'Storage') }

    if (($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Storage is healthy' -Severity 'Pass' `
            -Component 'Storage' -Detail 'All disks report healthy SMART status with adequate free space.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
