#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Network group scanners: Routes, Listening Ports, Proxy Configuration (WinHttpSettings
    decoding and the language-independent netsh fallback), WiFi Networks (language-
    independent netsh wlan parsing), and the bounded VPN event query.

    Every data source sits behind a private helper in the plugin; the tests mock those
    helpers inside the plugin's module scope, so every finding path runs on any host.
    Each plugin is copied to TestDrive under a unique file name so its module name is
    unique for Mock -ModuleName. The VPN case mocks Get-WinEvent and needs Windows.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:IsWindowsHost = $true
    try { if ($IsWindows -eq $false) { $script:IsWindowsHost = $false } } catch { $script:IsWindowsHost = $true }

    function Import-PluginCopy {
        param([string] $File, [string] $AsName)
        $dir = Join-Path $TestDrive 'plugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "$AsName.psm1"
        Copy-Item -LiteralPath (Join-Path $script:Root "src/Modules/$File") -Destination $copy -Force
        return (Import-Module -Name $copy -Force -PassThru -DisableNameChecking)
    }

    function New-TestContext {
        param([switch] $Probes, [switch] $Cancelled)
        $token = [System.Threading.CancellationToken]::None
        if ($Cancelled) {
            $cts = [System.Threading.CancellationTokenSource]::new()
            $cts.Cancel()
            $token = $cts.Token
        }
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -NetworkProbes:$Probes -CancellationToken $token
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-FindingById {
        # The unary comma keeps the array: a one-element @() returned from a function is
        # unrolled to the PSCustomObject, which has no .Count on Windows PowerShell 5.1
        # ("Expected 1, but got $null").
        param($Result, [string] $Id)
        return , @($Result.Findings | Where-Object Id -eq $Id)
    }

    function New-WinHttpBlob {
        # Builds a WinHttpSettings value: header, counter, flags, proxy (len+bytes), bypass (len+bytes).
        param([uint32] $Header = 0x18, [uint32] $Counter = 0, [uint32] $Flags = 1, [string] $Proxy = '', [string] $Bypass = '')
        $bytes = [System.Collections.Generic.List[byte]]::new()
        foreach ($d in @($Header, $Counter, $Flags)) { $bytes.AddRange([System.BitConverter]::GetBytes([uint32]$d)) }
        foreach ($s in @($Proxy, $Bypass)) {
            $raw = [System.Text.Encoding]::ASCII.GetBytes($s)
            $bytes.AddRange([System.BitConverter]::GetBytes([uint32]$raw.Length))
            $bytes.AddRange([byte[]]$raw)
        }
        return , $bytes.ToArray()
    }

    $script:RoutesMod = Import-PluginCopy -File 'Routes.psm1' -AsName 'OmniNetTestRoutes'
    $script:PortsMod = Import-PluginCopy -File 'ListeningPorts.psm1' -AsName 'OmniNetTestPorts'
    $script:ProxyMod = Import-PluginCopy -File 'ProxyConfiguration.psm1' -AsName 'OmniNetTestProxy'
    $script:WifiMod = Import-PluginCopy -File 'WifiNetworks.psm1' -AsName 'OmniNetTestWifi'
    $script:VpnMod = Import-PluginCopy -File 'Vpn.psm1' -AsName 'OmniNetTestVpn'
}

