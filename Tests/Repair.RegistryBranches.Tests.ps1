#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Branch tests for repair discovery and applicability (src/Repair/RepairRegistry.psm1)
    and the step runner (src/Repair/RepairModels.psm1): missing folders, invalid manifests
    and Risk values, duplicate Ids, *.Tests.psm1 exclusion, manifest defaults, the optional
    Test-OmniRepairApplicable hook (true, throwing, no session), the restore-point helper's
    fail-soft paths, and steps run from a context without a logger.

    Fake repairs live in TestDrive and are never executed here, except by the step-runner
    tests, whose actions only touch TestDrive. No real System Restore point is ever
    created: the elevated restore-point test runs only where the SystemRestore WMI class
    does not exist (Windows Server, e.g. the CI runners).
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function New-FakeRepairFile {
        param([string] $Folder, [string] $File, [string] $Manifest, [string] $Extra = '', [string[]] $Export = @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction'))
        if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
        $exportList = ($Export | ForEach-Object { "'$_'" }) -join ', '
        $text = "function Get-OmniRepairManifest { $Manifest }`n" +
            "function Invoke-OmniRepairAction { param(`$Context) throw 'never executed by these tests' }`n" +
            "$Extra`n" +
            "Export-ModuleMember -Function @($exportList)`n"
        Set-Content -LiteralPath (Join-Path $Folder $File) -Value $text -Encoding ascii
    }
    function Get-LogMessage { param($Logger, [string] $Pattern) @($Logger.Buffer | Where-Object { $_.Message -match $Pattern }) }
    function Get-LogText { param($Logger) "log: " + ((@($Logger.Buffer) | ForEach-Object { "[$($_.Level)] $($_.Message)" }) -join " / ") }
}

Describe 'Get-OmniRepair: discovery edge cases' {
    It 'warns about a missing folder and still loads the others' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $good = Join-Path $TestDrive 'disc-good'
        New-FakeRepairFile -Folder $good -File 'RgGood.psm1' -Manifest "@{ Name = 'Rg Good'; Category = 'Test' }"
        $repairs = @(Get-OmniRepair -Path @((Join-Path $TestDrive 'does-not-exist'), $good) -Logger $logger)
        $repairs.Count | Should -Be 1
        $repairs[0].Name | Should -Be 'Rg Good'
        @(Get-LogMessage $logger 'Repair folder not found').Count | Should -Be 1 -Because (Get-LogText $logger)
    }

    It 'rejects a manifest without a Category' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $dir = Join-Path $TestDrive 'disc-nocat'
        New-FakeRepairFile -Folder $dir -File 'RgNoCategory.psm1' -Manifest "@{ Name = 'Rg No Category' }"
        @(Get-OmniRepair -Path $dir -Logger $logger).Count | Should -Be 0
        @(Get-LogMessage $logger 'invalid manifest').Count | Should -Be 1 -Because (Get-LogText $logger)
        @(Get-LogMessage $logger "RgNoCategory\.psm1.*Name and Category are required").Count | Should -Be 1 -Because (Get-LogText $logger)
    }

    It 'rejects an unknown Risk level and names the valid ones' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $dir = Join-Path $TestDrive 'disc-risk'
        New-FakeRepairFile -Folder $dir -File 'RgBadRisk.psm1' -Manifest "@{ Name = 'Rg Bad Risk'; Category = 'Test'; Risk = 'Extreme' }"
        @(Get-OmniRepair -Path $dir -Logger $logger).Count | Should -Be 0
        $msg = @(Get-LogMessage $logger "invalid Risk 'Extreme'")
        $msg.Count | Should -Be 1
        $msg[0].Message | Should -Match 'Safe, Moderate, Destructive'
    }

    It 'keeps the first of two repairs that declare the same Id' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $dir = Join-Path $TestDrive 'disc-dup'
        New-FakeRepairFile -Folder $dir -File 'RgDupA.psm1' -Manifest "@{ Name = 'Rg Dup A'; Id = 'repair.rg-dup'; Category = 'Test' }"
        New-FakeRepairFile -Folder $dir -File 'RgDupB.psm1' -Manifest "@{ Name = 'Rg Dup B'; Id = 'repair.rg-dup'; Category = 'Test' }"
        $repairs = @(Get-OmniRepair -Path $dir -Logger $logger)
        $repairs.Count | Should -Be 1
        $repairs[0].Id | Should -Be 'repair.rg-dup'
        @(Get-LogMessage $logger 'already used by').Count | Should -Be 1 -Because (Get-LogText $logger)
    }

    It 'ignores *.Tests.psm1 files' {
        $dir = Join-Path $TestDrive 'disc-tests'
        New-FakeRepairFile -Folder $dir -File 'RgHelper.Tests.psm1' -Manifest "@{ Name = 'Rg Helper'; Category = 'Test' }"
        @(Get-OmniRepair -Path $dir -Logger (New-OmniLogger -MinimumLevel Error)).Count | Should -Be 0
    }

    It 'writes a warning to the host when no logger is given' {
        $dir = Join-Path $TestDrive 'disc-nologger'
        New-FakeRepairFile -Folder $dir -File 'RgNoLogger.psm1' -Manifest "@{ Name = 'Rg No Logger' }"
        $out = @(Get-OmniRepair -Path $dir 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match "failed to load repair 'RgNoLogger.psm1'"
        @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
    }

    It 'applies the documented manifest defaults' {
        $dir = Join-Path $TestDrive 'disc-defaults'
        New-FakeRepairFile -Folder $dir -File 'RgMinimal.psm1' -Manifest "@{ Name = 'Rg Minimal'; Category = 'Test' }"
        $r = @(Get-OmniRepair -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))[0]
        $r.Id | Should -Be 'repair.rg-minimal'
        $r.Risk | Should -Be 'Safe'
        $r.Description | Should -Be ''
        $r.RequiresAdmin | Should -BeFalse
        $r.RequiresElevation | Should -BeFalse
        $r.NetworkAccess | Should -Be 'None'
        $r.RestorePoint | Should -BeFalse
        $r.RebootHint | Should -BeFalse
        @($r.AppliesTo).Count | Should -Be 0
        $r.Order | Should -Be 100
        $r.Enabled | Should -BeTrue
        $r.HasApplicableTest | Should -BeFalse
        $r.Recommended | Should -BeFalse
    }

    It 'honors Enabled = $false and the declared fields' {
        $dir = Join-Path $TestDrive 'disc-declared'
        New-FakeRepairFile -Folder $dir -File 'RgDeclared.psm1' -Manifest "@{ Name = 'Rg Declared'; Category = 'Test'; Description = 'd'; Risk = 'Destructive'; RestorePoint = `$true; RebootHint = `$true; AppliesTo = @('a', 'b'); Order = 7; Enabled = `$false }"
        $r = @(Get-OmniRepair -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))[0]
        $r.Enabled | Should -BeFalse
        $r.Risk | Should -Be 'Destructive'
        $r.RestorePoint | Should -BeTrue
        $r.RebootHint | Should -BeTrue
        @($r.AppliesTo) -join ',' | Should -Be 'a,b'
        $r.Order | Should -Be 7
        $r.Description | Should -Be 'd'
    }
}

