<#
.SYNOPSIS
    OmniDiag diagnostic module: System.

.DESCRIPTION
    The system group's health-check scanner (the System Information scanner holds the
    inventory). It answers "is this operating system and platform in a supported,
    healthy state?":

      - Operating system support status: full version (10.0.<build>.<UBR>), release,
        edition, and whether that release is still serviced, from the documented
        CurrentVersion registry values and the end-of-servicing table below.
      - Architecture (x64 / ARM64) against the OmniDiag support matrix.
      - Uptime (last boot): Information below 30 days, Warning at 30 days or more.
      - TPM (Win32_Tpm; requires elevation) and Secure Boot (Confirm-SecureBootUEFI;
        requires elevation, not supported on legacy BIOS).

    Pending reboot is reported by the System Health scanner (updates group) and is not
    repeated here. Read-only; local registry and CIM only; no network. Results never
    depend on the OS display language (registry values, numeric build, CIM properties,
    and exception types only).

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command -Name 'Get-OmniSystemInventory' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\SystemInventory.psm1') -Global -Force -DisableNameChecking
}

# ---------------------------------------------------------------------------
# Windows release servicing table (data). Dates are the last day a release receives
# updates (the final Patch Tuesday, ISO 8601). Update this table when Microsoft
# publishes a new release. Sources (checked 2026-10-18):
#   https://learn.microsoft.com/windows/release-health/windows11-release-information
#   https://learn.microsoft.com/lifecycle/products/windows-11-home-and-pro
#   https://learn.microsoft.com/lifecycle/products/windows-11-enterprise-and-education
#   https://learn.microsoft.com/windows/release-health/release-information  (Windows 10)
#   https://learn.microsoft.com/lifecycle/products/windows-10-home-and-pro
# HomePro   = Home, Pro, Pro Education, Pro for Workstations (24 months).
# Enterprise = Enterprise, Education, IoT Enterprise, Enterprise multi-session (36 months).
# ---------------------------------------------------------------------------
$script:OmniWindowsEndOfSupport = '2025-10-14'   # Windows 10 (22H2 is the final release)

$script:OmniWindowsReleases = @(
    @{ Build = 19045; Family = 'Windows 10'; Release = '22H2'; HomePro = '2025-10-14'; Enterprise = '2025-10-14' }
    @{ Build = 22000; Family = 'Windows 11'; Release = '21H2'; HomePro = '2023-10-10'; Enterprise = '2024-10-08' }
    @{ Build = 22621; Family = 'Windows 11'; Release = '22H2'; HomePro = '2024-10-08'; Enterprise = '2025-10-14' }
    @{ Build = 22631; Family = 'Windows 11'; Release = '23H2'; HomePro = '2025-11-11'; Enterprise = '2026-11-10' }
    @{ Build = 26100; Family = 'Windows 11'; Release = '24H2'; HomePro = '2026-10-13'; Enterprise = '2027-10-12' }
    @{ Build = 26200; Family = 'Windows 11'; Release = '25H2'; HomePro = '2027-10-12'; Enterprise = '2028-10-10' }
    @{ Build = 26300; Family = 'Windows 11'; Release = '26H2'; HomePro = '2028-10-10'; Enterprise = '2029-10-09' }
    @{ Build = 28000; Family = 'Windows 11'; Release = '26H1'; HomePro = '2028-03-14'; Enterprise = '2029-03-13' }
)

# Long-Term Servicing Channel releases (EditionID EnterpriseS / IoTEnterpriseS). Standard
# = Enterprise LTSC/LTSB end of updates; IoT = IoT Enterprise LTSC extended end.
$script:OmniWindowsLtscReleases = @(
    @{ Build = 14393; Release = 'LTSB 2016'; Standard = '2026-10-13'; IoT = '2026-10-13' }
    @{ Build = 17763; Release = 'LTSC 2019'; Standard = '2029-01-09'; IoT = '2029-01-09' }
    @{ Build = 19044; Release = 'LTSC 2021'; Standard = '2027-01-12'; IoT = '2032-01-13' }
    @{ Build = 26100; Release = 'LTSC 2024'; Standard = '2029-10-09'; IoT = '2034-10-10' }
)

