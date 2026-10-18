<#
.SYNOPSIS
    OmniDiag diagnostic module: Windows time synchronization.

.DESCRIPTION
    Read-only, local-only Windows Time (W32Time) posture:

      - Service state and start type (Get-Service W32Time). On workgroup devices W32Time
        is a trigger-start (Manual) service that is often stopped between syncs, so a
        stopped Manual service is Information, a Disabled one a Warning.
      - Configuration from the registry: the Group Policy values under
        HKLM\SOFTWARE\Policies\Microsoft\W32Time\Parameters win over the local values
        under HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters (Type: NoSync,
        NTP, NT5DS, AllSync; NtpServer).
      - Status from the System event log, provider Microsoft-Windows-Time-Service, by
        event ID (bounded by MaxEvents and the scan time range): 35 / 37 (synchronizing
        with / receiving valid time from a source), 36 (not synchronized for a long
        period), 47 (no valid response from a manually configured peer).

    It does not run `w32tm` (its output is localized) and never contacts a time server.
#>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Time Synchronization'; Id='extras.time-synchronization'; Group='extras'; NetworkAccess='None'; Category='Identity'; Description='Windows Time service, configured source, sync events, and NTP policy posture.'; RequiresAdmin=$false; Order=480; Enabled=$true }
}

$script:OmniTimeSyncOkIds   = @(35, 37)
$script:OmniTimeSyncFailIds = @(36, 47)
$script:OmniTimeMaxEvents   = 50

