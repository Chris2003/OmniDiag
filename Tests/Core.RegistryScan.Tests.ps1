#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests the registry scan/backup/remove primitives. Detection is exercised read-only;
    backup + removal round-trip against a throwaway HKCU key (no admin needed). Windows-only.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:OnWindows = $true
    try { if ($IsWindows -eq $false) { $script:OnWindows = $false } } catch { }

    $script:TestKeySub = 'Software\OmniDiagRegTest'
    $script:TestKeyPP  = 'Registry::HKEY_CURRENT_USER\Software\OmniDiagRegTest'
}

AfterAll {
    if (Test-Path -LiteralPath $script:TestKeyPP) {
        Remove-Item -LiteralPath $script:TestKeyPP -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-OmniInvalidRegistryEntry' {
    It 'returns an array without throwing' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'Windows-only'; return }
        $entries = $null
        { $script:entries = @(Get-OmniInvalidRegistryEntry) } | Should -Not -Throw
        $script:entries | Should -BeOfType ([object])   # array (possibly empty)
    }
    It 'produces well-formed entries when any are found' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'Windows-only'; return }
        foreach ($e in @(Get-OmniInvalidRegistryEntry)) {
            $e.Category | Should -Not -BeNullOrEmpty
            $e.Root     | Should -BeIn @('HKLM', 'HKCU', 'HKCR')
        }
    }
}

Describe 'Backup + remove round-trip (HKCU, no admin)' {
    It 'backs up and then removes a value' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'Windows-only'; return }

        # Seed a throwaway value that points at a missing file.
        New-Item -Path $script:TestKeyPP -Force | Out-Null
        New-ItemProperty -Path $script:TestKeyPP -Name 'Ghost' -Value 'C:\nope\missing.exe' -PropertyType String -Force | Out-Null

        $entry = [pscustomobject]@{
            Category = 'Startup'; Root = 'HKCU'; SubPath = $script:TestKeySub
            ValueName = 'Ghost'; Target = 'C:\nope\missing.exe'; Detail = 'test'
        }

        $backup = Join-Path $TestDrive 'reg-backup.reg'
        Export-OmniRegistryBackup -Entries @($entry) -Path $backup | Should -Be $backup
        Test-Path -LiteralPath $backup | Should -BeTrue
        (Get-Content -LiteralPath $backup -Raw) | Should -Match 'OmniDiagRegTest'

        Remove-OmniRegistryEntry -Entry $entry
        (Get-ItemProperty -LiteralPath $script:TestKeyPP -Name 'Ghost' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

Describe 'Get-OmniRegExportBody (cross-platform, no registry)' {
    BeforeAll {
        # Private helper: call it inside the RegistryScan nested module's scope.
        $script:RegScanModule = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'RegistryScan' } | Select-Object -First 1
        $script:Body = "[HKEY_CURRENT_USER\Software\OmniDiagRegTest]`r`n`"Ghost`"=`"C:\\nope\\missing.exe`"`r`n"
    }
    It 'finds the RegistryScan nested module' { $script:RegScanModule | Should -Not -BeNullOrEmpty }
    It 'strips the header when there is no BOM' {
        $text = "Windows Registry Editor Version 5.00`r`n`r`n" + $script:Body
        $out = & $script:RegScanModule { param($t) Get-OmniRegExportBody -Content $t } $text
        $out | Should -BeExactly $script:Body
    }
    It 'strips the header when the text starts with a byte-order mark (U+FEFF)' {
        $text = [string][char]0xFEFF + "Windows Registry Editor Version 5.00`r`n`r`n" + $script:Body
        $out = & $script:RegScanModule { param($t) Get-OmniRegExportBody -Content $t } $text
        $out | Should -BeExactly $script:Body
        $out.IndexOf([char]0xFEFF) | Should -Be -1
    }
    It 'leaves text without a header unchanged and tolerates empty input' {
        (& $script:RegScanModule { param($t) Get-OmniRegExportBody -Content $t } $script:Body) | Should -BeExactly $script:Body
        (& $script:RegScanModule { Get-OmniRegExportBody -Content '' }) | Should -BeExactly ''
    }
    It 'keeps the module source ASCII-only (a literal BOM breaks the regex on Windows PowerShell 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core/RegistryScan.psm1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
