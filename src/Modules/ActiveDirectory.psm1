<#
.SYNOPSIS
    OmniDiag diagnostic module: Active Directory.

.DESCRIPTION
    Read-only local domain membership, secure-channel, domain-controller, and
    Group Policy posture checks. No remoting and no directory changes.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Active Directory'; Category='Identity'; Description='Local domain membership, secure channel, DC discovery, and Group Policy posture.'; RequiresAdmin=$false; Order=700; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Active Directory' -Category 'Identity' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
    if (-not $isWindowsHost) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Active Directory check is Windows-only' -Severity Information -Component 'Identity/ActiveDirectory' -Detail 'This scanner reads the local Windows domain and Group Policy state.')
        return (Complete-OmniResult -Result $result)
    }

    $partOfDomain = $false
    $domain = ''
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $partOfDomain = [bool]$computer.PartOfDomain
        $domain = [string]$computer.Domain
    } catch {
        $log.Warn("Computer domain query failed: $($_.Exception.Message)", 'Active Directory')
    }
    Set-OmniResultMetric -Result $result -Name 'PartOfDomain' -Value $partOfDomain
    Set-OmniResultMetric -Result $result -Name 'Domain' -Value $domain

    if (-not $partOfDomain) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Device is not Active Directory domain joined' -Severity Information -Component 'Identity/ActiveDirectory' -Detail "The local membership is '$domain'." -Recommendation 'No action is needed for workgroup or Entra-only devices; use the Entra ID scanner to verify cloud join state.')
        return (Complete-OmniResult -Result $result)
    }

    $secureChannel = $null
    try {
        if (Get-Command -Name Test-ComputerSecureChannel -ErrorAction SilentlyContinue) {
            $secureChannel = [bool](Test-ComputerSecureChannel -ErrorAction Stop)
            Set-OmniResultMetric -Result $result -Name 'SecureChannelHealthy' -Value $secureChannel
        }
    } catch {
        $log.Debug("Secure-channel check unavailable: $($_.Exception.Message)", 'Active Directory')
    }

    $dcName = [string]$env:LOGONSERVER
    Set-OmniResultMetric -Result $result -Name 'LogonServer' -Value $dcName
    if ([string]::IsNullOrWhiteSpace($dcName)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No domain logon server is recorded' -Severity Warning -Component 'Identity/ActiveDirectory' -Detail 'LOGONSERVER is empty for this domain-joined device.' -LikelyCause 'The device may be off the corporate network, unable to locate a domain controller, or using cached credentials.' -Confidence 65 -Recommendation 'Verify corporate network or VPN access, DNS settings, system time, and domain-controller reachability.')
    }
    if ($secureChannel -eq $false) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Active Directory secure channel is unhealthy' -Severity Error -Component 'Identity/ActiveDirectory/SecureChannel' -Detail "The trust check for domain '$domain' failed." -LikelyCause 'The computer-account password is out of sync, the account is disabled, or no domain controller is reachable.' -Confidence 85 -Recommendation 'Confirm DNS, time, and DC connectivity; then repair the computer secure channel using approved domain procedures.')
    }

    try {
        $gpPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List'
        $hasGpState = Test-Path -LiteralPath $gpPath
        Set-OmniResultMetric -Result $result -Name 'MachineGroupPolicyStatePresent' -Value $hasGpState
    } catch { $log.Debug("Group Policy state check failed: $($_.Exception.Message)", 'Active Directory') }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Active Directory posture healthy' -Severity Pass -Component 'Identity/ActiveDirectory' -Detail "The device is joined to '$domain' and no local trust issue was detected.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
