#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Public group cmdlets (src/Core/Groups.psm1): Get-OmniDiagGroup, Get-OmniDiagModule,
    Invoke-OmniDiagScan, and the Get-OmniDiag<Group> wrappers. Scans run against a
    TestDrive folder of fake scanners, so every assertion is OS-independent; listing
    checks also run against the built-in scanners. Data (logs) goes to TestDrive.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:BuiltIn = Join-Path $script:Root 'src/Modules'

    $script:OldData = $env:OMNIDIAG_DATA
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    $script:Plugins = Join-Path $TestDrive 'plugins'
    New-Item -ItemType Directory -Path $script:Plugins -Force | Out-Null
    $fakes = @(
        @{ File = 'GrpPass.psm1';  Manifest = "Name = 'Grp Pass'; Category = 'Test'; Group = 'system'; Order = 1"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'all good' -Severity 'Pass')" }
        @{ File = 'GrpWarn.psm1';  Manifest = "Name = 'Grp Warn'; Category = 'Test'; Group = 'storage'; Order = 2"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk filling up' -Severity 'Warning'); Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'volume ok' -Severity 'Pass')" }
        @{ File = 'GrpNet.psm1';   Manifest = "Name = 'Grp Net'; Category = 'Test'; Group = 'network'; NetworkAccess = 'Internet'; Order = 3"; Body = "if (Test-OmniNetworkProbeEnabled -Context `$Context) { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'probed' -Severity 'Pass') } else { Add-OmniFinding -Result `$r -Finding (New-OmniProbeSkippedFinding -Component 'Network/Test' -Probe 'ping the test target') }" }
        @{ File = 'GrpAdmin.psm1'; Manifest = "Name = 'Grp Admin'; Category = 'Test'; Group = 'security'; RequiresAdmin = `$true; Order = 4"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'admin ok' -Severity 'Pass')" }
    )
    foreach ($f in $fakes) {
        $text = @"
function Get-OmniModuleManifest { @{ $($f.Manifest) } }
function Invoke-OmniModuleScan {
    param(`$Context)
    `$m = Get-OmniModuleManifest
    `$r = New-OmniResult -ModuleName `$m.Name -Category `$m.Category
    $($f.Body)
    return (Complete-OmniResult -Result `$r)
}
Export-ModuleMember -Function 'Get-OmniModuleManifest', 'Invoke-OmniModuleScan'
"@
        Set-Content -LiteralPath (Join-Path $script:Plugins $f.File) -Value $text -Encoding ascii
    }

    $script:GroupCmdlets = [ordered]@{
        system = 'Get-OmniDiagSystem'; performance = 'Get-OmniDiagPerformance'; services = 'Get-OmniDiagServices'
        startup = 'Get-OmniDiagStartup'; events = 'Get-OmniDiagEvents'; reliability = 'Get-OmniDiagReliability'
        storage = 'Get-OmniDiagStorage'; network = 'Get-OmniDiagNetwork'; updates = 'Get-OmniDiagUpdates'
        security = 'Get-OmniDiagSecurity'; extras = 'Get-OmniDiagExtras'
    }
}

