#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The curated public PowerShell surface (decision 11): help on every public cmdlet
    (Phase 3 acceptance: Get-Help shows at least one example for every public cmdlet),
    the new cmdlets, and the one-time deprecation warning for the pre-1.0 names.
    Everything runs against TestDrive data and harmless fake repairs and scanners.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:OldData = $env:OMNIDIAG_DATA
    $script:OldOptOut = $env:OMNIDIAG_NO_DEPRECATION_WARNING
    $env:OMNIDIAG_NO_DEPRECATION_WARNING = $null
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $script:Root 'src/OmniDiag.psd1')
    $script:ApiModule = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'PublicApi' } | Select-Object -First 1
    $script:HasRedaction = [bool](Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue)

    # --- Fake scanners --------------------------------------------------------
    $script:Plugins = Join-Path $TestDrive 'plugins'
    New-Item -ItemType Directory -Path $script:Plugins -Force | Out-Null
    $fakes = @(
        # Warns only while OMNIDIAG_API_TOGGLE is 'on', so two scans can differ.
        @{ File = 'FakeWarn.psm1'; Manifest = "Name = 'Api Warn'; Category = 'Test'; Group = 'storage'; Order = 1"; Body = "if (`$env:OMNIDIAG_API_TOGGLE -eq 'on') { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk filling up' -Severity 'Warning' -Component 'Fake/Component') } else { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk fine' -Severity 'Pass' -Component 'Fake/Component') }" }
        @{ File = 'FakePass.psm1'; Manifest = "Name = 'Api Pass'; Category = 'Test'; Group = 'system'; Order = 2"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'all good' -Severity 'Pass')" }
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

    # --- Fake repairs (a marker file proves whether an action ran) ------------
    $script:Repairs = Join-Path $TestDrive 'repairs'
    New-Item -ItemType Directory -Path $script:Repairs -Force | Out-Null
    $script:MarkerFile = Join-Path $TestDrive 'api-marker.txt'
    $markerText = @"
function Get-OmniRepairManifest { @{ Name = 'Api Marker'; Category = 'Test'; Risk = 'Safe'; Order = 1; AppliesTo = @('Fake/Component') } }
function Invoke-OmniRepairAction {
    param(`$Context)
    `$r = New-OmniRepairResult -Name 'Api Marker' -Category 'Test'
    Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'write marker' -Action { Set-Content -LiteralPath '$($script:MarkerFile)' -Value 'ran' -Force } | Out-Null
    return (Complete-OmniRepairResult -Result `$r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
"@
    Set-Content -LiteralPath (Join-Path $script:Repairs 'ApiMarker.psm1') -Value $markerText -Encoding ascii
    Set-Content -LiteralPath (Join-Path $script:Repairs 'ApiReboot.psm1') -Encoding ascii -Value @'
function Get-OmniRepairManifest { @{ Name = 'Api Reboot'; Category = 'Test'; Risk = 'Moderate'; RebootHint = $true; Order = 2 } }
function Invoke-OmniRepairAction {
    param($Context)
    $r = New-OmniRepairResult -Name 'Api Reboot' -Category 'Test'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'noop' -Action { 'ok' } | Out-Null
    if (-not $Context.DryRun) { $r.RebootRequired = $true }
    return (Complete-OmniRepairResult -Result $r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
'@

    # --- Two saved sessions: 'previous' has a warning that 'last' no longer has ----
    $env:OMNIDIAG_API_TOGGLE = 'on'
    $before = Invoke-OmniDiagScan -ModulesPath $script:Plugins -AsSession
    $env:OMNIDIAG_API_TOGGLE = $null
    $after = Invoke-OmniDiagScan -ModulesPath $script:Plugins -AsSession
    $sessions = Get-OmniDataPath -Kind Sessions
    $script:PreviousPath = Save-OmniSession -Session $before -Path (Join-Path $sessions 'session-20260101-000000.json')
    $script:LastPath = Save-OmniSession -Session $after -Path (Join-Path $sessions 'session-20260102-000000.json')
    (Get-Item -LiteralPath $script:PreviousPath).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-2)
    (Get-Item -LiteralPath $script:LastPath).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)

    function Reset-Deprecation { & $script:ApiModule { $script:OmniDeprecationWarned.Clear() } }

    # Runs a command text from a script block with no file behind it (like a user's
    # prompt or script outside OmniDiag) and returns its warnings.
    function Get-ExternalWarning {
        param([string] $Command, [object[]] $ArgumentList = @())
        $sb = [scriptblock]::Create($Command)
        $all = & $sb @ArgumentList 3>&1
        return @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    }
}

AfterAll {
    $env:OMNIDIAG_API_TOGGLE = $null
    $env:OMNIDIAG_DATA = $script:OldData
    $env:OMNIDIAG_NO_DEPRECATION_WARNING = $script:OldOptOut
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'Every public cmdlet has complete help' {
    It '<Cmdlet> is exported and has SYNOPSIS, DESCRIPTION, and an EXAMPLE' -ForEach @(
        @{ Cmdlet = 'Get-OmniDiagModule' }, @{ Cmdlet = 'Get-OmniDiagGroup' }, @{ Cmdlet = 'Invoke-OmniDiagScan' }
        @{ Cmdlet = 'Get-OmniDiagSystem' }, @{ Cmdlet = 'Get-OmniDiagPerformance' }, @{ Cmdlet = 'Get-OmniDiagServices' }
        @{ Cmdlet = 'Get-OmniDiagStartup' }, @{ Cmdlet = 'Get-OmniDiagEvents' }, @{ Cmdlet = 'Get-OmniDiagReliability' }
        @{ Cmdlet = 'Get-OmniDiagStorage' }, @{ Cmdlet = 'Get-OmniDiagNetwork' }, @{ Cmdlet = 'Get-OmniDiagUpdates' }
        @{ Cmdlet = 'Get-OmniDiagSecurity' }, @{ Cmdlet = 'Get-OmniDiagExtras' }
        @{ Cmdlet = 'Invoke-OmniDiagReport' }, @{ Cmdlet = 'Export-OmniDiagReport' }, @{ Cmdlet = 'Import-OmniDiagSession' }
        @{ Cmdlet = 'Compare-OmniDiagSession' }, @{ Cmdlet = 'Get-OmniDiagRepair' }, @{ Cmdlet = 'Invoke-OmniDiagRepair' }
        @{ Cmdlet = 'Show-OmniDiagGui' }
    ) {
        $script:Manifest.FunctionsToExport | Should -Contain $Cmdlet
        Get-Command -Name $Cmdlet -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $help = Get-Help -Name $Cmdlet -Full
        ([string]$help.Synopsis).Trim() | Should -Not -BeNullOrEmpty
        ([string]$help.Synopsis).Trim() | Should -Not -Match "^$([regex]::Escape($Cmdlet))\b" -Because 'an auto-generated synopsis means the comment-based help did not parse'
        (($help.description | ForEach-Object { $_.Text }) -join ' ').Trim() | Should -Not -BeNullOrEmpty
        @($help.examples.example).Count | Should -BeGreaterThan 0
    }

    It 'Invoke-OmniDiagRepair supports -WhatIf and -Confirm with ConfirmImpact High' {
        $cmd = Get-Command Invoke-OmniDiagRepair
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
        $attr = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        [string]$attr.ConfirmImpact | Should -Be 'High'
    }

    It 'keeps the old names exported for one minor version' -ForEach @(
        @{ Name = 'Invoke-OmniDiag' }, @{ Name = 'Export-OmniReport' }, @{ Name = 'Import-OmniSession' }
        @{ Name = 'Compare-OmniSession' }, @{ Name = 'Invoke-OmniRepairCenter' }, @{ Name = 'Invoke-OmniRepair' }
        @{ Name = 'Show-OmniDiagWindow' }, @{ Name = 'Test-OmniOllama' }, @{ Name = 'Invoke-OmniOllamaAnalysis' }
    ) {
        $script:Manifest.FunctionsToExport | Should -Contain $Name
        Get-Command -Name $Name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'keeps the plugin SDK exported' -ForEach @(
        @{ Name = 'New-OmniFinding' }, @{ Name = 'New-OmniResult' }, @{ Name = 'Add-OmniFinding' }, @{ Name = 'Set-OmniResultMetric' }
        @{ Name = 'Complete-OmniResult' }, @{ Name = 'Get-OmniSeverityRank' }, @{ Name = 'Get-OmniSeverityNames' }
        @{ Name = 'Get-OmniDataPath' }, @{ Name = 'Get-OmniDataRoot' }, @{ Name = 'Get-OmniToolRoot' }, @{ Name = 'Get-OmniTimeRange' }
        @{ Name = 'New-OmniRepairResult' }, @{ Name = 'Invoke-OmniRepairStep' }, @{ Name = 'Add-OmniRepairStep' }
        @{ Name = 'Complete-OmniRepairResult' }, @{ Name = 'New-OmniProbeSkippedFinding' }, @{ Name = 'Get-OmniProbeTarget' }
        @{ Name = 'Test-OmniNetworkProbeEnabled' }, @{ Name = 'Get-OmniSystemInventory' }, @{ Name = 'Get-OmniInvalidRegistryEntry' }
        @{ Name = 'Export-OmniRegistryBackup' }, @{ Name = 'Remove-OmniRegistryEntry' }
    ) {
        $script:Manifest.FunctionsToExport | Should -Contain $Name
    }

    It 'is version 0.8.0' {
        $script:Manifest.ModuleVersion | Should -Be '0.8.0'
    }
}

Describe 'Deprecation warnings' {
    BeforeEach {
        Reset-Deprecation
        $env:OMNIDIAG_NO_DEPRECATION_WARNING = $null
    }
    AfterEach { $env:OMNIDIAG_NO_DEPRECATION_WARNING = $null }

    It 'warns once per session when a user calls an old name' {
        $first = Get-ExternalWarning -Command 'Import-OmniSession -Path $args[0] | Out-Null' -ArgumentList @($script:LastPath)
        @($first).Count | Should -Be 1
        $first[0] | Should -BeLike 'Import-OmniSession is deprecated; use Import-OmniDiagSession*'
        $second = Get-ExternalWarning -Command 'Import-OmniSession -Path $args[0] | Out-Null' -ArgumentList @($script:LastPath)
        @($second).Count | Should -Be 0
    }

    It 'names the replacement for <Old>' -ForEach @(
        @{ Old = 'Compare-OmniSession'; New = 'Compare-OmniDiagSession'; Command = 'Compare-OmniSession -Before $args[0] -After $args[1] | Out-Null' }
        @{ Old = 'Invoke-OmniRepairCenter'; New = 'Get-OmniDiagRepair'; Command = 'Invoke-OmniRepairCenter -RepairsPath $args[2] | Out-Null' }
    ) {
        $w = Get-ExternalWarning -Command $Command -ArgumentList @($script:PreviousPath, $script:LastPath, $script:Repairs)
        @($w).Count | Should -Be 1
        $w[0] | Should -BeLike "$Old is deprecated; use $New*"
    }

    It 'is silenced by OMNIDIAG_NO_DEPRECATION_WARNING' {
        $env:OMNIDIAG_NO_DEPRECATION_WARNING = '1'
        @(Get-ExternalWarning -Command 'Import-OmniSession -Path $args[0] | Out-Null' -ArgumentList @($script:LastPath)).Count | Should -Be 0
    }

    It 'does not warn when the new cmdlets call the old implementations' {
        $w = Get-ExternalWarning -Command 'Compare-OmniDiagSession -Before $args[0] -After $args[1] | Out-Null; Import-OmniDiagSession -Path $args[1] | Out-Null; Get-OmniDiagRepair -RepairsPath $args[2] | Out-Null' `
            -ArgumentList @($script:PreviousPath, $script:LastPath, $script:Repairs)
        @($w).Count | Should -Be 0
    }

    It 'does not warn when the CLI router uses them' {
        $out = [System.IO.StringWriter]::new(); $err = [System.IO.StringWriter]::new()
        $all = & { Invoke-OmniDiagCli -Arguments @('compare', 'previous', 'last', '--format', 'json') -Out $out -Err $err } 3>&1
        @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        @($all | Where-Object { $_ -is [int] }) | Should -Be @(0)
    }
}

Describe 'Sessions: Import-OmniDiagSession and Compare-OmniDiagSession' {
    It "resolves 'last' and 'previous' to the newest saved sessions" {
        Resolve-OmniSessionPath -Value last | Should -Be $script:LastPath
        Resolve-OmniSessionPath -Value Previous | Should -Be $script:PreviousPath
        (Import-OmniDiagSession -Path last).SourcePath | Should -Be $script:LastPath
    }

    It 'accepts pipeline input from Get-ChildItem' {
        $loaded = @(Get-ChildItem -LiteralPath (Split-Path $script:LastPath) -Filter 'session-2026010*.json' | Import-OmniDiagSession)
        $loaded.Count | Should -Be 2
    }

    It 'throws a clear error for a missing path' {
        { Import-OmniDiagSession -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }

    It 'compares previous with last' {
        $c = Compare-OmniDiagSession -Before previous -After last
        $c.PSTypeNames | Should -Contain 'OmniDiag.SessionComparison'
        $c.Verdict | Should -Be 'Improved'
        @($c.Resolved).Count | Should -Be 1
        @($c.New).Count | Should -Be 0
        $c.ScoreDelta | Should -BeGreaterThan 0
    }
}

Describe 'Repairs: Get-OmniDiagRepair and Invoke-OmniDiagRepair' {
    BeforeEach {
        Remove-Item -LiteralPath $script:MarkerFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-OmniRepairAuditPath) -Force -ErrorAction SilentlyContinue
    }

    It 'lists repairs with ids, risk, and recommendations for a session' {
        $all = @(Get-OmniDiagRepair -RepairsPath $script:Repairs)
        @($all.Id) | Should -Be @('repair.api-marker', 'repair.api-reboot')
        $rec = @(Get-OmniDiagRepair -RepairsPath $script:Repairs -Session previous -RecommendedOnly)
        @($rec.Id) | Should -Be @('repair.api-marker')
        @(Get-OmniDiagRepair -RepairsPath $script:Repairs -Id api-reboot).Name | Should -Be 'Api Reboot'
    }

    It '-WhatIf is a dry run: no action runs and nothing is audited' {
        $s = Invoke-OmniDiagRepair -Id api-marker -RepairsPath $script:Repairs -WhatIf
        $s.DryRun | Should -BeTrue
        $s.Results[0].Status | Should -Be 'DryRun'
        $s.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:MarkerFile | Should -BeFalse
        Test-Path -LiteralPath (Get-OmniRepairAuditPath) | Should -BeFalse
    }

    It '-Confirm:$false applies the repair and audits it' {
        $s = Invoke-OmniDiagRepair -Id repair.api-marker -RepairsPath $script:Repairs -Confirm:$false
        $s.Results[0].Status | Should -Be 'Succeeded'
        $s.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:MarkerFile | Should -BeTrue
        @(Get-Content -LiteralPath (Get-OmniRepairAuditPath)).Count | Should -Be 1
    }

    It '-Force applies without prompting and reports exit code 12 for a reboot' {
        $s = Invoke-OmniDiagRepair -Id 'Api Reboot' -RepairsPath $script:Repairs -Force
        $s.Results[0].Status | Should -Be 'RebootRequired'
        $s.ExitCode | Should -Be 12
    }

    It 'takes pipeline input from Get-OmniDiagRepair' {
        $s = Get-OmniDiagRepair -RepairsPath $script:Repairs -Id api-marker | Invoke-OmniDiagRepair -RepairsPath $script:Repairs -WhatIf
        @($s.Results).Count | Should -Be 1
        Test-Path -LiteralPath $script:MarkerFile | Should -BeFalse
    }

    It 'rejects unknown repair ids' {
        { Invoke-OmniDiagRepair -Id no-such-repair -RepairsPath $script:Repairs -WhatIf } | Should -Throw '*Unknown repair*'
    }
}

Describe 'Reports: Export-OmniDiagReport and Invoke-OmniDiagReport' {
    It 'exports a saved session by path, with -Bundle adding the .zip package' {
        $dir = Join-Path $TestDrive 'export'
        $set = Export-OmniDiagReport -Session last -OutputDirectory $dir -Format Json -Bundle
        @($set.Files | Where-Object { $_ -like '*.json' }).Count | Should -Be 1
        @($set.Files | Where-Object { $_ -like '*.zip' }).Count | Should -Be 1
    }

    It 'runs a scan and writes HTML + JSON by default' {
        $dir = Join-Path $TestDrive 'invoke-report'
        $env:OMNIDIAG_API_TOGGLE = 'on'
        try { $set = Invoke-OmniDiagReport -ModulesPath $script:Plugins -Group storage -OutputDirectory $dir }
        finally { $env:OMNIDIAG_API_TOGGLE = $null }
        @($set.Files | Where-Object { $_ -like '*.html' }).Count | Should -Be 1
        @($set.Files | Where-Object { $_ -like '*.json' }).Count | Should -Be 1
        $set.ExitCode | Should -Be 1
        $set.Session.PSTypeNames | Should -Contain 'OmniDiag.Session'
    }

    It '-Redact fails clearly when the redaction module is missing' {
        if ($script:HasRedaction) { Set-ItResult -Skipped -Because 'the redaction module is present'; return }
        { Export-OmniDiagReport -Session last -OutputDirectory (Join-Path $TestDrive 'r') -Redact } | Should -Throw '*Redaction is not available*'
    }

    It '-Redact removes the computer name from the JSON report' {
        if (-not $script:HasRedaction) { Set-ItResult -Skipped -Because 'New-OmniRedactionContext is not available in this build'; return }
        $dir = Join-Path $TestDrive 'redacted'
        $session = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group storage -AsSession
        $set = Export-OmniDiagReport -Session $session -OutputDirectory $dir -Format Json -Redact
        $json = Get-Content -LiteralPath @($set.Files)[0] -Raw
        $json | Should -Not -Match ([regex]::Escape([System.Environment]::MachineName))
    }
}

Describe 'Invoke-OmniDiagScan selections' {
    It 'runs a role profile and records it on the session' {
        $s = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Profile Full -AsSession
        $s.ScanPlan.Name | Should -Be 'Full'
    }

    It 'rejects -Profile with -Group' {
        { Invoke-OmniDiagScan -ModulesPath $script:Plugins -Profile Full -Group storage } | Should -Throw '*Do not combine*'
    }

    It '-ElevatedOnly needs an elevated process' {
        if (Test-OmniIsAdministrator) { Set-ItResult -Skipped -Because 'the test host is elevated'; return }
        { Invoke-OmniDiagScan -ModulesPath $script:Plugins -ElevatedOnly } | Should -Throw '*administrator*'
    }
}

Describe 'Show-OmniDiagGui' {
    It 'refuses to start on a non-Windows host' {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { Set-ItResult -Skipped -Because 'this is Windows'; return }
        { Show-OmniDiagGui } | Should -Throw '*needs Windows*'
    }
}
