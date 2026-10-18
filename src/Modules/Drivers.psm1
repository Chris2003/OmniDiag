<#
.SYNOPSIS
    OmniDiag diagnostic module: Drivers.

.DESCRIPTION
    Driver inventory and health:
      - Win32_PnPSignedDriver: driver count, unsigned drivers (IsSigned = False), and
        third-party drivers (provider not Microsoft) with the top providers.
      - Win32_SystemDriver: running kernel/file-system drivers whose image is outside
        %SystemRoot%\System32\drivers and the driver store.
      - Win32_PnPEntity: one finding per device with a Device Manager error
        (ConfigManagerErrorCode), with the meaning of the code and a recommendation.

    Read-only and local-only. File signatures are NOT re-verified (no
    Get-AuthenticodeSignature): IsSigned comes from the driver store metadata.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

# Device Manager error codes (CM_PROB_*): meaning, severity, recommendation.
$script:DeviceErrorCode = @{
    1  = @{ Meaning = 'The device is not configured correctly.'; Severity = 'Warning'; Recommendation = 'Update the driver from the device vendor or Windows Update.' }
    3  = @{ Meaning = 'The driver may be corrupted, or the system is low on memory or other resources.'; Severity = 'Warning'; Recommendation = 'Close applications, then uninstall and reinstall the driver.' }
    10 = @{ Meaning = 'The device cannot start.'; Severity = 'Warning'; Recommendation = 'Update the driver; if that fails, uninstall the device and scan for hardware changes.' }
    12 = @{ Meaning = 'The device cannot find enough free resources (resource conflict).'; Severity = 'Warning'; Recommendation = 'Disable a conflicting device or reset the firmware (BIOS/UEFI) configuration.' }
    18 = @{ Meaning = 'The drivers for this device must be reinstalled.'; Severity = 'Warning'; Recommendation = 'Reinstall the driver from Device Manager (Update driver).' }
    22 = @{ Meaning = 'The device is disabled.'; Severity = 'Information'; Recommendation = 'Enable the device in Device Manager if it is needed; otherwise no action.' }
    24 = @{ Meaning = 'The device is not present, not working properly, or does not have all its drivers installed.'; Severity = 'Warning'; Recommendation = 'Check the connection and install the vendor driver; remove the device if it was taken out.' }
    28 = @{ Meaning = 'The drivers for this device are not installed.'; Severity = 'Warning'; Recommendation = 'Install the driver from the device vendor or Windows Update.' }
    31 = @{ Meaning = 'Windows cannot load the drivers required for this device.'; Severity = 'Warning'; Recommendation = 'Update or reinstall the driver; check for a newer vendor driver.' }
    39 = @{ Meaning = 'Windows cannot load the device driver (it may be corrupted or missing).'; Severity = 'Error'; Recommendation = 'Uninstall the device and the driver, then reinstall the latest vendor driver.' }
    43 = @{ Meaning = 'Windows stopped this device because it reported problems.'; Severity = 'Error'; Recommendation = 'Reconnect or power-cycle the device; update the driver and firmware; replace the hardware if it persists.' }
    45 = @{ Meaning = 'The device is not currently connected to the computer.'; Severity = 'Information'; Recommendation = 'Reconnect the device if it is needed; otherwise no action.' }
    52 = @{ Meaning = 'Windows cannot verify the digital signature for the drivers.'; Severity = 'Error'; Recommendation = 'Install a signed driver from the vendor; check that Secure Boot or driver signature policy is not blocking it legitimately.' }
}

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Drivers scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Drivers'
        Id            = 'services.drivers'
        Group         = 'services'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Driver inventory, unsigned and third-party drivers, and problem devices with the Device Manager error meaning.'
        RequiresAdmin = $false
        Order         = 140
        Enabled       = $true
    }
}

function Get-OmniDriverCim {
    <#
    .SYNOPSIS
        Returns the instances of one CIM class (private; mocked in tests). Throws when unavailable.
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $ClassName)
    return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
}

function Get-OmniDriverSystemRoot {
    <#
    .SYNOPSIS
        Returns %SystemRoot% (C:\Windows when the variable is not set) (private).
    #>
    [OutputType([string])]
    param()
    $r = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($r)) { $r = 'C:\Windows' }
    return $r.TrimEnd('\')
}

