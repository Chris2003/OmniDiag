<#
.SYNOPSIS
    OmniDiag diagnostic module: Scheduled Tasks.

.DESCRIPTION
    Enumerates scheduled tasks via Get-ScheduledTask, counting enabled tasks and
    enabled non-Microsoft tasks (outside \Microsoft\). For non-Microsoft tasks with a
    logon or boot trigger it reports the actions (Execute + Arguments) and flags, as
    Warning, actions that invoke script hosts in a suspicious way (PowerShell encoded
    commands or downloads, wscript/cscript, mshta, rundll32 or regsvr32 with a URL).
    An action that only runs from a user-writable location is Information (per-user
    installs under %LOCALAPPDATA%\Programs are normal). Third-party tasks running as
    SYSTEM (principal SYSTEM, NT AUTHORITY\SYSTEM, or S-1-5-18) at logon are listed as
    Information, and are a Warning only when an action is also in a user-writable
    location or flagged by the script-host rules. Known vendor updaters
    (MicrosoftEdgeUpdate*, GoogleUpdate*, OneDrive*) are listed but never raise the
    SYSTEM-at-logon or user-writable findings.

    Read-only and local-only.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# The one Execute reason that is about location only; every other reason is a script-host reason.
$script:LocationReason = 'runs from a user-writable location'

# Principal names that mean LocalSystem (matched exactly, case-insensitively).
$script:SystemPrincipal = @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')

# Known vendor updater tasks that run at logon as SYSTEM on most machines (task name wildcards).
$script:KnownUpdaterTask = @('MicrosoftEdgeUpdate*', 'GoogleUpdate*', 'OneDrive*')

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Scheduled Tasks scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Scheduled Tasks'
        Id            = 'startup.scheduled-tasks'
        Group         = 'startup'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Enabled and third-party scheduled tasks, with logon/boot persistence and suspicious actions.'
        RequiresAdmin = $false
        Order         = 120
        Enabled       = $true
    }
}

function Get-OmniScheduledTaskList {
    <#
    .SYNOPSIS
        Returns all scheduled tasks (private; mocked in tests). Throws when the cmdlet is unavailable.
    #>
    [OutputType([object[]])]
    param()
    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        throw 'Get-ScheduledTask is not available on this system.'
    }
    return @(Get-ScheduledTask -ErrorAction Stop)
}

