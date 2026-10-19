#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Static and generator checks for the per-user MSI and the winget manifest
    (docs/INSTALLER.md): installer/OmniDiag.wxs, build/OmniDiag.Installer.psm1,
    build/Build-Msi.ps1 -GenerateOnly, build/New-WingetManifest.ps1, the installed-mode
    data location, and the launcher shim. OS-independent: no WiX, no msiexec, no network.
    The real build, install, and uninstall run in the CI 'installer' job (Windows).
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'build/OmniDiag.Installer.psm1') -Force -DisableNameChecking
    $script:WxsPath = Join-Path $script:Root 'installer/OmniDiag.wxs'
    $script:WxsText = [System.IO.File]::ReadAllText($script:WxsPath)
    $script:Wxs = [xml]$script:WxsText
    $script:Ns = [System.Xml.XmlNamespaceManager]::new($script:Wxs.NameTable)
    $script:Ns.AddNamespace('w', 'http://wixtoolset.org/schemas/v4/wxs')
    $script:Package = $script:Wxs.SelectSingleNode('/w:Wix/w:Package', $script:Ns)
    $script:PsdVersion = [string](Import-PowerShellDataFile -Path (Join-Path $script:Root 'src/OmniDiag.psd1')).ModuleVersion
    $script:Version = ConvertTo-OmniThreePartVersion $script:PsdVersion
    # The UpgradeCode must never change: it links every release for MajorUpgrade and winget.
    $script:UpgradeCode = '{7A225708-9A90-4726-8BE4-3480CB561715}'
    $script:PwshExe = (Get-Process -Id $PID).Path
}

