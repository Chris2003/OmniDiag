<#
.SYNOPSIS
    OmniDiag diagnostic module: Microsoft Entra ID join posture.

.DESCRIPTION
    Default scan (local only): reads the device join state from the registry,
    HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo\<thumbprint> (TenantId)
    and ...\CloudDomainJoin\TenantInfo\<tenant id> (DisplayName). The documented API for
    this (NetGetAadJoinInformation, lmjoin.h) needs P/Invoke, which OmniDiag does not
    compile at run time; the registry location is the one Windows itself maintains for
    joined devices. The device certificate is not read.

    With connectivity probes (--network-probes / -NetworkProbes) it also runs
    `dsregcmd /status`, because that command contacts Microsoft Entra ID (the
    DeviceAuthStatus check "requires network connectivity to Microsoft Entra ID", and the
    pre-join diagnostics test domain-controller and DRS connectivity). Its output is parsed
    by the documented field names (AzureAdJoined, WorkplaceJoined, DeviceAuthStatus,
    AzureAdPrt, TenantName, ...) and the YES / NO / SUCCESS values shown in Microsoft's
    dsregcmd documentation. Microsoft does not document whether these labels are
    localized (unverified on non-English Windows), so only these labels are matched and,
    when none is found, the dsregcmd checks are not reported rather than misread.
    Without probes the scanner
    adds the standard "Connectivity probe not run" Information finding.

    It does not authenticate to Microsoft Graph, upload data, or change device registration.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Entra ID'; Id='extras.entra-id'; Group='extras'; NetworkAccess='Internet'; Category='Cloud'; Description='Microsoft Entra join and tenant from the registry; opt-in dsregcmd device-auth and PRT check.'; RequiresAdmin=$false; Order=730; Enabled=$true }
}

# dsregcmd /status fields read with probes (documented names; see the module help).
$script:OmniDsregFields = @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'WorkplaceJoined', 'DeviceId',
    'TenantId', 'TenantName', 'DeviceAuthStatus', 'AzureAdPrt')

function Test-OmniEntraWindowsHost {
    <# .SYNOPSIS Internal: $true on Windows (Windows PowerShell 5.1 is always Windows). #>
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmniEntraJoinInfo {
    <#
    .SYNOPSIS
        Internal: device join state from the CloudDomainJoin registry key.
        Returns @{ Joined = bool; TenantId = string; TenantName = string }. Throws when
        the registry cannot be read.
    #>
    [OutputType([hashtable])]
    param()
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin'
    $info = @{ Joined = $false; TenantId = ''; TenantName = '' }
    $joinKey = Join-Path $root 'JoinInfo'
    if (-not (Test-Path -LiteralPath $joinKey)) { return $info }
    foreach ($entry in @(Get-ChildItem -LiteralPath $joinKey -ErrorAction Stop)) {
        $p = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties['TenantId'] -and $p.TenantId) {
            $info.Joined = $true
            $info.TenantId = [string]$p.TenantId
            break
        }
    }
    if ($info.TenantId) {
        $tenantKey = Join-Path (Join-Path $root 'TenantInfo') $info.TenantId
        $t = Get-ItemProperty -LiteralPath $tenantKey -ErrorAction SilentlyContinue
        if ($t -and $t.PSObject.Properties['DisplayName']) { $info.TenantName = [string]$t.DisplayName }
    }
    return $info
}

function Invoke-OmniEntraDsregStatus {
    <#
    .SYNOPSIS
        Internal (connectivity probe): run `dsregcmd /status` and return its lines, or
        $null when dsregcmd is missing. Only called when probes are enabled.
    #>
    [OutputType([string[]])]
    param()
    $command = Get-Command -Name 'dsregcmd.exe' -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    return [string[]]@(& $command.Source /status 2>&1 | ForEach-Object { [string]$_ })
}