AfterAll {
    foreach ($n in @('OmniNetTestRoutes', 'OmniNetTestPorts', 'OmniNetTestProxy', 'OmniNetTestWifi', 'OmniNetTestVpn')) {
        Remove-Module -Name $n -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Routes scanner' {
    It 'declares the contract manifest' {
        $m = & $script:RoutesMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'network.routes'
        $m.Group | Should -Be 'network'
        $m.NetworkAccess | Should -Be 'None'
    }

    It 'reports an unavailable routing table as Information' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable { [pscustomobject]@{ Available = $false; Routes = @() } }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        (Get-FindingById $r 'network-routes-unavailable').Count | Should -Be 1
        $r.Status | Should -Be 'Healthy'
    }

    It 'treats a failing Get-NetRoute as unavailable' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable { throw 'CIM failure' }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        (Get-FindingById $r 'network-routes-unavailable').Count | Should -Be 1
    }

    It 'warns when there is no default route' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'ActiveStore' } -MockWith {
            [pscustomobject]@{ Available = $true; Routes = @(
                    [pscustomobject]@{ DestinationPrefix = '192.168.1.0/24'; NextHop = '0.0.0.0'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 256; InterfaceMetric = 25 }
                    [pscustomobject]@{ DestinationPrefix = 'fe80::/64'; NextHop = '::'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 256; InterfaceMetric = 25 }
                ) }
        }
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'PersistentStore' } -MockWith { [pscustomobject]@{ Available = $true; Routes = @() } }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        $w = Get-FindingById $r 'network-routes-no-default'
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $r.Status | Should -Be 'Warning'
        $r.Metrics['RouteCount'] | Should -Be 2
        $r.Metrics['IPv4RouteCount'] | Should -Be 1
        $r.Metrics['IPv6RouteCount'] | Should -Be 1
        $r.Metrics['DefaultRouteCount'] | Should -Be 0
        (Get-FindingById $r 'network-routes-healthy').Count | Should -Be 0
    }

    It 'passes with one default route and lists persistent routes' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'ActiveStore' } -MockWith {
            [pscustomobject]@{ Available = $true; Routes = @(
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 0; InterfaceMetric = 25 }
                    [pscustomobject]@{ DestinationPrefix = '192.168.1.0/24'; NextHop = '0.0.0.0'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 256; InterfaceMetric = 25 }
                ) }
        }
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'PersistentStore' } -MockWith {
            [pscustomobject]@{ Available = $true; Routes = @(
                    [pscustomobject]@{ DestinationPrefix = '10.0.0.0/8'; NextHop = '192.168.1.254'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 1; InterfaceMetric = 25 }
                ) }
        }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        (Get-FindingById $r 'network-routes-healthy').Count | Should -Be 1
        $p = Get-FindingById $r 'network-routes-persistent'
        $p.Count | Should -Be 1
        $p[0].Severity | Should -Be 'Information'
        $p[0].Detail | Should -Match '10\.0\.0\.0/8'
        $r.Metrics['PersistentRouteCount'] | Should -Be 1
        $r.Metrics['DefaultRouteCount'] | Should -Be 1
        @($r.Metrics['DefaultRoutes'])[0].EffectiveMetric | Should -Be 25
        @($r.Findings | Where-Object { $_.Id -like 'network-routes-ambiguous-*' }).Count | Should -Be 0
        $r.Status | Should -Be 'Healthy'
    }

    It 'flags default routes on two interfaces with the same effective metric' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'ActiveStore' } -MockWith {
            [pscustomobject]@{ Available = $true; Routes = @(
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 0; InterfaceMetric = 35 }
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '10.8.0.1'; InterfaceIndex = 9; InterfaceAlias = 'VPN'; RouteMetric = 10; InterfaceMetric = 25 }
                    [pscustomobject]@{ DestinationPrefix = '::/0'; NextHop = 'fe80::1'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 0; InterfaceMetric = 35 }
                ) }
        }
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'PersistentStore' } -MockWith { [pscustomobject]@{ Available = $true; Routes = @() } }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        $a = Get-FindingById $r 'network-routes-ambiguous-default-ipv4'
        $a.Count | Should -Be 1
        $a[0].Severity | Should -Be 'Information'
        $a[0].Detail | Should -Match 'VPN'
        (Get-FindingById $r 'network-routes-ambiguous-default-ipv6').Count | Should -Be 0
        (Get-FindingById $r 'network-routes-persistent').Count | Should -Be 0
        $r.Metrics['DefaultRouteCount'] | Should -Be 3
    }

    It 'does not flag default routes with different effective metrics' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'ActiveStore' } -MockWith {
            [pscustomobject]@{ Available = $true; Routes = @(
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1'; InterfaceIndex = 5; InterfaceAlias = 'Ethernet'; RouteMetric = 0; InterfaceMetric = 25 }
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.2.1'; InterfaceIndex = 7; InterfaceAlias = 'Wi-Fi'; RouteMetric = 0; InterfaceMetric = 50 }
                ) }
        }
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable -ParameterFilter { $PolicyStore -eq 'PersistentStore' } -MockWith { [pscustomobject]@{ Available = $true; Routes = @() } }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext)
        (Get-FindingById $r 'network-routes-ambiguous-default-ipv4').Count | Should -Be 0
        (Get-FindingById $r 'network-routes-healthy').Count | Should -Be 1
    }

    It 'stops after the first read when the scan is cancelled' {
        Mock -ModuleName OmniNetTestRoutes Get-OmniRouteTable { [pscustomobject]@{ Available = $true; Routes = @() } }
        $r = Invoke-PluginScan -Module $script:RoutesMod -Context (New-TestContext -Cancelled)
        $r.Findings.Count | Should -Be 0
        Should -Invoke -ModuleName OmniNetTestRoutes Get-OmniRouteTable -Times 1 -Exactly
    }

    It 'derives the address family from the prefix and adds the metrics' {
        $rec = & $script:RoutesMod { ConvertTo-OmniRouteRecord -Route ([pscustomobject]@{ DestinationPrefix = '::/0'; NextHop = 'fe80::1'; ifIndex = 3; RouteMetric = 256; InterfaceMetric = 15 }) }
        $rec.AddressFamily | Should -Be 'IPv6'
        $rec.InterfaceIndex | Should -Be 3
        $rec.EffectiveMetric | Should -Be 271
    }
}