# EditionID -> servicing class. Anything not listed is 'Unknown' (no support verdict).
$script:OmniEditionClass = @{
    Core = 'HomePro'; CoreN = 'HomePro'; CoreSingleLanguage = 'HomePro'; CoreCountrySpecific = 'HomePro'
    Professional = 'HomePro'; ProfessionalN = 'HomePro'
    ProfessionalEducation = 'HomePro'; ProfessionalEducationN = 'HomePro'
    ProfessionalWorkstation = 'HomePro'; ProfessionalWorkstationN = 'HomePro'
    Enterprise = 'Enterprise'; EnterpriseN = 'Enterprise'; Education = 'Enterprise'; EducationN = 'Enterprise'
    IoTEnterprise = 'Enterprise'; ServerRdsh = 'Enterprise'
    EnterpriseS = 'Ltsc'; EnterpriseSN = 'Ltsc'; IoTEnterpriseS = 'LtscIoT'
}

# Uptime: Information below 30 days, Warning at 30 days or more (14 flagged too many
# machines that simply follow a monthly patch-and-restart cycle).
$script:OmniUptimeWarningDays = 30
$script:OmniEndOfServicingSoonDays = 90

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'System'
        Id            = 'system.system'
        Group         = 'system'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Operating system support status, architecture, uptime, TPM, and Secure Boot health checks.'
        RequiresAdmin = $false
        Order         = 100
        Enabled       = $true
    }
}

# ---------------------------------------------------------------------------
# Private data-access helpers (seams for Pester mocks)
# ---------------------------------------------------------------------------

