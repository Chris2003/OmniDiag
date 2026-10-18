#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The repair audit log (OmniDiagData\logs\repair-audit.jsonl), written by the repair
    engine for every applied (non-dry-run) repair step, and the guarantee that a dry run
    performs no action and writes no audit entry. Harmless fake repairs only: a marker
    file proves whether an action scriptblock ran. All data goes to TestDrive.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:OldData = $env:OMNIDIAG_DATA
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    $script:Logger = New-OmniLogger -MinimumLevel Error
    $script:FakeDir = Join-Path $TestDrive 'fake-repairs'
    New-Item -ItemType Directory -Path $script:FakeDir -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $script:FakeDir 'AuditMarker.psm1') -Encoding ascii -Value @'
function Get-OmniRepairManifest { @{ Name = 'Audit Marker'; Category = 'Test'; Risk = 'Safe'; Order = 1 } }
function Invoke-OmniRepairAction {
    param($Context)
    $r = New-OmniRepairResult -Name 'Audit Marker' -Category 'Test'
    $marker = $Context.Config['Marker']
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'write marker file' -Action {
        Set-Content -LiteralPath $marker -Value 'ran' -Force
        'x' * 5000
    } | Out-Null
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'second step' -Action { 'done' } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
'@

    Set-Content -LiteralPath (Join-Path $script:FakeDir 'AuditAdmin.psm1') -Encoding ascii -Value @'
function Get-OmniRepairManifest { @{ Name = 'Audit Admin'; Category = 'Test'; Risk = 'Moderate'; RequiresAdmin = $true; Order = 2 } }
function Invoke-OmniRepairAction {
    param($Context)
    $r = New-OmniRepairResult -Name 'Audit Admin' -Category 'Test'
    $marker = $Context.Config['Marker']
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'admin marker' -Action { Set-Content -LiteralPath $marker -Value 'ran' -Force } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
'@

    $script:Fakes = @(Get-OmniRepair -Path $script:FakeDir -Logger $script:Logger)
    $script:Marker = @($script:Fakes | Where-Object Name -eq 'Audit Marker')
    $script:Admin = @($script:Fakes | Where-Object Name -eq 'Audit Admin')

    # Raw JSON lines of the audit log (none when the file does not exist).
    function Get-AuditLine {
        param([string] $Path = (Get-OmniRepairAuditPath))
        if (-not (Test-Path -LiteralPath $Path)) { return }
        Get-Content -LiteralPath $Path | Where-Object { $_ }
    }
}

AfterAll {
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'Repair audit log' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-OmniRepairAuditPath) -Force -ErrorAction SilentlyContinue
        $script:MarkerFile = Join-Path $TestDrive ('marker-' + [guid]::NewGuid().ToString('N'))
    }

    It 'lives in OmniDiagData\logs\repair-audit.jsonl' {
        Get-OmniRepairAuditPath | Should -Be (Join-Path (Get-OmniDataPath -Kind Logs) 'repair-audit.jsonl')
    }

    It 'a dry run performs no action and writes no audit entry' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun -Config @{ Marker = $script:MarkerFile }
        $session = Invoke-OmniRepair -Registration $script:Marker -Context $ctx
        $session.Results[0].Status | Should -Be 'DryRun'
        Test-Path -LiteralPath $script:MarkerFile | Should -BeFalse -Because 'the action scriptblock must never run in a dry run'
        @(Get-AuditLine).Count | Should -Be 0
    }

    It 'an applied repair runs and appends one JSON line per step' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $script:MarkerFile }
        $session = Invoke-OmniRepair -Registration $script:Marker -Context $ctx
        $session.Results[0].Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $script:MarkerFile | Should -BeTrue

        $raw = @(Get-AuditLine)
        $raw.Count | Should -Be 2
        $lines = @($raw | ForEach-Object { $_ | ConvertFrom-Json })
        $first = $lines[0]
        $first.repairId | Should -Be 'repair.audit-marker'
        $first.repairName | Should -Be 'Audit Marker'
        $first.repairStatus | Should -Be 'Succeeded'
        $first.step | Should -Be 'write marker file'
        $first.succeeded | Should -BeTrue
        $first.dryRun | Should -BeFalse
        $first.user | Should -Not -BeNullOrEmpty
        $first.computer | Should -Not -BeNullOrEmpty
        $first.restorePoint | Should -Be 'NotRequested'
        ([string]$first.output).Length | Should -Be 2000 -Because 'output is truncated to 2000 characters'
        # Checked on the raw text: PowerShell 7's ConvertFrom-Json turns ISO strings into DateTime.
        $raw[0] | Should -Match '"time":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"'
        $raw[0] | Should -Match '"dryRun":false'
        $lines[1].step | Should -Be 'second step'
    }

    It 'appends (never rewrites) across runs' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $script:MarkerFile }
        Invoke-OmniRepair -Registration $script:Marker -Context $ctx | Out-Null
        Invoke-OmniRepair -Registration $script:Marker -Context $ctx | Out-Null
        @(Get-AuditLine).Count | Should -Be 4
    }

    It 'honors AuditLogPath from the repair context' {
        $custom = Join-Path $TestDrive 'custom-audit.jsonl'
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $script:MarkerFile; AuditLogPath = $custom }
        Invoke-OmniRepair -Registration $script:Marker -Context $ctx | Out-Null
        @(Get-AuditLine -Path $custom).Count | Should -Be 2
        @(Get-AuditLine).Count | Should -Be 0
    }

    It 'does not audit a repair that was skipped for elevation' {
        if (Test-OmniIsAdministrator) { Set-ItResult -Skipped -Because 'the test host is elevated'; return }
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $script:MarkerFile }
        $session = Invoke-OmniRepair -Registration $script:Admin -Context $ctx
        $session.Results[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath $script:MarkerFile | Should -BeFalse
        @(Get-AuditLine).Count | Should -Be 0
    }

    It 'does not audit a repair declined through -WhatIf on the engine' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $script:MarkerFile }
        Invoke-OmniRepair -Registration $script:Marker -Context $ctx -WhatIf | Out-Null
        Test-Path -LiteralPath $script:MarkerFile | Should -BeFalse
        @(Get-AuditLine).Count | Should -Be 0
    }
}