function ConvertFrom-OmniDsregStatus {
    <#
    .SYNOPSIS
        Internal: parse `dsregcmd /status` lines ("<Field> : <Value>") into a hashtable of
        the fields in $script:OmniDsregFields. Keyed on field names only.
    #>
    [OutputType([hashtable])]
    param([AllowNull()] [string[]] $Line)
    $values = @{}
    $pattern = '^\s*(' + ($script:OmniDsregFields -join '|') + ')\s*:\s*(.*?)\s*$'
    foreach ($l in @($Line)) {
        $m = [regex]::Match([string]$l, $pattern)
        if ($m.Success -and -not $values.ContainsKey($m.Groups[1].Value)) { $values[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return $values
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Entra ID' -Category 'Cloud' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    if (-not (Test-OmniEntraWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.windows-only' -Title 'Entra join status is unavailable' -Severity Information -Component 'Cloud/EntraID' -Detail 'Microsoft Entra join state is stored by Windows; this host is not Windows.')
        return (Complete-OmniResult -Result $result)
    }

    # --- Local (registry) join state ------------------------------------------
    $join = $null
    try { $join = Get-OmniEntraJoinInfo } catch {
        if ($log) { $log.Warn("Entra join registry read failed: $($_.Exception.Message)", 'Entra ID') }
    }
    $joined = $false; $tenantId = ''; $tenantName = ''
    if ($join) {
        $joined = [bool]$join.Joined; $tenantId = [string]$join.TenantId; $tenantName = [string]$join.TenantName
        Set-OmniResultMetric -Result $result -Name 'AzureAdJoined' -Value $(if ($joined) { 'YES' } else { 'NO' })
        if ($tenantId) { Set-OmniResultMetric -Result $result -Name 'TenantId' -Value $tenantId }
        if ($tenantName) { Set-OmniResultMetric -Result $result -Name 'TenantName' -Value $tenantName }
    }
    Set-OmniResultMetric -Result $result -Name 'JoinStateSource' -Value $(if ($join) { 'Registry' } else { 'Unavailable' })

    # --- Opt-in: dsregcmd /status (contacts Microsoft Entra ID) ---------------
    $probes = Test-OmniNetworkProbeEnabled -Context $Context
    Set-OmniResultMetric -Result $result -Name 'ConnectivityProbesRun' -Value $probes
    $registered = $false
    $values = @{}
    if ($probes -and -not ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested)) {
        $lines = $null
        try { $lines = Invoke-OmniEntraDsregStatus } catch {
            if ($log) { $log.Warn("dsregcmd failed: $($_.Exception.Message)", 'Entra ID') }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.dsregcmd-failed' -Title 'Could not read Entra join status' -Severity Warning -Component 'Cloud/EntraID' -Detail $_.Exception.Message -Recommendation 'Run dsregcmd /status manually and review the Device State and SSO State sections.')
        }
        if ($null -ne $lines) {
            $values = ConvertFrom-OmniDsregStatus -Line $lines
            foreach ($key in $values.Keys) { Set-OmniResultMetric -Result $result -Name $key -Value $values[$key] }
            # dsregcmd is authoritative when it ran; fill what the registry could not give.
            if ($values.ContainsKey('AzureAdJoined')) { $joined = ($values['AzureAdJoined'] -eq 'YES') }
            if ($values['TenantName']) { $tenantName = $values['TenantName'] }
            $registered = ($values['WorkplaceJoined'] -eq 'YES')
        }
    }

    $authStatus = [string]$values['DeviceAuthStatus']
    $hasPrt = ($values['AzureAdPrt'] -eq 'YES')
    $ranDsreg = ($values.Count -gt 0)

    if (-not $join -and -not $ranDsreg) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.join-state-unavailable' -Title 'Entra join state could not be read' -Severity Information -Component 'Cloud/EntraID' -Detail 'The CloudDomainJoin registry key could not be read.' -Recommendation 'Run dsregcmd /status manually, or re-run with --network-probes.')
    } elseif (-not $joined -and -not $registered) {
        if ($ranDsreg) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.not-joined-or-registered' -Title 'Device is not joined or registered with Entra ID' -Severity Information -Component 'Cloud/EntraID' -Detail 'dsregcmd reports AzureAdJoined and WorkplaceJoined as NO.' -Recommendation 'No action is needed for intentionally on-premises devices; otherwise confirm the organization join or registration process.')
        } else {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.not-joined' -Title 'Device is not Microsoft Entra joined' -Severity Information -Component 'Cloud/EntraID' -Detail 'No Microsoft Entra join record was found in the registry. Per-user Entra registration (workplace join) is reported only by dsregcmd, which runs with --network-probes.' -Recommendation 'No action is needed for intentionally on-premises or unmanaged devices; otherwise confirm the organization join process.')
        }
    }

    if ($ranDsreg) {
        if ($authStatus -and $authStatus -ne 'SUCCESS') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.device-auth-failed' -Title 'Entra device authentication is not healthy' -Severity Warning -Component 'Cloud/EntraID/Authentication' -Detail "dsregcmd reports DeviceAuthStatus '$authStatus'." -LikelyCause 'The Entra device object may be disabled, deleted, or unable to authenticate.' -Confidence 80 -Recommendation 'Check the device object in Entra admin center and review dsregcmd /status diagnostics before re-registering the device.')
        }
        if ($joined -and -not $hasPrt) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.prt-missing' -Title 'No Entra primary refresh token for the current user' -Severity Warning -Component 'Cloud/EntraID/SSO' -Detail 'The device is Entra joined but AzureAdPrt is not YES.' -LikelyCause 'The current sign-in session did not obtain an Entra PRT, affecting seamless Microsoft 365 SSO.' -Confidence 75 -Recommendation 'Verify time, network/proxy access, user credentials, and Conditional Access; review the SSO State in dsregcmd /status.')
        }
    } elseif ($joined -and -not $probes) {
        Add-OmniFinding -Result $result -Finding (New-OmniProbeSkippedFinding -Component 'Cloud/EntraID' -Probe 'run dsregcmd /status (the device-authentication and primary-refresh-token checks contact Microsoft Entra ID)')
    }

    if ($joined -or $registered) {
        if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0) {
            $what = if ($joined) { 'Microsoft Entra join' } else { 'Microsoft Entra registration' }
            $tenantText = if ($tenantName) { $tenantName } elseif ($tenantId) { $tenantId } else { 'unknown' }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.entra-id.healthy' -Title 'Entra registration posture healthy' -Severity Pass -Component 'Cloud/EntraID' -Detail "$what is present for tenant '$tenantText'.")
        }
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
