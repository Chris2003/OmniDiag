<#
.SYNOPSIS
    OmniDiag diagnostic module: Listening Ports.

.DESCRIPTION
    Lists the TCP listeners (Get-NetTCPConnection -State Listen) and UDP endpoints
    (Get-NetUDPEndpoint) with their owning process: name and path from Get-Process,
    Win32_Process.ExecutablePath when Get-Process has no path, and the Windows services
    hosted in the process (Win32_Service.ProcessId), which names what runs inside a
    shared svchost.exe. Flags listeners bound to every interface (0.0.0.0 / ::) by
    programs that are not part of Windows, and well-known remote-access or legacy ports
    (FTP, Telnet, SMB, RDP, WinRM) listening on every interface. WinRM (5985/5986) is
    Information on Windows Server SKUs (Win32_OperatingSystem.ProductType 2 or 3, or
    InstallationType 'Server'), where it is on by default, and a Warning on clients.

    Read-only and local: it reads the local TCP/IP tables and makes no connection
    attempt. The publisher check uses the file's version information (CompanyName),
    not an Authenticode signature: verifying a signature can fetch revocation data from
    the network, which a default scan must never do.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

# TCP ports whose exposure on every interface deserves a firewall-scope review. SMB (445)
# listens on every interface on almost every Windows device by default, so it is reported as
# Information to avoid a warning on healthy machines; the others are opt-in services on
# client SKUs. WinRM (5985/5986) is enabled by default on Windows Server, so on a Server
# SKU it is Information (ServerSeverity) and a Warning only on clients.
$script:OmniRiskyListenPort = @(
    [pscustomobject]@{ Port = 21;   Service = 'FTP';                            Severity = 'Warning';     ServerSeverity = 'Warning' }
    [pscustomobject]@{ Port = 23;   Service = 'Telnet';                         Severity = 'Warning';     ServerSeverity = 'Warning' }
    [pscustomobject]@{ Port = 445;  Service = 'SMB (file and printer sharing)'; Severity = 'Information'; ServerSeverity = 'Information' }
    [pscustomobject]@{ Port = 3389; Service = 'Remote Desktop';                 Severity = 'Warning';     ServerSeverity = 'Warning' }
    [pscustomobject]@{ Port = 5985; Service = 'WinRM (HTTP)';                   Severity = 'Warning';     ServerSeverity = 'Information' }
    [pscustomobject]@{ Port = 5986; Service = 'WinRM (HTTPS)';                  Severity = 'Warning';     ServerSeverity = 'Information' }
)

# Windows processes that own listeners and whose path a standard user cannot read.
$script:OmniWindowsListenerProcess = @('System', 'Idle', 'svchost', 'lsass', 'services', 'wininit',
    'spoolsv', 'smss', 'csrss', 'winlogon', 'dns', 'dfsrs', 'ismserv', 'Microsoft.ActiveDirectory.WebServices')

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Listening Ports'
        Id            = 'network.listening-ports'
        Group         = 'network'
        NetworkAccess = 'None'
        Category      = 'Network'
        Description   = 'TCP listeners and UDP endpoints with their owning process and services; flags exposure on all interfaces.'
        RequiresAdmin = $false
        Order         = 408
        Enabled       = $true
    }
}