function Get-OmniDriverValue {
    <#
    .SYNOPSIS
        Reads a property that may be absent (private).
    #>
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-OmniDriverImagePath {
    <#
    .SYNOPSIS
        Normalizes a driver image path (\SystemRoot\..., \??\C:\..., system32\...) to a full path (private).
    #>
    [OutputType([string])]
    param([string] $Path, [string] $SystemRoot)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '^\\\?\?\\') { $p = $p.Substring(4) }
    if ($p -match '^(?i)\\SystemRoot\\') { $p = $SystemRoot + $p.Substring(11) }
    elseif ($p -match '^(?i)system32\\') { $p = $SystemRoot + '\' + $p }
    return $p
}

function ConvertTo-OmniDriverKey {
    <#
    .SYNOPSIS
        Kebab-cases a device id for a stable finding id (private).
    #>
    param([string] $Text)
    $k = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($k.Length -gt 80) { $k = $k.Substring(0, 80).Trim('-') }
    if (-not $k) { $k = 'unknown' }
    return $k
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the Drivers scan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Drivers' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $available = 0

    # --- PnP signed drivers: count, unsigned, third-party -------------------
    try {
        $drivers = @(Get-OmniDriverCim -ClassName 'Win32_PnPSignedDriver')
        $available++
        Set-OmniResultMetric -Result $result -Name 'DriverCount' -Value $drivers.Count

        $unsigned = @($drivers | Where-Object { $v = Get-OmniDriverValue $_ 'IsSigned'; $null -ne $v -and -not [bool]$v })
        Set-OmniResultMetric -Result $result -Name 'UnsignedDriverCount' -Value $unsigned.Count
        if ($unsigned.Count -gt 0) {
            $list = @($unsigned | Select-Object -First 20 | ForEach-Object {
                '{0} ({1} {2}, {3})' -f (Get-OmniDriverValue $_ 'DeviceName'), (Get-OmniDriverValue $_ 'DriverProviderName'),
                    (Get-OmniDriverValue $_ 'DriverVersion'), (Get-OmniDriverValue $_ 'InfName')
            })
            $data = @($unsigned | ForEach-Object {
                [pscustomobject]@{
                    DeviceName = Get-OmniDriverValue $_ 'DeviceName'; Provider = Get-OmniDriverValue $_ 'DriverProviderName'
                    Version = Get-OmniDriverValue $_ 'DriverVersion'; InfName = Get-OmniDriverValue $_ 'InfName'
                }
            })
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-unsigned' `
                -Title ("$($unsigned.Count) unsigned driver(s) installed") -Severity 'Warning' -Component 'System/Drivers' `
                -Detail ('Drivers whose package is not signed (first 20): ' + ($list -join '; ')) `
                -LikelyCause 'A driver was installed with signature enforcement disabled, in test mode, or from an untrusted package.' `
                -Confidence 75 `
                -Recommendation 'Replace these drivers with signed versions from the device vendor or Windows Update; remove drivers you do not recognize.' `
                -Data $data)
        }

        $thirdParty = @($drivers | Where-Object {
            $prov = [string](Get-OmniDriverValue $_ 'DriverProviderName')
            $prov -and $prov -notmatch '^(?i)\s*Microsoft'
        })
        Set-OmniResultMetric -Result $result -Name 'ThirdPartyDriverCount' -Value $thirdParty.Count
        if ($thirdParty.Count -gt 0) {
            $top = @($thirdParty | Group-Object -Property { [string](Get-OmniDriverValue $_ 'DriverProviderName') } |
                Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
                Select-Object -First 5)
            $topText = @($top | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }) -join '; '
            Set-OmniResultMetric -Result $result -Name 'TopDriverProviders' -Value @($top | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Count = $_.Count } })
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-third-party-summary' `
                -Title ("$($thirdParty.Count) third-party driver(s)") -Severity 'Information' -Component 'System/Drivers' `
                -Detail ("Drivers from providers other than Microsoft: $($thirdParty.Count) of $($drivers.Count). Top providers: $topText."))
        }
    } catch {
        $log.Warn("CIM query failed for Win32_PnPSignedDriver: $($_.Exception.Message)", 'Drivers')
    }

    # --- Non-PnP kernel / file-system drivers outside the driver folders ---
    try {
        $sysDrivers = @(Get-OmniDriverCim -ClassName 'Win32_SystemDriver')
        $available++
        $root = Get-OmniDriverSystemRoot
        $okPrefixes = @(($root + '\System32\drivers\'), ($root + '\System32\DriverStore\'))
        $outside = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $sysDrivers) {
            if ($Context.CancellationToken.IsCancellationRequested) { break }
            if ([string](Get-OmniDriverValue $d 'State') -ne 'Running') { continue }
            $img = ConvertTo-OmniDriverImagePath -Path ([string](Get-OmniDriverValue $d 'PathName')) -SystemRoot $root
            if (-not $img) { continue }
            $inside = $false
            foreach ($pre in $okPrefixes) { if ($img.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $inside = $true } }
            if (-not $inside) {
                $outside.Add([pscustomobject]@{ Name = [string](Get-OmniDriverValue $d 'Name'); StartMode = [string](Get-OmniDriverValue $d 'StartMode'); Path = $img })
            }
        }
        Set-OmniResultMetric -Result $result -Name 'RunningDriversOutsideDriverFolderCount' -Value $outside.Count
        if ($outside.Count -gt 0) {
            $list = @($outside | Select-Object -First 20 | ForEach-Object { '{0} [{1}] {2}' -f $_.Name, $_.StartMode, $_.Path })
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-system-driver-outside-driver-folder' `
                -Title ("$($outside.Count) running driver(s) load from outside the driver folders") -Severity 'Information' `
                -Component 'System/Drivers' `
                -Detail ("Running kernel/file-system drivers whose image is outside $root\System32\drivers and the driver store (first 20): " + ($list -join '; ')) `
                -LikelyCause 'Usually security, backup, virtualization, or anti-cheat software installing its own driver; occasionally an unwanted driver.' `
                -Confidence 40 `
                -Recommendation 'Confirm each driver belongs to software you expect on this machine.' `
                -Data @($outside))
        }
    } catch {
        $log.Warn("CIM query failed for Win32_SystemDriver: $($_.Exception.Message)", 'Drivers')
    }

    # --- Problem devices (one finding per device) ---------------------------
    try {
        $problems = @(Get-OmniDriverCim -ClassName 'Win32_PnPEntity' |
            Where-Object { $c = Get-OmniDriverValue $_ 'ConfigManagerErrorCode'; $null -ne $c -and [int]$c -ne 0 })
        $available++
        Set-OmniResultMetric -Result $result -Name 'ProblemDeviceCount' -Value $problems.Count

        $cap = 25
        foreach ($dev in @($problems | Select-Object -First $cap)) {
            $code = [int](Get-OmniDriverValue $dev 'ConfigManagerErrorCode')
            $devId = [string](Get-OmniDriverValue $dev 'DeviceID')
            $name = [string](Get-OmniDriverValue $dev 'Name')
            if (-not $name) { $name = $devId }
            $info = if ($script:DeviceErrorCode.ContainsKey($code)) { $script:DeviceErrorCode[$code] } else {
                @{ Meaning = 'Device Manager reports a problem with this device.'; Severity = 'Warning'; Recommendation = 'Open the device in Device Manager for details; update or reinstall its driver.' }
            }
            $key = if ($devId) { $devId } else { $name }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Id ('drivers-problem-device-' + (ConvertTo-OmniDriverKey $key)) `
                -Title ("Device problem: $name (code $code)") -Severity $info.Severity -Component 'System/Drivers' `
                -Detail ("Device Manager error code ${code}: $($info.Meaning) Device ID: $devId.") `
                -LikelyCause $info.Meaning -Confidence 70 -Recommendation $info.Recommendation `
                -Data ([pscustomobject]@{ Name = $name; DeviceID = $devId; ErrorCode = $code }))
        }
        if ($problems.Count -gt $cap) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-problem-device-more' `
                -Title 'More devices reporting problems' -Severity 'Warning' -Component 'System/Drivers' `
                -Detail ("$($problems.Count - $cap) more device(s) with a Device Manager error were not listed individually."))
        }
    } catch {
        $log.Warn("CIM query failed for Win32_PnPEntity: $($_.Exception.Message)", 'Drivers')
    }

    if ($available -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-inventory-unavailable' `
            -Title 'Driver inventory not available' -Severity 'Information' -Component 'System/Drivers' `
            -Detail 'Win32_PnPSignedDriver, Win32_SystemDriver, and Win32_PnPEntity could not be queried (CIM is not available on this platform or the queries failed).')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'drivers-healthy' `
            -Title 'No device problems detected' -Severity 'Pass' -Component 'System/Drivers' `
            -Detail 'Driver inventory collected; no unsigned drivers and no devices reporting errors.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