Describe 'Listening Ports scanner' {
    It 'declares the contract manifest' {
        $m = & $script:PortsMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'network.listening-ports'
        $m.NetworkAccess | Should -Be 'None'
    }

    It 'reports unavailable listener tables as Information' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable { [pscustomobject]@{ Available = $false; Tcp = @(); Udp = @() } }
        $r = Invoke-PluginScan -Module $script:PortsMod -Context (New-TestContext)
        (Get-FindingById $r 'network-listening-ports-unavailable').Count | Should -Be 1
    }

    It 'warns about RDP on all interfaces and names the hosting service' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable {
            [pscustomobject]@{ Available = $true
                Tcp = @(
                    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3389; OwningProcess = 1200 }
                    [pscustomobject]@{ LocalAddress = '::'; LocalPort = 3389; OwningProcess = 1200 }
                    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 135; OwningProcess = 900 }
                )
                Udp = @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3389; OwningProcess = 1200 })
            }
        }
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerOwner {
            @{
                1200 = [pscustomobject]@{ Name = 'svchost'; Path = 'C:\Windows\System32\svchost.exe'; Company = 'Microsoft Corporation'; Services = @('TermService') }
                900  = [pscustomobject]@{ Name = 'svchost'; Path = 'C:\Windows\System32\svchost.exe'; Company = 'Microsoft Corporation'; Services = @('RpcSs', 'RpcEptMapper') }
            }
        }
        $r = Invoke-PluginScan -Module $script:PortsMod -Context (New-TestContext)
        $w = Get-FindingById $r 'network-listening-ports-exposed-3389'
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match 'TermService'
        $w[0].Recommendation | Should -Match 'firewall'
        (Get-FindingById $r 'network-listening-ports-third-party-all-interfaces').Count | Should -Be 0
        (Get-FindingById $r 'network-listening-ports-reviewed').Count | Should -Be 0
        $r.Status | Should -Be 'Warning'
        $r.Metrics['TcpListenerCount'] | Should -Be 3
        $r.Metrics['UdpEndpointCount'] | Should -Be 1
        $r.Metrics['AllInterfacesListenerCount'] | Should -Be 4
        @($r.Metrics['Listeners']).Count | Should -Be 4
        (@($r.Metrics['Listeners']) | Where-Object LocalPort -eq 135)[0].Services | Should -Be 'RpcEptMapper, RpcSs'
    }

    It 'warns for every risky port on all interfaces' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable {
            [pscustomobject]@{ Available = $true; Udp = @()
                Tcp = @(21, 23, 445, 5985, 5986 | ForEach-Object { [pscustomobject]@{ LocalAddress = '::'; LocalPort = $_; OwningProcess = 4 } })
            }
        }
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerOwner { @{ 4 = [pscustomobject]@{ Name = 'System'; Path = ''; Company = ''; Services = @() } } }
        $r = Invoke-PluginScan -Module $script:PortsMod -Context (New-TestContext)
        foreach ($port in @(21, 23, 445, 5985, 5986)) {
            (Get-FindingById $r "network-listening-ports-exposed-$port").Count | Should -Be 1 -Because "TCP $port"
            $expected = if ($port -eq 445) { 'Information' } else { 'Warning' }
            (Get-FindingById $r "network-listening-ports-exposed-$port")[0].Severity | Should -Be $expected -Because "TCP $port"
        }
        (Get-FindingById $r 'network-listening-ports-exposed-3389').Count | Should -Be 0
        (Get-FindingById $r 'network-listening-ports-third-party-all-interfaces').Count | Should -Be 0
    }

    It 'lists non-Microsoft listeners on all interfaces and ignores loopback ones' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable {
            [pscustomobject]@{ Available = $true
                Tcp = @(
                    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3000; OwningProcess = 5000 }
                    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 5001; OwningProcess = 5001 }
                )
                Udp = @([pscustomobject]@{ LocalAddress = '::'; LocalPort = 5353; OwningProcess = 5000 })
            }
        }
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerOwner {
            @{
                5000 = [pscustomobject]@{ Name = 'node'; Path = 'C:\Program Files\nodejs\node.exe'; Company = 'Node.js'; Services = @() }
                5001 = [pscustomobject]@{ Name = 'devserver'; Path = 'C:\Tools\devserver.exe'; Company = 'Example Ltd'; Services = @() }
            }
        }
        $r = Invoke-PluginScan -Module $script:PortsMod -Context (New-TestContext)
        $i = Get-FindingById $r 'network-listening-ports-third-party-all-interfaces'
        $i.Count | Should -Be 1
        $i[0].Severity | Should -Be 'Information'
        $i[0].Detail | Should -Match 'TCP 3000: node'
        $i[0].Detail | Should -Match 'UDP 5353: node'
        $i[0].Detail | Should -Not -Match 'devserver'
        @($i[0].Data).Count | Should -Be 2
        (Get-FindingById $r 'network-listening-ports-reviewed').Count | Should -Be 1
        $r.Status | Should -Be 'Healthy'
    }

    It 'says when owner paths need elevation for a standard user' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable {
            [pscustomobject]@{ Available = $true; Tcp = @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 8443; OwningProcess = 777 }); Udp = @() }
        }
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerOwner { @{ 777 = [pscustomobject]@{ Name = 'agentsvc'; Path = ''; Company = ''; Services = @('AgentSvc') } } }
        $ctx = New-TestContext
        $ctx.IsAdmin = $false
        $r = Invoke-PluginScan -Module $script:PortsMod -Context $ctx
        $e = Get-FindingById $r 'network-listening-ports-paths-require-elevation'
        $e.Count | Should -Be 1
        $e[0].Recommendation | Should -Match 'requires elevation'
        $ctx.IsAdmin = $true
        $r2 = Invoke-PluginScan -Module $script:PortsMod -Context $ctx
        (Get-FindingById $r2 'network-listening-ports-paths-require-elevation').Count | Should -Be 0
    }

    It 'classifies Windows-owned listeners' {
        $verdicts = & $script:PortsMod {
            @(
                (Test-OmniListenerWindowsOwner -ProcessId 4 -Owner $null)
                (Test-OmniListenerWindowsOwner -ProcessId 900 -Owner ([pscustomobject]@{ Name = 'svchost'; Path = ''; Company = '' }))
                (Test-OmniListenerWindowsOwner -ProcessId 901 -Owner ([pscustomobject]@{ Name = 'x'; Path = 'C:\x.exe'; Company = 'Microsoft Corporation' }))
                (Test-OmniListenerWindowsOwner -ProcessId 902 -Owner ([pscustomobject]@{ Name = 'svchost'; Path = 'C:\Temp\svchost.exe'; Company = '' }))
                (Test-OmniListenerWindowsOwner -ProcessId 903 -Owner ([pscustomobject]@{ Name = 'agent'; Path = ''; Company = '' }))
            )
        }
        $verdicts | Should -Be @($true, $true, $true, $false, $false)
    }

    It 'resolves the current process as an owner without network access' {
        $owners = & $script:PortsMod { param($id) Get-OmniListenerOwner -ProcessId @($id) } $PID
        $owners.ContainsKey($PID) | Should -BeTrue
        $owners[$PID].Name | Should -Not -BeNullOrEmpty
    }

    It 'returns early when the scan is cancelled' {
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerTable { [pscustomobject]@{ Available = $true; Tcp = @(); Udp = @() } }
        Mock -ModuleName OmniNetTestPorts Get-OmniListenerOwner { @{} }
        $r = Invoke-PluginScan -Module $script:PortsMod -Context (New-TestContext -Cancelled)
        $r.Findings.Count | Should -Be 0
        Should -Invoke -ModuleName OmniNetTestPorts Get-OmniListenerOwner -Times 0 -Exactly
    }
}

