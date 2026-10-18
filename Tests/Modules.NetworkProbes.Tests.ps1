#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Connectivity probes are opt-in (decision 1). For the three scanners that can contact
    the network (Network, DNS Resolver, Active Directory), every network call goes through
    a private helper in the plugin; these tests mock that helper inside the plugin's module
    scope and assert it is NOT invoked without probes (an Information finding says how to
    run it) and IS invoked, with the configured targets, when Context.NetworkProbes is set.

    Each plugin is copied to TestDrive under a unique file name so its module name is
    unique for Mock -ModuleName (discovery elsewhere may have loaded 'Network' already).
    The Active Directory case needs Windows (the scanner returns early elsewhere).
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

    function New-ProbeContext {
        param([switch] $Probes, [hashtable] $Config = @{})
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -NetworkProbes:$Probes -Config $Config
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    $script:NetMod = Import-PluginCopy -File 'Network.psm1' -AsName 'OmniProbeTestNetwork'
    $script:DnsMod = Import-PluginCopy -File 'DnsResolver.psm1' -AsName 'OmniProbeTestDns'
    $script:AdMod = Import-PluginCopy -File 'ActiveDirectory.psm1' -AsName 'OmniProbeTestAd'
}

AfterAll {
    foreach ($n in @('OmniProbeTestNetwork', 'OmniProbeTestDns', 'OmniProbeTestAd')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

Describe 'Probe targets and switches' {
    It 'is off unless the context opts in (older contexts count as off)' {
        Test-OmniNetworkProbeEnabled -Context (New-ProbeContext) | Should -BeFalse
        Test-OmniNetworkProbeEnabled -Context (New-ProbeContext -Probes) | Should -BeTrue
        Test-OmniNetworkProbeEnabled -Context ([pscustomobject]@{ Logger = $null }) | Should -BeFalse
        (New-ProbeContext).NetworkProbes | Should -BeFalse
    }

    It 'has sane default targets' {
        $t = Get-OmniProbeTarget -Context (New-ProbeContext)
        $t.PingGateway | Should -BeTrue
        $t.PublicAddress | Should -Be '1.1.1.1'
        $t.DnsName | Should -Be 'www.microsoft.com'
        $t.TimeoutMs | Should -Be 2000
    }

    It 'takes overrides from Config.ProbeTargets' {
        $ctx = New-ProbeContext -Config @{ ProbeTargets = @{ PublicAddress = '9.9.9.9'; DnsName = 'intranet.example'; PingGateway = $false; TimeoutMs = 500; Unknown = 'x' } }
        $t = Get-OmniProbeTarget -Context $ctx
        $t.PublicAddress | Should -Be '9.9.9.9'
        $t.DnsName | Should -Be 'intranet.example'
        $t.PingGateway | Should -BeFalse
        $t.TimeoutMs | Should -Be 500
        $t.PSObject.Properties.Name | Should -Not -Contain 'Unknown'
    }

    It 'builds the standard Information finding' {
        $f = New-OmniProbeSkippedFinding -Component 'Network/Test' -Probe 'ping 1.1.1.1'
        $f.Title | Should -Be 'Connectivity probe not run'
        $f.Severity | Should -Be 'Information'
        $f.Detail | Should -Match 'ping 1\.1\.1\.1'
        $f.Recommendation | Should -Match '--network-probes'
        $f.Recommendation | Should -Match '-NetworkProbes'
    }
}

Describe 'Network scanner' {
    BeforeEach {
        Mock -ModuleName OmniProbeTestNetwork Invoke-OmniNetworkPing { 7 }
        Mock -ModuleName OmniProbeTestNetwork Test-OmniNetworkDnsProbe { $true }
    }

    It 'does not ping or resolve without probes, and says how to run them' {
        $r = Invoke-PluginScan -Module $script:NetMod -Context (New-ProbeContext)
        Should -Invoke -ModuleName OmniProbeTestNetwork Invoke-OmniNetworkPing -Times 0 -Exactly
        Should -Invoke -ModuleName OmniProbeTestNetwork Test-OmniNetworkDnsProbe -Times 0 -Exactly
        $info = @($r.Findings | Where-Object Title -eq 'Connectivity probe not run')
        $info.Count | Should -Be 1
        $info[0].Severity | Should -Be 'Information'
        $r.Metrics['ConnectivityProbesRun'] | Should -BeFalse
        $r.Metrics.Contains('InternetReachable') | Should -BeFalse
    }

    It 'pings the configured public address and resolves the configured name with probes' {
        $ctx = New-ProbeContext -Probes -Config @{ ProbeTargets = @{ PublicAddress = '9.9.9.9'; DnsName = 'intranet.example' } }
        $r = Invoke-PluginScan -Module $script:NetMod -Context $ctx
        Should -Invoke -ModuleName OmniProbeTestNetwork Invoke-OmniNetworkPing -Times 1 -Exactly -ParameterFilter { $Target -eq '9.9.9.9' }
        Should -Invoke -ModuleName OmniProbeTestNetwork Test-OmniNetworkDnsProbe -Times 1 -Exactly -ParameterFilter { $Name -eq 'intranet.example' }
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 0
        $r.Metrics['ConnectivityProbesRun'] | Should -BeTrue
        $r.Metrics['InternetReachable'] | Should -BeTrue
        $r.Metrics['DnsOk'] | Should -BeTrue
    }
}

Describe 'DNS Resolver scanner' {
    BeforeEach {
        Mock -ModuleName OmniProbeTestDns Test-OmniDnsResolverProbe { $true }
    }

    It 'does not resolve without probes, and says how to run the test' {
        $r = Invoke-PluginScan -Module $script:DnsMod -Context (New-ProbeContext)
        Should -Invoke -ModuleName OmniProbeTestDns Test-OmniDnsResolverProbe -Times 0 -Exactly
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 1
        $r.Metrics.Contains('DnsResolutionOk') | Should -BeFalse
    }

    It 'resolves the configured name with probes' {
        $ctx = New-ProbeContext -Probes -Config @{ ProbeTargets = @{ DnsName = 'intranet.example' } }
        $r = Invoke-PluginScan -Module $script:DnsMod -Context $ctx
        Should -Invoke -ModuleName OmniProbeTestDns Test-OmniDnsResolverProbe -Times 1 -Exactly -ParameterFilter { $Name -eq 'intranet.example' }
        $r.Metrics['DnsResolutionOk'] | Should -BeTrue
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 0
    }

    It 'reports a failed resolution as a Warning naming the target' {
        Mock -ModuleName OmniProbeTestDns Test-OmniDnsResolverProbe { $false }
        $r = Invoke-PluginScan -Module $script:DnsMod -Context (New-ProbeContext -Probes)
        $w = @($r.Findings | Where-Object Title -eq 'DNS resolution failed')
        $w.Count | Should -Be 1
        $w[0].Detail | Should -Match 'www\.microsoft\.com'
    }
}

Describe 'Active Directory scanner' {
    BeforeEach {
        if ($script:IsWindowsHost) {
            Mock -ModuleName OmniProbeTestAd Get-CimInstance { [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example' } }
            Mock -ModuleName OmniProbeTestAd Test-OmniAdSecureChannel { $true }
        }
    }

    It 'skips the secure-channel check without probes and says how to run it' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'the scanner returns early off Windows'; return }
        $r = Invoke-PluginScan -Module $script:AdMod -Context (New-ProbeContext)
        Should -Invoke -ModuleName OmniProbeTestAd Test-OmniAdSecureChannel -Times 0 -Exactly
        $info = @($r.Findings | Where-Object Title -eq 'Connectivity probe not run')
        $info.Count | Should -Be 1
        $info[0].Detail | Should -Match 'corp\.example'
    }

    It 'checks the secure channel with probes' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'the scanner returns early off Windows'; return }
        $r = Invoke-PluginScan -Module $script:AdMod -Context (New-ProbeContext -Probes)
        Should -Invoke -ModuleName OmniProbeTestAd Test-OmniAdSecureChannel -Times 1 -Exactly
        $r.Metrics['SecureChannelHealthy'] | Should -BeTrue
    }

    It 'does nothing network-related off Windows' {
        if ($script:IsWindowsHost) { Set-ItResult -Skipped -Because 'Windows host'; return }
        $r = Invoke-PluginScan -Module $script:AdMod -Context (New-ProbeContext -Probes)
        $r.Findings[0].Title | Should -Be 'Active Directory check is Windows-only'
    }
}

Describe 'Through the engine (probes off by default)' {
    It 'runs the network-capable scanners with only local work and the Information finding' {
        $regs = @(Get-OmniModule -Path (Join-Path $script:Root 'src/Modules') -Logger (New-OmniLogger -MinimumLevel Error) |
            Where-Object { $_.Id -in @('network.network', 'network.dns-resolver') })
        $regs.Count | Should -Be 2
        $session = Invoke-OmniSession -Registration $regs -Context (New-ProbeContext)
        foreach ($r in $session.Results) {
            $r.Status | Should -Not -Be 'Failed'
            @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 1 -Because $r.ModuleName
            $r.Metrics['ConnectivityProbesRun'] | Should -BeFalse
        }
    }
}
