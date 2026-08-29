#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Validates the portable packaging step (build/Build-Portable.ps1): the package
    contains the full runnable surface, excludes developer-only content, and ships a
    version stamp and integrity hash. OS-independent - builds into a temp folder.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:BuildScript = Join-Path $script:Root 'build/Build-Portable.ps1'
    $script:OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ("omnidiag-portable-test-" + [guid]::NewGuid().ToString('N'))

    $script:Result = & $script:BuildScript -OutputDirectory $script:OutDir -KeepStaging 6>$null
    $script:Version = (Import-PowerShellDataFile -Path (Join-Path $script:Root 'src/OmniDiag.psd1')).ModuleVersion
    $script:StageDir = Join-Path $script:OutDir "OmniDiag-$($script:Version)-portable"
}

AfterAll {
    if ($script:OutDir -and (Test-Path -LiteralPath $script:OutDir)) {
        Remove-Item -LiteralPath $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Portable build output' {
    It 'produces a versioned zip and a sha256 sidecar' {
        $script:Result.Package | Should -Exist
        "$($script:Result.Package).sha256" | Should -Exist
    }

    It 'reports a SHA256 that matches the zip on disk' {
        $onDisk = (Get-FileHash -LiteralPath $script:Result.Package -Algorithm SHA256).Hash
        $script:Result.Sha256 | Should -Be $onDisk
    }
}

Describe 'Portable package contents' {
    It 'includes the launcher, module, and portable docs' {
        foreach ($rel in @('OmniDiag.ps1', 'OmniDiag.cmd', 'OmniDiag-GUI.cmd', 'install.ps1',
                           'PORTABLE.md', 'README.md', 'VERSION.txt',
                           'src/OmniDiag.psd1', 'src/OmniDiag.psm1')) {
            Join-Path $script:StageDir $rel | Should -Exist -Because "$rel must ship in the portable package"
        }
    }

    It 'bundles the diagnostic and repair plugin folders' {
        Join-Path $script:StageDir 'src/Modules' | Should -Exist
        Join-Path $script:StageDir 'src/Repairs' | Should -Exist
    }

    It 'excludes developer-only content' {
        foreach ($rel in @('Tests', '.github', '.claude', 'dist', 'build')) {
            Join-Path $script:StageDir $rel | Should -Not -Exist -Because "$rel is repo-only and must not ship"
        }
    }
}