Describe 'Get-OmniApplicableRepair: the optional applicability hook' {
    BeforeAll {
        $script:HookDir = Join-Path $TestDrive 'hooks'
        $export3 = @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction', 'Test-OmniRepairApplicable')
        New-FakeRepairFile -Folder $script:HookDir -File 'RgHookTrue.psm1' -Manifest "@{ Name = 'Rg Hook True'; Category = 'Test' }" `
            -Extra 'function Test-OmniRepairApplicable { param($Session) return (@($Session.Results).Count -gt 0) }' -Export $export3
        New-FakeRepairFile -Folder $script:HookDir -File 'RgHookThrows.psm1' -Manifest "@{ Name = 'Rg Hook Throws'; Category = 'Test' }" `
            -Extra "function Test-OmniRepairApplicable { param(`$Session) throw 'hook failed' }" -Export $export3
        New-FakeRepairFile -Folder $script:HookDir -File 'RgNeedle.psm1' -Manifest "@{ Name = 'Rg Needle'; Category = 'Test'; AppliesTo = @('RG-NEEDLE') }"
        $script:Hooks = @(Get-OmniRepair -Path $script:HookDir -Logger (New-OmniLogger -MinimumLevel Error))

        $r = New-OmniResult -ModuleName 'Rg' -Category 'Test'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Id 'rg-needle-001' -Title 'Needle warning' -Severity 'Warning' -Component 'Test/Other')
        $script:Session = [pscustomobject]@{ PSTypeName = 'OmniDiag.Session'; Results = @((Complete-OmniResult -Result $r)) }
    }

    It 'detects the hook at registration' {
        ($script:Hooks | Where-Object Name -eq 'Rg Hook True').HasApplicableTest | Should -BeTrue
        ($script:Hooks | Where-Object Name -eq 'Rg Needle').HasApplicableTest | Should -BeFalse
    }

    It 'recommends when the hook returns true, and treats a throwing hook as not applicable' {
        $annotated = @(Get-OmniApplicableRepair -Registration $script:Hooks -Session $script:Session)
        ($annotated | Where-Object Name -eq 'Rg Hook True').Recommended | Should -BeTrue
        ($annotated | Where-Object Name -eq 'Rg Hook Throws').Recommended | Should -BeFalse
    }

    It 'matches AppliesTo against finding Ids case-insensitively' {
        $annotated = @(Get-OmniApplicableRepair -Registration $script:Hooks -Session $script:Session)
        ($annotated | Where-Object Name -eq 'Rg Needle').Recommended | Should -BeTrue
    }

    It 'recommends nothing without a session (the hook is not consulted)' {
        $annotated = @(Get-OmniApplicableRepair -Registration $script:Hooks)
        @($annotated | Where-Object Recommended).Count | Should -Be 0
        $annotated.Count | Should -Be 3 -Because 'registrations are annotated, never filtered'
    }
}

