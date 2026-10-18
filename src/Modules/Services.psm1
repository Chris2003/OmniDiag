<#
.SYNOPSIS
    OmniDiag diagnostic module: Services.

.DESCRIPTION
    Inventories Windows services via Win32_Service: counts by state and by start type
    (Automatic, Automatic (Delayed Start), Manual, Disabled), reports automatic-start
    services that are stopped (the single owner of this check: Warning only when the
    ExitCode is not 0 and not 1077, otherwise Information; trigger-start services with a
    TriggerInfo registry subkey are skipped), and reads the System log for Service Control Manager
    events over the session time range to report services that crashed (7031, 7034)
    or failed to start (7000, 7009, 7011), grouped per service.

    Read-only and local-only: CIM queries and the local System event log.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

# SCM event ids: unexpected termination vs. start failure / timeout.
$script:ScmCrashIds = @(7031, 7034)
$script:ScmStartFailureIds = @(7000, 7009, 7011)

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Services scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Services'
        Id            = 'services.services'
        Group         = 'services'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Service inventory by start type, stopped auto-start services, and recent SCM crash/start-failure events.'
        RequiresAdmin = $false
        Order         = 130
        Enabled       = $true
    }
}

function Get-OmniServiceInstance {
    <#
    .SYNOPSIS
        Returns Win32_Service instances (private; mocked in tests). Throws when CIM is unavailable.
    #>
    [OutputType([object[]])]
    param()
    return @(Get-CimInstance -ClassName 'Win32_Service' -ErrorAction Stop)
}

function Get-OmniServiceScmEvent {
    <#
    .SYNOPSIS
        Returns Service Control Manager events from the local System log (private; mocked in tests).

    .DESCRIPTION
        Emits objects with Id, TimeCreated, and ServiceName, taken from the event's insertion
        strings by position (language-independent): param1 for 7000/7031/7034, param2 for
        7009/7011. Returns nothing when no event matches; throws when the log is unavailable.
    #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [datetime] $Start,
        [Parameter(Mandatory)] [datetime] $End,
        [Parameter(Mandatory)] [int[]] $Id,
        [int] $MaxEvents = 500
    )
    $filter = @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = $Id; StartTime = $Start; EndTime = $End }
    $raw = $null
    try {
        $raw = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw
    }
    $out = foreach ($e in $raw) {
        $props = @($e.Properties)
        $index = if ([int]$e.Id -in @(7009, 7011)) { 1 } else { 0 }
        $name = if ($props.Count -gt $index) { [string]$props[$index].Value } else { '' }
        [pscustomobject]@{ Id = [int]$e.Id; TimeCreated = $e.TimeCreated; ServiceName = $name }
    }
    return @($out)
}

function Get-OmniServiceValue {
    <#
    .SYNOPSIS
        Reads a property that may be absent on older systems or partial objects (private).
    #>
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-OmniServiceKey {
    <#
    .SYNOPSIS
        Kebab-cases a service name for a stable finding id (private).
    #>
    param([string] $Name)
    $k = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $k) { $k = 'unknown' }
    return $k
}

