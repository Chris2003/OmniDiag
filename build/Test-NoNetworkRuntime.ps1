<#
.SYNOPSIS
    Runtime no-network test: proves a default OmniDiag scan makes no outbound network attempt.

.DESCRIPTION
    Windows-only, needs an elevated session (the GitHub windows-latest runner is). It is the
    runtime half of OmniDiag's no-network enforcement (docs/ARCHITECTURE.md); the static half
    is Tests/NoNetwork.Tests.ps1.

    1. Saves the audit policy (auditpol /backup) and enables success+failure auditing for the
       "Filtering Platform Connection" subcategory (Security events 5156 allowed / 5157
       blocked, one per connection attempt, with the calling ProcessID and Application) and
       "Process Creation" (event 4688, used to follow child processes the scan starts).
    2. Enables the Microsoft-Windows-DNS-Client/Operational log (event 3006 = a name query
       was issued; the event's System/Execution ProcessID is the calling process).
    3. Turns on any disabled Windows Firewall profile and adds outbound BLOCK rules for the
       PowerShell executables (pwsh.exe and powershell.exe, by program path), so even an
       attempt never leaves the machine. Other processes keep their connectivity.
    4. Runs, each as a child process with the same environment OmniDiag.cmd sets up
       (PowerShell telemetry and update check off, OMNIDIAG_DATA in a temp folder):
         a. positive control - a tiny command that opens a TCP connection to 1.1.1.1:443
            and resolves a fixed control name. The detector MUST see both, otherwise the
            test is vacuous and fails;
         b. 'omnidiag scan --format json --output <tmp>' (the default selection);
         c. 'omnidiag report --output <tmp>';
         d. informational: 'omnidiag scan --network-probes ...' when the CLI supports the
            flag ('omnidiag help scan' mentions it). Attempts there are expected and are
            reported, not failed - they show the opt-in path is the one that connects.
    5. For each run, reads 5156/5157 and DNS 3006 events from its time window, keeps those
       from the run's process tree (root PID plus descendants from 4688), drops loopback
       destinations (127.0.0.0/8, ::1) and inbound records, and also flags - from ANY
       process - connections to the known probe targets (1.1.1.1, the default gateways) and
       queries for the known probe name (www.microsoft.com), in case a probe is attributed
       to a system process. Anything left in b or c is a violation.
    6. Restores everything in a finally block: removes the firewall rules, restores the
       firewall profile states, the audit policy (auditpol /restore), and the DNS log state.

    Writes no-network.json and no-network.md to -OutputDirectory (and appends the markdown
    to $GITHUB_STEP_SUMMARY when set).

    Exit codes: 0 = no violation and the positive control was detected; 1 = violation, or
    the control was not detected; 2 = could not run (not Windows, not elevated, setup error,
    a run timed out or ended with a usage/internal error).

    Microsoft documentation:
      auditpol set/backup/restore:
        https://learn.microsoft.com/windows-server/administration/windows-commands/auditpol-set
        https://learn.microsoft.com/windows-server/administration/windows-commands/auditpol-backup
        https://learn.microsoft.com/windows-server/administration/windows-commands/auditpol-restore
      Audit Filtering Platform Connection (subcategory GUID {0CCE9226-69AE-11D9-BED3-505054503030}):
        https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/audit-filtering-platform-connection
      Event 5156 / 5157 (fields ProcessID, Application, Direction %%14593 = outbound, DestAddress):
        https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-5156
        https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-5157
      Audit Process Creation ({0CCE922B-69AE-11D9-BED3-505054503030}) and event 4688
      (NewProcessId, ProcessId = creator):
        https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4688
      wevtutil set-log (enable the DNS-Client operational channel):
        https://learn.microsoft.com/windows-server/administration/windows-commands/wevtutil
      New-NetFirewallRule / Remove-NetFirewallRule / Set-NetFirewallProfile:
        https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule
        https://learn.microsoft.com/powershell/module/netsecurity/remove-netfirewallrule
        https://learn.microsoft.com/powershell/module/netsecurity/set-netfirewallprofile
      Get-WinEvent -FilterHashtable:
        https://learn.microsoft.com/powershell/module/microsoft.powershell.diagnostics/get-winevent

.PARAMETER OutputDirectory
    Where the report files go. Default: <repo>/test-results/no-network.

.PARAMETER PowerShellPath
    The PowerShell executable that runs the CLI. Default: the one running this script.

.PARAMETER TimeoutSeconds
    Per-run timeout. Default 900.

.PARAMETER SkipNetworkProbesCheck
    Skip the informational '--network-probes' run.

.EXAMPLE
    pwsh -NoProfile -File build/Test-NoNetworkRuntime.ps1
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $PowerShellPath,
    [ValidateRange(30, 3600)] [int] $TimeoutSeconds = 900,
    [switch] $SkipNetworkProbesCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent

# --- Preconditions -------------------------------------------------------------------
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'Test-NoNetworkRuntime: this test needs Windows (Windows Filtering Platform auditing, Windows Firewall, the Security event log). Run it on a Windows host or the CI no-network job.'
    exit 2
}
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Test-NoNetworkRuntime: run elevated (auditpol, firewall rules, and the Security log need administrator rights).'
    exit 2
}

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'test-results/no-network' }
if (-not $PowerShellPath) { $PowerShellPath = (Get-Process -Id $PID).Path }
$cli = Join-Path $repoRoot 'src/Cli/omnidiag.ps1'
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$work = Join-Path ([IO.Path]::GetTempPath()) ('omnidiag-nonet-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force

$auditSubcategories = [ordered]@{
    'Filtering Platform Connection' = '{0CCE9226-69AE-11D9-BED3-505054503030}'
    'Process Creation'              = '{0CCE922B-69AE-11D9-BED3-505054503030}'
}
$dnsLog = 'Microsoft-Windows-DNS-Client/Operational'
$ruleGroup = 'OmniDiag-NoNetworkTest'
$controlTarget = '1.1.1.1'
$controlName = 'omnidiag-nonet-control.example.com'
$probeNames = @('www.microsoft.com')

# --- Helpers -------------------------------------------------------------------------
function ConvertTo-ArgumentString {
    param([string[]] $Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-ChildRun {
    # Starts PowerShell with the given arguments, waits, returns PID, exit code, and times.
    param([string] $Name, [string[]] $Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellPath
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    $start = Get-Date
    $p = [System.Diagnostics.Process]::Start($psi)
    $childPid = $p.Id
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { try { $p.Kill() } catch { Write-Verbose "Kill failed: $($_.Exception.Message)" } }
    $p.WaitForExit()
    $end = Get-Date
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.stdout.txt") -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.stderr.txt") -Value $stderr -Encoding UTF8
    [pscustomobject]@{
        Name     = $Name
        Pid      = $childPid
        ExitCode = if ($timedOut) { -1 } else { $p.ExitCode }
        TimedOut = $timedOut
        Start    = $start
        End      = $end
        Seconds  = [math]::Round(($end - $start).TotalSeconds, 1)
        Stdout   = $stdout
    }
}

function Get-EventRecord {
    param([hashtable] $Filter)
    try { @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match 'No events were found') { @() }
        else { throw }
    }
}

function Get-EventData {
    param($Record)
    $xml = [xml]$Record.ToXml()
    $data = @{}
    foreach ($d in $xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']")) {
        $n = $d.GetAttribute('Name')
        if ($n) { $data[$n] = [string]$d.InnerText }
    }
    $data
}

function ConvertTo-Pid {
    param([string] $Value)
    if (-not $Value) { return -1 }
    if ($Value -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }
    $n = 0L
    if ([long]::TryParse($Value, [ref]$n)) { return $n }
    -1
}

function Test-Loopback {
    param([string] $Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse(($Address -replace '%.*$', ''), [ref]$ip)) { return $false }
    [System.Net.IPAddress]::IsLoopback($ip)
}

function Get-ProcessTree {
    # Root PID plus every descendant created in the window (Security 4688).
    param([long] $RootPid, [datetime] $From, [datetime] $To)
    $tree = New-Object 'System.Collections.Generic.HashSet[long]'
    [void]$tree.Add($RootPid)
    $created = foreach ($e in (Get-EventRecord @{ LogName = 'Security'; Id = 4688; StartTime = $From; EndTime = $To })) {
        $d = Get-EventData $e
        [pscustomobject]@{ Pid = (ConvertTo-Pid $d['NewProcessId']); Parent = (ConvertTo-Pid $d['ProcessId']); Name = $d['NewProcessName'] }
    }
    $created = @($created)
    do {
        $added = $false
        foreach ($c in $created) {
            if ($tree.Contains($c.Parent) -and $tree.Add($c.Pid)) { $added = $true }
        }
    } while ($added)
    [pscustomobject]@{
        Pids     = @($tree)
        Children = @($created | Where-Object { $_.Pid -ne $RootPid -and $tree.Contains($_.Pid) } | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Pid })
    }
}

function Get-RunNetworkActivity {
    param($Run, [string[]] $ProbeTargets)
    # Small slack around the window: event timestamps and process start/stop are not atomic.
    $from = $Run.Start.AddSeconds(-1)
    $to = $Run.End.AddSeconds(3)
    $tree = Get-ProcessTree -RootPid $Run.Pid -From $from -To $to
    $pidSet = $tree.Pids

    $connections = foreach ($e in (Get-EventRecord @{ LogName = 'Security'; Id = @(5156, 5157); StartTime = $from; EndTime = $to })) {
        $d = Get-EventData $e
        if ($d['Direction'] -notin '%%14593', 'Outbound') { continue }
        if (Test-Loopback $d['DestAddress']) { continue }
        $procId = ConvertTo-Pid $d['ProcessID']
        $inTree = $pidSet -contains $procId
        $probeTarget = $d['DestAddress'] -in $ProbeTargets
        if (-not ($inTree -or $probeTarget)) { continue }
        [pscustomobject]@{
            Time        = $e.TimeCreated.ToString('o')
            Event       = $e.Id
            Outcome     = if ($e.Id -eq 5157) { 'blocked' } else { 'allowed' }
            ProcessId   = $procId
            Application = $d['Application']
            Destination = '{0}:{1}' -f $d['DestAddress'], $d['DestPort']
            Protocol    = $d['Protocol']
            Matched     = if ($inTree) { 'process tree' } else { 'probe target (any process)' }
        }
    }

    $dns = @()
    if ($script:DnsLogEnabled) {
        $local = @('localhost', $env:COMPUTERNAME)
        $dns = foreach ($e in (Get-EventRecord @{ LogName = $dnsLog; Id = 3006; StartTime = $from; EndTime = $to })) {
            $d = Get-EventData $e
            $name = ([string]$d['QueryName']).TrimEnd('.')
            if (-not $name -or $name -in $local) { continue }
            $inTree = $pidSet -contains [long]$e.ProcessId
            $probeName = $name -in ($probeNames + $controlName)
            if (-not ($inTree -or $probeName)) { continue }
            [pscustomobject]@{
                Time      = $e.TimeCreated.ToString('o')
                ProcessId = [long]$e.ProcessId
                QueryName = $name
                Matched   = if ($inTree) { 'process tree' } else { 'probe name (any process)' }
            }
        }
    }

    [pscustomobject]@{
        ProcessTree = $tree.Children
        Connections = @($connections)
        DnsQueries  = @($dns)
    }
}

# --- Setup ---------------------------------------------------------------------------
$auditBackup = Join-Path $work 'audit-backup.csv'
$profileState = @()
$dnsWasEnabled = $null
$script:DnsLogEnabled = $false
$runs = [System.Collections.Generic.List[object]]::new()
$setupNotes = [System.Collections.Generic.List[string]]::new()
$harnessError = $null
$envBackup = @{}

try {
    # Audit policy (backup first, restored in finally).
    & auditpol.exe /backup "/file:$auditBackup" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "auditpol /backup failed ($LASTEXITCODE)" }
    foreach ($sub in $auditSubcategories.GetEnumerator()) {
        & auditpol.exe /set "/subcategory:$($sub.Value)" /success:enable /failure:enable | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "auditpol /set $($sub.Key) failed ($LASTEXITCODE)" }
    }
    $setupNotes.Add('Audit: Filtering Platform Connection + Process Creation (success, failure) enabled.')

    # DNS-Client operational log.
    try {
        $dnsWasEnabled = (Get-WinEvent -ListLog $dnsLog -ErrorAction Stop).IsEnabled
        if (-not $dnsWasEnabled) {
            & wevtutil.exe sl $dnsLog /e:true | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wevtutil sl failed ($LASTEXITCODE)" }
        }
        $script:DnsLogEnabled = $true
        $setupNotes.Add("DNS: $dnsLog enabled (was enabled: $dnsWasEnabled).")
    } catch {
        $setupNotes.Add("DNS: could not enable $dnsLog ($($_.Exception.Message)); DNS queries are NOT checked.")
        Write-Warning $setupNotes[-1]
    }

    # Firewall: profiles on, outbound block for the PowerShell executables.
    Remove-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue
    $profileState = @(Get-NetFirewallProfile | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled } })
    $disabled = @($profileState | Where-Object { $_.Enabled -ne 'True' })
    if ($disabled.Count -gt 0) {
        Set-NetFirewallProfile -Name $disabled.Name -Enabled True
        $setupNotes.Add("Firewall: enabled profile(s) $($disabled.Name -join ', ') for the test.")
    }
    $blocked = @($PowerShellPath,
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
    foreach ($exe in $blocked) {
        $null = New-NetFirewallRule -DisplayName "OmniDiag no-network test: block $(Split-Path $exe -Leaf)" -Group $ruleGroup `
            -Direction Outbound -Action Block -Program $exe -Profile Any -Enabled True
    }
    $setupNotes.Add("Firewall: outbound block for $($blocked -join '; ').")

    # Known probe targets (flagged from any process).
    $probeTargets = @($controlTarget)
    try {
        $probeTargets += @(Get-NetRoute -DestinationPrefix '0.0.0.0/0', '::/0' -ErrorAction Stop |
                Where-Object { $_.NextHop -and $_.NextHop -notin '0.0.0.0', '::' } | ForEach-Object { $_.NextHop })
    } catch { Write-Verbose "Get-NetRoute: $($_.Exception.Message)" }
    $probeTargets = @($probeTargets | Sort-Object -Unique)
    $setupNotes.Add("Probe targets flagged from any process: $($probeTargets -join ', '); probe names: $($probeNames -join ', ').")

    # Same environment OmniDiag.cmd sets up: PowerShell's update check and telemetry off,
    # data in a throwaway folder.
    foreach ($name in 'OMNIDIAG_DATA', 'POWERSHELL_TELEMETRY_OPTOUT', 'POWERSHELL_UPDATECHECK', 'POWERSHELL_CLI_TELEMETRY_OPTOUT') {
        $envBackup[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:OMNIDIAG_DATA = Join-Path $work 'OmniDiagData'
    $env:POWERSHELL_TELEMETRY_OPTOUT = '1'
    $env:POWERSHELL_UPDATECHECK = 'Off'
    $env:POWERSHELL_CLI_TELEMETRY_OPTOUT = '1'

    $common = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')

    # a. Positive control.
    $controlCommand = @"
`$ErrorActionPreference = 'Continue'
try { `$c = New-Object System.Net.Sockets.TcpClient; [void]`$c.ConnectAsync('$controlTarget', 443).Wait(5000); `$c.Dispose() } catch { 'tcp: ' + `$_.Exception.Message }
try { [void][System.Net.Dns]::GetHostAddresses('$controlName') } catch { 'dns: ' + `$_.Exception.Message }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($controlCommand))
    $runs.Add((Invoke-ChildRun -Name 'control' -Arguments ($common + @('-EncodedCommand', $encoded))))

    # b, c. Default scan and report.
    $runs.Add((Invoke-ChildRun -Name 'scan' -Arguments ($common + @('-File', $cli, 'scan', '--format', 'json', '--output', (Join-Path $work 'scan.json'), '--quiet'))))
    $runs.Add((Invoke-ChildRun -Name 'report' -Arguments ($common + @('-File', $cli, 'report', '--output', (Join-Path $work 'report'), '--quiet'))))

    # d. Opt-in probes (informational), when the CLI supports the flag.
    $script:ProbesSupported = $false
    if (-not $SkipNetworkProbesCheck) {
        $help = Invoke-ChildRun -Name 'help-scan' -Arguments ($common + @('-File', $cli, 'help', 'scan'))
        $script:ProbesSupported = $help.Stdout -match '--network-probes'
        if ($script:ProbesSupported) {
            $runs.Add((Invoke-ChildRun -Name 'network-probes' -Arguments ($common + @('-File', $cli, 'scan', '--network-probes', '--format', 'json', '--output', (Join-Path $work 'probes.json'), '--quiet'))))
        } else {
            $setupNotes.Add("'omnidiag help scan' does not mention --network-probes; the opt-in check was skipped.")
        }
    }

    # Let the event log catch up, then collect.
    Start-Sleep -Seconds 5
    foreach ($run in $runs) {
        $activity = Get-RunNetworkActivity -Run $run -ProbeTargets $probeTargets
        $run | Add-Member -NotePropertyName ProcessTree -NotePropertyValue $activity.ProcessTree
        $run | Add-Member -NotePropertyName Connections -NotePropertyValue $activity.Connections
        $run | Add-Member -NotePropertyName DnsQueries -NotePropertyValue $activity.DnsQueries
    }
} catch {
    $harnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
} finally {
    foreach ($k in $envBackup.Keys) { [Environment]::SetEnvironmentVariable($k, $envBackup[$k]) }
    try { Remove-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue } catch { Write-Warning "Remove-NetFirewallRule: $($_.Exception.Message)" }
    foreach ($p in $profileState) {
        try { Set-NetFirewallProfile -Name $p.Name -Enabled $p.Enabled } catch { Write-Warning "Set-NetFirewallProfile $($p.Name): $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $auditBackup) {
        & auditpol.exe /restore "/file:$auditBackup" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "auditpol /restore failed ($LASTEXITCODE)" }
    }
    if ($dnsWasEnabled -eq $false) { & wevtutil.exe sl $dnsLog /e:false | Out-Null }
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { Write-Verbose "cleanup: $($_.Exception.Message)" }
}

# --- Evaluate ------------------------------------------------------------------------
$failures = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()
$runByName = @{}
foreach ($r in $runs) { $runByName[$r.Name] = $r }

if (-not $harnessError) {
    foreach ($r in $runs) {
        if ($r.TimedOut) { $harnessError = "run '$($r.Name)' timed out after $TimeoutSeconds s" }
        elseif ($r.Name -ne 'control' -and $r.ExitCode -ge 10) { $harnessError = "run '$($r.Name)' exited $($r.ExitCode) (usage/internal error); see $($r.Name).stderr.txt" }
    }
}

if (-not $harnessError) {
    $control = $runByName['control']
    $tcpSeen = @($control.Connections | Where-Object { $_.Matched -eq 'process tree' -and $_.Destination -like "$($controlTarget):443" }).Count -gt 0
    if (-not $tcpSeen) { $failures.Add("Positive control: the TCP attempt to $($controlTarget):443 was NOT detected for PID $($control.Pid); the detector would be vacuous.") }
    if ($script:DnsLogEnabled) {
        $dnsByPid = @($control.DnsQueries | Where-Object { $_.QueryName -eq $controlName -and $_.Matched -eq 'process tree' }).Count -gt 0
        $dnsByName = @($control.DnsQueries | Where-Object { $_.QueryName -eq $controlName }).Count -gt 0
        if (-not $dnsByName) { $failures.Add("Positive control: the DNS query for $controlName was NOT detected; the DNS check would be vacuous.") }
        elseif (-not $dnsByPid) { $notes.Add('DNS control was seen by name but not attributed to its PID: DNS queries are only checked against the known probe names.') }
    }
    foreach ($name in 'scan', 'report') {
        $r = $runByName[$name]
        foreach ($c in $r.Connections) { $failures.Add("[$name] $($c.Outcome) connection to $($c.Destination) (protocol $($c.Protocol)) by PID $($c.ProcessId) $($c.Application) [$($c.Matched)]") }
        foreach ($q in $r.DnsQueries) { $failures.Add("[$name] DNS query for $($q.QueryName) by PID $($q.ProcessId) [$($q.Matched)]") }
    }
    if ($runByName.ContainsKey('network-probes')) {
        $pr = $runByName['network-probes']
        $notes.Add("--network-probes run (informational): $(@($pr.Connections).Count) connection attempt(s), $(@($pr.DnsQueries).Count) DNS quer(ies) - expected, the opt-in path.")
    }
}

$status = if ($harnessError) { 'error' } elseif ($failures.Count -gt 0) { 'fail' } else { 'pass' }

# --- Report --------------------------------------------------------------------------
$summary = [ordered]@{
    status         = $status
    harnessError   = $harnessError
    failures       = @($failures)
    notes          = @($notes)
    setup          = @($setupNotes)
    powershell     = $PowerShellPath
    dnsChecked     = $script:DnsLogEnabled
    runs           = @($runs | ForEach-Object {
            [ordered]@{
                name        = $_.Name
                pid         = $_.Pid
                exitCode    = $_.ExitCode
                seconds     = $_.Seconds
                childProcesses = @(if ($_.PSObject.Properties['ProcessTree']) { $_.ProcessTree })
                connections = @(if ($_.PSObject.Properties['Connections']) { $_.Connections })
                dnsQueries  = @(if ($_.PSObject.Properties['DnsQueries']) { $_.DnsQueries })
            }
        })
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'no-network.json') -Encoding UTF8

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('### No-network runtime test')
$md.Add('')
$md.Add("**Result: $($status.ToUpperInvariant())**")
$md.Add('')
if ($harnessError) { $md.Add("Harness error: $harnessError"); $md.Add('') }
$md.Add('| Run | PID | Exit | Seconds | Child processes | Connections | DNS queries |')
$md.Add('|---|---:|---:|---:|---:|---:|---:|')
foreach ($r in $runs) {
    $cp = if ($r.PSObject.Properties['ProcessTree']) { @($r.ProcessTree).Count } else { '-' }
    $cn = if ($r.PSObject.Properties['Connections']) { @($r.Connections).Count } else { '-' }
    $dq = if ($r.PSObject.Properties['DnsQueries']) { @($r.DnsQueries).Count } else { '-' }
    $md.Add("| $($r.Name) | $($r.Pid) | $($r.ExitCode) | $($r.Seconds) | $cp | $cn | $dq |")
}
$md.Add('')
$md.Add('The control run must show a connection (and a DNS query); `scan` and `report` must show none.')
if ($failures.Count -gt 0) { $md.Add(''); $md.Add('**Failures**'); $md.Add(''); foreach ($f in $failures) { $md.Add("- $f") } }
if ($notes.Count -gt 0) { $md.Add(''); $md.Add('**Notes**'); $md.Add(''); foreach ($n in $notes) { $md.Add("- $n") } }
$md.Add(''); $md.Add('**Setup**'); $md.Add(''); foreach ($s in $setupNotes) { $md.Add("- $s") }
$mdText = $md -join "`n"
Set-Content -LiteralPath (Join-Path $OutputDirectory 'no-network.md') -Value $mdText -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $mdText -Encoding UTF8 }

Write-Host $mdText
foreach ($r in $runs) {
    if ($r.PSObject.Properties['Connections']) {
        foreach ($c in $r.Connections) { Write-Host ("  [{0}] {1} {2} pid={3} {4} ({5})" -f $r.Name, $c.Outcome, $c.Destination, $c.ProcessId, $c.Application, $c.Matched) }
        foreach ($q in $r.DnsQueries) { Write-Host ("  [{0}] dns {1} pid={2} ({3})" -f $r.Name, $q.QueryName, $q.ProcessId, $q.Matched) }
    }
}

switch ($status) {
    'pass' { exit 0 }
    'fail' { exit 1 }
    default { exit 2 }
}
