#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Installer = Join-Path $script:Root 'install.ps1'
    $script:Content = Get-Content -LiteralPath $script:Installer -Raw
}

Describe 'Quick installer safety and behavior' {
    It 'parses as valid PowerShell' {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -HaveCount 0
    }

    It 'downloads only from the OmniDiag GitHub repository' {
        $script:Content | Should -Match 'https://github\.com/Chris2003/OmniDiag/archive/'
    }

    It 'validates required files before installation' {
        $script:Content | Should -Match 'src\\OmniDiag\.psd1'
        $script:Content | Should -Match 'src\\UI\\MainWindow\.xaml'
    }

    It 'unblocks the installed files and launches the GUI launcher' {
        $script:Content | Should -Match 'Unblock-File'
        $script:Content | Should -Match "OmniDiag-GUI\.cmd"
        $script:Content | Should -Match 'Start-Process'
    }

    It 'does not change machine-wide execution policy or elevate itself' {
        $script:Content | Should -Not -Match 'Set-ExecutionPolicy'
        $script:Content | Should -Not -Match 'RunAs'
    }

    It 'backs up an existing installation instead of deleting it' {
        $script:Content | Should -Match '\.backup-'
        $script:Content | Should -Match 'Move-Item -LiteralPath \$destination -Destination \$backupPath'
    }
}
