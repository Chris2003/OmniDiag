#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Release engineering (Phase 5): reproducible portable zip (build/Build-Portable.ps1),
    SHA256SUMS (build/New-ReleaseManifest.ps1), CycloneDX SBOM (build/New-Sbom.ps1),
    release notes (build/Get-ReleaseNotes.ps1), the signing hook (build/Sign.ps1), and the
    release / CI workflow wiring. Cross-platform; the signing-with-a-certificate tests run
    on Windows only and skip elsewhere.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Build = Join-Path $script:Root 'build'
    Import-Module (Join-Path $script:Build 'ReleaseTools.psm1') -Force
    $script:Version = (Import-PowerShellDataFile -Path (Join-Path $script:Root 'src/OmniDiag.psd1')).ModuleVersion
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-release-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
    $script:SavedEpoch = $env:SOURCE_DATE_EPOCH
    $script:IsWin = $true
    try { if ($IsWindows -eq $false) { $script:IsWin = $false } } catch { $script:IsWin = $true }

    Add-Type -AssemblyName System.IO.Compression
    function Get-ZipEntryInfo {
        param([string] $Path)
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                @($zip.Entries | ForEach-Object {
                        $ext = $null
                        if ($_.PSObject.Properties['ExternalAttributes']) { $ext = $_.ExternalAttributes }
                        [pscustomobject]@{
                            Name = $_.FullName; Length = $_.Length; Compressed = $_.CompressedLength
                            Clock = $_.LastWriteTime.DateTime.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                            External = $ext
                        }
                    })
            } finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
    }
    function Get-ZipEntryBytes {
        param([string] $Path, [string] $Name)
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                $e = $zip.GetEntry($Name)
                $ms = New-Object System.IO.MemoryStream
                $s = $e.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
                return , $ms.ToArray()
            } finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
    }

    # Two builds of the same tree with a fixed SOURCE_DATE_EPOCH (2026-01-01T00:00:00Z).
    $env:SOURCE_DATE_EPOCH = '1767225600'
    try {
        $script:A = & (Join-Path $script:Build 'Build-Portable.ps1') -OutputDirectory (Join-Path $script:Work 'a') 6>$null 3>$null
        $script:B = & (Join-Path $script:Build 'Build-Portable.ps1') -OutputDirectory (Join-Path $script:Work 'b') -KeepStaging 6>$null 3>$null
        $script:C = & (Join-Path $script:Build 'Build-Portable.ps1') -OutputDirectory (Join-Path $script:Work 'c') -Version '9.8.7-test.1' -CompressionLevel NoCompression 6>$null 3>$null
    } finally {
        $env:SOURCE_DATE_EPOCH = $script:SavedEpoch
    }
    $script:PkgRoot = "OmniDiag-$($script:Version)-portable/"
    $script:EntriesA = @(Get-ZipEntryInfo -Path $script:A.Package)
}

