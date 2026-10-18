<#
.SYNOPSIS
    OmniDiag diagnostic module: TRIM.

.DESCRIPTION
    Reports whether file-system delete notifications (TRIM / unmap) are enabled for
    NTFS and ReFS, and correlates the setting with the solid-state drives present.

    Data sources (read-only, language independent):
      - HKLM\SYSTEM\CurrentControlSet\Control\FileSystem
          DisableDeleteNotification      (NTFS; 0 or absent = enabled, 1 = disabled)
          RefsDisableDeleteNotification  (ReFS; 0 = enabled, 1 = disabled, absent =
                                          not set, the ReFS default applies)
        These are the values 'fsutil behavior query DisableDeleteNotify' reports; the
        scanner reads them directly and never runs fsutil.
      - Get-PhysicalDisk (MSFT_PhysicalDisk.MediaType: SSD / 4) for SSD detection.
      - Get-Volume (MSFT_Volume.FileSystem) to see whether any ReFS volume exists.

    Severity: TRIM disabled while an SSD is present -> Warning; disabled with no SSD
    (or media type unknown) -> Information; enabled -> Pass.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

$script:OmniTrimFileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the TRIM scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'TRIM'
        Id            = 'storage.trim'
        Group         = 'storage'
        NetworkAccess = 'None'
        Category      = 'Storage'
        Description   = 'TRIM (delete notification) state for NTFS and ReFS, correlated with SSDs.'
        RequiresAdmin = $false
        Order         = 307
        Enabled       = $true
    }
}

function Get-OmniTrimSetting {
    <#
    .SYNOPSIS
        Reads the NTFS and ReFS delete-notification values. Returns $null when the
        FileSystem key cannot be read (non-Windows host, access denied).
    #>
    [OutputType([pscustomobject])]
    param()
    if (-not (Test-Path -LiteralPath $script:OmniTrimFileSystemKey)) { return $null }
    $props = Get-ItemProperty -LiteralPath $script:OmniTrimFileSystemKey -ErrorAction Stop
    $ntfs = $null
    $refs = $null
    if ($props.PSObject.Properties['DisableDeleteNotification']) { $ntfs = [int]$props.DisableDeleteNotification }
    if ($props.PSObject.Properties['RefsDisableDeleteNotification']) { $refs = [int]$props.RefsDisableDeleteNotification }
    return [pscustomobject]@{ Ntfs = $ntfs; Refs = $refs }
}

function Get-OmniTrimPhysicalDisk {
    <#
    .SYNOPSIS
        Returns the physical disks (FriendlyName, MediaType) or $null when the Storage
        module is unavailable.
    #>
    [OutputType([object[]])]
    param()
    if (-not (Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue)) { return $null }
    $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ FriendlyName = "$($_.FriendlyName)"; MediaType = "$($_.MediaType)" }
    })
    return , $disks
}

function Get-OmniTrimRefsVolumeCount {
    <#
    .SYNOPSIS
        Returns the number of ReFS volumes, or -1 when volumes cannot be enumerated.
    #>
    [OutputType([int])]
    param()
    if (-not (Get-Command -Name 'Get-Volume' -ErrorAction SilentlyContinue)) { return -1 }
    try {
        return @(Get-Volume -ErrorAction Stop | Where-Object { "$($_.FileSystem)" -eq 'ReFS' }).Count
    } catch { return -1 }
}

