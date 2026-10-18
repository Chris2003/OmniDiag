#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
}

Describe 'Portable, zero-footprint data locations' {
    BeforeAll {
        # Restore the caller's data location (the test runner isolates runs with it) and
        # remove the default-location folder only if this file created it.
        $script:SavedData = $env:OMNIDIAG_DATA
        $script:RepoData = Join-Path $script:Root 'OmniDiagData'
        $script:RepoDataExisted = Test-Path -LiteralPath $script:RepoData
    }
    AfterEach {
        if ($null -ne $script:SavedData) { $env:OMNIDIAG_DATA = $script:SavedData } else { Remove-Item Env:OMNIDIAG_DATA -ErrorAction SilentlyContinue }
        Get-OmniDataRoot -Refresh | Out-Null
    }
    AfterAll {
        if (-not $script:RepoDataExisted -and (Test-Path -LiteralPath $script:RepoData)) {
            Remove-Item -LiteralPath $script:RepoData -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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

    It 'does not treat a sibling folder with the same prefix as portable' {
        $env:OMNIDIAG_DATA = (Get-OmniToolRoot).TrimEnd('/', '\') + '-old'
        try {
            (Get-OmniDataRoot -Refresh).IsPortable | Should -BeFalse
        } finally { Remove-Item -LiteralPath $env:OMNIDIAG_DATA -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never deletes a temp folder OmniDiag did not create' {
        $env:OMNIDIAG_DATA = Join-Path $TestDrive 'foreign'
        $foreign = Join-Path $env:OMNIDIAG_DATA 'temp'
        New-Item -ItemType Directory -Path $foreign -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $foreign 'user-file.txt') -Value 'keep me'
        Get-OmniDataRoot -Refresh | Out-Null
        Clear-OmniTempData
        Join-Path $foreign 'user-file.txt' | Should -Exist
    }

    It 'never writes to the system temp folder outside the read-only fallback' {
        # Reading $env:TEMP (to measure or clean it) is fine; building a path under it to write is not.
        $offenders = Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter '*.psm1' -Recurse |
            Where-Object Name -ne 'Paths.psm1' |
            Select-String -Pattern 'GetTempPath\(\)', 'GetTempFileName\(\)', 'Join-Path\s+\$env:(TEMP|TMP|APPDATA|LOCALAPPDATA)\b'
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
