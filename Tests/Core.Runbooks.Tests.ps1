#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:Dir = Join-Path $TestDrive 'runbooks'
    New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:Dir 'dns.md') -Value @"
---
id: rb-dns
title: DNS failures
status: approved
owner: Network Team
appliesTo: network/dns
tags: dns, lookup
---
# DNS failures
1. Check resolvers.
"@
    Set-Content -LiteralPath (Join-Path $script:Dir 'draft.md') -Value @"
---
id: rb-draft
status: draft
appliesTo: network/dns
---
# Draft procedure
"@
    $f = New-OmniFinding -Id 'network-dns-failure' -Title 'DNS resolution failed' -Severity Error -Component 'Network/DNS'
    $r = New-OmniResult -ModuleName 'DNS Resolver' -Category Network
    Add-OmniFinding -Result $r -Finding $f
    Complete-OmniResult -Result $r | Out-Null
    $script:Session = [pscustomobject]@{ Results = @($r) }
}

Describe 'Organization runbooks' {
    It 'parses front matter and returns only approved runbooks by default' {
        $rbs = @(Get-OmniRunbook -Path $script:Dir)
        $rbs.Count | Should -Be 1
        $rbs[0].Id | Should -Be 'rb-dns'
        $rbs[0].Owner | Should -Be 'Network Team'
        $rbs[0].AppliesTo | Should -Contain 'network/dns'
        $rbs[0].Body | Should -Match 'Check resolvers'
    }

    It 'includes drafts only on request and derives a title from the heading' {
        $draft = Get-OmniRunbook -Path $script:Dir -IncludeUnapproved -Id 'rb-draft'
        $draft.Approved | Should -BeFalse
        $draft.Title | Should -Be 'Draft procedure'
    }

    It 'matches runbooks to session findings by appliesTo' {
        $match = @(Find-OmniRunbook -Session $script:Session -Path $script:Dir)
        $match.Count | Should -Be 1
        $match[0].Id | Should -Be 'rb-dns'
        $match[0].FindingIds | Should -Contain 'network-dns-failure'
    }

    It 'ships approved sample runbooks with the tool' {
        @(Get-OmniRunbook -Path (Get-OmniDefaultRunbookPath)).Count | Should -BeGreaterThan 2
        (Get-OmniRunbook -Path (Get-OmniDefaultRunbookPath)).Id | Should -Not -Contain 'rb-printer-spooler'
    }
}