Describe 'installer/OmniDiag.wxs' {
    It 'is well-formed WiX v4/v5 source with one Package' {
        $script:Wxs.DocumentElement.LocalName | Should -Be 'Wix'
        $script:Wxs.DocumentElement.NamespaceURI | Should -Be 'http://wixtoolset.org/schemas/v4/wxs'
        $script:Package | Should -Not -BeNullOrEmpty
    }

    It 'is ASCII-only' {
        $script:WxsText | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
    }

    It 'is per-user only, Windows Installer 5.0, and refuses ALLUSERS' {
        $script:Package.GetAttribute('Scope') | Should -Be 'perUser'
        $script:Package.GetAttribute('InstallerVersion') | Should -Be '500'
        $script:Wxs.SelectNodes("//w:Property[@Id='ALLUSERS' or @Id='MSIINSTALLPERUSER']", $script:Ns).Count | Should -Be 0
        $launch = @($script:Wxs.SelectNodes('//w:Launch', $script:Ns))
        ($launch | Where-Object { $_.GetAttribute('Condition') -match 'NOT ALLUSERS' }) | Should -Not -BeNullOrEmpty
    }

    It 'keeps the UpgradeCode constant (and in step with build/OmniDiag.Installer.psm1)' {
        $script:Package.GetAttribute('UpgradeCode') | Should -Be $script:UpgradeCode
        (Get-OmniInstallerConstant).UpgradeCode | Should -Be $script:UpgradeCode
    }

    It 'takes Version and ProductCode from the build script and names the publisher' {
        $script:Package.GetAttribute('Version') | Should -Be '$(var.Version)'
        $script:Package.GetAttribute('ProductCode') | Should -Be '$(var.ProductCode)'
        $script:Package.GetAttribute('Manufacturer') | Should -Be (Get-OmniInstallerConstant).Publisher
    }

    It 'has MajorUpgrade and ARP links to the repository' {
        $script:Wxs.SelectNodes('//w:MajorUpgrade', $script:Ns).Count | Should -Be 1
        $script:Wxs.SelectSingleNode("//w:Property[@Id='ARPURLINFOABOUT']", $script:Ns).GetAttribute('Value') | Should -Be 'https://github.com/Chris2003/OmniDiag'
    }

    It 'writes the registry under HKCU only' {
        $roots = @($script:Wxs.SelectNodes('//*[@Root]', $script:Ns) | ForEach-Object { $_.GetAttribute('Root') })
        $roots.Count | Should -BeGreaterThan 0
        ($roots | Where-Object { $_ -ne 'HKCU' }) | Should -BeNullOrEmpty
        $script:Wxs.SelectNodes('//w:RegistrySearch | //w:RegistryKey[@Root!="HKCU"]', $script:Ns).Count | Should -Be 0
    }

    It 'installs only under LocalAppData and the per-user Start menu' {
        $std = @($script:Wxs.SelectNodes('//w:StandardDirectory', $script:Ns) | ForEach-Object { $_.GetAttribute('Id') } | Sort-Object)
        $std | Should -Be @('LocalAppDataFolder', 'ProgramMenuFolder')
        $programs = $script:Wxs.SelectSingleNode("//w:StandardDirectory[@Id='LocalAppDataFolder']/w:Directory", $script:Ns)
        $programs.GetAttribute('Name') | Should -Be 'Programs'
        $programs.SelectSingleNode('w:Directory', $script:Ns).GetAttribute('Id') | Should -Be 'INSTALLFOLDER'
        $programs.SelectSingleNode('w:Directory', $script:Ns).GetAttribute('Name') | Should -Be 'OmniDiag'
    }

    It 'has no custom actions, scripts, services, UI extension, or binaries' {
        foreach ($name in @('CustomAction', 'CustomActionRef', 'SetProperty', 'SetDirectory', 'Binary', 'ServiceInstall',
                'ServiceControl', 'UIRef', 'UI', 'Custom', 'InstallExecuteSequence', 'InstallUISequence')) {
            $script:Wxs.SelectNodes("//w:$name", $script:Ns).Count | Should -Be 0 -Because "<$name> is not allowed"
        }
        $script:WxsText | Should -Not -Match 'xmlns:(ui|util|netfx)='
    }

    It 'adds only <install>\bin to the user PATH, last, removed on uninstall' {
        $envs = @($script:Wxs.SelectNodes('//w:Environment', $script:Ns))
        $envs.Count | Should -Be 1
        $e = $envs[0]
        $e.GetAttribute('Name') | Should -Be 'PATH'
        $e.GetAttribute('Value') | Should -Be '[INSTALLFOLDER]bin'
        $e.GetAttribute('Part') | Should -Be 'last'
        $e.GetAttribute('System') | Should -Be 'no'
        $e.GetAttribute('Permanent') | Should -Be 'no'
    }

    It 'gives every component an HKCU key path, and profile folders a RemoveFolder' {
        foreach ($c in @($script:Wxs.SelectNodes('//w:Component', $script:Ns))) {
            $key = $c.SelectSingleNode("w:RegistryValue[@KeyPath='yes']", $script:Ns)
            $key | Should -Not -BeNullOrEmpty -Because "component $($c.GetAttribute('Id')) needs an HKCU key path (ICE38)"
            $key.GetAttribute('Root') | Should -Be 'HKCU'
        }
        foreach ($id in @('LocalProgramsFolderCleanup', 'StartMenuShortcuts')) {
            $script:Wxs.SelectSingleNode("//w:Component[@Id='$id']/w:RemoveFolder", $script:Ns) | Should -Not -BeNullOrEmpty
        }
    }

    It 'creates the GUI and console Start menu shortcuts to the launchers' {
        $targets = @($script:Wxs.SelectNodes('//w:Shortcut', $script:Ns) | ForEach-Object { $_.GetAttribute('Target') } | Sort-Object)
        $targets | Should -Be @('[INSTALLFOLDER]OmniDiag-GUI.cmd', '[INSTALLFOLDER]OmniDiag.cmd')
    }
}