Describe 'Proxy Configuration: WinHttpSettings decoding' {
    It 'decodes the documented direct-access value' {
        $bytes = [byte[]](0x18, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        $d = & $script:ProxyMod { param($b) ConvertFrom-OmniWinHttpBlob -Bytes $b } $bytes
        $d.Valid | Should -BeTrue
        $d.Version | Should -Be 24
        $d.AccessType | Should -Be 'Direct'
        $d.ProxyServer | Should -Be ''
    }

    It 'decodes a named proxy with a bypass list' {
        $bytes = New-WinHttpBlob -Counter 7 -Flags 3 -Proxy 'proxy.contoso.com:8080' -Bypass 'localhost;*.contoso.com'
        $d = & $script:ProxyMod { param($b) ConvertFrom-OmniWinHttpBlob -Bytes $b } $bytes
        $d.Valid | Should -BeTrue
        $d.Flags | Should -Be 3
        $d.AccessType | Should -Be 'NamedProxy'
        $d.ProxyServer | Should -Be 'proxy.contoso.com:8080'
        $d.BypassList | Should -Be 'localhost;*.contoso.com'
    }

    It 'decodes a per-protocol proxy without a bypass list (header 0x28)' {
        $bytes = New-WinHttpBlob -Header 0x28 -Flags 2 -Proxy 'http=p1:80;https=p2:443'
        $d = & $script:ProxyMod { param($b) ConvertFrom-OmniWinHttpBlob -Bytes $b } $bytes
        $d.Valid | Should -BeTrue
        $d.ProxyServer | Should -Be 'http=p1:80;https=p2:443'
        $d.BypassList | Should -Be ''
    }

    It 'treats a proxy string without the proxy flag as direct access' {
        $bytes = New-WinHttpBlob -Flags 1 -Proxy 'leftover:3128'
        $d = & $script:ProxyMod { param($b) ConvertFrom-OmniWinHttpBlob -Bytes $b } $bytes
        $d.AccessType | Should -Be 'Direct'
        $d.ProxyServer | Should -Be ''
    }

    It 'rejects malformed values: <Case>' -ForEach @(
        @{ Case = 'null'; Hex = $null }
        @{ Case = 'too short'; Hex = '1800000000000000010000000000' }
        @{ Case = 'proxy length past the end'; Hex = '180000000000000003000000FF00000070' + '00000000' }
        @{ Case = 'missing bypass length'; Hex = '18000000000000000300000004000000' + '70707070' }
        @{ Case = 'bypass length past the end'; Hex = '180000000000000003000000010000007005000000' + '7878' }
    ) {
        $bytes = $null
        if ($Hex) { $bytes = [byte[]]@(for ($i = 0; $i -lt $Hex.Length; $i += 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }) }
        $d = & $script:ProxyMod { param($b) ConvertFrom-OmniWinHttpBlob -Bytes $b } $bytes
        $d.Valid | Should -BeFalse
    }
}

Describe 'Proxy Configuration: netsh fallback parsing' {
    It 'parses <Case>' -ForEach @(
        @{ Case = 'English direct access'; Text = "`r`nCurrent WinHTTP proxy settings:`r`n`r`n    Direct access (no proxy server).`r`n"; Access = 'Direct'; Proxy = ''; Bypass = '' }
        @{ Case = 'English named proxy'; Text = "Current WinHTTP proxy settings:`n`n    Proxy Server(s) :  proxy.contoso.com:8080`n    Bypass List     :  localhost;*.contoso.com`n"; Access = 'NamedProxy'; Proxy = 'proxy.contoso.com:8080'; Bypass = 'localhost;*.contoso.com' }
        @{ Case = 'English proxy, no bypass'; Text = "Current WinHTTP proxy settings:`n    Proxy Server(s) :  http=p1:80;https=p2:443`n    Bypass List     :  (none)`n"; Access = 'NamedProxy'; Proxy = 'http=p1:80;https=p2:443'; Bypass = '' }
        @{ Case = 'localized labels'; Text = "Parametres actuels du proxy WinHTTP :`n    Serveur(s) proxy :  proxy.example:3128`n    Liste de contournement :  (aucun)`n"; Access = 'NamedProxy'; Proxy = 'proxy.example:3128'; Bypass = '' }
        @{ Case = 'localized direct access'; Text = "Aktuelle WinHTTP-Proxyeinstellungen:`n    Direkter Zugriff (kein Proxyserver).`n"; Access = 'Direct'; Proxy = ''; Bypass = '' }
    ) {
        $p = & $script:ProxyMod { param($t) ConvertFrom-OmniNetshWinHttpText -Text $t } $Text
        $p.Valid | Should -BeTrue
        $p.AccessType | Should -Be $Access
        $p.ProxyServer | Should -Be $Proxy
        $p.BypassList | Should -Be $Bypass
    }

    It 'reports empty output as invalid' {
        (& $script:ProxyMod { ConvertFrom-OmniNetshWinHttpText -Text '' }).Valid | Should -BeFalse
    }
}

Describe 'Proxy Configuration scanner' {
    BeforeEach {
        Mock -ModuleName OmniNetTestProxy Test-OmniProxyWindowsHost { $true }
        Mock -ModuleName OmniNetTestProxy Invoke-OmniNetshWinHttp { "Current WinHTTP proxy settings:`n    Direct access (no proxy server)." }
    }

    It 'reads WinHTTP from the registry value and does not run netsh' {
        # flags 3, proxy 'p:8', bypass 'x'
        Mock -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue { [byte[]](0x18, 0, 0, 0, 5, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 0x70, 0x3A, 0x38, 1, 0, 0, 0, 0x78) }
        $r = Invoke-PluginScan -Module $script:ProxyMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniNetTestProxy Invoke-OmniNetshWinHttp -Times 0 -Exactly
        $r.Metrics['WinHttpSource'] | Should -Be 'Registry'
        $r.Metrics['WinHttpAccessType'] | Should -Be 'NamedProxy'
        $r.Metrics['WinHttpProxyServer'] | Should -Be 'p:8'
        $r.Metrics['WinHttpBypassList'] | Should -Be 'x'
        $f = Get-FindingById $r 'network-proxy-winhttp-named-proxy'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
    }

    It 'falls back to netsh when the registry value is missing' {
        Mock -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue { $null }
        $r = Invoke-PluginScan -Module $script:ProxyMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniNetTestProxy Invoke-OmniNetshWinHttp -Times 1 -Exactly
        $r.Metrics['WinHttpSource'] | Should -Be 'netsh'
        $r.Metrics['WinHttpAccessType'] | Should -Be 'Direct'
        (Get-FindingById $r 'network-proxy-winhttp-named-proxy').Count | Should -Be 0
        (Get-FindingById $r 'network-proxy-winhttp-undecodable').Count | Should -Be 0
    }

    It 'reports an undecodable value and falls back to netsh' {
        Mock -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue { [byte[]](0x18, 0, 0, 0) }
        $r = Invoke-PluginScan -Module $script:ProxyMod -Context (New-TestContext)
        $u = Get-FindingById $r 'network-proxy-winhttp-undecodable'
        $u.Count | Should -Be 1
        $u[0].Detail | Should -Match 'netsh'
        $r.Metrics['WinHttpSource'] | Should -Be 'netsh'
    }

    It 'reports WinHTTP as unavailable when neither source works' {
        Mock -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue { $null }
        Mock -ModuleName OmniNetTestProxy Invoke-OmniNetshWinHttp { '' }
        $r = Invoke-PluginScan -Module $script:ProxyMod -Context (New-TestContext)
        $r.Metrics['WinHttpSource'] | Should -Be 'Unavailable'
        $r.Metrics['WinHttpSummary'] | Should -Be ''
    }

    It 'returns early off Windows' {
        Mock -ModuleName OmniNetTestProxy Test-OmniProxyWindowsHost { $false }
        Mock -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue { $null }
        $r = Invoke-PluginScan -Module $script:ProxyMod -Context (New-TestContext)
        @($r.Findings | Where-Object Title -eq 'Windows proxy stores are unavailable').Count | Should -Be 1
        Should -Invoke -ModuleName OmniNetTestProxy Get-OmniWinHttpSettingsValue -Times 0 -Exactly
    }
}

Describe 'WiFi Networks: language-independent netsh wlan parsing' {
    BeforeAll {
        $script:WlanEnglish = @'

There is 1 interface on the system:

    Name                   : Wi-Fi
    Description            : Intel(R) Wi-Fi 6 AX201 160MHz
    GUID                   : 0c2b8a1e-1111-2222-3333-444455556666
    Physical address       : aa:bb:cc:dd:ee:ff
    State                  : connected
    BSSID                  : 11:22:33:44:55:66
    SSID                   : CorpWiFi
    Network type           : Infrastructure
    Signal                 : 85%
    Profile                : CorpWiFi

    Hosted network status  : Not available
'@
        $script:WlanLocalized = @'
Il existe 1 interface sur le systeme :

    Nom                    : Wi-Fi
    GUID                   : 0c2b8a1e-1111-2222-3333-444455556666
    Adresse physique       : aa:bb:cc:dd:ee:ff
    Etat                   : connecte
    BSSID                  : 11:22:33:44:55:66
    SSID                   : Cafe: Free
    Signal                 : 30 %
'@
        $script:WlanDisconnected = @'
There is 1 interface on the system:

    Name                   : Wi-Fi
    GUID                   : 0c2b8a1e-1111-2222-3333-444455556666
    Physical address       : aa:bb:cc:dd:ee:ff
    State                  : disconnected
    Radio status           : Hardware On
'@
    }

    It 'parses an English connected interface' {
        $i = & $script:WifiMod { param($t) ConvertFrom-OmniWlanInterfaceText -Text $t } $script:WlanEnglish
        $i.HasInterface | Should -BeTrue
        $i.Connected | Should -BeTrue
        $i.Ssid | Should -Be 'CorpWiFi'
        $i.SignalPercent | Should -Be 85
    }

    It 'parses translated labels (SSID with a colon, "30 %")' {
        $i = & $script:WifiMod { param($t) ConvertFrom-OmniWlanInterfaceText -Text $t } $script:WlanLocalized
        $i.HasInterface | Should -BeTrue
        $i.Ssid | Should -Be 'Cafe: Free'
        $i.SignalPercent | Should -Be 30
    }

    It 'treats an interface without an SSID as disconnected' {
        $i = & $script:WifiMod { param($t) ConvertFrom-OmniWlanInterfaceText -Text $t } $script:WlanDisconnected
        $i.HasInterface | Should -BeTrue
        $i.Connected | Should -BeFalse
        $i.SignalPercent | Should -BeNullOrEmpty
    }

    It 'finds no interface in an error message or empty output' {
        (& $script:WifiMod { ConvertFrom-OmniWlanInterfaceText -Text 'The Wireless AutoConfig Service (wlansvc) is not running.' }).HasInterface | Should -BeFalse
        (& $script:WifiMod { ConvertFrom-OmniWlanInterfaceText -Text '' }).HasInterface | Should -BeFalse
    }
}

Describe 'WiFi Networks scanner' {
    It 'reports a weak connected signal and the nearby network count' {
        Mock -ModuleName OmniNetTestWifi Invoke-OmniWlanNetsh -ParameterFilter { $Arguments -contains 'interfaces' } -MockWith {
            "    Name : Wi-Fi`n    GUID : 0c2b8a1e-1111-2222-3333-444455556666`n    SSID : Office`n    Signal : 30%`n"
        }
        Mock -ModuleName OmniNetTestWifi Invoke-OmniWlanNetsh -ParameterFilter { $Arguments -contains 'networks' } -MockWith {
            "SSID 1 : Office`n    BSSID 1 : 11:22:33:44:55:66`nSSID 2 : Guest`n"
        }
        $r = Invoke-PluginScan -Module $script:WifiMod -Context (New-TestContext)
        (Get-FindingById $r 'network-wifi-connected').Count | Should -Be 1
        $w = Get-FindingById $r 'network-wifi-weak-signal'
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $r.Metrics['NearbyNetworkCount'] | Should -Be 2
        $r.Metrics['ConnectionState'] | Should -Be 'Connected'
        $r.Metrics['CurrentSSID'] | Should -Be 'Office'
    }

    It 'reports a present but disconnected adapter' {
        Mock -ModuleName OmniNetTestWifi Invoke-OmniWlanNetsh -ParameterFilter { $Arguments -contains 'interfaces' } -MockWith {
            "    Name : Wi-Fi`n    GUID : 0c2b8a1e-1111-2222-3333-444455556666`n    State : disconnected`n"
        }
        Mock -ModuleName OmniNetTestWifi Invoke-OmniWlanNetsh -ParameterFilter { $Arguments -contains 'networks' } -MockWith { '' }
        $r = Invoke-PluginScan -Module $script:WifiMod -Context (New-TestContext)
        (Get-FindingById $r 'network-wifi-not-connected').Count | Should -Be 1
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 1
        $r.Metrics['ConnectionState'] | Should -Be 'Disconnected'
    }

    It 'reports no wireless adapter' {
        Mock -ModuleName OmniNetTestWifi Invoke-OmniWlanNetsh { 'There is no wireless interface on the system.' }
        $r = Invoke-PluginScan -Module $script:WifiMod -Context (New-TestContext)
        @($r.Findings | Where-Object Title -eq 'No wireless adapter present').Count | Should -Be 1
    }
}

Describe 'VPN scanner: bounded RasClient query' {
    It 'queries RasClient errors with MaxEvents and a bounded time range' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'Get-WinEvent is Windows-only'; return }
        Mock -ModuleName OmniNetTestVpn Get-WinEvent -ParameterFilter { $ListLog } -MockWith { [pscustomobject]@{ LogName = 'Microsoft-Windows-RasClient/Operational' } }
        Mock -ModuleName OmniNetTestVpn Get-WinEvent -ParameterFilter { $FilterHashtable } -MockWith { 1..3 | ForEach-Object { [pscustomobject]@{ Id = 20227 } } }
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -TimeRange (Get-OmniTimeRange -Start (Get-Date).AddDays(-90))
        $r = Invoke-PluginScan -Module $script:VpnMod -Context $ctx
        Should -Invoke -ModuleName OmniNetTestVpn Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $FilterHashtable -and $MaxEvents -eq 200 -and $FilterHashtable.StartTime -ge (Get-Date).AddDays(-31)
        }
        $r.Metrics['RecentRasClientErrorCount'] | Should -Be 3
        $r.Metrics['RasClientErrorCountCapped'] | Should -BeFalse
        (Get-FindingById $r 'network-vpn-rasclient-errors').Count | Should -Be 1
    }
}