AfterAll {
    $env:SOURCE_DATE_EPOCH = $script:SavedEpoch
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reproducible portable zip' {
    It 'is named OmniDiag-<version>-portable.zip from the module version' {
        Split-Path $script:A.Package -Leaf | Should -BeExactly "OmniDiag-$($script:Version)-portable.zip"
        $script:A.Version | Should -Be $script:Version
    }

    It 'produces byte-identical zips from two builds of the same tree' {
        (Get-FileHash -LiteralPath $script:A.Package -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $script:B.Package -Algorithm SHA256).Hash
        $script:A.Sha256 | Should -Be $script:B.Sha256
    }

    It 'contains file entries only, sorted ordinally, with forward-slash names under one versioned root' {
        $names = @($script:EntriesA | ForEach-Object { $_.Name })
        $names.Count | Should -BeGreaterThan 50
        $sorted = New-Object 'System.Collections.Generic.List[string]'
        foreach ($n in $names) { $sorted.Add($n) }
        $sorted.Sort([System.StringComparer]::Ordinal)
        ($names -join '|') | Should -BeExactly ($sorted.ToArray() -join '|')
        foreach ($n in $names) {
            $n.StartsWith($script:PkgRoot, [System.StringComparison]::Ordinal) | Should -BeTrue -Because "$n must sit under $($script:PkgRoot)"
            $n | Should -Not -Match '\\'
            $n.EndsWith('/') | Should -BeFalse -Because 'no directory entries'
        }
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'stamps every entry with SOURCE_DATE_EPOCH (UTC clock time, no host time zone)' {
        foreach ($e in $script:EntriesA) { $e.Clock | Should -Be '2026-01-01 00:00:00' -Because $e.Name }
        $script:A.SourceDateEpoch | Should -Be 1767225600
    }

    It 'writes no OS-specific attributes' {
        foreach ($e in $script:EntriesA) {
            if ($null -ne $e.External) { $e.External | Should -Be 0 -Because $e.Name }
        }
    }

    It 'uses the fixed compression level (Optimal deflates; NoCompression stores)' {
        @($script:EntriesA | Where-Object { $_.Length -gt 1024 -and $_.Compressed -lt $_.Length }).Count | Should -BeGreaterThan 0
        foreach ($e in @(Get-ZipEntryInfo -Path $script:C.Package)) { $e.Compressed | Should -Be $e.Length -Because $e.Name }
    }

    It 'keeps file bytes exactly as checked out' {
        foreach ($rel in @('src/OmniDiag.psd1', 'OmniDiag.cmd', 'LICENSE')) {
            $inZip = Get-ZipEntryBytes -Path $script:A.Package -Name ($script:PkgRoot + $rel)
            $onDisk = [System.IO.File]::ReadAllBytes((Join-Path $script:Root $rel))
            (Get-OmniSha256Hex -Bytes $inZip) | Should -Be (Get-OmniSha256Hex -Bytes $onDisk) -Because $rel
        }
    }

    It 'writes a deterministic VERSION.txt (source date, ASCII, no BOM, LF)' {
        $bytes = Get-ZipEntryBytes -Path $script:A.Package -Name ($script:PkgRoot + 'VERSION.txt')
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $bytes[0] | Should -Not -Be 0xEF
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text | Should -Match "^OmniDiag $([regex]::Escape($script:Version))\n"
        $text | Should -Match 'Source date: 2026-01-01T00:00:00Z \(SOURCE_DATE_EPOCH 1767225600\)'
        $text | Should -Not -Match "`r"
    }

    It 'honours -Version and writes a GNU-format sidecar' {
        Split-Path $script:C.Package -Leaf | Should -BeExactly 'OmniDiag-9.8.7-test.1-portable.zip'
        $first = @(Get-ZipEntryInfo -Path $script:C.Package)[0].Name
        $first | Should -Match '^OmniDiag-9\.8\.7-test\.1-portable/'
        $sidecar = [System.IO.File]::ReadAllText("$($script:C.Package).sha256")
        $sidecar | Should -BeExactly ("{0}  OmniDiag-9.8.7-test.1-portable.zip`n" -f $script:C.Sha256.ToLowerInvariant())
    }

    It 'rejects a malformed -Version' {
        { & (Join-Path $script:Build 'Build-Portable.ps1') -OutputDirectory (Join-Path $script:Work 'bad') -Version '1.0' 6>$null } | Should -Throw '*Invalid version*'
    }

    It 'defaults the timestamp to the HEAD commit time when SOURCE_DATE_EPOCH is unset' {
        $ct = Invoke-OmniGit -RepoRoot $script:Root -Arguments @('log', '-1', '--format=%ct')
        if (-not $ct) { Set-ItResult -Skipped -Because 'git history is not available here'; return }
        $saved = $env:SOURCE_DATE_EPOCH
        try {
            $env:SOURCE_DATE_EPOCH = $null
            Get-OmniSourceDateEpoch -RepoRoot $script:Root | Should -Be ([long]$ct.Trim())
        } finally { $env:SOURCE_DATE_EPOCH = $saved }
    }

    It 'packages exactly the git-tracked files (checked for docs/)' {
        $tracked = Invoke-OmniGit -RepoRoot $script:Root -Arguments @('ls-files', '--', 'docs')
        if (-not $tracked) { Set-ItResult -Skipped -Because 'git is not usable on this checkout'; return }
        $names = @($script:EntriesA | ForEach-Object { $_.Name.Substring($script:PkgRoot.Length) } | Where-Object { $_ -like 'docs/*' })
        $expected = New-Object 'System.Collections.Generic.List[string]'
        foreach ($t in @($tracked -split "`n" | Where-Object { $_ })) { $expected.Add($t.Trim()) }
        $expected.Sort([System.StringComparer]::Ordinal)
        ($names -join '|') | Should -BeExactly ($expected.ToArray() -join '|') -Because 'only git-tracked docs ship'
    }
}

Describe 'Release helper functions' {
    It 'rejects a non-numeric SOURCE_DATE_EPOCH and clamps dates before 1980' {
        $saved = $env:SOURCE_DATE_EPOCH
        try {
            $env:SOURCE_DATE_EPOCH = 'yesterday'
            { Get-OmniSourceDateEpoch -RepoRoot $script:Root } | Should -Throw '*SOURCE_DATE_EPOCH*'
            $env:SOURCE_DATE_EPOCH = '0'
            Get-OmniSourceDateEpoch -RepoRoot $script:Root | Should -Be 315532800
        } finally { $env:SOURCE_DATE_EPOCH = $saved }
    }

    It 'rounds zip timestamps down to an even second at offset zero' {
        $t = Get-OmniZipTimestamp -Epoch 1767225601
        $t.Offset | Should -Be ([TimeSpan]::Zero)
        $t.DateTime.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-01-01 00:00:00'
    }

    It 'writes deterministic, ASCII-escaped JSON' {
        $json = ConvertTo-OmniJson -InputObject ([ordered]@{ a = 'x"y\z'; b = @(); c = @(1); d = $true; e = $null; f = "caf$([char]0xE9)`n" })
        $json | Should -BeExactly "{`n  `"a`": `"x\`"y\\z`",`n  `"b`": [],`n  `"c`": [`n    1`n  ],`n  `"d`": true,`n  `"e`": null,`n  `"f`": `"caf\u00e9\n`"`n}"
    }
}

