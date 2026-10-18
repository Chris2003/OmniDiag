#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
}

Describe 'Portable, zero-footprint data locations' {
    AfterEach { Remove-Item Env:OMNIDIAG_DATA -ErrorAction SilentlyContinue; Get-OmniDataRoot -Refresh | Out-Null }

    It 'keeps data in OmniDiagData next to the tool by default' {
        Remove-Item Env:OMNIDIAG_DATA -ErrorAction SilentlyContinue
        $data = Get-OmniDataRoot -Refresh
        $data.Path | Should -Be (Join-Path $script:Root 'OmniDiagData')
        $data.IsPortable | Should -BeTrue
        $data.Source | Should -Be 'ToolFolder'
    }

    It 'honors the OMNIDIAG_DATA override the launchers set' {
        $env:OMNIDIAG_DATA = Join-Path $TestDrive 'usb/OmniDiagData'
        $data = Get-OmniDataRoot -Refresh
        $data.Path | Should -Be $env:OMNIDIAG_DATA
        $data.Source | Should -Be 'Environment'
        Get-OmniDataPath -Kind Logs | Should -Exist
        Get-OmniDataPath -Kind Sessions -ChildPath 'x.json' | Should -BeLike '*sessions*x.json'
    }

    It 'removes only the scratch folder on cleanup' {
        $env:OMNIDIAG_DATA = Join-Path $TestDrive 'clean'
        Get-OmniDataRoot -Refresh | Out-Null
        $temp = Get-OmniDataPath -Kind Temp; $logs = Get-OmniDataPath -Kind Logs
        Set-Content -LiteralPath (Join-Path $temp 'scratch.txt') -Value 'x'
        Clear-OmniTempData
        $temp | Should -Not -Exist
        $logs | Should -Exist
    }

    It 'never writes to the system temp folder outside the read-only fallback' {
        $offenders = Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter '*.psm1' -Recurse |
            Where-Object Name -ne 'Paths.psm1' |
            Select-String -Pattern 'GetTempPath\(\)' -SimpleMatch:$false
        @($offenders).Count | Should -Be 0 -Because "everything OmniDiag writes must stay in its data folder: $($offenders -join '; ')"
    }

    It 'launchers redirect PowerShell and TEMP into the tool folder' {
        foreach ($launcher in @('OmniDiag.cmd', 'OmniDiag-GUI.cmd')) {
            $text = Get-Content -LiteralPath (Join-Path $script:Root $launcher) -Raw
            $text | Should -Match 'OMNIDIAG_DATA=%HERE%OmniDiagData'
            $text | Should -Match 'PSModuleAnalysisCachePath='
            $text | Should -Match 'POWERSHELL_TELEMETRY_OPTOUT=1'
            $text | Should -Match 'set "TEMP=%OMNIDIAG_DATA%\\temp"'
            $text | Should -Match 'OMNIDIAG_HOST_TEMP=%TEMP%'
        }
    }

    It 'the temp-clean repair targets the host temp folder, not the redirected one' {
        $text = Get-Content -LiteralPath (Join-Path $script:Root 'src/Repairs/ClearTempFiles.psm1') -Raw
        $text | Should -Match 'OMNIDIAG_HOST_TEMP'
    }
}
