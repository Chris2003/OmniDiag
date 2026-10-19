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

    It 'installs the approved runbooks and keeps OmniDiagData across upgrades' {
        $script:Content | Should -Match "'runbooks'"
        $script:Content | Should -Match ([regex]::Escape("Join-Path `$destination 'OmniDiagData'"))
    }
}

Describe 'Quick installer: release pinning and checksum verification' {
    BeforeAll {
        $script:Start = $script:Content.IndexOf('# Release checksum verification', [System.StringComparison]::Ordinal)
        $script:End = $script:Content.IndexOf('# End release checksum verification', [System.StringComparison]::Ordinal)
        $script:VerifyBlock = [scriptblock]::Create($script:Content.Substring($script:Start, $script:End - $script:Start))
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-installer-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Zip = Join-Path $script:Dir 'OmniDiag.zip'
        [System.IO.File]::WriteAllText($script:Zip, 'pretend zip')
        $script:ZipHash = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash
        function Invoke-Verify {
            # Runs the real block from install.ps1 with the variables it reads.
            param([string] $Sums, [switch] $NoSums)
            $assetName = 'OmniDiag-1.2.3-portable.zip'
            $archivePath = $script:Zip
            $sumsPath = Join-Path $script:Dir ('SHA256SUMS-' + [guid]::NewGuid().ToString('N'))
            if (-not $NoSums) { [System.IO.File]::WriteAllText($sumsPath, $Sums) }
            . $script:VerifyBlock
            return $actualHash
        }
    }

    AfterAll {
        if ($script:Dir -and (Test-Path -LiteralPath $script:Dir)) { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'defaults to the latest release tag from the GitHub releases API, not main' {
        $script:Content | Should -Match ([regex]::Escape('https://api.github.com/repos/Chris2003/OmniDiag/releases/latest'))
        $script:Content | Should -Match 'tag_name'
        $script:Content | Should -Match 'releases/download/'
        $script:Content | Should -Not -Match "\`$Ref\s*=\s*'main'"
        $script:Content | Should -Match 'Could not resolve the latest OmniDiag release'
    }

    It 'verifies SHA256SUMS before the zip-slip guard and before extraction' {
        $guard = $script:Content.IndexOf('# Zip-slip / zip-bomb guard', [System.StringComparison]::Ordinal)
        $expand = $script:Content.IndexOf('Expand-Archive -LiteralPath', [System.StringComparison]::Ordinal)
        $script:Start | Should -BeGreaterThan 0
        $script:End | Should -BeGreaterThan $script:Start
        $script:End | Should -BeLessThan $guard
        $guard | Should -BeLessThan $expand
    }

    It 'accepts a matching SHA256SUMS entry (GNU text or binary marker, any hex case)' {
        Invoke-Verify -Sums ("{0}  OmniDiag-1.2.3-portable.zip`n{1}  other.msi`n" -f $script:ZipHash.ToLowerInvariant(), ('0' * 64)) | Should -Be $script:ZipHash
        Invoke-Verify -Sums ("{0} *OmniDiag-1.2.3-portable.zip`r`n" -f $script:ZipHash) | Should -Be $script:ZipHash
    }

    It 'fails closed when <Why>' -ForEach @(
        @{ Why = 'the hash does not match'; Sums = ('ab' * 32) + "  OmniDiag-1.2.3-portable.zip`n"; Expect = '*mismatch*' }
        @{ Why = 'the zip is not listed'; Sums = ('ab' * 32) + "  OmniDiag-9.9.9-portable.zip`n"; Expect = '*no entry*' }
        @{ Why = 'SHA256SUMS is empty'; Sums = ''; Expect = '*no entry*' }
        @{ Why = 'the zip is listed twice'; Sums = ('ab' * 32) + "  OmniDiag-1.2.3-portable.zip`n" + ('cd' * 32) + "  OmniDiag-1.2.3-portable.zip`n"; Expect = '*more than once*' }
    ) {
        { Invoke-Verify -Sums $Sums } | Should -Throw $Expect
    }

    It 'fails closed when SHA256SUMS is missing' {
        { Invoke-Verify -NoSums } | Should -Throw '*missing*'
    }

    It 'documents the release URL in README and PORTABLE, not the main branch' {
        foreach ($doc in 'README.md', 'PORTABLE.md') {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Root $doc))
            $text | Should -Match ([regex]::Escape('https://github.com/Chris2003/OmniDiag/releases/latest/download/install.ps1')) -Because $doc
            $text | Should -Not -Match ([regex]::Escape('raw.githubusercontent.com/Chris2003/OmniDiag/main/install.ps1')) -Because $doc
        }
    }
}