Describe 'SHA256SUMS (build/New-ReleaseManifest.ps1)' {
    BeforeAll {
        $script:SumDir = Join-Path $script:Work 'sums'
        New-Item -ItemType Directory -Path $script:SumDir -Force | Out-Null
        Copy-Item -LiteralPath $script:A.Package -Destination $script:SumDir
        [System.IO.File]::WriteAllText((Join-Path $script:SumDir 'b-installer.msi'), 'fake msi')
        [System.IO.File]::WriteAllText((Join-Path $script:SumDir 'Install.ps1'), '# installer')
        $script:SumResult = & (Join-Path $script:Build 'New-ReleaseManifest.ps1') -Path $script:SumDir 6>$null
        $script:SumPath = Join-Path $script:SumDir 'SHA256SUMS'
    }

    It 'writes one GNU-format line per artifact, sorted ordinally, LF, ASCII, no BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($script:SumPath)
        $bytes[0] | Should -Not -Be 0xEF
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Not -Match "`r"
        $text.EndsWith("`n") | Should -BeTrue
        $lines = @($text.TrimEnd("`n").Split("`n"))
        $lines.Count | Should -Be 3
        foreach ($l in $lines) { $l | Should -Match '^[0-9a-f]{64}  [^ /\\]+$' }
        $names = @($lines | ForEach-Object { $_.Substring(66) })
        $names[0] | Should -BeExactly 'Install.ps1'   # ordinal: uppercase before lowercase
        $names | Should -Not -Contain 'SHA256SUMS'
    }

    It 'lists the same hash as Get-FileHash' {
        $line = @([System.IO.File]::ReadAllLines($script:SumPath) | Where-Object { $_ -like '*portable.zip' })[0]
        $line.Substring(0, 64) | Should -BeExactly (Get-FileHash -LiteralPath $script:A.Package -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'verifies a good manifest and rejects a tampered artifact' {
        { & (Join-Path $script:Build 'New-ReleaseManifest.ps1') -Path $script:SumDir -Verify 6>$null } | Should -Not -Throw
        [System.IO.File]::WriteAllText((Join-Path $script:SumDir 'b-installer.msi'), 'tampered')
        { & (Join-Path $script:Build 'New-ReleaseManifest.ps1') -Path $script:SumDir -Verify 6>$null } | Should -Throw '*hash mismatch: b-installer.msi*'
    }
}

Describe 'SBOM (build/New-Sbom.ps1, CycloneDX 1.5)' {
    BeforeAll {
        $saved = $env:SOURCE_DATE_EPOCH
        try {
            $env:SOURCE_DATE_EPOCH = '1767225600'
            $script:Sbom1 = & (Join-Path $script:Build 'New-Sbom.ps1') -ZipPath $script:A.Package -OutputPath (Join-Path $script:Work 'sbom1.cdx.json') 6>$null
            $script:Sbom2 = & (Join-Path $script:Build 'New-Sbom.ps1') -ZipPath $script:B.Package -OutputPath (Join-Path $script:Work 'sbom2.cdx.json') 6>$null
            $script:SbomC = & (Join-Path $script:Build 'New-Sbom.ps1') -ZipPath $script:C.Package -Version '9.8.7-test.1' -OutputPath (Join-Path $script:Work 'sbomC.cdx.json') 6>$null
        } finally { $env:SOURCE_DATE_EPOCH = $saved }
        $script:SbomText = [System.IO.File]::ReadAllText($script:Sbom1.Path)
        $script:Bom = $script:SbomText | ConvertFrom-Json
    }

    It 'is deterministic (same zip -> same bytes) and ASCII without a BOM' {
        (Get-FileHash -LiteralPath $script:Sbom1.Path).Hash | Should -Be (Get-FileHash -LiteralPath $script:Sbom2.Path).Hash
        $bytes = [System.IO.File]::ReadAllBytes($script:Sbom1.Path)
        $bytes[0] | Should -Be ([byte][char]'{')
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'declares CycloneDX 1.5 with a derived serial number and the source-date timestamp' {
        $script:Bom.bomFormat | Should -Be 'CycloneDX'
        $script:Bom.specVersion | Should -Be '1.5'
        $script:Bom.version | Should -Be 1
        $script:Bom.serialNumber | Should -Match '^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        $script:SbomC.SerialNumber | Should -Not -Be $script:Sbom1.SerialNumber
        $script:SbomText | Should -Match '"timestamp": "2026-01-01T00:00:00Z"'
    }

    It 'describes OmniDiag: version, MIT license, purl, and the zip hash' {
        $c = $script:Bom.metadata.component
        $c.name | Should -Be 'OmniDiag'
        $c.version | Should -Be $script:Version
        $c.purl | Should -BeExactly "pkg:github/Chris2003/OmniDiag@$($script:Version)"
        $c.licenses[0].license.id | Should -Be 'MIT'
        $dist = @($c.externalReferences | Where-Object { $_.type -eq 'distribution' })[0]
        $dist.hashes[0].content | Should -Be $script:A.Sha256.ToLowerInvariant()
    }

    It 'lists every shipped file with its SHA-256' {
        $files = @($script:Bom.components | Where-Object { $_.type -eq 'file' })
        $files.Count | Should -Be $script:EntriesA.Count
        $psd1 = @($files | Where-Object { $_.name -eq 'src/OmniDiag.psd1' })[0]
        $psd1.hashes[0].alg | Should -Be 'SHA-256'
        $psd1.hashes[0].content | Should -Be (Get-OmniSha256Hex -Path (Join-Path $script:Root 'src/OmniDiag.psd1'))
    }

    It 'lists build/test tools as excluded and ships none of them' {
        $excluded = @($script:Bom.components | Where-Object { $_.scope -eq 'excluded' })
        @($excluded | ForEach-Object { $_.name }) | Should -Contain 'Pester'
        @($excluded | ForEach-Object { $_.name }) | Should -Contain 'PSScriptAnalyzer'
        foreach ($e in $script:EntriesA) { $e.Name | Should -Not -Match '(?i)/(Tests|build|\.github)/' }
    }

    It 'backs the "no third-party runtime code" claim: the package has no binaries, libraries, or fonts' {
        $binary = @($script:EntriesA | Where-Object { $_.Name -match '(?i)\.(dll|exe|so|dylib|msi|cab|ttf|otf|woff2?|eot|nupkg|zip|jar|node)$' })
        $binary | Should -BeNullOrEmpty
    }
}

Describe 'Release notes (build/Get-ReleaseNotes.ps1)' {
    BeforeAll {
        $script:NotesScript = Join-Path $script:Build 'Get-ReleaseNotes.ps1'
        $script:Log = Join-Path $script:Work 'CHANGELOG.test.md'
        $content = @(
            '# Changelog', '',
            '## 1.0.1 (unreleased)', '', '- next', '',
            '## [1.0.0] - 2026-11-02', '', '### Added', '- first release', '- with SHA256SUMS', '',
            '## 1.0.0-rc.1', '- candidate', '',
            '## 0.9.0', '', ''
        ) -join "`n"
        [System.IO.File]::WriteAllText($script:Log, $content)
    }

    It 'returns the section body up to the next level-2 heading' {
        $notes = & $script:NotesScript -Version '1.0.0' -ChangelogPath $script:Log
        $notes | Should -BeExactly "### Added`n- first release`n- with SHA256SUMS`n"
    }

    It 'accepts a v-prefixed tag and does not confuse 1.0.0 with 1.0.0-rc.1' {
        & $script:NotesScript -Version 'v1.0.0-rc.1' -ChangelogPath $script:Log | Should -BeExactly "- candidate`n"
    }

    It 'fails for a missing or empty section' {
        { & $script:NotesScript -Version '2.0.0' -ChangelogPath $script:Log } | Should -Throw '*no*2.0.0*'
        { & $script:NotesScript -Version '0.9.0' -ChangelogPath $script:Log } | Should -Throw '*empty*'
    }

    It 'with -RequireReleased refuses an "unreleased" heading' {
        { & $script:NotesScript -Version '1.0.1' -ChangelogPath $script:Log -RequireReleased } | Should -Throw '*unreleased*'
        & $script:NotesScript -Version '1.0.1' -ChangelogPath $script:Log | Should -BeExactly "- next`n"
    }

    It 'finds the current module version in the real CHANGELOG and writes UTF-8 without a BOM' {
        $out = Join-Path $script:Work 'notes.md'
        $notes = & $script:NotesScript -Version $script:Version -OutputPath $out
        $notes | Should -Not -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($out)[0] | Should -Not -Be 0xEF
    }
}

Describe 'Signing hook (build/Sign.ps1)' {
    BeforeAll {
        $script:SignScript = Join-Path $script:Build 'Sign.ps1'
        function New-SignFixture {
            param([string] $Name)
            $dir = Join-Path $script:Work $Name
            New-Item -ItemType Directory -Path (Join-Path $dir 'src') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'OmniDiag.ps1'), "Write-Output 'hello'`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'src/Mod.psm1'), "function Get-X { 1 }`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'src/Mod.psd1'), "@{ ModuleVersion = '1.0.0' }`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'OmniDiag.cmd'), "@echo off`r`necho hi`r`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'README.md'), "# readme`n")
            return $dir
        }
    }

    It 'does nothing and succeeds without a certificate' {
        $dir = New-SignFixture -Name 'sign-none'
        $before = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { Get-OmniSha256Hex -Path $_.FullName })
        $out = & $script:SignScript -Path $dir 6>&1
        $result = @($out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Signed'] })[0]
        $result.Signed | Should -BeFalse
        ($out | Out-String) | Should -Match 'no signing certificate'
        $after = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { Get-OmniSha256Hex -Path $_.FullName })
        ($after -join ',') | Should -Be ($before -join ',')
        Test-Path -LiteralPath (Join-Path $dir 'OmniDiag.cat') | Should -BeFalse
    }

    It 'refuses two certificate sources at once' {
        $dir = New-SignFixture -Name 'sign-both'
        { & $script:SignScript -Path $dir -CertificateThumbprint ('A' * 40) -PfxPath 'x.pfx' 6>$null } | Should -Throw '*not both*'
    }

    It 'signs every script and a catalog from a PFX, without printing the password (Windows)' {
        if (-not $script:IsWin) { Set-ItResult -Skipped -Because 'Authenticode signing is Windows-only'; return }
        $password = 'P-' + [guid]::NewGuid().ToString('N')
        $pfx = Join-Path $script:Work 'pester-sign.pfx'
        $thumb = $null
        try {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest('CN=OmniDiag Pester throwaway signing', $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $oids = New-Object System.Security.Cryptography.OidCollection
            [void]$oids.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.5.5.7.3.3')))
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($oids, $true)))
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension(
                        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true)))
            $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
            [System.IO.File]::WriteAllBytes($pfx, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
            $thumb = $cert.Thumbprint
            # The account must be able to load a PFX key at all (profile-less service accounts cannot).
            $probe = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $probe.Import($pfx, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
            foreach ($c in $probe) { $c.Reset() }
        } catch {
            Set-ItResult -Skipped -Because "a throwaway certificate cannot be created or loaded here: $($_.Exception.Message)"
            return
        }

        $dir = New-SignFixture -Name 'sign-pfx'
        $savedPw = $env:OMNIDIAG_SIGN_PFX_PASSWORD
        try {
            $env:OMNIDIAG_SIGN_PFX_PASSWORD = $password
            $out = & $script:SignScript -Path $dir -PfxPath $pfx *>&1
        } finally { $env:OMNIDIAG_SIGN_PFX_PASSWORD = $savedPw }
        ($out | Out-String) | Should -Not -Match ([regex]::Escape($password))
        $result = @($out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Signed'] })[0]
        $result.Signed | Should -BeTrue
        $result.Files | Should -Be 3

        foreach ($rel in @('OmniDiag.ps1', 'src/Mod.psm1', 'src/Mod.psd1', 'OmniDiag.cat')) {
            $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $dir $rel)
            $sig.SignerCertificate | Should -Not -BeNullOrEmpty -Because "$rel must be signed"
            $sig.SignerCertificate.Thumbprint | Should -Be $thumb
            # Untrusted self-signed root: 'UnknownError'; never a broken signature.
            [string]$sig.Status | Should -BeIn @('Valid', 'UnknownError', 'NotTrusted')
        }
        (Get-AuthenticodeSignature -LiteralPath (Join-Path $dir 'OmniDiag.cmd')).Status | Should -Be 'NotSigned'
        [string](Test-FileCatalog -Path $dir -CatalogFilePath (Join-Path $dir 'OmniDiag.cat') -FilesToSkip 'OmniDiag.cat') | Should -Be 'Valid'

        # The catalog covers what Authenticode cannot: a changed .cmd launcher is detected.
        [System.IO.File]::AppendAllText((Join-Path $dir 'OmniDiag.cmd'), "echo tampered`r`n")
        [string](Test-FileCatalog -Path $dir -CatalogFilePath (Join-Path $dir 'OmniDiag.cat') -FilesToSkip 'OmniDiag.cat') | Should -Be 'ValidationFailed'
    }
}

