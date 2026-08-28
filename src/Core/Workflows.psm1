<#
.SYNOPSIS
    Role profiles and task-oriented scan workflows for OmniDiag.

.DESCRIPTION
    Maps familiar IT roles and daily support tasks to focused scanner sets. The
    mappings are data only: the engine remains unaware of roles and workflows.
    This keeps automation predictable while giving newer technicians a safe,
    plain-language entry point.
#>

Set-StrictMode -Version Latest

$script:OmniRoleProfiles = @(
    [pscustomobject]@{
        Name = 'HelpDesk'; Audience = 'Tier 1 help desk and service desk'
        Description = 'Fast endpoint triage for common user-impacting issues.'
        Modules = @('System Information','System Health','CPU','Memory','Disk','Disk Usage','Network','IP Configuration','DNS Resolver','Printers','Windows Update','Error Summary')
    },
    [pscustomobject]@{
        Name = 'DesktopSupport'; Audience = 'Tier 2 desktop and field support'
        Description = 'Deeper endpoint, application, device, startup, and reliability checks.'
        Modules = @('System Information','System','System Health','Windows Health','Windows Update','Drivers','Services','Startup','Installed Software','CPU','Memory','Processes','Startup Performance','Disk','Disk Usage','Temp Files','Network','IP Configuration','DNS Resolver','WiFi Networks','Printers','USB Devices','Battery','Browser Diagnostics','Reliability','Event Logs','Error Summary')
    },
    [pscustomobject]@{
        Name = 'SystemsAdmin'; Audience = 'Windows systems administrators'
        Description = 'Server and workstation operating-system, service, storage, security, and domain posture.'
        Modules = @('System Information','System','System Health','Windows Health','Windows Update','Services','Drivers','Scheduled Tasks','Windows Features','Environment Variables','Registry Health','Installed Software','CPU','Memory','Processes','Performance','Disk','Storage','Disk Usage','Network','IP Configuration','DNS Resolver','Network Shares','Security','Firewall Rules','Reliability','Event Logs','Error Summary','Active Directory','Entra ID','Intune and MDM')
    },
    [pscustomobject]@{
        Name = 'NetworkAdmin'; Audience = 'Network and infrastructure administrators'
        Description = 'Adapter, addressing, DNS, Wi-Fi, shares, host overrides, firewall, and identity reachability posture.'
        Modules = @('Network','IP Configuration','DNS Resolver','Hosts File','Network Shares','WiFi Networks','Firewall Rules','Active Directory','Entra ID','Event Logs','Error Summary')
    },
    [pscustomobject]@{
        Name = 'SecurityAdmin'; Audience = 'Security operations and endpoint security administrators'
        Description = 'Endpoint protection, firewall, patch, persistence, identity, and security-event posture.'
        Modules = @('Security','Firewall Rules','Windows Update','Windows Features','Startup','Scheduled Tasks','Services','Processes','Installed Software','Browser Diagnostics','Active Directory','Entra ID','Intune and MDM','Event Logs','Error Summary')
    },
    [pscustomobject]@{
        Name = 'CloudAdmin'; Audience = 'Microsoft 365, Entra, Intune, and cloud administrators'
        Description = 'Local identity, join, enrollment, policy, DNS, and cloud access readiness.'
        Modules = @('System Information','System Health','Windows Update','Network','IP Configuration','DNS Resolver','Firewall Rules','Active Directory','Entra ID','Intune and MDM','Event Logs','Error Summary')
    },
    [pscustomobject]@{
        Name = 'Full'; Audience = 'Tier 3, engineering, and comprehensive audits'
        Description = 'Run every enabled scanner.'
        Modules = @()
    }
)

$script:OmniTaskWorkflows = @(
    [pscustomobject]@{ Name='QuickTriage'; Description='A fast first pass for an unknown user issue.'; Modules=@('System Information','System Health','CPU','Memory','Disk','Network','IP Configuration','DNS Resolver','Windows Update','Error Summary') },
    [pscustomobject]@{ Name='SlowComputer'; Description='Investigate CPU, memory, process, disk, startup, and thermal-style symptoms.'; Modules=@('CPU','Memory','Processes','Performance','Benchmark','Startup','Startup Performance','Disk','Disk Usage','Temp Files','System Health','Reliability','Error Summary') },
    [pscustomobject]@{ Name='NetworkConnectivity'; Description='Diagnose adapter, IP, DNS, Wi-Fi, hosts-file, share, and firewall issues.'; Modules=@('Network','IP Configuration','DNS Resolver','Hosts File','Network Shares','WiFi Networks','Firewall Rules','Active Directory') },
    [pscustomobject]@{ Name='Printing'; Description='Diagnose printers, spooler-related services, drivers, and errors.'; Modules=@('Printers','Services','Drivers','Network','Error Summary') },
    [pscustomobject]@{ Name='WindowsUpdate'; Description='Check update, servicing, reboot, service, and recent error posture.'; Modules=@('Windows Update','Windows Health','System Health','Services','Disk','Event Logs','Error Summary') },
    [pscustomobject]@{ Name='LoginAndIdentity'; Description='Diagnose local, domain, Entra, MDM, DNS, and time-sensitive sign-in dependencies.'; Modules=@('System Information','Network','IP Configuration','DNS Resolver','Active Directory','Entra ID','Intune and MDM','Event Logs','Error Summary') },
    [pscustomobject]@{ Name='StorageCleanup'; Description='Find capacity, disk-health, usage, and temporary-file pressure.'; Modules=@('Disk','Storage','Disk Usage','Temp Files','System Health') },
    [pscustomobject]@{ Name='SecurityPosture'; Description='Review protection, firewall, patch, persistence, software, and identity posture.'; Modules=@('Security','Firewall Rules','Windows Update','Startup','Scheduled Tasks','Services','Processes','Installed Software','Active Directory','Entra ID','Intune and MDM','Error Summary') },
    [pscustomobject]@{ Name='CloudReadiness'; Description='Check Entra join, Intune enrollment, domain trust, DNS, network, and update prerequisites.'; Modules=@('System Information','System Health','Windows Update','Network','IP Configuration','DNS Resolver','Firewall Rules','Active Directory','Entra ID','Intune and MDM') },
    [pscustomobject]@{ Name='FullScan'; Description='Run every enabled scanner.'; Modules=@() }
)

function Get-OmniRoleProfile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Name)

    if (-not $Name) { return @($script:OmniRoleProfiles) }
    $match = @($script:OmniRoleProfiles | Where-Object { $_.Name -ieq $Name })
    if ($match.Count -eq 0) {
        throw "Unknown role profile '$Name'. Valid profiles: $($script:OmniRoleProfiles.Name -join ', ')."
    }
    return $match[0]
}

function Get-OmniTaskWorkflow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Name)

    if (-not $Name) { return @($script:OmniTaskWorkflows) }
    $match = @($script:OmniTaskWorkflows | Where-Object { $_.Name -ieq $Name })
    if ($match.Count -eq 0) {
        throw "Unknown task workflow '$Name'. Valid workflows: $($script:OmniTaskWorkflows.Name -join ', ')."
    }
    return $match[0]
}

Export-ModuleMember -Function @('Get-OmniRoleProfile', 'Get-OmniTaskWorkflow')