function Test-OmniTrimIsSsd {
    <#
    .SYNOPSIS
        True when a MediaType value means SSD (enum name 'SSD' or numeric value 4).
    #>
    [OutputType([bool])]
    param([AllowNull()] [AllowEmptyString()] [string] $MediaType)
    return ($MediaType -eq 'SSD' -or $MediaType -eq '4')
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the TRIM check and returns an OmniDiag.Result.
    .PARAMETER Context
        The scan context from New-OmniContext.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'TRIM' -Category 'Storage' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Delete-notification settings -------------------------------------
    $setting = $null
    try { $setting = Get-OmniTrimSetting } catch {
        $log.Debug("FileSystem key unreadable: $($_.Exception.Message)", 'TRIM')
        $setting = $null
    }
    if ($null -eq $setting) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'storage-trim-not-available' `
            -Title 'TRIM setting not available' -Severity 'Information' -Component 'Storage/TRIM' `
            -Detail 'The file-system delete-notification settings could not be read (they exist only on Windows).')
        return (Complete-OmniResult -Result $result)
    }
    if ($Context.CancellationToken.IsCancellationRequested) { return (Complete-OmniResult -Result $result) }

    $ntfsDisabled = ($null -ne $setting.Ntfs -and $setting.Ntfs -ne 0)
    $refsState = if ($null -eq $setting.Refs) { 'NotSet' } elseif ($setting.Refs -ne 0) { 'Disabled' } else { 'Enabled' }
    Set-OmniResultMetric -Result $result -Name 'NtfsDeleteNotification' -Value $(if ($ntfsDisabled) { 'Disabled' } else { 'Enabled' })
    Set-OmniResultMetric -Result $result -Name 'RefsDeleteNotification' -Value $refsState

    # --- SSDs and ReFS volumes --------------------------------------------
    $disks = $null
    try { $disks = Get-OmniTrimPhysicalDisk } catch {
        $log.Debug("Get-PhysicalDisk failed: $($_.Exception.Message)", 'TRIM')
        $disks = $null
    }
    $ssdKnown = ($null -ne $disks)
    $ssds = @()
    if ($ssdKnown) {
        $ssds = @($disks | Where-Object { Test-OmniTrimIsSsd -MediaType $_.MediaType })
        Set-OmniResultMetric -Result $result -Name 'PhysicalDiskCount' -Value @($disks).Count
        Set-OmniResultMetric -Result $result -Name 'SsdCount' -Value $ssds.Count
    }
    $refsVolumes = Get-OmniTrimRefsVolumeCount
    if ($refsVolumes -ge 0) { Set-OmniResultMetric -Result $result -Name 'RefsVolumeCount' -Value $refsVolumes }

    $ssdNames = ($ssds | Select-Object -First 5 | ForEach-Object { $_.FriendlyName }) -join '; '
    $mediaNote = if (-not $ssdKnown) { ' The drive media type could not be read, so it is not known whether an SSD is present.' }
    elseif ($ssds.Count -eq 0) { ' No SSD was detected, so this has no effect on drive wear or performance.' }
    else { " SSD(s) present: $ssdNames." }
    $howTo = 'From an elevated prompt run "fsutil behavior set DisableDeleteNotify {0} 0" (no restart needed), unless TRIM was turned off on purpose (for example a storage vendor or SAN recommendation).'

    # --- NTFS -------------------------------------------------------------
    if ($ntfsDisabled) {
        $sev = if ($ssdKnown -and $ssds.Count -gt 0) { 'Warning' } else { 'Information' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'storage-trim-ntfs-disabled' `
            -Title 'TRIM is disabled for NTFS' -Severity $sev -Component 'Storage/TRIM' `
            -Detail ("DisableDeleteNotification is {0}: NTFS does not send delete notifications (TRIM) to the drives.{1}" -f $setting.Ntfs, $mediaNote) `
            -LikelyCause 'TRIM was turned off manually, by a tuning tool, or for a storage device that mishandles it.' -Confidence 85 `
            -Recommendation ($howTo -f 'NTFS') `
            -Data @{ DisableDeleteNotification = $setting.Ntfs; SsdCount = $ssds.Count; SsdKnown = $ssdKnown })
    }

    # --- ReFS -------------------------------------------------------------
    if ($refsState -eq 'Disabled') {
        $sev = if ($ssdKnown -and $ssds.Count -gt 0 -and $refsVolumes -ne 0) { 'Warning' } else { 'Information' }
        $volNote = if ($refsVolumes -eq 0) { ' No ReFS volume is present, so the setting has no effect today.' } else { '' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'storage-trim-refs-disabled' `
            -Title 'TRIM is disabled for ReFS' -Severity $sev -Component 'Storage/TRIM' `
            -Detail ("RefsDisableDeleteNotification is {0}: ReFS does not send delete notifications (TRIM) to the drives.{1}{2}" -f $setting.Refs, $volNote, $mediaNote) `
            -LikelyCause 'TRIM was turned off for ReFS manually or on a storage vendor recommendation.' -Confidence 75 `
            -Recommendation ($howTo -f 'ReFS') `
            -Data @{ RefsDisableDeleteNotification = $setting.Refs; RefsVolumeCount = $refsVolumes; SsdCount = $ssds.Count })
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0 -and -not $ntfsDisabled) {
        $refsText = switch ($refsState) {
            'Enabled' { 'enabled' }
            'Disabled' { 'disabled' }
            default { 'not set (the ReFS default applies)' }
        }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'storage-trim-enabled' `
            -Title 'TRIM is enabled' -Severity 'Pass' -Component 'Storage/TRIM' `
            -Detail ("NTFS delete notifications are enabled; ReFS is {0}.{1}" -f $refsText, $mediaNote))
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