Describe 'Release and CI workflows' {
    BeforeAll {
        $script:ReleaseYml = [System.IO.File]::ReadAllText((Join-Path $script:Root '.github/workflows/release.yml'))
        $script:CiYml = [System.IO.File]::ReadAllText((Join-Path $script:Root '.github/workflows/ci.yml'))
        function Get-JobBlock {
            param([string] $Yaml, [string] $Job)
            $m = [regex]::Match($Yaml, "(?ms)^  $([regex]::Escape($Job)):\s*\n(.*?)(?=^  [A-Za-z0-9_-]+:\s*\n|\z)")
            if (-not $m.Success) { return $null }
            return $m.Groups[1].Value
        }
    }

    It 'release.yml runs on v* tags and on manual dry runs with a tag input' {
        $script:ReleaseYml | Should -Match "(?m)^\s+tags:\s*\[\s*'v\*'\s*\]"
        $script:ReleaseYml | Should -Match '(?m)^\s+workflow_dispatch:'
        $script:ReleaseYml | Should -Match '(?m)^\s+tag:'
    }

    It 'grants contents: write only to the publish job, which runs only for tag pushes' {
        $script:ReleaseYml | Should -Match '(?m)^permissions:\s*\n\s+contents: read'
        ([regex]::Matches($script:ReleaseYml, 'contents:\s*write')).Count | Should -Be 1
        $publish = Get-JobBlock -Yaml $script:ReleaseYml -Job 'publish'
        $publish | Should -Match 'contents:\s*write'
        $publish | Should -Match "if: github\.event_name == 'push'"
        $publish | Should -Match 'gh release create'
    }

    It 'uses only the pinned checkout and upload-artifact actions' {
        $uses = @([regex]::Matches($script:ReleaseYml, '(?m)^\s*-?\s*uses:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $uses.Count | Should -BeGreaterThan 0
        foreach ($u in $uses) {
            $u | Should -BeIn @('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a')
        }
    }

    It 'checks the tag, tests, signs before zipping, guards the MSI/winget scripts, and writes SHA256SUMS last' {
        $y = $script:ReleaseYml
        $y | Should -Match 'build/Invoke-Tests\.ps1'
        $y | Should -Match 'Test-Path build/Build-Msi\.ps1'
        $y | Should -Match 'Test-Path build/New-WingetManifest\.ps1'
        $y | Should -Match 'OMNIDIAG_SIGN_PFX_BASE64'
        $y | Should -Match 'OMNIDIAG_SIGN_PFX_PASSWORD'
        $y | Should -Match 'Get-ReleaseNotes\.ps1'
        $iTag = $y.IndexOf('Verify the tag', [System.StringComparison]::Ordinal)
        $iTests = $y.IndexOf('build/Invoke-Tests.ps1', [System.StringComparison]::Ordinal)
        $iZip = $y.IndexOf('Build-Portable.ps1', [System.StringComparison]::Ordinal)
        $iSbom = $y.IndexOf('New-Sbom.ps1', [System.StringComparison]::Ordinal)
        $iSums = $y.IndexOf('New-ReleaseManifest.ps1', [System.StringComparison]::Ordinal)
        $iTag | Should -BeGreaterThan 0
        $iTag | Should -BeLessThan $iTests
        $iTests | Should -BeLessThan $iZip
        $iZip | Should -BeLessThan $iSbom
        $iSbom | Should -BeLessThan $iSums
        $y | Should -Match 'install\.ps1'
        # Secrets are only ever handed to steps through env, never interpolated into scripts.
        $y | Should -Not -Match 'run:.*\$\{\{\s*secrets\.'
    }

    It 'ci.yml has blocking reproducible and signing jobs' {
        foreach ($job in 'reproducible', 'signing') {
            $block = Get-JobBlock -Yaml $script:CiYml -Job $job
            $block | Should -Not -BeNullOrEmpty -Because "ci.yml needs a '$job' job"
            $block | Should -Not -Match 'continue-on-error:\s*true'
        }
        $repro = Get-JobBlock -Yaml $script:CiYml -Job 'reproducible'
        ([regex]::Matches($repro, 'actions/checkout@')).Count | Should -Be 2
        $sign = Get-JobBlock -Yaml $script:CiYml -Job 'signing'
        $sign | Should -Match 'New-SelfSignedCertificate -Type CodeSigningCert'
        $sign | Should -Match 'Test-ReleaseSignature\.ps1'
        $sign | Should -Match 'if: always\(\)'
    }
}