function Test-OmniServiceTriggerStart {
    <#
    .SYNOPSIS
        True when a service is trigger-started (HKLM\SYSTEM\CurrentControlSet\Services\<name>\TriggerInfo
        exists) (private; mocked in tests). Read-only; $false when the registry is unavailable.
    #>
    [OutputType([bool])]
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    try {
        return [bool](Test-Path -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\TriggerInfo" -f $Name) -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Test-OmniServiceFailedExitCode {
    <#
    .SYNOPSIS
        True when a stopped service's Win32 ExitCode indicates a failure: not 0 and not
        1077 (ERROR_SERVICE_NEVER_STARTED) (private).
    #>
    [OutputType([bool])]
    param([object] $Service)
    $code = Get-OmniServiceValue $Service 'ExitCode'
    if ($null -eq $code -or "$code" -eq '') { return $false }
    $c = [int64]$code
    return ($c -ne 0 -and $c -ne 1077)
}

function Get-OmniServiceStartType {
    <#
    .SYNOPSIS
        Maps a Win32_Service to a start-type label (private).
    #>
    param([object] $Service)
    $mode = [string](Get-OmniServiceValue $Service 'StartMode')
    switch ($mode) {
        'Auto' {
            if (Get-OmniServiceValue $Service 'DelayedAutoStart') { return 'Automatic (Delayed Start)' }
            return 'Automatic'
        }
        'Manual'   { return 'Manual' }
        'Disabled' { return 'Disabled' }
        'Boot'     { return 'Boot' }
        'System'   { return 'System' }
        default    { return 'Unknown' }
    }
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the Services scan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Services' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = if ($Context.PSObject.Properties['Config'] -and $Context.Config) { $Context.Config } else { @{} }

    $services = $null
    try {
        $services = @(Get-OmniServiceInstance)
    } catch {
        $log.Warn("CIM query failed for Win32_Service: $($_.Exception.Message)", 'Services')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'services-inventory-unavailable' `
            -Title 'Service inventory not available' -Severity 'Information' -Component 'System/Services' `
            -Detail 'Win32_Service could not be queried (CIM is not available on this platform or the query failed).')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $total   = $services.Count
    $running = @($services | Where-Object { $_.State -eq 'Running' }).Count
    $stopped = @($services | Where-Object { $_.State -eq 'Stopped' }).Count

    Set-OmniResultMetric -Result $result -Name 'ServiceCount'        -Value $total
    Set-OmniResultMetric -Result $result -Name 'RunningServiceCount' -Value $running
    Set-OmniResultMetric -Result $result -Name 'StoppedServiceCount' -Value $stopped

    # --- Counts by start type ----------------------------------------------
    $byType = [ordered]@{ 'Automatic' = 0; 'Automatic (Delayed Start)' = 0; 'Manual' = 0; 'Disabled' = 0 }
    foreach ($s in $services) {
        $t = Get-OmniServiceStartType -Service $s
        if ($byType.Contains($t)) { $byType[$t] = $byType[$t] + 1 } else { $byType[$t] = 1 }
    }
    Set-OmniResultMetric -Result $result -Name 'ServicesByStartType' -Value $byType
    $typeText = @($byType.Keys | ForEach-Object { '{0}: {1}' -f $_, $byType[$_] }) -join '; '
    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'services-start-type-summary' `
        -Title 'Service start types' -Severity 'Information' -Component 'System/Services' `
        -Detail ("$total services ($running running, $stopped stopped). By start type: $typeText.") `
        -Data $byType)

    # --- Automatic-start services that are stopped ------------------------
    # This scanner is the single owner of this check (Windows Health records a count only).
    # Trigger-start services (a TriggerInfo subkey) stop by design and are skipped. A stop
    # is a Warning only when the exit code shows a failure: not 0 (clean) and not 1077
    # (ERROR_SERVICE_NEVER_STARTED); otherwise it is Information.
    try {
        $autoStopped = @($services | Where-Object {
            $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' -and
            -not (Get-OmniServiceValue $_ 'DelayedAutoStart') -and
            -not (Test-OmniServiceTriggerStart -Name ([string]$_.Name))
        })
        $failedStop = @($autoStopped | Where-Object { Test-OmniServiceFailedExitCode -Service $_ })
        Set-OmniResultMetric -Result $result -Name 'AutoStoppedServiceCount' -Value $autoStopped.Count
        Set-OmniResultMetric -Result $result -Name 'AutoStoppedFailedServiceCount' -Value $failedStop.Count

        if ($autoStopped.Count -gt 0) {
            # Failed ones first, so they are always within the first 10 listed.
            $ordered = @($failedStop) + @($autoStopped | Where-Object { -not (Test-OmniServiceFailedExitCode -Service $_) })
            $names = @($ordered | Select-Object -First 10 | ForEach-Object {
                $code = Get-OmniServiceValue $_ 'ExitCode'
                if ($null -ne $code -and [int64]$code -ne 0) { '{0} (exit code {1})' -f $_.DisplayName, $code } else { [string]$_.DisplayName }
            })
            $params = @{
                Id        = 'services-auto-start-stopped'
                Title     = "$($autoStopped.Count) automatic service(s) are stopped"
                Component = 'System/Services'
                Detail    = 'Automatic-start services currently stopped (first 10): ' + ($names -join '; ')
                Data      = @($ordered | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; DisplayName = [string]$_.DisplayName; ExitCode = (Get-OmniServiceValue $_ 'ExitCode') } })
            }
            if ($failedStop.Count -gt 0) {
                $params['Severity'] = 'Warning'
                $params['LikelyCause'] = "$($failedStop.Count) of them stopped with a failure exit code: the service failed to start or crashed."
                $params['Confidence'] = 60
                $params['Recommendation'] = 'Investigate the services with an exit code; check the System log for Service Control Manager events, the service dependencies, and the logon account.'
            } else {
                $params['Severity'] = 'Information'
                $params['LikelyCause'] = 'The services stopped cleanly or never needed to start (exit code 0 or 1077); many services stop on their own when idle.'
                $params['Recommendation'] = 'No action is needed unless a feature that depends on one of these services is not working.'
            }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding @params)
        }
    } catch {
        $log.Debug("Auto-stopped service detection failed: $($_.Exception.Message)", 'Services')
    }

    # --- SCM crash / start-failure history (System log) --------------------
    $range = $null
    if ($Context.PSObject.Properties['TimeRange']) { $range = $Context.TimeRange }
    $start = if ($range) { [datetime]$range.Start } else { (Get-Date).AddDays(-7) }
    $end   = if ($range) { [datetime]$range.End } else { Get-Date }
    $label = if ($range -and $range.PSObject.Properties['Label']) { [string]$range.Label } else { 'Last7Days' }
    $maxEvents = 500
    if ($cfg.ContainsKey('ServiceEventMaxEvents')) { $maxEvents = [Math]::Max(1, [int]$cfg['ServiceEventMaxEvents']) }

    $events = $null
    try {
        $events = @(Get-OmniServiceScmEvent -Start $start -End $end -Id ($script:ScmCrashIds + $script:ScmStartFailureIds) -MaxEvents $maxEvents)
    } catch {
        $log.Debug("SCM event query failed: $($_.Exception.Message)", 'Services')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'services-scm-events-unavailable' `
            -Title 'Service crash history not available' -Severity 'Information' -Component 'System/Services' `
            -Detail 'The System event log could not be read, so Service Control Manager crash and start-failure events (7000, 7009, 7011, 7031, 7034) were not checked.')
    }

    if ($null -ne $events) {
        Set-OmniResultMetric -Result $result -Name 'ScmEventCount' -Value $events.Count
        Set-OmniResultMetric -Result $result -Name 'ScmEventsTruncated' -Value ($events.Count -ge $maxEvents)

        # Map display names (as logged) to service names for stable ids.
        $byDisplay = @{}
        foreach ($s in $services) {
            $dn = [string](Get-OmniServiceValue $s 'DisplayName')
            if ($dn -and -not $byDisplay.ContainsKey($dn)) { $byDisplay[$dn] = [string]$s.Name }
        }

        $groups = [ordered]@{}
        foreach ($e in $events) {
            if ($Context.CancellationToken.IsCancellationRequested) { break }
            $logged = [string]$e.ServiceName
            if (-not $logged) { $logged = '(unknown service)' }
            $svcName = if ($byDisplay.ContainsKey($logged)) { $byDisplay[$logged] } else { $logged }
            $kind = if ([int]$e.Id -in $script:ScmCrashIds) { 'crash' } else { 'start-failure' }
            $key = "$kind|$svcName"
            if (-not $groups.Contains($key)) {
                $groups[$key] = [pscustomobject]@{
                    Kind = $kind; ServiceName = $svcName; DisplayName = $logged; Hits = 0
                    EventIds = [System.Collections.Generic.List[int]]::new(); Last = $null
                }
            }
            $g = $groups[$key]
            $g.Hits++
            if (-not $g.EventIds.Contains([int]$e.Id)) { $g.EventIds.Add([int]$e.Id) }
            if ($null -ne $e.TimeCreated -and ($null -eq $g.Last -or $e.TimeCreated -gt $g.Last)) { $g.Last = $e.TimeCreated }
        }

        $crashGroups = @($groups.Values | Where-Object Kind -eq 'crash' | Sort-Object Hits -Descending)
        $failGroups  = @($groups.Values | Where-Object Kind -eq 'start-failure' | Sort-Object Hits -Descending)
        Set-OmniResultMetric -Result $result -Name 'CrashedServiceCount' -Value $crashGroups.Count
        Set-OmniResultMetric -Result $result -Name 'FailedStartServiceCount' -Value $failGroups.Count

        $cap = 15
        foreach ($g in @($crashGroups | Select-Object -First $cap)) {
            $last = if ($g.Last) { ([datetime]$g.Last).ToString('u') } else { 'unknown' }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Id ('services-scm-crash-' + (ConvertTo-OmniServiceKey $g.ServiceName)) `
                -Title ("Service terminated unexpectedly: $($g.DisplayName)") -Severity 'Warning' `
                -Component 'System/Services' `
                -Detail ("$($g.Hits) unexpected termination event(s) (Event ID $(($g.EventIds | Sort-Object) -join ', ')) in $label; last at $last.") `
                -LikelyCause 'The service process crashed or was killed; a faulting module, resource exhaustion, or a bad update are common causes.' `
                -Confidence 70 `
                -Recommendation 'Check the Application log (Event ID 1000/1001) around the same times for the faulting module, then update or repair the owning software.' `
                -Data ([pscustomobject]@{ ServiceName = $g.ServiceName; DisplayName = $g.DisplayName; Count = $g.Hits; EventIds = @($g.EventIds); LastOccurrence = $g.Last }))
        }
        foreach ($g in @($failGroups | Select-Object -First $cap)) {
            $last = if ($g.Last) { ([datetime]$g.Last).ToString('u') } else { 'unknown' }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Id ('services-scm-start-failure-' + (ConvertTo-OmniServiceKey $g.ServiceName)) `
                -Title ("Service failed to start: $($g.DisplayName)") -Severity 'Warning' `
                -Component 'System/Services' `
                -Detail ("$($g.Hits) start failure or timeout event(s) (Event ID $(($g.EventIds | Sort-Object) -join ', ')) in $label; last at $last.") `
                -LikelyCause 'A missing or corrupt binary, a failed dependency, wrong logon credentials, or a slow start that exceeded the SCM timeout.' `
                -Confidence 65 `
                -Recommendation 'Open the event details for the error code, check the service dependencies and logon account, and reinstall or repair the owning software if the binary is missing.' `
                -Data ([pscustomobject]@{ ServiceName = $g.ServiceName; DisplayName = $g.DisplayName; Count = $g.Hits; EventIds = @($g.EventIds); LastOccurrence = $g.Last }))
        }
        $extra = [Math]::Max(0, $crashGroups.Count - $cap) + [Math]::Max(0, $failGroups.Count - $cap)
        if ($extra -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'services-scm-more' `
                -Title 'More services with SCM failures' -Severity 'Information' -Component 'System/Services' `
                -Detail ("$extra more service(s) with crash or start-failure events were not listed individually."))
        }
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'services-healthy' `
            -Title 'Services healthy' -Severity 'Pass' -Component 'System/Services' `
            -Detail "$running of $total services running; no automatic service stopped with a failure exit code and no service crashes or start failures logged.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
