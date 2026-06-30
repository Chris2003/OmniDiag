#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for repair discovery, context creation, applicability matching, and the
    restore-point helper. No repair is executed; the restore-point assertion uses the
    not-elevated path (skipped when elevated) so no checkpoint is ever created.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:RepairsPath = Join-Path $root 'src/Repairs'
    $script:Logger = New-OmniLogger -MinimumLevel Error
}

Describe 'Get-OmniRepair' {
    It 'discovers the built-in repair catalog' {
        $repairs = @(Get-OmniRepair -Path $script:RepairsPath -Logger $script:Logger)
        $repairs.Count | Should -Be 10
        $repairs[0].PSTypeNames | Should -Contain 'OmniDiag.RepairRegistration'
    }

    It 'skips a folder of invalid plugins without throwing' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("omnidiag-badrepair-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            # Missing Invoke-OmniRepairAction -> invalid contract.
            Set-Content -LiteralPath (Join-Path $tmp 'Bad.psm1') -Value @'
function Get-OmniRepairManifest { @{ Name = 'Bad'; Category = 'Test' } }
Export-ModuleMember -Function 'Get-OmniRepairManifest'
'@
            $repairs = @(Get-OmniRepair -Path $tmp -Logger $script:Logger)
            $repairs.Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'New-OmniRepairContext' {
    It 'builds a repair context with a DryRun flag' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun
        $ctx.PSTypeNames | Should -Contain 'OmniDiag.RepairContext'
        $ctx.DryRun | Should -BeTrue
        $ctx.Host.ComputerName | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-OmniApplicableRepair' {
    It 'flags repairs whose AppliesTo matches a finding component' {
        $r = New-OmniResult -ModuleName 'Network' -Category 'Network'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'DNS resolution is failing' -Severity 'Critical' -Component 'Network/DNS')
        $session = [pscustomobject]@{ PSTypeName = 'OmniDiag.Session'; Results = @((Complete-OmniResult -Result $r)) }

        $repairs = @(Get-OmniRepair -Path $script:RepairsPath -Logger $script:Logger)
        $annotated = @(Get-OmniApplicableRepair -Registration $repairs -Session $session)

        ($annotated | Where-Object Name -eq 'Flush DNS Cache').Recommended | Should -BeTrue
        ($annotated | Where-Object Name -eq 'Repair Component Store (DISM)').Recommended | Should -BeFalse
    }
}

Describe 'New-OmniRestorePoint' {
    It 'skips (does not throw) when not elevated' {
        # Guard inside the test body, not in -Skip: (which is evaluated at discovery
        # time, before BeforeAll imports the module). Never creates a real checkpoint.
        if (Test-OmniIsAdministrator) { Set-ItResult -Skipped -Because 'running elevated'; return }
        $status = New-OmniRestorePoint -Logger $script:Logger
        $status.Created | Should -BeFalse
        $status.Status | Should -Be 'Skipped'
    }
}