function Get-OmniListenerTable {
    <#
    .SYNOPSIS
        Internal: reads the local TCP listeners and UDP endpoints.

    .DESCRIPTION
        Returns Available (false when Get-NetTCPConnection does not exist, e.g. off
        Windows), Tcp (MSFT_NetTCPConnection in the Listen state) and Udp
        (MSFT_NetUDPEndpoint). Reads local tables only; no connection is made.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    if (-not (Get-Command -Name 'Get-NetTCPConnection' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Tcp = @(); Udp = @() }
    }
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    $udp = @()
    if (Get-Command -Name 'Get-NetUDPEndpoint' -ErrorAction SilentlyContinue) {
        $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{ Available = $true; Tcp = $tcp; Udp = $udp }
}

function Get-OmniListenerOwner {
    <#
    .SYNOPSIS
        Internal: resolves process ids to name, path, publisher, and hosted services.

    .DESCRIPTION
        Returns a hashtable keyed by process id; each value has Name, Path, Company, and
        Services (string[]). Path comes from Get-Process, then Win32_Process
        (ExecutablePath) when Get-Process has none; both are empty for other users'
        processes without elevation. Company is the CompanyName of the file's version
        information. Services come from Win32_Service.ProcessId.

    .PARAMETER ProcessId
        The owning process ids to resolve.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int[]] $ProcessId = @())

    $owners = @{}
    foreach ($id in @($ProcessId | Select-Object -Unique)) {
        $owners[$id] = [pscustomobject]@{ Name = ''; Path = ''; Company = ''; Services = @() }
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $owners[$id].Name = [string]$p.ProcessName
            try { $owners[$id].Path = [string]$p.Path } catch { $owners[$id].Path = '' }
        } catch { $owners[$id].Name = '' }
    }

    $missing = @($owners.Keys | Where-Object { -not $owners[$_].Path })
    if ($missing.Count -gt 0 -and (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
        try {
            foreach ($wp in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, Name, ExecutablePath -ErrorAction Stop)) {
                $wid = [int]$wp.ProcessId
                if ($owners.ContainsKey($wid)) {
                    if (-not $owners[$wid].Path -and $wp.ExecutablePath) { $owners[$wid].Path = [string]$wp.ExecutablePath }
                    if (-not $owners[$wid].Name -and $wp.Name) { $owners[$wid].Name = ([string]$wp.Name -replace '\.exe$', '') }
                }
            }
        } catch { Write-Verbose "Win32_Process query failed: $($_.Exception.Message)" }
    }

    if ($owners.Count -gt 0 -and (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
        try {
            foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -Filter 'ProcessId <> 0' -Property Name, ProcessId -ErrorAction Stop)) {
                $sid = [int]$svc.ProcessId
                if ($owners.ContainsKey($sid)) { $owners[$sid].Services = @($owners[$sid].Services) + [string]$svc.Name }
            }
        } catch { Write-Verbose "Win32_Service query failed: $($_.Exception.Message)" }
    }

    foreach ($id in @($owners.Keys)) {
        $path = $owners[$id].Path
        if ($path) {
            try { $owners[$id].Company = [string]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($path).CompanyName) } catch { $owners[$id].Company = '' }
        }
    }
    return $owners
}

function Test-OmniListenerServerSku {
    <#
    .SYNOPSIS
        Internal: true on a Windows Server SKU (Win32_OperatingSystem.ProductType 2 = domain
        controller or 3 = server, or the CurrentVersion InstallationType starts with
        'Server'). Local, read-only; $false when neither source can be read.
    #>
    [OutputType([bool])]
    param()
    if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property ProductType -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $os -and $null -ne $os.ProductType) { return ([int]$os.ProductType -in @(2, 3)) }
        } catch { Write-Verbose "Win32_OperatingSystem query failed: $($_.Exception.Message)" }
    }
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction Stop
        if ($cv -and $cv.PSObject.Properties['InstallationType']) { return ([string]$cv.InstallationType -like 'Server*') }
    } catch { Write-Verbose "InstallationType read failed: $($_.Exception.Message)" }
    return $false
}