function Get-OmniTaskValue {
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

function Get-OmniTaskClassName {
    <#
    .SYNOPSIS
        Returns the CIM class name of a trigger or action object (private).
    #>
    [OutputType([string])]
    param([object] $InputObject)
    if ($null -eq $InputObject) { return '' }
    $cls = Get-OmniTaskValue $InputObject 'CimClass'
    if ($cls) {
        $n = Get-OmniTaskValue $cls 'CimClassName'
        if ($n) { return [string]$n }
    }
    foreach ($t in $InputObject.PSObject.TypeNames) {
        if ($t -match '(MSFT_Task\w+)$') { return $Matches[1] }
    }
    return ''
}

function Test-OmniTaskUserWritablePath {
    <#
    .SYNOPSIS
        True when a path is in a location standard users can write (private).
    #>
    [OutputType([bool])]
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Replace('/', '\')
    $patterns = @(
        '(?i)\\Users\\[^\\]+\\AppData\\',
        '(?i)\\Users\\Public\\',
        '(?i)\\Users\\[^\\]+\\(Downloads|Desktop|Documents)\\',
        '(?i)\\(Temp|Tmp)\\',
        '(?i)^[a-z]:\\ProgramData\\[^\\]+$',
        '(?i)^[a-z]:\\(Temp|Tmp)\\'
    )
    foreach ($re in $patterns) { if ($p -match $re) { return $true } }
    return $false
}

function Get-OmniTaskActionRisk {
    <#
    .SYNOPSIS
        Returns the reasons an Execute/Arguments pair looks suspicious (private; empty when none).
    #>
    [OutputType([string[]])]
    param([string] $Execute, [string] $Arguments)
    $reasons = [System.Collections.Generic.List[string]]::new()
    $exe = [Environment]::ExpandEnvironmentVariables(([string]$Execute).Trim().Trim('"'))
    $argText = [string]$Arguments
    $leaf = (($exe.Replace('/', '\')) -split '\\')[-1].ToLowerInvariant()
    if ($leaf -notmatch '\.') { $leaf = $leaf + '.exe' }
    $url = '(?i)(https?://|\\\\[^\\]+\\|javascript:|vbscript:)'

    if (Test-OmniTaskUserWritablePath -Path $exe) { $reasons.Add($script:LocationReason) }
    switch ($leaf) {
        { $_ -in @('powershell.exe', 'pwsh.exe') } {
            $encoded = $false
            foreach ($tok in @($argText -split '\s+')) {
                if ($tok -notmatch '^[-/]') { continue }
                $name = $tok.Substring(1).ToLowerInvariant()
                if ($name -eq 'ec' -or ($name.StartsWith('e') -and 'encodedcommand'.StartsWith($name))) { $encoded = $true }
            }
            if ($encoded) { $reasons.Add('PowerShell encoded command') }
            if ($argText -match $url -or $argText -match '(?i)(DownloadString|DownloadFile|Invoke-WebRequest|\biwr\b|Net\.WebClient)') { $reasons.Add('PowerShell downloads from the network') }
        }
        { $_ -in @('wscript.exe', 'cscript.exe') } { $reasons.Add('Windows Script Host') }
        'mshta.exe' { $reasons.Add('mshta (HTML application host)') }
        'rundll32.exe' { if ($argText -match $url) { $reasons.Add('rundll32 with a URL or script') } }
        'regsvr32.exe' { if ($argText -match $url) { $reasons.Add('regsvr32 with a URL') } }
    }
    return [string[]]@($reasons)
}

function Test-OmniTaskSystemPrincipal {
    <#
    .SYNOPSIS
        True when a task principal UserId is exactly LocalSystem (private).
    #>
    [OutputType([bool])]
    param([string] $UserId)
    if ([string]::IsNullOrWhiteSpace($UserId)) { return $false }
    $u = $UserId.Trim()
    foreach ($s in $script:SystemPrincipal) { if ($u -eq $s) { return $true } }
    return $false
}

function Test-OmniTaskKnownUpdater {
    <#
    .SYNOPSIS
        True when a task name matches the known vendor updater allowlist (private).
    #>
    [OutputType([bool])]
    param([string] $TaskName)
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return $false }
    foreach ($pattern in $script:KnownUpdaterTask) { if ($TaskName -like $pattern) { return $true } }
    return $false
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the Scheduled Tasks scan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Scheduled Tasks' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $tasks = $null
    try {
        $tasks = @(Get-OmniScheduledTaskList)
    } catch {
        $log.Warn("Scheduled tasks unavailable: $($_.Exception.Message)", 'Scheduled Tasks')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-unavailable' `
            -Title 'Scheduled tasks not available' -Severity 'Information' -Component 'System/ScheduledTasks' `
            -Detail 'Get-ScheduledTask is not available on this platform or failed, so scheduled tasks were not checked.')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $enabled = @($tasks | Where-Object { [string](Get-OmniTaskValue $_ 'State') -ne 'Disabled' })
    $thirdParty = @($enabled | Where-Object { [string](Get-OmniTaskValue $_ 'TaskPath') -notlike '\Microsoft\*' })

    Set-OmniResultMetric -Result $result -Name 'EnabledTaskCount'    -Value $enabled.Count
    Set-OmniResultMetric -Result $result -Name 'ThirdPartyTaskCount' -Value $thirdParty.Count

    $note = if ($Context.IsAdmin) { '' } else { ' Without elevation, tasks whose security descriptor hides them from standard users are not listed.' }
    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-summary' `
        -Title ("$($enabled.Count) enabled scheduled task(s)") -Severity 'Information' -Component 'System/ScheduledTasks' `
        -Detail ("$($enabled.Count) enabled tasks, of which $($thirdParty.Count) are non-Microsoft.$note"))

    # --- Third-party logon/boot tasks, their actions, and risky ones ---------
    $persist = [System.Collections.Generic.List[object]]::new()
    $suspicious = [System.Collections.Generic.List[object]]::new()
    $userWritable = [System.Collections.Generic.List[object]]::new()
    $systemAtLogon = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $thirdParty) {
        if ($Context.CancellationToken.IsCancellationRequested) { break }
        try {
            $taskName = [string](Get-OmniTaskValue $t 'TaskName')
            $full = '{0}{1}' -f (Get-OmniTaskValue $t 'TaskPath'), $taskName
            $triggerKinds = [System.Collections.Generic.List[string]]::new()
            foreach ($trig in @(Get-OmniTaskValue $t 'Triggers')) {
                switch (Get-OmniTaskClassName $trig) {
                    'MSFT_TaskLogonTrigger' { if (-not $triggerKinds.Contains('Logon')) { $triggerKinds.Add('Logon') } }
                    'MSFT_TaskBootTrigger'  { if (-not $triggerKinds.Contains('Boot')) { $triggerKinds.Add('Boot') } }
                }
            }
            if ($triggerKinds.Count -eq 0) { continue }

            $principal = Get-OmniTaskValue $t 'Principal'
            $userId = [string](Get-OmniTaskValue $principal 'UserId')
            $knownUpdater = Test-OmniTaskKnownUpdater -TaskName $taskName

            $actions = [System.Collections.Generic.List[object]]::new()
            foreach ($a in @(Get-OmniTaskValue $t 'Actions')) {
                if ($null -eq $a) { continue }
                $exec = [string](Get-OmniTaskValue $a 'Execute')
                if (-not $exec) { continue }
                $argText = [string](Get-OmniTaskValue $a 'Arguments')
                $reasons = @(Get-OmniTaskActionRisk -Execute $exec -Arguments $argText)
                $actions.Add([pscustomobject]@{ Execute = $exec; Arguments = $argText; Reasons = $reasons })
            }
            $entry = [pscustomobject]@{ Task = $full; Triggers = @($triggerKinds); RunAs = $userId; KnownUpdater = $knownUpdater; Actions = @($actions) }
            $persist.Add($entry)

            $allReasons = @($actions | ForEach-Object { $_.Reasons })
            $scriptHost = @($allReasons | Where-Object { $_ -ne $script:LocationReason }).Count -gt 0
            $anyRisk = $allReasons.Count -gt 0
            # Script-host reasons are a Warning even for allowlisted names (names are easy to copy).
            if ($scriptHost) { $suspicious.Add($entry) }
            elseif ($anyRisk -and -not $knownUpdater) { $userWritable.Add($entry) }
            if (-not $knownUpdater -and $triggerKinds.Contains('Logon') -and (Test-OmniTaskSystemPrincipal -UserId $userId)) {
                $systemAtLogon.Add([pscustomobject]@{ Task = $full; Risky = $anyRisk })
            }
        } catch {
            $log.Debug("Failed to inspect task '$(Get-OmniTaskValue $t 'TaskName')': $($_.Exception.Message)", 'Scheduled Tasks')
        }
    }

    Set-OmniResultMetric -Result $result -Name 'LogonBootTaskCount' -Value $persist.Count
    Set-OmniResultMetric -Result $result -Name 'SuspiciousTaskCount' -Value $suspicious.Count
    Set-OmniResultMetric -Result $result -Name 'UserWritableTaskCount' -Value $userWritable.Count
    Set-OmniResultMetric -Result $result -Name 'SystemAtLogonTaskCount' -Value $systemAtLogon.Count

    $describe = {
        param($e)
        $acts = @($e.Actions | ForEach-Object { (('{0} {1}' -f $_.Execute, $_.Arguments).Trim()) }) -join ' | '
        if (-not $acts) { $acts = '(no executable action)' }
        '{0} [{1}] -> {2}' -f $e.Task, ($e.Triggers -join '/'), $acts
    }

    if ($persist.Count -gt 0) {
        $list = @($persist | Select-Object -First 20 | ForEach-Object { & $describe $_ })
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-logon-boot' `
            -Title ("$($persist.Count) non-Microsoft task(s) start at logon or boot") -Severity 'Information' `
            -Component 'System/ScheduledTasks' `
            -Detail ('Non-Microsoft tasks with a logon or boot trigger (first 20): ' + ($list -join '; ')) `
            -Data @($persist))
    }

    if ($userWritable.Count -gt 0) {
        $list = @($userWritable | Select-Object -First 20 | ForEach-Object { & $describe $_ })
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-user-writable-action' `
            -Title ("$($userWritable.Count) logon/boot task(s) run a program from a user-writable location") -Severity 'Information' `
            -Component 'System/ScheduledTasks' `
            -Detail ('Tasks whose program is under AppData, Temp, Users\Public, Downloads/Desktop/Documents, or directly in ProgramData (first 20): ' + ($list -join '; ') + '. Per-user installs (for example under %LOCALAPPDATA%\Programs) are normal; review tasks you do not recognize.') `
            -Data @($userWritable))
    }

    if ($suspicious.Count -gt 0) {
        $list = @($suspicious | Select-Object -First 20 | ForEach-Object {
            $why = @($_.Actions | ForEach-Object { $_.Reasons } | Select-Object -Unique) -join ', '
            '{0} ({1})' -f (& $describe $_), $why
        })
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-suspicious-action' `
            -Title ("$($suspicious.Count) logon/boot task(s) with a suspicious action") -Severity 'Warning' `
            -Component 'System/ScheduledTasks' `
            -Detail ('Tasks that invoke a script host in a way commonly used by malware: ' + ($list -join '; ')) `
            -LikelyCause 'Persistence by unwanted software or malware.' `
            -Confidence 60 `
            -Recommendation 'Verify each task and its binary or script; disable and remove tasks you cannot attribute to trusted software, and scan the machine for malware.' `
            -Data @($suspicious))
    }

    if ($systemAtLogon.Count -gt 0) {
        # Information on its own (many vendors do this); a Warning only when the action is
        # also in a user-writable location or flagged by the script-host rules.
        $riskyCount = @($systemAtLogon | Where-Object { $_.Risky }).Count
        $sev = if ($riskyCount -gt 0) { 'Warning' } else { 'Information' }
        $names = @($systemAtLogon | Sort-Object -Property @{ Expression = { -not $_.Risky } } | Select-Object -First 10 | ForEach-Object {
            if ($_.Risky) { "$($_.Task) (action in a user-writable location or script host)" } else { $_.Task }
        })
        $params = @{
            Id        = 'scheduled-tasks-system-at-logon'
            Title     = "$($systemAtLogon.Count) third-party task(s) run as SYSTEM at logon"
            Severity  = $sev
            Component = 'System/ScheduledTasks'
            Detail    = 'The following non-Microsoft tasks run as SYSTEM at logon (first 10): ' + ($names -join '; ') + '.'
            Data      = @($systemAtLogon)
        }
        if ($riskyCount -gt 0) {
            $params['LikelyCause'] = 'A high-privilege autostart task whose program can be replaced by a standard user, or that uses a script host in a way commonly used by malware.'
            $params['Confidence'] = 60
            $params['Recommendation'] = 'Verify these tasks are legitimate; move the program to a protected folder or remove the task.'
        }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding @params)
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'scheduled-tasks-ok' `
            -Title 'Scheduled tasks inventory collected' -Severity 'Pass' -Component 'System/ScheduledTasks' `
            -Detail 'Scheduled tasks were enumerated; no suspicious logon or boot tasks found.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