function Test-OmniSysWindowsHost {
    <# .SYNOPSIS Internal: $true on Windows (Windows PowerShell 5.1 is always Windows). #>
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmniSysToday {
    <# .SYNOPSIS Internal: today's date (seam so tests can pin the servicing verdict). #>
    [OutputType([datetime])]
    param()
    return (Get-Date).Date
}

function Get-OmniSysOsVersionInfo {
    <#
    .SYNOPSIS
        Internal: documented version values from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion.
        Returns a hashtable (missing values are $null). Throws when the key cannot be read.
    #>
    [OutputType([hashtable])]
    param()
    $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $info = @{}
    foreach ($name in @('CurrentBuild', 'CurrentBuildNumber', 'UBR', 'DisplayVersion', 'ReleaseId', 'EditionID',
            'ProductName', 'InstallationType', 'CurrentMajorVersionNumber', 'CurrentMinorVersionNumber')) {
        $prop = $p.PSObject.Properties[$name]
        $info[$name] = if ($prop) { $prop.Value } else { $null }
    }
    return $info
}

function Get-OmniSysTpm {
    <#
    .SYNOPSIS
        Internal: the Win32_Tpm instance (root/cimv2/Security/MicrosoftTpm), or $null when
        there is none. Throws on access denied / provider errors. Call only when elevated.
    #>
    param()
    return (Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop |
        Select-Object -First 1)
}

function Get-OmniSysSecureBootState {
    <#
    .SYNOPSIS
        Internal: Secure Boot state from Confirm-SecureBootUEFI, as one of
        'Enabled', 'Disabled', 'LegacyBios', 'RequiresElevation', 'Unavailable'.

    .DESCRIPTION
        Confirm-SecureBootUEFI returns $true / $false on UEFI computers, fails with
        "Cmdlet not supported on this platform" on BIOS (non-UEFI) computers, and with
        "Access was denied" when not elevated. The failure is classified by exception
        type / FullyQualifiedErrorId, never by the (localized) message text.
    #>
    [OutputType([string])]
    param()
    if (-not (Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue)) { return 'Unavailable' }
    try {
        $on = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($on) { return 'Enabled' }
        return 'Disabled'
    } catch {
        return (ConvertTo-OmniSysSecureBootFailure -ErrorRecord $_)
    }
}

function ConvertTo-OmniSysSecureBootFailure {
    <# .SYNOPSIS Internal: classify a Confirm-SecureBootUEFI error record (language-independent). #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $ErrorRecord)
    $ex = $null; $fqid = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
        $fqid = [string]$ErrorRecord.FullyQualifiedErrorId
    } elseif ($ErrorRecord -is [System.Exception]) {
        $ex = $ErrorRecord
    }
    while ($ex) {
        if ($ex -is [System.PlatformNotSupportedException]) { return 'LegacyBios' }
        if ($ex -is [System.UnauthorizedAccessException]) { return 'RequiresElevation' }
        $ex = $ex.InnerException
    }
    if ($fqid -match 'PlatformNotSupported') { return 'LegacyBios' }
    if ($fqid -match 'UnauthorizedAccess') { return 'RequiresElevation' }
    return 'Unavailable'
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

function ConvertTo-OmniSysArchitecture {
    <#
    .SYNOPSIS
        Internal: Win32_Processor.Architecture (0 x86, 5 ARM, 6 ia64, 9 x64, 12 ARM64) to a
        name; falls back to the given contract value / PROCESSOR_ARCHITECTURE string.
    #>
    [OutputType([string])]
    param([AllowNull()] [object] $CimArchitecture, [AllowNull()] [string] $Fallback)
    if ($null -ne $CimArchitecture -and "$CimArchitecture" -ne '') {
        switch ([int]$CimArchitecture) {
            0  { return 'x86' }
            5  { return 'ARM' }
            6  { return 'ia64' }
            9  { return 'x64' }
            12 { return 'ARM64' }
        }
    }
    switch -Regex ([string]$Fallback) {
        '^(?i)(x64|amd64)$' { return 'x64' }
        '^(?i)arm64$'       { return 'ARM64' }
        '^(?i)x86$'         { return 'x86' }
    }
    if ($Fallback) { return $Fallback }
    return 'Unknown'
}

function Get-OmniSysOsSupport {
    <#
    .SYNOPSIS
        Internal: derive the OS identity and servicing verdict from CurrentVersion values.

    .OUTPUTS
        pscustomobject: Build, Ubr, Version, Family, Release, EditionId, ProductName,
        ServicingClass, EndDate ([datetime] or $null), Verdict
        ('Supported' | 'EndingSoon' | 'Unsupported' | 'Windows10Final' | 'Unknown' | 'Server'),
        and Reason (for Unknown).
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [hashtable] $Info, [Parameter(Mandatory)] [datetime] $Today)

    $buildText = if ($Info['CurrentBuild']) { [string]$Info['CurrentBuild'] } else { [string]$Info['CurrentBuildNumber'] }
    $build = 0
    [void][int]::TryParse($buildText, [ref]$build)
    $ubr = 0
    if ($null -ne $Info['UBR']) { try { $ubr = [int]$Info['UBR'] } catch { $ubr = 0 } }
    $major = if ($null -ne $Info['CurrentMajorVersionNumber']) { [int]$Info['CurrentMajorVersionNumber'] } else { 10 }
    $minor = if ($null -ne $Info['CurrentMinorVersionNumber']) { [int]$Info['CurrentMinorVersionNumber'] } else { 0 }

    $family = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $release = if ($Info['DisplayVersion']) { [string]$Info['DisplayVersion'] } elseif ($Info['ReleaseId']) { [string]$Info['ReleaseId'] } else { '' }
    $edition = [string]$Info['EditionID']
    # ProductName still says "Windows 10" on Windows 11; derive the family from the build.
    $product = [string]$Info['ProductName']
    if ($family -eq 'Windows 11' -and $product -match 'Windows 10') { $product = $product -replace 'Windows 10', 'Windows 11' }
    if (-not $product) { $product = $family }

    $class = if ($edition -and $script:OmniEditionClass.ContainsKey($edition)) { $script:OmniEditionClass[$edition] } else { 'Unknown' }

    $out = [ordered]@{
        Build = $build; Ubr = $ubr; Version = ('{0}.{1}.{2}.{3}' -f $major, $minor, $build, $ubr)
        Family = $family; Release = $release; EditionId = $edition; ProductName = $product
        ServicingClass = $class; EndDate = $null; Verdict = 'Unknown'; Reason = ''
    }

    if (([string]$Info['InstallationType'] -match '^Server') -or (($edition -match '^Server') -and ($edition -ne 'ServerRdsh'))) {
        $out.Verdict = 'Server'; $out.Reason = 'Windows Server is outside the OmniDiag support matrix.'
        return [pscustomobject]$out
    }
    if ($build -le 0) {
        $out.Reason = 'The build number could not be read.'
        return [pscustomobject]$out
    }

    $end = $null
    if ($class -in @('Ltsc', 'LtscIoT')) {
        $row = $script:OmniWindowsLtscReleases | Where-Object { $_.Build -eq $build } | Select-Object -First 1
        if ($row) {
            $end = if ($class -eq 'LtscIoT') { $row.IoT } else { $row.Standard }
            $out.Release = $row.Release
        } else {
            $out.Reason = "LTSC build $build is not in the servicing table."
            return [pscustomobject]$out
        }
    } elseif ($family -eq 'Windows 10' -and $build -lt 19045) {
        $out.Verdict = 'Unsupported'
        return [pscustomobject]$out
    } else {
        $row = $script:OmniWindowsReleases | Where-Object { $_.Build -eq $build } | Select-Object -First 1
        if (-not $row) {
            $out.Reason = "Build $build is not in the servicing table (newer or pre-release build)."
            return [pscustomobject]$out
        }
        if ($family -eq 'Windows 10') {
            # 22H2: the final Windows 10 release; end of support for every non-LTSC edition.
            $out.EndDate = [datetime]::ParseExact($row.HomePro, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $out.Verdict = 'Windows10Final'
            return [pscustomobject]$out
        }
        if ($class -eq 'Unknown') {
            $out.Reason = "Edition '$edition' is not in the servicing table."
            return [pscustomobject]$out
        }
        $end = $row[$class]
    }

    $endDate = [datetime]::ParseExact($end, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $out.EndDate = $endDate
    if ($Today -gt $endDate) { $out.Verdict = 'Unsupported' }
    elseif (($endDate - $Today).TotalDays -le $script:OmniEndOfServicingSoonDays) { $out.Verdict = 'EndingSoon' }
    else { $out.Verdict = 'Supported' }
    return [pscustomobject]$out
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'System' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cancelled = { [bool]($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested) }

    if (-not (Test-OmniSysWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.windows-only' `
            -Title 'System health checks are Windows-only' -Severity 'Information' -Component 'System' `
            -Detail 'This scanner reads the Windows version registry, CIM, TPM, and Secure Boot state; none is available on this host.')
        return (Complete-OmniResult -Result $result)
    }

    $inv = Get-OmniSystemInventory -Section OperatingSystem, Processor
    foreach ($e in @($inv.Errors)) { if ($log) { $log.Warn("CIM query failed: $e", 'System') } }

    # --- Operating system support status ----------------------------------
    $os = $null
    try {
        $os = Get-OmniSysOsSupport -Info (Get-OmniSysOsVersionInfo) -Today (Get-OmniSysToday)
    } catch {
        if ($log) { $log.Warn("OS version registry read failed: $($_.Exception.Message)", 'System') }
    }
    if ($os) {
        Set-OmniResultMetric -Result $result -Name 'OSVersion'      -Value $os.Version
        Set-OmniResultMetric -Result $result -Name 'OSBuildNumber'  -Value $os.Build
        Set-OmniResultMetric -Result $result -Name 'OSUBR'          -Value $os.Ubr
        Set-OmniResultMetric -Result $result -Name 'OSFamily'       -Value $os.Family
        Set-OmniResultMetric -Result $result -Name 'OSRelease'      -Value $os.Release
        Set-OmniResultMetric -Result $result -Name 'OSEdition'      -Value $os.EditionId
        Set-OmniResultMetric -Result $result -Name 'OSProductName'  -Value $os.ProductName
        Set-OmniResultMetric -Result $result -Name 'OSSupportStatus' -Value $os.Verdict
        if ($os.EndDate) { Set-OmniResultMetric -Result $result -Name 'OSEndOfServicing' -Value $os.EndDate.ToString('yyyy-MM-dd') }

        $label = ("{0} {1} ({2})" -f $os.ProductName, $os.Release, $os.Version) -replace '\s+', ' '
        $endText = if ($os.EndDate) { $os.EndDate.ToString('yyyy-MM-dd') } else { '' }
        switch ($os.Verdict) {
            'Unsupported' {
                $detail = if ($endText) { "$label stopped receiving security updates after $endText." } else { "$label is a release that no longer receives security updates." }
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-unsupported-release' `
                    -Title 'Unsupported Windows release, upgrade required' -Severity 'Warning' -Component 'System/OperatingSystem' `
                    -Detail $detail `
                    -LikelyCause 'The device was not moved to a newer feature update before its release reached end of servicing.' `
                    -Confidence 90 `
                    -Recommendation 'Upgrade to a serviced Windows 11 release (or Windows 10 22H2 with Extended Security Updates as a stop-gap) and confirm feature-update policy.' `
                    -Data @{ Build = $os.Build; Release = $os.Release; Edition = $os.EditionId; EndOfServicing = $endText })
            }
            'Windows10Final' {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-windows10-end-of-support' `
                    -Title 'Windows 10 has reached end of support' -Severity 'Information' -Component 'System/OperatingSystem' `
                    -Detail "$label is the final Windows 10 release. Windows 10 reached end of support on $($script:OmniWindowsEndOfSupport); only devices enrolled in Extended Security Updates (ESU) still receive security updates. ESU enrollment cannot be determined offline." `
                    -Confidence 90 `
                    -Recommendation 'Confirm the device is enrolled in Windows 10 ESU, and plan the upgrade to Windows 11.' `
                    -Data @{ Build = $os.Build; Release = $os.Release; Edition = $os.EditionId; EndOfSupport = $script:OmniWindowsEndOfSupport })
            }
            'EndingSoon' {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-end-of-servicing-soon' `
                    -Title 'Windows release reaches end of servicing soon' -Severity 'Information' -Component 'System/OperatingSystem' `
                    -Detail "$label receives updates until $endText." `
                    -Recommendation 'Schedule the feature update to a newer Windows 11 release before that date.' `
                    -Data @{ Build = $os.Build; Release = $os.Release; Edition = $os.EditionId; EndOfServicing = $endText })
            }
            'Supported' {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-supported-release' `
                    -Title 'Windows release is in support' -Severity 'Pass' -Component 'System/OperatingSystem' `
                    -Detail "$label receives updates until $endText.")
            }
            default {
                $why = if ($os.Reason) { $os.Reason } else { 'The release could not be matched to the servicing table.' }
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-support-unknown' `
                    -Title 'Windows support status could not be determined' -Severity 'Information' -Component 'System/OperatingSystem' `
                    -Detail "$label. $why" `
                    -Recommendation 'Check the release against Microsoft Windows release health (learn.microsoft.com/windows/release-health).')
            }
        }
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.os-version-unavailable' `
            -Title 'Windows version could not be read' -Severity 'Information' -Component 'System/OperatingSystem' `
            -Detail 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion could not be read, so the support status is unknown.')
    }

    # --- Architecture -------------------------------------------------------
    $cpuArch = if ($inv.Processor) { $inv.Processor.Architecture } else { $null }
    $ctxArch = $null
    $archProp = $Context.PSObject.Properties['Architecture']
    if ($archProp) { $ctxArch = [string]$archProp.Value }
    if (-not $ctxArch) { $ctxArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
    $arch = ConvertTo-OmniSysArchitecture -CimArchitecture $cpuArch -Fallback $ctxArch
    Set-OmniResultMetric -Result $result -Name 'Architecture' -Value $arch
    $family = if ($os) { $os.Family } else { '' }
    $inMatrix = ($arch -eq 'x64') -or ($arch -eq 'ARM64' -and $family -ne 'Windows 10')
    if (-not $inMatrix) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.platform-outside-support-matrix' `
            -Title 'Platform is outside the OmniDiag support matrix' -Severity 'Information' -Component 'System/Platform' `
            -Detail "Architecture '$arch' on '$family'. OmniDiag supports Windows 10 22H2 x64 and Windows 11 x64 / ARM64; results on this platform are best effort.")
    }

    # --- Uptime ---------------------------------------------------------------
    $boot = if ($inv.OperatingSystem) { $inv.OperatingSystem.LastBootUpTime } else { $null }
    if ($boot) {
        try {
            $bootTime = [datetime]$boot
            Set-OmniResultMetric -Result $result -Name 'LastBootUpTime' -Value $bootTime
            $uptime = (Get-Date) - $bootTime
            Set-OmniResultMetric -Result $result -Name 'UptimeDays' -Value ([math]::Round($uptime.TotalDays, 1))
            $days = [math]::Floor($uptime.TotalDays)
            if ($uptime.TotalDays -ge $script:OmniUptimeWarningDays) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.uptime-long' `
                    -Title ("System uptime is {0:N0} days" -f $days) -Severity 'Warning' `
                    -Component 'System/Uptime' `
                    -Detail "The system has not been restarted in $($script:OmniUptimeWarningDays) days or more (last boot $($bootTime.ToString('yyyy-MM-dd HH:mm')))." `
                    -LikelyCause 'Long uptime can defer pending updates and accumulate memory pressure.' `
                    -Confidence 60 `
                    -Recommendation 'Restart the device to apply pending updates and clear transient issues.')
            } else {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.uptime' `
                    -Title ("System uptime is {0:N0} days" -f $days) -Severity 'Information' `
                    -Component 'System/Uptime' `
                    -Detail "Last boot $($bootTime.ToString('yyyy-MM-dd HH:mm')). Uptime becomes a Warning at $($script:OmniUptimeWarningDays) days.")
            }
        } catch {
            if ($log) { $log.Debug("Uptime calculation failed: $($_.Exception.Message)", 'System') }
        }
    }

    if (& $cancelled) { return (Complete-OmniResult -Result $result) }

    # --- TPM ------------------------------------------------------------------
    if (-not $Context.IsAdmin) {
        Set-OmniResultMetric -Result $result -Name 'TPMStatus' -Value 'RequiresElevation'
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-requires-elevation' `
            -Title 'TPM details require elevation' -Severity 'Information' -Component 'System/Security/TPM' `
            -Detail 'The TPM WMI provider (Win32_Tpm) is readable only by administrators, so TPM presence, version, and state were not checked (requires elevation).' `
            -Recommendation 'Re-run OmniDiag as an administrator to check the TPM.')
    } else {
        $tpm = $null; $tpmError = $null
        try { $tpm = Get-OmniSysTpm } catch { $tpmError = $_.Exception.Message }
        if ($tpmError) {
            Set-OmniResultMetric -Result $result -Name 'TPMStatus' -Value 'Unavailable'
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-unavailable' `
                -Title 'TPM state could not be read' -Severity 'Information' -Component 'System/Security/TPM' `
                -Detail "Win32_Tpm query failed: $tpmError" `
                -Recommendation 'Open tpm.msc to check the TPM, or review the TPM-WMI event log.')
        } elseif (-not $tpm) {
            Set-OmniResultMetric -Result $result -Name 'TPMStatus' -Value 'NotFound'
            Set-OmniResultMetric -Result $result -Name 'TPMPresent' -Value $false
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-not-found' `
                -Title 'No TPM detected' -Severity 'Warning' -Component 'System/Security/TPM' `
                -Detail 'Win32_Tpm returned no TPM on this device.' `
                -LikelyCause 'The TPM is disabled in firmware or not present.' -Confidence 75 `
                -Recommendation 'A TPM 2.0 is required for Windows 11 and recommended for BitLocker. Enable the TPM (PTT / fTPM) in UEFI settings.')
        } else {
            $spec = [string]$tpm.SpecVersion
            $specMajor = ($spec -split ',')[0].Trim()
            $enabled = [bool]$tpm.IsEnabled_InitialValue
            $activated = [bool]$tpm.IsActivated_InitialValue
            Set-OmniResultMetric -Result $result -Name 'TPMStatus'    -Value 'Present'
            Set-OmniResultMetric -Result $result -Name 'TPMPresent'   -Value $true
            Set-OmniResultMetric -Result $result -Name 'TPMVersion'   -Value $specMajor
            Set-OmniResultMetric -Result $result -Name 'TPMEnabled'   -Value $enabled
            Set-OmniResultMetric -Result $result -Name 'TPMActivated' -Value $activated
            $ver = $null
            [void][version]::TryParse($specMajor, [ref]$ver)
            if (-not $enabled -or -not $activated) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-disabled' `
                    -Title 'TPM is present but not enabled' -Severity 'Warning' -Component 'System/Security/TPM' `
                    -Detail "TPM $specMajor reports enabled=$enabled, activated=$activated." `
                    -LikelyCause 'The TPM is turned off or not activated in firmware.' -Confidence 80 `
                    -Recommendation 'Enable and activate the TPM in UEFI settings, then check tpm.msc.')
            } elseif ($ver -and $ver.Major -lt 2) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-version-below-2' `
                    -Title 'TPM version is below 2.0' -Severity 'Warning' -Component 'System/Security/TPM' `
                    -Detail "The TPM implements specification $specMajor." `
                    -LikelyCause 'Older hardware, or firmware set to TPM 1.2 mode.' -Confidence 80 `
                    -Recommendation 'Windows 11 requires TPM 2.0. Check for a firmware option to switch the TPM to 2.0, or plan a hardware refresh.')
            } else {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.tpm-ready' `
                    -Title 'TPM is present and enabled' -Severity 'Pass' -Component 'System/Security/TPM' `
                    -Detail "TPM $specMajor is enabled and activated.")
            }
        }
    }

    if (& $cancelled) { return (Complete-OmniResult -Result $result) }

    # --- Secure Boot ----------------------------------------------------------
    $sb = Get-OmniSysSecureBootState
    Set-OmniResultMetric -Result $result -Name 'SecureBoot' -Value $sb
    switch ($sb) {
        'Enabled' {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.secure-boot-enabled' `
                -Title 'Secure Boot is enabled' -Severity 'Pass' -Component 'System/Security/SecureBoot' `
                -Detail 'The device boots in UEFI mode with Secure Boot on.')
        }
        'Disabled' {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.secure-boot-disabled' `
                -Title 'Secure Boot is disabled' -Severity 'Warning' -Component 'System/Security/SecureBoot' `
                -Detail 'The device boots in UEFI mode and supports Secure Boot, but it is turned off.' `
                -LikelyCause 'Disabled in UEFI firmware settings.' -Confidence 85 `
                -Recommendation 'Enable Secure Boot in UEFI settings for boot integrity (a Windows 11 requirement).')
        }
        'LegacyBios' {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.secure-boot-legacy-bios' `
                -Title 'Device boots in legacy BIOS mode' -Severity 'Warning' -Component 'System/Security/SecureBoot' `
                -Detail 'Secure Boot is not supported on this platform: the device boots in legacy BIOS (CSM) mode or the firmware has no Secure Boot.' `
                -LikelyCause 'The system disk uses MBR partitioning or the firmware is set to legacy/CSM boot.' -Confidence 80 `
                -Recommendation 'Windows 11 requires UEFI with Secure Boot capability. Convert the system disk to GPT (mbr2gpt) and switch the firmware to UEFI, following your change process.')
        }
        'RequiresElevation' {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.secure-boot-requires-elevation' `
                -Title 'Secure Boot state requires elevation' -Severity 'Information' -Component 'System/Security/SecureBoot' `
                -Detail 'Confirm-SecureBootUEFI was denied access, so the Secure Boot state was not checked (requires elevation).' `
                -Recommendation 'Re-run OmniDiag as an administrator to check Secure Boot.')
        }
        default {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system.secure-boot-unavailable' `
                -Title 'Secure Boot state is not available' -Severity 'Information' -Component 'System/Security/SecureBoot' `
                -Detail 'The Secure Boot state could not be read on this host (Confirm-SecureBootUEFI is missing or failed).')
        }
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