Describe 'Installer helpers (build/OmniDiag.Installer.psm1)' {
    It 'makes RFC 4122 version-5 GUIDs (matches an independent implementation)' {
        # Python: uuid.uuid5(uuid.UUID('958E1C7B-0865-4EF6-BB22-D9F3BB043FF1'), 'product:1.0.0:x64')
        Get-OmniStableGuid -Name 'product:1.0.0:x64' | Should -Be '{A49092C7-842D-5A18-9FEF-ED9D01981196}'
        Get-OmniStableGuid -Name 'product:1.0.0:arm64' | Should -Be '{70805874-9A9D-579F-803B-6F425651D8C8}'
        Get-OmniStableGuid -Name 'x' | Should -Be (Get-OmniStableGuid -Name 'x')
    }

    It 'accepts only MSI-compatible x.y.z versions' {
        Test-OmniVersionString '1.0.0' | Should -BeTrue
        Test-OmniVersionString '255.255.65535' | Should -BeTrue
        Test-OmniVersionString '1.0' | Should -BeFalse
        Test-OmniVersionString '1.0.0-rc1' | Should -BeFalse
        Test-OmniVersionString '256.0.0' | Should -BeFalse
        Test-OmniVersionString '1.0.0.0' | Should -BeFalse
    }

    It 'the module version in src/OmniDiag.psd1 is a valid MSI ProductVersion' {
        Test-OmniVersionString $script:Version | Should -BeTrue
    }

    Context 'payload fragment' {
        BeforeAll {
            $script:Payload = Join-Path $TestDrive 'payload'
            foreach ($d in @('src/Core', 'src/UI/Sections', 'bin', 'empty')) { New-Item -ItemType Directory -Path (Join-Path $script:Payload $d) -Force | Out-Null }
            foreach ($f in @('OmniDiag.cmd', 'OmniDiag-GUI.cmd', '.omnidiag-installed', 'src/OmniDiag.psd1', 'src/Core/Paths.psm1', 'src/UI/Sections/A & B.xaml', 'bin/omnidiag.cmd')) {
                [System.IO.File]::WriteAllText((Join-Path $script:Payload $f), 'x')
            }
            $script:Fragment = Get-OmniMsiPayloadXml -PayloadRoot $script:Payload
            $script:FragmentXml = [xml]$script:Fragment.Xml
        }

        It 'is well-formed and deterministic' {
            $script:FragmentXml.DocumentElement.LocalName | Should -Be 'Wix'
            (Get-OmniMsiPayloadXml -PayloadRoot $script:Payload).Xml | Should -BeExactly $script:Fragment.Xml
            $script:Fragment.FileCount | Should -Be 7
            $script:Fragment.DirectoryCount | Should -Be 7   # root, bin, empty, src, src/Core, src/UI, src/UI/Sections
        }

        It 'has unique identifiers and one HKCU-keyed component with a RemoveFolder per folder' {
            $ids = @($script:FragmentXml.SelectNodes('//*[@Id]') | ForEach-Object { $_.GetAttribute('Id') })
            @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
            $components = @($script:FragmentXml.GetElementsByTagName('Component'))
            $components.Count | Should -Be $script:Fragment.DirectoryCount
            foreach ($c in $components) {
                $reg = @($c.GetElementsByTagName('RegistryValue'))
                $reg.Count | Should -Be 1
                $reg[0].GetAttribute('Root') | Should -Be 'HKCU'
                $reg[0].GetAttribute('KeyPath') | Should -Be 'yes'
                @($c.GetElementsByTagName('RemoveFolder')).Count | Should -Be 1
            }
        }

        It 'uses name-based component GUIDs and nests folders under INSTALLFOLDER' {
            $script:Fragment.Components['src/Core'] | Should -Be (Get-OmniStableGuid -Name 'component:src/core')
            $script:Fragment.Components['.'] | Should -Be (Get-OmniStableGuid -Name 'component:')
            $script:FragmentXml.GetElementsByTagName('DirectoryRef')[0].GetAttribute('Id') | Should -Be 'INSTALLFOLDER'
            $names = @($script:FragmentXml.GetElementsByTagName('Directory') | ForEach-Object { $_.GetAttribute('Name') })
            $names | Should -Contain 'Sections'
        }

        It 'creates empty folders explicitly and escapes file names' {
            @($script:FragmentXml.GetElementsByTagName('CreateFolder')).Count | Should -Be 1
            $script:Fragment.Xml | Should -Match 'A &amp; B\.xaml'
        }
    }

    Context 'winget YAML subset' {
        It 'round-trips nested mappings, sequences, and quoting' {
            $doc = [ordered]@{
                PackageIdentifier = 'Chris2003.OmniDiag'
                PackageVersion    = '1.2.3'
                Note              = "it's: quoted"
                Flag              = 'yes'
                Commands          = @('omnidiag')
                Installers        = @([ordered]@{ Architecture = 'x64'; AppsAndFeaturesEntries = @([ordered]@{ UpgradeCode = '{X}' }) },
                    [ordered]@{ Architecture = 'arm64'; InstallerUrl = 'https://example.invalid/a.msi' })
                ManifestType      = 'installer'
                ManifestVersion   = '1.6.0'
            }
            $yaml = ConvertTo-OmniWingetYaml -Manifest $doc
            $yaml | Should -Match "(?m)^PackageVersion: '1\.2\.3'$"
            $yaml | Should -Match "(?m)^Flag: 'yes'$"
            $yaml | Should -Match "(?m)^Note: 'it''s: quoted'$"
            $back = ConvertFrom-OmniWingetYaml -Yaml $yaml
            ($back | ConvertTo-Json -Depth 8 -Compress) | Should -Be ($doc | ConvertTo-Json -Depth 8 -Compress)
            ConvertTo-OmniWingetYaml -Manifest $back | Should -BeExactly $yaml
        }

        It 'refuses YAML it does not understand' {
            { ConvertFrom-OmniWingetYaml -Yaml "Commands: [omnidiag]`n" } | Should -Throw
            { ConvertFrom-OmniWingetYaml -Yaml "A: 1`n  B: 2`n" } | Should -Throw
        }
    }
}