function Test-OmniTimeWindowsHost {
    <# .SYNOPSIS Internal: $true on Windows (Windows PowerShell 5.1 is always Windows). #>
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmniTimeService {
    <# .SYNOPSIS Internal: W32Time service as @{ Status; StartType } (strings). Throws when missing. #>
    [OutputType([hashtable])]
    param()
    $s = Get-Service -Name 'W32Time' -ErrorAction Stop
    $start = ''
    if ($s.PSObject.Properties['StartType']) { $start = [string]$s.StartType }
    return @{ Status = [string]$s.Status; StartType = $start }
}

function Get-OmniTimeConfig {
    <#
    .SYNOPSIS
        Internal: effective W32Time Type / NtpServer and where they came from ('Policy' or
        'Local'). Returns @{ Type; NtpServer; Source }.
    #>
    [OutputType([hashtable])]
    param()
    $cfg = @{ Type = ''; NtpServer = ''; Source = '' }
    foreach ($pair in @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'; Source = 'Policy' },
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'; Source = 'Local' })) {
        $p = Get-ItemProperty -LiteralPath $pair.Path -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if (-not $cfg.Type -and $p.PSObject.Properties['Type'] -and $p.Type) { $cfg.Type = [string]$p.Type; $cfg.Source = $pair.Source }
        if (-not $cfg.NtpServer -and $p.PSObject.Properties['NtpServer'] -and $p.NtpServer) { $cfg.NtpServer = [string]$p.NtpServer }
    }
    return $cfg
}

function Get-OmniTimeEvent {
    <#
    .SYNOPSIS
        Internal: newest Microsoft-Windows-Time-Service events from the System log with the
        given IDs, bounded by MaxEvents (and StartTime when given). Returns objects with
        Id and TimeCreated.
    #>
    param(
        [Parameter(Mandatory)] [int[]] $Id,
        [Parameter(Mandatory)] [int] $MaxEvents,
        [Nullable[datetime]] $StartTime
    )
    $filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Time-Service'; Id = $Id }
    if ($StartTime) { $filter['StartTime'] = [datetime]$StartTime }
    return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Id = [int]$_.Id; TimeCreated = $_.TimeCreated } })
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Time Synchronization' -Category 'Identity' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    if (-not (Test-OmniTimeWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.windows-only' -Title 'Windows time synchronization is unavailable' -Severity Information -Component 'Identity/Time' -Detail 'This host is not Windows.')
        return (Complete-OmniResult -Result $result)
    }

    $svc = $null
    try { $svc = Get-OmniTimeService } catch { if ($log) { $log.Debug("W32Time service query failed: $($_.Exception.Message)", 'Time Synchronization') } }
    $cfg = @{ Type = ''; NtpServer = ''; Source = '' }
    try { $cfg = Get-OmniTimeConfig } catch { if ($log) { $log.Debug("W32Time parameters failed: $($_.Exception.Message)", 'Time Synchronization') } }

    $serviceStatus = if ($svc) { $svc.Status } else { '' }
    $startType = if ($svc) { $svc.StartType } else { '' }
    Set-OmniResultMetric -Result $result -Name 'ServiceStatus' -Value $serviceStatus
    Set-OmniResultMetric -Result $result -Name 'ServiceStartType' -Value $startType
    Set-OmniResultMetric -Result $result -Name 'Type' -Value $cfg.Type
    Set-OmniResultMetric -Result $result -Name 'NtpServer' -Value $cfg.NtpServer
    Set-OmniResultMetric -Result $result -Name 'ConfigurationSource' -Value $cfg.Source

    # --- Events (bounded) ------------------------------------------------------
    $lastOk = $null; $failures = @()
    if (-not ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested)) {
        try {
            $ok = @(Get-OmniTimeEvent -Id $script:OmniTimeSyncOkIds -MaxEvents 1)
            if ($ok.Count -gt 0) { $lastOk = $ok[0].TimeCreated }
            $start = $null
            if ($Context.PSObject.Properties['TimeRange'] -and $Context.TimeRange) { $start = $Context.TimeRange.Start }
            $failures = @(Get-OmniTimeEvent -Id $script:OmniTimeSyncFailIds -MaxEvents $script:OmniTimeMaxEvents -StartTime $start)
        } catch { if ($log) { $log.Debug("Time-Service event query failed: $($_.Exception.Message)", 'Time Synchronization') } }
    }
    Set-OmniResultMetric -Result $result -Name 'LastSyncEvent' -Value $lastOk
    Set-OmniResultMetric -Result $result -Name 'SyncFailureEventCount' -Value $failures.Count

    # --- Findings ----------------------------------------------------------------
    if ($startType -eq 'Disabled') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.service-disabled' -Title 'Windows Time service is disabled' -Severity Warning -Component 'Identity/Time' -Detail 'The W32Time service start type is Disabled, so the clock is never synchronized.' -LikelyCause 'The service was disabled manually or by a hardening baseline.' -Confidence 85 -Recommendation 'Review the effective time policy and service configuration; Kerberos and certificate validation require accurate time.')
    } elseif ($serviceStatus -and $serviceStatus -ne 'Running') {
        if ($startType -eq 'Manual') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.service-on-demand' -Title 'Windows Time service is stopped (starts on demand)' -Severity Information -Component 'Identity/Time' -Detail "W32Time is '$serviceStatus' with start type Manual; on workgroup devices it is trigger-started for each synchronization.")
        } else {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.service-not-running' -Title 'Windows Time service is not running' -Severity Warning -Component 'Identity/Time' -Detail "W32Time state is '$serviceStatus' (start type '$startType')." -LikelyCause 'The service stopped unexpectedly or is controlled by an incomplete policy.' -Confidence 80 -Recommendation 'Review the effective time policy and service configuration; authentication systems commonly require accurate time.')
        }
    }
    if ($cfg.Type -eq 'NoSync') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.sync-disabled' -Title 'Time synchronization is turned off' -Severity Warning -Component 'Identity/Time' -Detail "W32Time Type is NoSync ($($cfg.Source) configuration): the clock is not synchronized with any source." -LikelyCause 'A policy or manual change set the client to NoSync.' -Confidence 85 -Recommendation 'Set Type to NT5DS (domain members) or NTP with an approved NtpServer, through the same policy that set it.')
    }
    if ($failures.Count -gt 0) {
        $newest = ($failures | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $ids = (@($failures | ForEach-Object { $_.Id } | Sort-Object -Unique) -join ', ')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.sync-failures' -Title 'Time synchronization failures were logged' -Severity Warning -Component 'Identity/Time' -Detail "The Time-Service logged $($failures.Count) synchronization failure event(s) (IDs $ids) in the selected time range; newest $newest." -LikelyCause 'The configured time source is unreachable, or the device has not synchronized for a long period.' -Confidence 75 -Recommendation 'Verify domain connectivity or the approved NTP source and firewall (UDP 123), then resynchronize and confirm events 35/37 follow.' -Data @{ EventIds = $ids; Count = $failures.Count })
    }
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0) {
        $lastText = if ($lastOk) { "last synchronization event $lastOk" } else { 'no synchronization event in the System log' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.time-synchronization.healthy' -Title 'Time synchronization posture healthy' -Severity Pass -Component 'Identity/Time' -Detail "Service '$serviceStatus'; type '$($cfg.Type)'; source '$($cfg.NtpServer)'; $lastText.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