AfterAll {
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'Get-OmniDiagGroup' {
    It 'lists the eleven groups in order with their built-in scanners' {
        $groups = @(Get-OmniDiagGroup)
        @($groups.Id) | Should -Be @(Get-OmniGroupNames)
        foreach ($g in $groups) {
            $g.PSTypeNames | Should -Contain 'OmniDiag.GroupInfo'
            $g.Name | Should -Not -BeNullOrEmpty
            $g.Description | Should -Not -BeNullOrEmpty
            $g.ScannerCount | Should -Be @($g.ScannerIds).Count
            $g.ScannerCount | Should -BeGreaterThan 0 -Because "group '$($g.Id)' has built-in scanners"
            foreach ($id in $g.ScannerIds) { $id | Should -BeLike "$($g.Id).*" }
        }
        ($groups | Measure-Object -Property ScannerCount -Sum).Sum | Should -Be @(Get-OmniModule -Path $script:BuiltIn -Logger (New-OmniLogger -MinimumLevel Error)).Count
    }

    It 'filters by id' {
        $g = @(Get-OmniDiagGroup -Id network)
        $g.Count | Should -Be 1
        $g[0].ScannerIds | Should -Contain 'network.dns-resolver'
    }
}

Describe 'Get-OmniDiagModule' {
    It 'returns clean registration objects' {
        $m = @(Get-OmniDiagModule -Id 'network.dns-resolver')
        $m.Count | Should -Be 1
        $m[0].PSTypeNames | Should -Contain 'OmniDiag.ModuleInfo'
        foreach ($p in @('Id', 'Name', 'Group', 'Category', 'Description', 'RequiresElevation', 'NetworkAccess')) {
            $m[0].PSObject.Properties.Name | Should -Contain $p
        }
        $m[0].PSObject.Properties.Name | Should -Not -Contain 'ModuleInfo'
        $m[0].NetworkAccess | Should -Be 'Internet'
    }

    It 'filters by group and by id wildcard' {
        $net = @(Get-OmniDiagModule -Group network)
        $net.Count | Should -BeGreaterThan 0
        foreach ($m in $net) { $m.Group | Should -Be 'network' }
        foreach ($m in @(Get-OmniDiagModule -Id 'storage.*')) { $m.Id | Should -BeLike 'storage.*' }
    }

    It 'rejects an unknown group' {
        { Get-OmniDiagModule -Group gaming } | Should -Throw '*Unknown group*'
    }
}

Describe 'Invoke-OmniDiagScan' {
    It 'writes v1 finding objects and leaves passing checks out by default' {
        $f = @(Invoke-OmniDiagScan -ModulesPath $script:Plugins -WarningAction SilentlyContinue)
        $f.Count | Should -BeGreaterThan 0
        foreach ($x in $f) {
            $x.PSTypeNames | Should -Contain 'OmniDiag.V1.Finding'
            $x.passed | Should -BeFalse
            $x.severity | Should -BeIn @('Info', 'Warning', 'Critical')
            foreach ($p in @('id', 'moduleId', 'group', 'severity', 'severityNative', 'passed', 'title', 'recommendation')) {
                $x.PSObject.Properties.Name | Should -Contain $p
            }
        }
        $warn = @($f | Where-Object title -eq 'disk filling up')
        $warn.Count | Should -Be 1
        $warn[0].moduleId | Should -Be 'storage.grp-warn'
        $warn[0].group | Should -Be 'storage'
        $warn[0].severityNative | Should -Be 'Warning'
        @($f | Where-Object title -eq 'volume ok').Count | Should -Be 0
    }

    It 'includes passing checks with -IncludePassed' {
        $f = @(Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group storage -IncludePassed)
        @($f.title) | Should -Be @('disk filling up', 'volume ok')
        ($f | Where-Object title -eq 'volume ok').passed | Should -BeTrue
    }

    It 'keeps probes off unless -NetworkProbes' {
        @((Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group network).title) | Should -Be @('Connectivity probe not run')
        @((Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group network -NetworkProbes -IncludePassed).title) | Should -Be @('probed')
    }

    It 'returns the native session with -AsSession' {
        $s = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Module 'system.grp-pass' -AsSession
        $s.PSTypeNames | Should -Contain 'OmniDiag.Session'
        @($s.Results.ModuleId) | Should -Be @('system.grp-pass')
        $s.LogPath | Should -Exist
        Get-OmniExitCode -Session $s | Should -Be 0
    }

    It 'combines -Group and -Module, and accepts display names' {
        $s = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group storage -Module 'Grp Pass' -AsSession
        @($s.Results.ModuleId) | Should -Be @('system.grp-pass', 'storage.grp-warn')
    }

    It 'reports a skipped module through its finding and a warning' {
        $f = @(Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group security -WarningVariable w -WarningAction SilentlyContinue)
        if (Test-OmniIsAdministrator) { Set-ItResult -Skipped -Because 'the test host is elevated'; return }
        $f.Count | Should -Be 1
        $f[0].skippedReason | Should -Be 'RequiresElevation'
        $f[0].moduleStatus | Should -Be 'Skipped'
        ($w -join ' ') | Should -Match 'security\.grp-admin \(RequiresElevation\)'
    }

    It 'rejects unknown groups and modules' {
        { Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group gaming } | Should -Throw '*Unknown group*'
        { Invoke-OmniDiagScan -ModulesPath $script:Plugins -Module nope.nothing } | Should -Throw '*Unknown module*'
    }
}

Describe 'Get-OmniDiag<Group> cmdlets' {
    It '<Cmdlet> exists, is exported, and has help with an example' -ForEach @(
        @{ Cmdlet = 'Get-OmniDiagSystem' }, @{ Cmdlet = 'Get-OmniDiagPerformance' }, @{ Cmdlet = 'Get-OmniDiagServices' }
        @{ Cmdlet = 'Get-OmniDiagStartup' }, @{ Cmdlet = 'Get-OmniDiagEvents' }, @{ Cmdlet = 'Get-OmniDiagReliability' }
        @{ Cmdlet = 'Get-OmniDiagStorage' }, @{ Cmdlet = 'Get-OmniDiagNetwork' }, @{ Cmdlet = 'Get-OmniDiagUpdates' }
        @{ Cmdlet = 'Get-OmniDiagSecurity' }, @{ Cmdlet = 'Get-OmniDiagExtras' }
        @{ Cmdlet = 'Get-OmniDiagGroup' }, @{ Cmdlet = 'Get-OmniDiagModule' }, @{ Cmdlet = 'Invoke-OmniDiagScan' }
    ) {
        $cmd = Get-Command -Name $Cmdlet -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        (Import-PowerShellDataFile -Path (Join-Path $script:Root 'src/OmniDiag.psd1')).FunctionsToExport | Should -Contain $Cmdlet
        $help = Get-Help -Name $Cmdlet -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        @($help.examples.example).Count | Should -BeGreaterThan 0
    }

    It 'covers every group with one cmdlet' {
        @($script:GroupCmdlets.Keys) | Should -Be @(Get-OmniGroupNames)
    }

    It 'runs only its group' {
        $f = @(Get-OmniDiagStorage -ModulesPath $script:Plugins -IncludePassed)
        @($f.group | Select-Object -Unique) | Should -Be @('storage')
        @(Get-OmniDiagSystem -ModulesPath $script:Plugins).Count | Should -Be 0 -Because 'the only system finding passes'
        @(Get-OmniDiagSystem -ModulesPath $script:Plugins -IncludePassed).Count | Should -Be 1
    }

    It 'passes -NetworkProbes through (network and extras)' {
        @((Get-OmniDiagNetwork -ModulesPath $script:Plugins -NetworkProbes -IncludePassed).title) | Should -Be @('probed')
        (Get-Command Get-OmniDiagExtras).Parameters.Keys | Should -Contain 'NetworkProbes'
        (Get-Command Get-OmniDiagStorage).Parameters.Keys | Should -Not -Contain 'NetworkProbes'
    }

    It 'returns a session with -AsSession' {
        (Get-OmniDiagStorage -ModulesPath $script:Plugins -AsSession).PSTypeNames | Should -Contain 'OmniDiag.Session'
    }
}
