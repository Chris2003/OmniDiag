<#
.SYNOPSIS
    OmniDiag Event Log knowledge base: channels + Event-ID translation.

.DESCRIPTION
    Two things power the "translate logs into plain English" requirement:

      1. Channel definitions - the set of logs OmniDiag collects, expressed as
         Get-WinEvent FilterHashtable inputs. The four big logs (System,
         Application, Security, Setup) are collected whole; provider-scoped
         sources the spec calls out (Kernel-Power, Disk, NTFS, Service Control
         Manager, User Profiles Service) live *inside* those logs and are
         categorized during analysis via the translation catalog below - so they
         are covered without redundant queries.

      2. The translation catalog - a curated table mapping (Event ID [+ provider])
         to a plain-English meaning, a category, an (optional) severity override,
         a likely cause, and a recommended next step. Security auditing events such
         as 4625 are logged at Information level by Windows; the override lets
         OmniDiag surface them at the severity a technician actually cares about.

    This file is pure reference data + lookups - no collection, no side effects -
    so it is trivial to unit test and extend.
#>

Set-StrictMode -Version Latest

function Get-OmniEventChannelDefinition {
    <#
    .SYNOPSIS
        Returns the channel definitions OmniDiag collects from.

    .OUTPUTS
        Objects with Key, Name, LogName, optional ProviderName, RequiresAdmin.
    #>
    [OutputType([object[]])]
    param()

    $defs = @(
        @{ Key = 'System';        Name = 'System';                LogName = 'System';      RequiresAdmin = $false }
        @{ Key = 'Application';   Name = 'Application';           LogName = 'Application'; RequiresAdmin = $false }
        @{ Key = 'Security';      Name = 'Security';              LogName = 'Security';    RequiresAdmin = $true  }
        @{ Key = 'Setup';         Name = 'Setup';                 LogName = 'Setup';       RequiresAdmin = $false }
        @{ Key = 'WindowsUpdate'; Name = 'Windows Update';        LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; RequiresAdmin = $false }
        @{ Key = 'PowerShellOp';  Name = 'PowerShell';            LogName = 'Microsoft-Windows-PowerShell/Operational';          RequiresAdmin = $false }
        @{ Key = 'PowerShellWin'; Name = 'Windows PowerShell';    LogName = 'Windows PowerShell';                                 RequiresAdmin = $false }
        @{ Key = 'Defender';      Name = 'Windows Defender';      LogName = 'Microsoft-Windows-Windows Defender/Operational';     RequiresAdmin = $true  }
        @{ Key = 'DnsClient';     Name = 'DNS Client';            LogName = 'Microsoft-Windows-DNS-Client/Operational';           RequiresAdmin = $false }
        @{ Key = 'GroupPolicy';   Name = 'Group Policy';          LogName = 'Microsoft-Windows-GroupPolicy/Operational';          RequiresAdmin = $false }
        @{ Key = 'DeviceSetup';   Name = 'Device Setup Manager';  LogName = 'Microsoft-Windows-DeviceSetupManager/Operational';   RequiresAdmin = $false }
        @{ Key = 'WlanAutoConfig';Name = 'WLAN AutoConfig';       LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational';      RequiresAdmin = $false }
        @{ Key = 'NetworkProfile';Name = 'Network Profile';       LogName = 'Microsoft-Windows-NetworkProfile/Operational';       RequiresAdmin = $false }
        @{ Key = 'OfficeAlerts';  Name = 'Microsoft 365 / Office';LogName = 'OAlerts';     RequiresAdmin = $false }
    )

    foreach ($d in $defs) {
        [pscustomobject]@{
            PSTypeName    = 'OmniDiag.EventChannel'
            Key           = $d.Key
            Name          = $d.Name
            LogName       = $d.LogName
            ProviderName  = if ($d.ContainsKey('ProviderName')) { $d.ProviderName } else { $null }
            RequiresAdmin = [bool]$d.RequiresAdmin
        }
    }
}

# ---------------------------------------------------------------------------
# Translation catalog
# ---------------------------------------------------------------------------
# Each entry: Id, optional Provider (wildcard), Title, Category, optional
# Severity override (Pass/Information/Warning/Error/Critical), Cause, Recommendation.
$script:OmniEventCatalog = @(
    # --- Boot / shutdown / power -----------------------------------------
    @{ Id = 41;   Provider = '*Kernel-Power*'; Title = 'Unexpected shutdown or power loss'; Category = 'Power'; Severity = 'Critical'
       Cause = 'The system rebooted without cleanly shutting down (power loss, hard crash, or hold-the-button shutdown).'
       Recommendation = 'Check power delivery and overheating; if recurring, inspect for driver/hardware faults and BSODs.' }
    @{ Id = 6008; Provider = $null; Title = 'Previous shutdown was unexpected'; Category = 'Power'; Severity = 'Error'
       Cause = 'The last shutdown did not complete normally.'
       Recommendation = 'Correlate with Kernel-Power 41 and any bugcheck (BSOD) around the same time.' }
    @{ Id = 6005; Provider = $null; Title = 'Event log service started (system boot)'; Category = 'Boot'; Severity = 'Information'
       Cause = 'Marks a system startup.'; Recommendation = '' }
    @{ Id = 6006; Provider = $null; Title = 'Clean shutdown'; Category = 'Boot'; Severity = 'Information'
       Cause = 'The event log service stopped as part of a normal shutdown.'; Recommendation = '' }
    @{ Id = 6009; Provider = $null; Title = 'OS version logged at boot'; Category = 'Boot'; Severity = 'Information'
       Cause = 'Marks a system startup.'; Recommendation = '' }
    @{ Id = 1074; Provider = $null; Title = 'Planned shutdown/restart initiated'; Category = 'Boot'; Severity = 'Information'
       Cause = 'A process or user initiated a shutdown/restart.'; Recommendation = '' }
    @{ Id = 1076; Provider = $null; Title = 'Reason supplied for prior unexpected shutdown'; Category = 'Power'; Severity = 'Warning'
       Cause = 'A user/admin recorded a reason after an unexpected shutdown.'; Recommendation = 'Review the recorded reason for context.' }

    # --- Crashes ----------------------------------------------------------
    @{ Id = 1001; Provider = '*WER-SystemErrorReporting*'; Title = 'Bug check (Blue Screen / BSOD)'; Category = 'Crash'; Severity = 'Critical'
       Cause = 'The kernel crashed and produced a bug check.'
       Recommendation = 'Note the bug-check code; analyze the memory dump (WinDbg/!analyze) and update or roll back the implicated driver.' }
    @{ Id = 1000; Provider = '*Application Error*'; Title = 'Application crash'; Category = 'Application'; Severity = 'Error'
       Cause = 'A user-mode application terminated unexpectedly.'
       Recommendation = 'Identify the faulting module in the message; update/repair the app or its dependencies.' }
    @{ Id = 1002; Provider = '*Application Hang*'; Title = 'Application stopped responding (hang)'; Category = 'Application'; Severity = 'Warning'
       Cause = 'An application became unresponsive.'
       Recommendation = 'Check for add-ins, resource exhaustion, or blocking I/O; update the application.' }
    @{ Id = 1026; Provider = '*.NET Runtime*'; Title = 'Unhandled .NET exception'; Category = 'Application'; Severity = 'Error'
       Cause = 'A .NET application threw an unhandled exception.'
       Recommendation = 'Review the exception/stack in the message; update the application or .NET runtime.' }

    # --- Disk / file system ----------------------------------------------
    @{ Id = 7;   Provider = '*disk*'; Title = 'Bad block on disk'; Category = 'Disk'; Severity = 'Critical'
       Cause = 'The disk reported an unrecoverable bad block.'
       Recommendation = 'Back up immediately and run storage diagnostics; the drive may be failing.' }
    @{ Id = 11;  Provider = '*disk*'; Title = 'Disk controller error'; Category = 'Disk'; Severity = 'Error'
       Cause = 'The driver detected a controller error on the disk.'
       Recommendation = 'Check cabling/connection and SMART data; consider replacing the drive or controller.' }
    @{ Id = 51;  Provider = '*disk*'; Title = 'Paging error on disk'; Category = 'Disk'; Severity = 'Warning'
       Cause = 'An error occurred during a paging operation.'
       Recommendation = 'Watch for further disk errors; verify SMART health.' }
    @{ Id = 55;  Provider = '*Ntfs*'; Title = 'File system corruption detected'; Category = 'Disk'; Severity = 'Critical'
       Cause = 'NTFS detected structural corruption on a volume.'
       Recommendation = 'Run chkdsk on the affected volume; back up data first.' }
    @{ Id = 98;  Provider = '*Ntfs*'; Title = 'Volume needs checking'; Category = 'Disk'; Severity = 'Warning'
       Cause = 'NTFS flagged a volume for verification.'; Recommendation = 'Schedule chkdsk on the volume.' }
    @{ Id = 140; Provider = '*Ntfs*'; Title = 'Volume write failure'; Category = 'Disk'; Severity = 'Error'
       Cause = 'The system failed to flush data to a volume.'
       Recommendation = 'Check the disk and connection; verify SMART health.' }

    # --- Service Control Manager -----------------------------------------
    @{ Id = 7000; Provider = '*Service Control Manager*'; Title = 'Service failed to start'; Category = 'Service'; Severity = 'Error'
       Cause = 'A service could not be started.'
       Recommendation = 'Check the service dependencies and credentials; review the specific error in the message.' }
    @{ Id = 7001; Provider = '*Service Control Manager*'; Title = 'Service start blocked by failed dependency'; Category = 'Service'; Severity = 'Error'
       Cause = 'A service depends on another service that failed to start.'
       Recommendation = 'Fix the dependency service first.' }
    @{ Id = 7009; Provider = '*Service Control Manager*'; Title = 'Timeout starting service'; Category = 'Service'; Severity = 'Error'
       Cause = 'A service did not respond to the start request in time.'
       Recommendation = 'Investigate slow startup (disk, dependencies); raise the timeout only as a last resort.' }
    @{ Id = 7011; Provider = '*Service Control Manager*'; Title = 'Service control timeout'; Category = 'Service'; Severity = 'Warning'
       Cause = 'A transaction with a service timed out.'
       Recommendation = 'Identify the service; check for hangs or resource contention.' }
    @{ Id = 7031; Provider = '*Service Control Manager*'; Title = 'Service terminated unexpectedly'; Category = 'Service'; Severity = 'Error'
       Cause = 'A service crashed; the SCM may attempt recovery.'
       Recommendation = 'Update the owning software; review its application logs for the crash cause.' }
    @{ Id = 7034; Provider = '*Service Control Manager*'; Title = 'Service crashed (no recovery action)'; Category = 'Service'; Severity = 'Warning'
       Cause = 'A service terminated unexpectedly with no configured recovery.'
       Recommendation = 'Configure recovery actions and investigate the crash.' }
    @{ Id = 7045; Provider = '*Service Control Manager*'; Title = 'New service installed'; Category = 'Service'; Severity = 'Information'
       Cause = 'A new service was registered (sometimes security-relevant).'
       Recommendation = 'Confirm the service is expected; unexpected services can indicate unwanted software.' }

    # --- Network ----------------------------------------------------------
    @{ Id = 1014; Provider = '*DNS-Client*'; Title = 'DNS name resolution timeout'; Category = 'Network'; Severity = 'Warning'
       Cause = 'The DNS client did not receive a response for a query.'
       Recommendation = 'Verify DNS server reachability and configuration; flush the DNS cache.' }
    @{ Id = 4199; Provider = '*Tcpip*'; Title = 'Duplicate IP address detected'; Category = 'Network'; Severity = 'Error'
       Cause = 'Another host on the network is using this IP address.'
       Recommendation = 'Resolve the IP conflict (check DHCP scope and static assignments).' }
    @{ Id = 1003; Provider = '*Dhcp*'; Title = 'DHCP lease failure'; Category = 'Network'; Severity = 'Warning'
       Cause = 'The client could not obtain an IP lease from a DHCP server.'
       Recommendation = 'Check DHCP server availability and the network link.' }
    @{ Id = 10000;Provider = '*NetworkProfile*'; Title = 'Network connected'; Category = 'Network'; Severity = 'Information'
       Cause = 'A network profile became active.'; Recommendation = '' }
    @{ Id = 10001;Provider = '*NetworkProfile*'; Title = 'Network disconnected'; Category = 'Network'; Severity = 'Information'
       Cause = 'A network profile disconnected.'; Recommendation = '' }

    # --- Authentication / security (Security log) -------------------------
    @{ Id = 4625; Provider = $null; Title = 'Failed logon'; Category = 'Authentication'; Severity = 'Warning'
       Cause = 'An account failed to authenticate.'
       Recommendation = 'A burst of these from one source may indicate a brute-force attempt; verify the account and source.' }
    @{ Id = 4740; Provider = $null; Title = 'Account locked out'; Category = 'Authentication'; Severity = 'Warning'
       Cause = 'An account was locked out after repeated failures.'
       Recommendation = 'Identify the source of the bad attempts (cached credentials, mapped drives, services).' }
    @{ Id = 1102; Provider = $null; Title = 'Audit log was cleared'; Category = 'Security'; Severity = 'Critical'
       Cause = 'The Security audit log was cleared - can indicate tampering.'
       Recommendation = 'Confirm this was an authorized action; investigate if not.' }
    @{ Id = 4724; Provider = $null; Title = 'Password reset attempt'; Category = 'Security'; Severity = 'Information'
       Cause = 'An attempt was made to reset an account password.'; Recommendation = 'Confirm the change was expected.' }

    # --- Windows Update ---------------------------------------------------
    @{ Id = 20; Provider = '*WindowsUpdateClient*'; Title = 'Update installation failure'; Category = 'Update'; Severity = 'Error'
       Cause = 'A Windows update failed to install.'
       Recommendation = 'Note the update KB and error code; run the Windows Update troubleshooter or reset update components.' }
    @{ Id = 25; Provider = '*WindowsUpdateClient*'; Title = 'Update installation failure'; Category = 'Update'; Severity = 'Error'
       Cause = 'A Windows update failed to install.'
       Recommendation = 'Note the update KB and error code; consider resetting Windows Update components.' }
    @{ Id = 31; Provider = '*WindowsUpdateClient*'; Title = 'Update download failure'; Category = 'Update'; Severity = 'Warning'
       Cause = 'A Windows update failed to download.'
       Recommendation = 'Check connectivity to update servers and available disk space.' }
    @{ Id = 19; Provider = '*WindowsUpdateClient*'; Title = 'Update installed successfully'; Category = 'Update'; Severity = 'Information'
       Cause = 'A Windows update installed.'; Recommendation = '' }

    # --- Windows Defender -------------------------------------------------
    @{ Id = 1116; Provider = '*Defender*'; Title = 'Malware detected'; Category = 'Security'; Severity = 'Critical'
       Cause = 'Microsoft Defender detected malware.'
       Recommendation = 'Confirm remediation (event 1117); run a full scan and investigate the source.' }
    @{ Id = 1117; Provider = '*Defender*'; Title = 'Action taken on malware'; Category = 'Security'; Severity = 'Warning'
       Cause = 'Defender took action on a detected threat.'
       Recommendation = 'Verify the threat was quarantined/removed; investigate origin.' }
    @{ Id = 2001; Provider = '*Defender*'; Title = 'Defender signature update failed'; Category = 'Security'; Severity = 'Warning'
       Cause = 'Definition update did not complete.'
       Recommendation = 'Check connectivity; manually update Defender signatures.' }
    @{ Id = 5001; Provider = '*Defender*'; Title = 'Real-time protection disabled'; Category = 'Security'; Severity = 'Warning'
       Cause = 'Defender real-time protection was turned off.'
       Recommendation = 'Confirm this was intentional; re-enable real-time protection if not.' }

    # --- User Profile Service --------------------------------------------
    @{ Id = 1511; Provider = '*User Profile*'; Title = 'Logged on with a temporary profile'; Category = 'Profile'; Severity = 'Error'
       Cause = 'Windows could not load the user profile and used a temporary one.'
       Recommendation = 'Check the user profile path/permissions and the ProfileList registry key.' }
    @{ Id = 1515; Provider = '*User Profile*'; Title = 'Profile backed up / temporary profile created'; Category = 'Profile'; Severity = 'Warning'
       Cause = 'A previous profile load failed.'; Recommendation = 'Investigate underlying profile load failures.' }
    @{ Id = 1530; Provider = '*User Profile*'; Title = 'Registry handle leaked at logoff'; Category = 'Profile'; Severity = 'Warning'
       Cause = 'An application held registry handles open during logoff.'; Recommendation = 'Usually benign; identify the app if it recurs.' }

    # --- Group Policy -----------------------------------------------------
    @{ Id = 1058; Provider = '*GroupPolicy*'; Title = 'Group Policy processing failed (gpt.ini)'; Category = 'GroupPolicy'; Severity = 'Error'
       Cause = 'The client could not read a Group Policy file from the domain controller.'
       Recommendation = 'Check DC connectivity, DNS, and SYSVOL access.' }
    @{ Id = 1030; Provider = '*GroupPolicy*'; Title = 'Group Policy processing failed'; Category = 'GroupPolicy'; Severity = 'Error'
       Cause = 'Group Policy could not be applied.'
       Recommendation = 'Correlate with 1058; verify domain connectivity.' }
)

function Get-OmniEventCatalog {
    <# .SYNOPSIS Returns the full translation catalog (array of hashtables). #>
    [OutputType([object[]])]
    param()
    return $script:OmniEventCatalog
}

function Resolve-OmniEventMeaning {
    <#
    .SYNOPSIS
        Looks up the catalog entry for an event, preferring a provider-specific
        match over an Id-only match.

    .OUTPUTS
        The matching catalog hashtable, or $null when unknown.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [int] $Id,
        [string] $ProviderName
    )

    $candidates = $script:OmniEventCatalog | Where-Object { $_.Id -eq $Id }
    if (-not $candidates) { return $null }

    if ($ProviderName) {
        $specific = $candidates | Where-Object { $_.Provider -and ($ProviderName -like $_.Provider) }
        if ($specific) { return ($specific | Select-Object -First 1) }
    }

    # Fall back to a generic (provider-less) entry if one exists.
    $generic = $candidates | Where-Object { -not $_.Provider }
    if ($generic) { return ($generic | Select-Object -First 1) }

    return $null
}

Export-ModuleMember -Function @(
    'Get-OmniEventChannelDefinition', 'Get-OmniEventCatalog', 'Resolve-OmniEventMeaning'
)