function Get-OmniListenerProperty {
    <# .SYNOPSIS Internal: reads a property that may be missing (StrictMode-safe). #>
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-OmniListenerWindowsOwner {
    <#
    .SYNOPSIS
        Internal: true when a listener's owner is part of Windows or published by Microsoft.

    .DESCRIPTION
        PIDs 0 and 4 (System Idle / System), a path under %SystemRoot%, a CompanyName
        starting with 'Microsoft', or (when the path is unreadable) a well-known Windows
        process name. This is a heuristic based on file metadata, not a signature check.
    #>
    [OutputType([bool])]
    param([int] $ProcessId, [object] $Owner)
    if ($ProcessId -in @(0, 4)) { return $true }
    if ($null -eq $Owner) { return $false }
    $root = $env:SystemRoot
    if ($Owner.Path -and $root -and $Owner.Path.StartsWith($root.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Owner.Company -and $Owner.Company -match '^\s*Microsoft') { return $true }
    if (-not $Owner.Path -and $Owner.Name -and ($script:OmniWindowsListenerProcess -contains $Owner.Name)) { return $true }
    return $false
}

function Test-OmniListenerCancelled {
    <# .SYNOPSIS Internal: true when the scan context's cancellation token is signalled. #>
    param([object] $Context)
    $p = $Context.PSObject.Properties['CancellationToken']
    return [bool]($p -and $null -ne $p.Value -and $p.Value.IsCancellationRequested)
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the listening-ports check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, CancellationToken, ...).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Listening Ports' -Category 'Network' -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $table = $null
    try { $table = Get-OmniListenerTable } catch { $log.Debug("Listener query failed: $($_.Exception.Message)", 'Listening Ports') }
    if ($null -eq $table -or -not $table.Available) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-listening-ports-unavailable' `
            -Title 'Listening ports not available' -Severity 'Information' -Component 'Network/Ports' `
            -Detail 'Get-NetTCPConnection (NetTCPIP module) is not available or could not read the TCP table on this system, so listeners were not checked.')
        return (Complete-OmniResult -Result $result)
    }
    if (Test-OmniListenerCancelled $Context) { return (Complete-OmniResult -Result $result) }

    $raw = @(
        foreach ($t in @($table.Tcp | Where-Object { $null -ne $_ })) { [pscustomobject]@{ Protocol = 'TCP'; Endpoint = $t } }
        foreach ($u in @($table.Udp | Where-Object { $null -ne $_ })) { [pscustomobject]@{ Protocol = 'UDP'; Endpoint = $u } }
    )

    $pids = @($raw | ForEach-Object { $o = Get-OmniListenerProperty $_.Endpoint 'OwningProcess'; if ($null -ne $o) { [int]$o } } | Select-Object -Unique)
    $owners = @{}
    try { $owners = Get-OmniListenerOwner -ProcessId $pids } catch { $log.Debug("Owner lookup failed: $($_.Exception.Message)", 'Listening Ports') }
    if ($null -eq $owners) { $owners = @{} }
    if (Test-OmniListenerCancelled $Context) { return (Complete-OmniResult -Result $result) }

    $records = foreach ($entry in $raw) {
        $proto = $entry.Protocol; $item = $entry.Endpoint
        $procId = Get-OmniListenerProperty $item 'OwningProcess'
        $procId = if ($null -ne $procId) { [int]$procId } else { -1 }
        $owner = if ($owners.ContainsKey($procId)) { $owners[$procId] } else { $null }
        $address = [string](Get-OmniListenerProperty $item 'LocalAddress')
        [pscustomobject][ordered]@{
            Protocol      = $proto
            LocalAddress  = $address
            LocalPort     = [int](Get-OmniListenerProperty $item 'LocalPort')
            AllInterfaces = ($address -in @('0.0.0.0', '::'))
            ProcessId     = $procId
            ProcessName   = $(if ($owner) { [string]$owner.Name } else { '' })
            Path          = $(if ($owner) { [string]$owner.Path } else { '' })
            Company       = $(if ($owner) { [string]$owner.Company } else { '' })
            Services      = $(if ($owner) { (@($owner.Services) | Sort-Object) -join ', ' } else { '' })
            WindowsOwned  = (Test-OmniListenerWindowsOwner -ProcessId $procId -Owner $owner)
        }
    }
    $records = @($records | Sort-Object Protocol, LocalPort, LocalAddress)

    $tcpCount = @($records | Where-Object Protocol -eq 'TCP').Count
    $udpCount = @($records | Where-Object Protocol -eq 'UDP').Count
    $wild = @($records | Where-Object AllInterfaces)
    Set-OmniResultMetric -Result $result -Name 'TcpListenerCount' -Value $tcpCount
    Set-OmniResultMetric -Result $result -Name 'UdpEndpointCount' -Value $udpCount
    Set-OmniResultMetric -Result $result -Name 'AllInterfacesListenerCount' -Value $wild.Count
    Set-OmniResultMetric -Result $result -Name 'Listeners' -Value $records

    # Non-Windows programs listening on every interface (one line per protocol/port/process).
    $thirdParty = @($wild | Where-Object { -not $_.WindowsOwned } | Sort-Object Protocol, LocalPort, ProcessId -Unique)
    if ($thirdParty.Count -gt 0) {
        $lines = ($thirdParty | Select-Object -First 25 | ForEach-Object {
                $who = if ($_.ProcessName) { $_.ProcessName } else { "PID $($_.ProcessId)" }
                $where = if ($_.Path) { " ($($_.Path))" } else { '' }
                '{0} {1}: {2}{3}' -f $_.Protocol, $_.LocalPort, $who, $where
            }) -join '; '
        if ($thirdParty.Count -gt 25) { $lines += ('; and {0} more' -f ($thirdParty.Count - 25)) }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-listening-ports-third-party-all-interfaces' `
            -Title ("{0} non-Microsoft listener(s) on all interfaces" -f $thirdParty.Count) -Severity 'Information' -Component 'Network/Ports' `
            -Detail ("Programs that are not part of Windows accept traffic on every interface (0.0.0.0 or ::): {0}." -f $lines) `
            -Recommendation 'Confirm each program is expected on this device and that the firewall limits who can reach it.' `
            -Data $thirdParty)
    }

    # Well-known remote-access / legacy services exposed on every interface.
    $isServer = $false
    try { $isServer = [bool](Test-OmniListenerServerSku) } catch { $log.Debug("Server SKU check failed: $($_.Exception.Message)", 'Listening Ports') }
    Set-OmniResultMetric -Result $result -Name 'ServerSku' -Value $isServer
    foreach ($risky in $script:OmniRiskyListenPort) {
        $port = [int]$risky.Port
        $hits = @($wild | Where-Object { $_.Protocol -eq 'TCP' -and $_.LocalPort -eq $port })
        if ($hits.Count -eq 0) { continue }
        $svcName = $risky.Service
        $sev = if ($isServer) { $risky.ServerSeverity } else { $risky.Severity }
        $skuNote = if ($isServer -and $risky.ServerSeverity -ne $risky.Severity) { " $svcName is enabled by default on Windows Server, so this is informational here." } else { '' }
        $owner = @($hits | ForEach-Object { if ($_.Services) { "$($_.ProcessName) [$($_.Services)]" } elseif ($_.ProcessName) { $_.ProcessName } else { "PID $($_.ProcessId)" } } | Select-Object -Unique) -join ', '
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id ("network-listening-ports-exposed-{0}" -f $port) `
            -Title ("{0} (TCP {1}) listens on all interfaces" -f $svcName, $port) -Severity $sev -Component 'Network/Ports' `
            -Detail ("TCP port {0} ({1}) is bound to every interface, owned by {2}. Whether it is reachable depends on the Windows Firewall rules for that port.{3}" -f $port, $svcName, $owner, $skuNote) `
            -LikelyCause 'The service is enabled on this device; it accepts connections from any network the firewall allows.' `
            -Confidence 60 `
            -Recommendation ("Confirm the firewall rules for TCP {0} are scoped to trusted networks or addresses (and not the Public profile), or turn the service off if it is not needed." -f $port) `
            -Data $hits)
    }

    $noPath = @($records | Where-Object { -not $_.Path -and -not $_.WindowsOwned } | Select-Object -ExpandProperty ProcessId -Unique)
    if ($noPath.Count -gt 0 -and -not $Context.IsAdmin) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-listening-ports-paths-require-elevation' `
            -Title 'Some listener program paths require elevation' -Severity 'Information' -Component 'Network/Ports' `
            -Detail ("The program path of {0} listening process(es) could not be read as a standard user, so they could not be identified as Windows components." -f $noPath.Count) `
            -Recommendation 'Re-run elevated (requires elevation) for the full owner path and publisher of every listener.')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-listening-ports-reviewed' `
            -Title 'No risky listener exposed on all interfaces' -Severity 'Pass' -Component 'Network/Ports' `
            -Detail ("{0} TCP listener(s) and {1} UDP endpoint(s) reviewed; no FTP, Telnet, RDP, or (on clients) WinRM listener is exposed on every interface." -f $tcpCount, $udpCount))
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