Describe 'New-OmniRestorePoint: fail-soft paths' {
    It 'reports Failed (never throws) on an elevated host without System Restore' {
        if ($IsWindows -eq $false) { Set-ItResult -Skipped -Because 'Windows only'; return }
        if (-not (Test-OmniIsAdministrator)) { Set-ItResult -Skipped -Because 'the not-elevated path is covered in Repair.Registry.Tests.ps1'; return }
        $cls = Get-CimClass -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue
        if ($cls) { Set-ItResult -Skipped -Because 'System Restore exists on this host; tests never create a real checkpoint'; return }
        $logger = New-OmniLogger -MinimumLevel Debug
        $status = New-OmniRestorePoint -Description 'OmniDiag test (not created)' -Logger $logger
        $status.Status | Should -Be 'Failed'
        $status.Created | Should -BeFalse
        $status.Protected | Should -BeFalse
        $status.Message | Should -Match 'Could not create a restore point'
        @(Get-LogMessage $logger 'Could not create a restore point').Count | Should -Be 1 -Because (Get-LogText $logger)
    }

    It 'skips with a Windows-only message on other systems' {
        if ($IsWindows -ne $false) { Set-ItResult -Skipped -Because 'non-Windows only'; return }
        $status = New-OmniRestorePoint
        $status.Status | Should -Be 'Skipped'
        $status.Protected | Should -BeFalse
        $status.Message | Should -Match 'Windows-only'
    }
}

Describe 'Repair models: edge cases' {
    It 'lists the risk levels from least to most impactful' {
        (Get-OmniRepairRiskNames) -join ',' | Should -Be 'Safe,Moderate,Destructive'
    }

    It 'a failed step outranks a pending reboot' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        Add-OmniRepairStep -Result $r -Description 'ok' -Succeeded $true
        Add-OmniRepairStep -Result $r -Description 'bad' -Succeeded $false
        $r.RebootRequired = $true
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'Failed'
    }

    It 'a dry-run result stays DryRun even with a failed step recorded' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $r.DryRun = $true
        Add-OmniRepairStep -Result $r -Description 'bad' -Succeeded $false
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'DryRun'
    }

    It 'runs, fails, and dry-runs steps from a context without a logger or token' {
        $plain = [pscustomobject]@{ Logger = $null; DryRun = $false }
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        Invoke-OmniRepairStep -Result $r -Context $plain -Description 'ok' -Action { 'fine' } | Should -BeTrue
        Invoke-OmniRepairStep -Result $r -Context $plain -Description 'throws' -Action { throw 'boom' } | Should -BeFalse
        Invoke-OmniRepairStep -Result $r -Context $plain -Description 'exit 5' -Action { $global:LASTEXITCODE = 5 } | Should -BeFalse
        $r.Steps.Count | Should -Be 3
        $r.Steps[1].Output | Should -Match 'boom'

        $dry = [pscustomobject]@{ Logger = $null; DryRun = $true }
        $d = New-OmniRepairResult -Name 'Y' -Category 'T'
        Invoke-OmniRepairStep -Result $d -Context $dry -Description 'never' -Action { throw 'must not run' } | Should -BeTrue
        $d.Steps[0].Output | Should -Match 'dry-run'
        $global:LASTEXITCODE = 0
    }

    It 'stamps timing on completion' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        Add-OmniRepairStep -Result $r -Description 'a' -Succeeded $true
        $done = Complete-OmniRepairResult -Result $r
        $done.EndTime | Should -BeOfType [datetime]
        $done.DurationMs | Should -BeGreaterOrEqual 0
    }
}