Describe 'build/New-WingetManifest.ps1' {
    BeforeAll {
        $script:Script = Join-Path $script:Root 'build/New-WingetManifest.ps1'
        $script:MsiDir = Join-Path $TestDrive 'msi'
        New-Item -ItemType Directory -Path $script:MsiDir -Force | Out-Null
        $script:X64 = Join-Path $script:MsiDir "OmniDiag-$($script:Version)-x64.msi"
        $script:Arm = Join-Path $script:MsiDir "OmniDiag-$($script:Version)-arm64.msi"
        [System.IO.File]::WriteAllText($script:X64, 'fake x64 msi')
        [System.IO.File]::WriteAllText($script:Arm, 'fake arm64 msi')
        $script:CodeX64 = Get-OmniStableGuid -Name "product:$($script:Version):x64"
        $script:CodeArm = Get-OmniStableGuid -Name "product:$($script:Version):arm64"
        $script:Out1 = Join-Path $TestDrive 'winget1'
        $script:Out2 = Join-Path $TestDrive 'winget2'
        $script:Result = & $script:Script -Version $script:Version -InstallerPath $script:X64, $script:Arm -OutputDirectory $script:Out1 `
            -ProductCode $script:CodeX64, $script:CodeArm -PassThru 6>$null
        & $script:Script -Version $script:Version -InstallerPath $script:X64, $script:Arm -OutputDirectory $script:Out2 `
            -ProductCode $script:CodeX64, $script:CodeArm 6>$null | Out-Null
        $script:Names = @('Chris2003.OmniDiag.yaml', 'Chris2003.OmniDiag.installer.yaml', 'Chris2003.OmniDiag.locale.en-US.yaml')
        $script:Installer = ConvertFrom-OmniWingetYaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $script:Out1 'Chris2003.OmniDiag.installer.yaml')))
        $script:Locale = ConvertFrom-OmniWingetYaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $script:Out1 'Chris2003.OmniDiag.locale.en-US.yaml')))
        $script:VersionDoc = ConvertFrom-OmniWingetYaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $script:Out1 'Chris2003.OmniDiag.yaml')))
    }

    It 'writes the three multi-file manifests, byte-identical across runs, ASCII without BOM' {
        foreach ($n in $script:Names) {
            $a = [System.IO.File]::ReadAllBytes((Join-Path $script:Out1 $n))
            $b = [System.IO.File]::ReadAllBytes((Join-Path $script:Out2 $n))
            [Convert]::ToBase64String($a) | Should -Be ([Convert]::ToBase64String($b)) -Because "$n must be deterministic"
            $a[0] | Should -Not -Be 0xEF
            @($a | Where-Object { $_ -gt 0x7E -or $_ -eq 0x0D }).Count | Should -Be 0
        }
    }

    It 'declares manifest v1.6.0 for Chris2003.OmniDiag at the psd1 version' {
        foreach ($d in @($script:VersionDoc, $script:Installer, $script:Locale)) {
            $d['PackageIdentifier'] | Should -Be 'Chris2003.OmniDiag'
            $d['PackageVersion'] | Should -Be $script:Version
            $d['ManifestVersion'] | Should -Be '1.6.0'
        }
        $script:VersionDoc['ManifestType'] | Should -Be 'version'
        $script:VersionDoc['DefaultLocale'] | Should -Be 'en-US'
    }

    It 'describes a per-user MSI with the omnidiag command' {
        $script:Installer['InstallerType'] | Should -Be 'msi'
        $script:Installer['Scope'] | Should -Be 'user'
        @($script:Installer['Commands']) | Should -Be @('omnidiag')
        $script:Installer['ManifestType'] | Should -Be 'installer'
    }

    It 'points each installer at the GitHub release with its SHA256 and ProductCode' {
        $items = @($script:Installer['Installers'])
        $items.Count | Should -Be 2
        $byArch = @{}; foreach ($i in $items) { $byArch[$i['Architecture']] = $i }
        $byArch['x64']['InstallerUrl'] | Should -Be "https://github.com/Chris2003/OmniDiag/releases/download/v$($script:Version)/OmniDiag-$($script:Version)-x64.msi"
        $byArch['x64']['InstallerSha256'] | Should -Be (Get-FileHash -LiteralPath $script:X64 -Algorithm SHA256).Hash
        $byArch['x64']['ProductCode'] | Should -Be $script:CodeX64
        $byArch['arm64']['InstallerSha256'] | Should -Be (Get-FileHash -LiteralPath $script:Arm -Algorithm SHA256).Hash
        $byArch['arm64']['ProductCode'] | Should -Be $script:CodeArm
        @($byArch['x64']['AppsAndFeaturesEntries'])[0]['UpgradeCode'] | Should -Be $script:UpgradeCode
    }

    It 'carries the MIT license and the required locale fields' {
        $script:Locale['License'] | Should -Be 'MIT'
        $script:Locale['Publisher'] | Should -Be 'OmniDiag Contributors'
        $script:Locale['PackageName'] | Should -Be 'OmniDiag'
        $script:Locale['ShortDescription'].Length | Should -BeLessOrEqual 256
        $script:Locale['ManifestType'] | Should -Be 'defaultLocale'
    }

    It 'returns the files and manifests with -PassThru' {
        @($script:Result.Files).Count | Should -Be 3
        $script:Result.Manifests['installer']['Scope'] | Should -Be 'user'
    }

    It 'fails (exit 1) on a version mismatch or a duplicate architecture' {
        & $script:Script -Version '9.9.9' -InstallerPath $script:X64 -OutputDirectory (Join-Path $TestDrive 'bad1') -ProductCode $script:CodeX64 *>$null
        $LASTEXITCODE | Should -Be 1
        & $script:Script -Version $script:Version -InstallerPath $script:X64, $script:X64 -OutputDirectory (Join-Path $TestDrive 'bad2') -ProductCode $script:CodeX64, $script:CodeX64 *>$null
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'build/Build-Msi.ps1 -GenerateOnly' {
    BeforeAll {
        $script:BuildMsi = Join-Path $script:Root 'build/Build-Msi.ps1'
        $script:PortableOut = Join-Path $TestDrive 'portable'
        $script:Portable = & (Join-Path $script:Root 'build/Build-Portable.ps1') -OutputDirectory $script:PortableOut 6>$null
        $script:Zip = @(Get-ChildItem -LiteralPath $script:PortableOut -Filter '*.zip' -File)[0].FullName
        $script:Work = Join-Path $TestDrive 'msi-work'
        $script:Gen = & $script:BuildMsi -Version $script:Version -OutputDirectory (Join-Path $TestDrive 'dist') -PayloadZip $script:Zip `
            -WorkDirectory $script:Work -GenerateOnly 6>$null
    }

    It 'stages the payload with the PATH shim and the installed-mode marker, without install.ps1' {
        $stage = Join-Path $script:Work 'payload'
        Join-Path $stage 'bin/omnidiag.cmd' | Should -Exist
        Join-Path $stage '.omnidiag-installed' | Should -Exist
        Join-Path $stage 'OmniDiag.cmd' | Should -Exist
        Join-Path $stage 'src/OmniDiag.psd1' | Should -Exist
        Join-Path $stage 'install.ps1' | Should -Not -Exist
        @(Get-ChildItem -LiteralPath (Join-Path $stage 'bin') -Force).Count | Should -Be 1
    }

    It 'writes the shim with CRLF line endings' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Work 'payload/bin/omnidiag.cmd'))
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Match "`r`n"
        $text | Should -Not -Match "[^`r]`n"
    }

    It 'generates a fragment that covers every staged file' {
        $script:Gen.Fragment | Should -Exist
        $xml = [xml][System.IO.File]::ReadAllText($script:Gen.Fragment)
        $staged = @(Get-ChildItem -LiteralPath (Join-Path $script:Work 'payload') -Recurse -File -Force).Count
        @($xml.GetElementsByTagName('File')).Count | Should -Be $staged
        $script:Gen.FileCount | Should -Be $staged
    }

    It 'refuses a -Version that does not match src/OmniDiag.psd1 (exit 1)' {
        & $script:BuildMsi -Version '9.9.9' -OutputDirectory (Join-Path $TestDrive 'dist') -PayloadZip $script:Zip -GenerateOnly `
            -WorkDirectory (Join-Path $TestDrive 'msi-work-bad') *>$null
        $LASTEXITCODE | Should -Be 1
    }

    It 'refuses a version MSI cannot represent (exit 1)' {
        & $script:BuildMsi -Version '1.0.0-rc1' -OutputDirectory (Join-Path $TestDrive 'dist') -PayloadZip $script:Zip -GenerateOnly *>$null
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'Installed mode (MSI) data location and launchers' {
    It 'resolves data to %LOCALAPPDATA%\OmniDiag\Data only when the MSI marker is present' {
        $tool = Join-Path $TestDrive 'tool'
        $core = Join-Path $tool 'src/Core'
        New-Item -ItemType Directory -Path $core -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Root 'src/Core/Paths.psm1') -Destination (Join-Path $core 'PathsUnderTest.psm1')
        $lad = Join-Path $TestDrive 'localappdata'
        New-Item -ItemType Directory -Path $lad -Force | Out-Null
        $probe = @'
param($Module, $Lad)
Remove-Item Env:OMNIDIAG_DATA -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $Lad
Import-Module $Module -Force
$r = Get-OmniDataRoot -Refresh
[pscustomobject]@{ Path = $r.Path; Source = $r.Source; IsPortable = $r.IsPortable } | ConvertTo-Json -Compress
'@
        $probePath = Join-Path $TestDrive 'probe.ps1'
        [System.IO.File]::WriteAllText($probePath, $probe)
        $module = Join-Path $core 'PathsUnderTest.psm1'

        $portable = & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $probePath -Module $module -Lad $lad | ConvertFrom-Json
        $portable.Source | Should -Be 'ToolFolder'
        $portable.IsPortable | Should -BeTrue

        [System.IO.File]::WriteAllText((Join-Path $tool '.omnidiag-installed'), 'marker')
        $installed = & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $probePath -Module $module -Lad $lad | ConvertFrom-Json
        $installed.Source | Should -Be 'Installed'
        $installed.IsPortable | Should -BeFalse
        $installed.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $lad 'OmniDiag') 'Data')))
    }

    It 'the portable package never carries the marker' {
        (Get-Content -LiteralPath (Join-Path $script:Root 'build/Build-Portable.ps1') -Raw) | Should -Not -Match 'omnidiag-installed'
        Join-Path $script:Root '.omnidiag-installed' | Should -Not -Exist
    }

    It 'both launchers switch to %LOCALAPPDATA%\OmniDiag\Data when the marker exists' {
        foreach ($cmd in @('OmniDiag.cmd', 'OmniDiag-GUI.cmd')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Root $cmd))
            $text | Should -Match ([regex]::Escape('if exist "%HERE%.omnidiag-installed" if defined LOCALAPPDATA set "OMNIDIAG_DATA=%LOCALAPPDATA%\OmniDiag\Data"'))
        }
    }

    It 'the PATH shim hands over to ..\OmniDiag.cmd without call' {
        $shim = [System.IO.File]::ReadAllText((Join-Path $script:Root 'installer/omnidiag.cmd'))
        $shim | Should -Match ([regex]::Escape('"%~dp0..\OmniDiag.cmd" %*'))
        $shim | Should -Not -Match '(?im)^\s*call\s'
        $shim | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
    }
}

Describe 'Installer licensing and CI wiring' {
    It 'pins WiX Toolset 5.0.2 in CI (not v6+, which adds the maintenance fee)' {
        $ci = [System.IO.File]::ReadAllText((Join-Path $script:Root '.github/workflows/ci.yml'))
        $ci | Should -Match 'dotnet tool install --global wix --version 5\.0\.2'
        $ci | Should -Not -Match 'wix --version [6-9]'
    }

    It 'documents the build-time WiX dependency and its license' {
        $doc = [System.IO.File]::ReadAllText((Join-Path $script:Root 'docs/INSTALLER.md'))
        $doc | Should -Match 'MS-RL'
        $doc | Should -Match '5\.0\.2'
        [System.IO.File]::ReadAllText((Join-Path $script:Root 'CREDITS.md')) | Should -Match 'WiX Toolset'
    }
}
