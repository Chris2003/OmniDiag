#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the Event Log analyzer using synthetic records (OS-independent:
    no real Windows event logs are touched).
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $root 'src/EventLog/EventLogCatalog.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $root 'src/EventLog/EventLogAnalyzer.psm1') -Force -DisableNameChecking -Global

    function New-Rec {
        param([int]$Id, [string]$Provider, [int]$Level, [datetime]$Time,
              [string]$Msg = 'sample', [string]$Channel = 'System', [string]$LogName = 'System')
        [pscustomobject]@{
            PSTypeName = 'OmniDiag.EventRecord'
            TimeCreated = $Time; Id = $Id; ProviderName = $Provider; Level = $Level
            Severity = (ConvertFrom-OmniEventLevel -Level $Level)
            LogName = $LogName; Machine = 'PC'; Channel = $Channel; Message = $Msg
        }
    }
}

Describe 'ConvertFrom-OmniEventLevel' {
    It 'maps level numbers to severities' {
        ConvertFrom-OmniEventLevel -Level 1 | Should -Be 'Critical'
        ConvertFrom-OmniEventLevel -Level 2 | Should -Be 'Error'
        ConvertFrom-OmniEventLevel -Level 3 | Should -Be 'Warning'
        ConvertFrom-OmniEventLevel -Level 4 | Should -Be 'Information'
    }
}

Describe 'Group-OmniEventRecord' {
    BeforeAll {
        $base = Get-Date '2026-06-01T08:00:00'
        $script:records = @(
            New-Rec -Id 4625 -Provider 'Microsoft-Windows-Security-Auditing' -Level 4 -Time $base
            New-Rec -Id 4625 -Provider 'Microsoft-Windows-Security-Auditing' -Level 4 -Time $base.AddMinutes(5)
            New-Rec -Id 4625 -Provider 'Microsoft-Windows-Security-Auditing' -Level 4 -Time $base.AddMinutes(10)
            New-Rec -Id 55   -Provider 'Ntfs' -Level 1 -Time $base.AddMinutes(2)
        )
        $script:groups = Group-OmniEventRecord -Record $script:records
    }

    It 'collapses repeats into one group with the right count' {
        $g = $script:groups | Where-Object Id -eq 4625
        $g.Count | Should -Be 3
    }
    It 'computes first and last seen' {
        $g = $script:groups | Where-Object Id -eq 4625
        $g.FirstSeen | Should -Be (Get-Date '2026-06-01T08:00:00')
        $g.LastSeen  | Should -Be (Get-Date '2026-06-01T08:10:00')
    }
    It 'applies the catalog severity override (4625 Information -> Warning)' {
        ($script:groups | Where-Object Id -eq 4625).Severity | Should -Be 'Warning'
    }
    It 'sorts the most severe group first' {
        $script:groups[0].Id | Should -Be 55   # Critical NTFS corruption outranks Warning logons
    }
    It 'enriches known events with a category' {
        ($script:groups | Where-Object Id -eq 55).Category | Should -Be 'Disk'
    }
}

Describe 'Get-OmniEventTimeline' {
    It 'keeps only major lifecycle events' {
        $base = Get-Date '2026-06-01T08:00:00'
        $recs = @(
            New-Rec -Id 6005 -Provider 'EventLog' -Level 4 -Time $base
            New-Rec -Id 41   -Provider 'Microsoft-Windows-Kernel-Power' -Level 1 -Time $base.AddHours(1)
            New-Rec -Id 1000 -Provider 'Application Error' -Level 2 -Time $base.AddHours(2)  # not a timeline event
        )
        $tl = Get-OmniEventTimeline -Record $recs
        $tl | Should -HaveCount 2
        $tl[0].Id | Should -Be 41   # newest first
    }
}

Describe 'New-OmniEventFinding' {
    It 'raises a Critical brute-force pattern for many failed logons' {
        $base = Get-Date '2026-06-01T08:00:00'
        $recs = 1..12 | ForEach-Object {
            New-Rec -Id 4625 -Provider 'Microsoft-Windows-Security-Auditing' -Level 4 -Time $base.AddMinutes($_)
        }
        $groups = Group-OmniEventRecord -Record $recs
        $findings = New-OmniEventFinding -Group $groups
        ($findings | Where-Object { $_.Severity -eq 'Critical' -and $_.Title -like '*failed logon*' }) |
            Should -Not -BeNullOrEmpty
    }
    It 'emits a per-group finding for an error event' {
        $base = Get-Date '2026-06-01T08:00:00'
        $groups = Group-OmniEventRecord -Record @(New-Rec -Id 7031 -Provider 'Service Control Manager' -Level 2 -Time $base)
        $findings = New-OmniEventFinding -Group $groups
        ($findings | Where-Object { $_.Component -like 'Event Logs/Service*' }) | Should -Not -BeNullOrEmpty
    }
    It 'does not surface a single low-count warning' {
        $base = Get-Date '2026-06-01T08:00:00'
        $groups = Group-OmniEventRecord -Record @(New-Rec -Id 1014 -Provider 'Microsoft-Windows-DNS-Client' -Level 3 -Time $base)
        $findings = New-OmniEventFinding -Group $groups -RecurringThreshold 5
        $findings | Should -BeNullOrEmpty
    }
}
