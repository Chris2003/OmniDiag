#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Events group: the known-bad event hints (unexpected shutdowns, disk and file-system
    errors, bug checks) and the grouping / de-duplication of Critical and Error events.
    Synthetic records only, so the suite is OS-independent.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $root 'src/EventLog/EventLogCatalog.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $root 'src/EventLog/EventLogAnalyzer.psm1') -Force -DisableNameChecking -Global

    function New-Rec {
        param([int] $Id, [string] $Provider, [int] $Level, [datetime] $Time, [string] $Msg = 'sample')
        [pscustomobject]@{
            PSTypeName   = 'OmniDiag.EventRecord'
            TimeCreated  = $Time; Id = $Id; ProviderName = $Provider; Level = $Level
            Severity     = (ConvertFrom-OmniEventLevel -Level $Level)
            LogName      = 'System'; Machine = 'PC'; Channel = 'System'; Message = $Msg
        }
    }
}

Describe 'Known-bad event hints' {
    It 'covers <Name> (<Provider> <Id>) with a recommendation' -TestCases @(
        @{ Name = 'unexpected shutdown'; Provider = 'Microsoft-Windows-Kernel-Power'; Id = 41; Severity = 'Critical' }
        @{ Name = 'unexpected shutdown'; Provider = 'EventLog'; Id = 6008; Severity = 'Error' }
        @{ Name = 'bad block'; Provider = 'disk'; Id = 7; Severity = 'Critical' }
        @{ Name = 'controller error'; Provider = 'disk'; Id = 11; Severity = 'Error' }
        @{ Name = 'paging error'; Provider = 'disk'; Id = 51; Severity = 'Warning' }
        @{ Name = 'I/O retried'; Provider = 'disk'; Id = 153; Severity = 'Warning' }
        @{ Name = 'NTFS corruption'; Provider = 'Ntfs'; Id = 55; Severity = 'Critical' }
        @{ Name = 'NTFS transaction manager'; Provider = 'Microsoft-Windows-Ntfs'; Id = 137; Severity = 'Error' }
        @{ Name = 'bug check'; Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Severity = 'Critical' }
        @{ Name = 'bug check (legacy source)'; Provider = 'BugCheck'; Id = 1001; Severity = 'Critical' }
        @{ Name = 'WER report'; Provider = 'Windows Error Reporting'; Id = 1001; Severity = 'Information' }
    ) {
        $m = Resolve-OmniEventMeaning -Id $Id -ProviderName $Provider
        $m | Should -Not -BeNullOrEmpty
        $m.Severity | Should -Be $Severity
        $m.Cause | Should -Not -BeNullOrEmpty
        $m.Recommendation | Should -Not -BeNullOrEmpty
    }

    It 'covers Ntfs 98 without forcing a severity (it is also logged as "volume healthy")' {
        $m = Resolve-OmniEventMeaning -Id 98 -ProviderName 'Microsoft-Windows-Ntfs'
        $m | Should -Not -BeNullOrEmpty
        $m.Severity | Should -BeNullOrEmpty
        $m.Recommendation | Should -Match 'chkdsk'
        $base = Get-Date '2026-06-01T08:00:00'
        $g = @(Group-OmniEventRecord -Record @(
            New-Rec -Id 98 -Provider 'Microsoft-Windows-Ntfs' -Level 4 -Time $base
            New-Rec -Id 98 -Provider 'Microsoft-Windows-Ntfs' -Level 2 -Time $base.AddMinutes(1)
        ))
        ($g | Where-Object EventLevel -eq 'Information').Severity | Should -Be 'Information'
        ($g | Where-Object EventLevel -eq 'Error').Severity | Should -Be 'Error'
    }

    It 'keeps every catalog entry well-formed' {
        foreach ($e in (Get-OmniEventCatalog)) {
            $e.Title | Should -Not -BeNullOrEmpty
            $e.Category | Should -Not -BeNullOrEmpty
            if ($e.Severity) { $e.Severity | Should -BeIn @('Pass', 'Information', 'Warning', 'Error', 'Critical') }
        }
    }
}

Describe 'Grouping and de-duplication of Critical/Error events' {
    BeforeAll {
        $base = Get-Date '2026-06-01T08:00:00'
        $script:Records = @(
            # Three identical Kernel-Power 41 events -> one group, one finding.
            New-Rec -Id 41 -Provider 'Microsoft-Windows-Kernel-Power' -Level 1 -Time $base
            New-Rec -Id 41 -Provider 'Microsoft-Windows-Kernel-Power' -Level 1 -Time $base.AddHours(1)
            New-Rec -Id 41 -Provider 'Microsoft-Windows-Kernel-Power' -Level 1 -Time $base.AddHours(2)
            # Same event id, different providers -> separate groups.
            New-Rec -Id 7 -Provider 'disk' -Level 2 -Time $base
            New-Rec -Id 7 -Provider 'disk' -Level 2 -Time $base.AddMinutes(30)
            New-Rec -Id 7 -Provider 'Contoso-Driver' -Level 2 -Time $base.AddMinutes(10)
        )
        $script:Groups = @(Group-OmniEventRecord -Record $script:Records)
        $script:Findings = @(New-OmniEventFinding -Group $script:Groups)
    }

    It 'collapses identical events into one group with the full count' {
        $kp = @($script:Groups | Where-Object { $_.Id -eq 41 })
        $kp.Count | Should -Be 1
        $kp[0].Count | Should -Be 3
        $kp[0].FirstSeen | Should -Be (Get-Date '2026-06-01T08:00:00')
        $kp[0].LastSeen | Should -Be (Get-Date '2026-06-01T10:00:00')
    }

    It 'groups by provider + event id' {
        $script:Groups.Count | Should -Be 3
        @($script:Groups | Where-Object { $_.Id -eq 7 }).Count | Should -Be 2
        (@($script:Groups | Where-Object { $_.Id -eq 7 -and $_.ProviderName -eq 'disk' }))[0].Count | Should -Be 2
        (@($script:Groups | Where-Object { $_.Id -eq 7 -and $_.ProviderName -eq 'Contoso-Driver' }))[0].Count | Should -Be 1
    }

    It 'emits exactly one per-group finding per group, with a stable Id' {
        $perGroup = @($script:Findings | Where-Object { $_.Id -like 'events.group.*' })
        $perGroup.Count | Should -Be 3
        @($perGroup.Id | Select-Object -Unique).Count | Should -Be 3
        $perGroup.Id | Should -Contain 'events.group.microsoft-windows-kernel-power-41-critical'
        $perGroup.Id | Should -Contain 'events.group.disk-7-error'
        ($perGroup | Where-Object Id -eq 'events.group.microsoft-windows-kernel-power-41-critical').Title | Should -Match '\(x3\)'
    }

    It 'keeps the Id stable when the count changes' {
        $base = Get-Date '2026-06-01T08:00:00'
        $one = @(New-OmniEventFinding -Group @(Group-OmniEventRecord -Record @(New-Rec -Id 7 -Provider 'disk' -Level 2 -Time $base)))
        ($one | Where-Object { $_.Id -like 'events.group.*' }).Id | Should -Be 'events.group.disk-7-error'
    }

    It 'raises the repeated-unexpected-shutdown pattern with a stable Id' {
        $p = @($script:Findings | Where-Object Id -eq 'events.pattern.unexpected-shutdowns')
        $p.Count | Should -Be 1
        $p[0].Severity | Should -Be 'Critical'
    }
}
