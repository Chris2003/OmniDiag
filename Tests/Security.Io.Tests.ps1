#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Phase 4 security review (docs/SECURITY-REVIEW.md), one Describe per item:
      1. --output / -OutputPath export path handling (canonical paths, no traversal,
         device paths, reserved names, or NTFS streams; host-derived file names sanitized)
      2. Zip-slip and zip-bomb guards on report-package (.zip) import
      3. Launchers pin the PowerShell executable instead of a PATH lookup
      4. Temp files only through Get-OmniDataPath (static AST check with an allowlist)
      5. No secrets in reports or logs (planted corpus through every exporter)
    Everything runs on Windows PowerShell 5.1 and pwsh 7, on Windows and Ubuntu; the one
    Windows-only check (running OmniDiag.cmd with a planted pwsh) skips elsewhere.
#>

BeforeDiscovery {
    $script:IsWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $script:IsWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $script:OldData = $env:OMNIDIAG_DATA
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    function Invoke-Cli {
        param([string[]] $Arguments)
        $out = [System.IO.StringWriter]::new()
        $err = [System.IO.StringWriter]::new()
        $code = Invoke-OmniDiagCli -Arguments $Arguments -Out $out -Err $err -In ([System.IO.StringReader]::new('')) -NonInteractive
        return [pscustomobject]@{ Code = $code; Out = $out.ToString(); Err = $err.ToString() }
    }

    function New-TinySession {
        param([string] $ComputerName = 'WS-01')
        $r = New-OmniResult -ModuleName 'Tiny' -Category 'Test'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Id 'tiny-warn' -Title 'Something to look at' -Severity 'Warning' -Component 'Test/Tiny')
        $null = Complete-OmniResult -Result $r
        $results = @($r)
        return [pscustomobject]@{
            PSTypeName = 'OmniDiag.Session'
            StartTime  = (Get-Date).AddSeconds(-2); EndTime = (Get-Date); DurationMs = 2000; Cancelled = $false
            TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
            Host       = [pscustomobject]@{ ComputerName = $ComputerName; UserName = 'tester'; PSVersion = '5.1' }
            IsAdmin    = $false
            Results    = $results
            Summary    = ($results | Get-OmniHealthScore)
        }
    }

    # Writes a zip whose entries are given verbatim (names are NOT normalized), so the
    # malicious names a hostile package would carry reach the importer unchanged.
    function New-TestZip {
        param([string] $Path, [object[]] $Entry)
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        try {
            $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($e in $Entry) {
                    $ze = $zip.CreateEntry([string]$e.Name)
                    $s = $ze.Open()
                    try {
                        if ($e.Contains('ZeroBytes')) {
                            $buf = New-Object byte[] (1MB)
                            $left = [long]$e.ZeroBytes
                            while ($left -gt 0) { $n = [int][math]::Min($left, $buf.Length); $s.Write($buf, 0, $n); $left -= $n }
                        } else {
                            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$e.Text)
                            $s.Write($bytes, 0, $bytes.Length)
                        }
                    } finally { $s.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
        return $Path
    }

    # A valid report document to embed in packages.
    $jsonPath = Export-OmniJsonReport -Session (New-TinySession) -Path (Join-Path $TestDrive 'valid-report.json')
    $script:ValidJson = [System.IO.File]::ReadAllText($jsonPath)
}

AfterAll {
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

# ---------------------------------------------------------------------------
# 1. Export path handling
# ---------------------------------------------------------------------------
Describe 'Security 1: export path handling (--output / -OutputPath)' {
    It 'canonicalizes .. segments before writing' {
        $requested = Join-Path $TestDrive 'a/b/../../canon/./out'
        $expected = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'canon/out'))
        Resolve-OmniOutputPath -Path $requested | Should -Be $expected
    }

    It 'resolves relative paths against the PowerShell location, not the process directory' {
        Push-Location -LiteralPath $TestDrive
        try {
            Resolve-OmniOutputPath -Path 'x/../rel.json' | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'rel.json')))
        } finally { Pop-Location }
    }

    It 'refuses the device path <_>' -ForEach @('\\.\PhysicalDrive0', '\\.\pipe\omnidiag', '\\?\C:\Windows\x.json', '//./COM1', '//?/C:/x.json', '\??\C:\x.json',
        '\\localhost\pipe\omnidiag', '\\127.0.0.1\pipe\x', '//localhost/PIPE/x', '\\server\mailslot\x', '\\localhost\pipe') {
        { Resolve-OmniOutputPath -Path $_ } | Should -Throw '*device path*'
    }

    It 'refuses the reserved device name <_>' -ForEach @('NUL', 'nul.json', 'CON', 'con.txt', 'PRN.html', 'AUX', 'COM1', 'com9.csv', 'LPT1.pdf', 'CONOUT$', 'NUL .json') {
        $p = Join-Path (Join-Path $TestDrive 'dev') $_
        { Resolve-OmniOutputPath -Path $p } | Should -Throw '*reserved device*'
    }

    It 'refuses a reserved device name in a folder component' {
        { Resolve-OmniOutputPath -Path (Join-Path (Join-Path $TestDrive 'NUL') 'report.json') } | Should -Throw '*reserved device*'
    }

    It 'refuses NTFS alternate data streams (<_>)' -ForEach @('report.json:hidden', 'report.json::$DATA', 'dir:ads/report.json') {
        $p = Join-Path (Join-Path $TestDrive 'ads') $_
        { Resolve-OmniOutputPath -Path $p } | Should -Throw
    }

    It 'refuses a path that leaves -Root' {
        $root = Join-Path $TestDrive 'jail'
        { Resolve-OmniOutputPath -Path (Join-Path $root '../../escape.json') -Root $root } | Should -Throw '*outside*'
        Resolve-OmniOutputPath -Path (Join-Path $root 'sub/../in.json') -Root $root |
            Should -Be ([System.IO.Path]::GetFullPath((Join-Path $root 'in.json')))
    }

    It 'sanitizes host-derived file names: <Name> -> <Expected>' -ForEach @(
        @{ Name = '..\..\evil'; Expected = '.._.._evil' }
        @{ Name = '../../evil'; Expected = '.._.._evil' }
        @{ Name = 'C:\Windows\x'; Expected = 'C__Windows_x' }
        @{ Name = 'report.json:stream'; Expected = 'report.json_stream' }
        @{ Name = 'a/b\c:d*e?f"g<h>i|j'; Expected = 'a_b_c_d_e_f_g_h_i_j' }
        @{ Name = '..'; Expected = 'file' }
        @{ Name = '.'; Expected = 'file' }
        @{ Name = 'trailing. . '; Expected = 'trailing' }
        @{ Name = 'CON'; Expected = '_CON' }
        @{ Name = 'nul.txt'; Expected = '_nul.txt' }
        @{ Name = ''; Expected = 'file' }
    ) {
        ConvertTo-OmniSafeFileName -Name $Name | Should -BeExactly $Expected
        $Expected.IndexOfAny([char[]]@('\', '/', ':')) | Should -Be -1
    }

    It 'Get-OmniSafeName never yields a traversal or device name' {
        # Internal to the module (not in FunctionsToExport): call it in the module's scope.
        $safe = { param($v) & (Get-Module OmniDiag) { param($x) Get-OmniSafeName $x } $v }
        & $safe '..' | Should -Be 'host'
        & $safe 'NUL' | Should -Be '_NUL'
        & $safe '..\..\x' | Should -Not -Match '[\\/:]'
    }

    It 'keeps every report file inside the output folder when the computer name is hostile (<_>)' -ForEach @('..\..\evil', '../../evil', 'EVIL:stream', 'C:\Windows\Temp\evil', 'NUL') {
        $out = Join-Path $TestDrive ('host-' + [guid]::NewGuid().ToString('N'))
        $set = Export-OmniDiagReport -Session (New-TinySession -ComputerName $_) -OutputDirectory $out -Format Html, Json, Csv, Md, Zip
        $outFull = [System.IO.Path]::GetFullPath($out)
        @($set.Files).Count | Should -BeGreaterThan 0
        foreach ($f in $set.Files) {
            [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($f)) | Should -Be $outFull
            Split-Path $f -Leaf | Should -Not -Match ':'
        }
        # Nothing escaped to the folders a '..\..\' name would reach.
        foreach ($above in @($TestDrive, (Split-Path $TestDrive -Parent))) {
            @(Get-ChildItem -LiteralPath $above -File -Filter '*evil*' -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
    }

    It 'keeps every report file inside the output folder when -BaseName is hostile' {
        $out = Join-Path $TestDrive 'basename'
        $set = Export-OmniDiagReport -Session (New-TinySession) -OutputDirectory $out -Format Json, Csv -BaseName '..\..\..\escaped/x:y'
        $outFull = [System.IO.Path]::GetFullPath($out)
        foreach ($f in $set.Files) { [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($f)) | Should -Be $outFull }
        $set.BaseName | Should -Not -Match '[\\/:]'
    }

    It 'redacted packages keep their (redacted) file name in the requested folder' {
        $dir = Join-Path $TestDrive 'redpkg'
        $zip = Export-OmniReportPackage -Session (New-TinySession -ComputerName 'WS-01') -Path (Join-Path $dir 'WS-01.zip') -Redact
        [System.IO.Path]::GetDirectoryName($zip) | Should -Be ([System.IO.Path]::GetFullPath($dir))
        Split-Path $zip -Leaf | Should -Not -Match 'WS-01'
    }

    It 'reports the canonical output folder' {
        $set = Export-OmniDiagReport -Session (New-TinySession) -OutputDirectory (Join-Path $TestDrive 'x/../canonical-out') -Format Json
        $set.OutputDirectory | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'canonical-out')))
    }

    It 'single-file exporters refuse a stream or device target' {
        { Export-OmniJsonReport -Session (New-TinySession) -Path (Join-Path $TestDrive 'r.json:hidden') } | Should -Throw
        { Export-OmniCsvReport -Session (New-TinySession) -Path (Join-Path $TestDrive 'NUL.csv') } | Should -Throw '*reserved device*'
        { Save-OmniSession -Session (New-TinySession) -Path '\\.\PhysicalDrive0' } | Should -Throw '*device path*'
    }

    It 'the CLI treats a device, stream, or reserved --output as a usage error (exit 10)' -ForEach @('\\.\PhysicalDrive0', 'NUL', 'version.txt:ads') {
        $target = $_
        if ($target -notlike '\\*') { $target = Join-Path $TestDrive $target }
        $r = Invoke-Cli -Arguments @('version', '--output', $target)
        $r.Code | Should -Be 10
    }

    It 'the CLI names the offending option (--redaction-map) in the refusal' {
        $saved = Save-OmniSession -Session (New-TinySession) -Path (Join-Path $TestDrive 'map-session.json')
        $r = Invoke-Cli -Arguments @('report', '--from-session', $saved, '--output', (Join-Path $TestDrive 'map-out'), '--redact', '--redaction-map', (Join-Path $TestDrive 'NUL.json'))
        $r.Code | Should -Be 10
        $r.Err | Should -Match '--redaction-map'
    }

    It 'the CLI writes a traversing --output to its canonical location' {
        $r = Invoke-Cli -Arguments @('version', '--output', (Join-Path $TestDrive 'cli/sub/../version.txt'))
        $r.Code | Should -Be 0
        Join-Path $TestDrive 'cli/version.txt' | Should -Exist
    }

    It 'CSV exporters write to literal paths (no wildcard expansion of [ ])' {
        $dir = Join-Path $TestDrive 'brackets[1]'
        $p = Export-OmniCsvReport -Session (New-TinySession) -Path (Join-Path $dir 'findings.csv')
        Test-Path -LiteralPath (Join-Path $dir 'findings.csv') | Should -BeTrue
        $p | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 2. Zip-slip / zip bomb on report-package import
# ---------------------------------------------------------------------------
Describe 'Security 2: report-package (.zip) import' {
    BeforeAll {
        $script:ZipDir = Join-Path $TestDrive 'zips'
        New-Item -ItemType Directory -Path $script:ZipDir -Force | Out-Null
        $script:Outside = Join-Path (Split-Path $TestDrive -Parent) ('omnidiag-zipslip-' + [guid]::NewGuid().ToString('N') + '.txt')
    }

    It 'imports a well-formed package (root or one folder deep)' {
        $ok = New-TestZip -Path (Join-Path $script:ZipDir 'ok.zip') -Entry @(@{ Name = 'data.json'; Text = $script:ValidJson }, @{ Name = 'README.txt'; Text = 'hi' })
        @((Import-OmniDiagSession -Path $ok).Results).Count | Should -Be 1
        $nested = New-TestZip -Path (Join-Path $script:ZipDir 'nested.zip') -Entry @(@{ Name = 'pkg/data.json'; Text = $script:ValidJson })
        @((Import-OmniDiagSession -Path $nested).Results).Count | Should -Be 1
    }

    It 'imports a package written by Export-OmniReportPackage' {
        $zip = Export-OmniReportPackage -Session (New-TinySession) -Path (Join-Path $script:ZipDir 'real.zip')
        @((Import-OmniDiagSession -Path $zip).Results).Count | Should -Be 1
    }

    It 'refuses a package with the entry <Name> (<Why>)' -ForEach @(
        @{ Name = '../data.json'; Why = 'traversal' }
        @{ Name = '..\..\data.json'; Why = 'traversal' }
        @{ Name = 'reports/../../../evil.txt'; Why = 'traversal' }
        @{ Name = '/etc/data.json'; Why = 'absolute' }
        @{ Name = '\Windows\Temp\evil.txt'; Why = 'absolute' }
        @{ Name = 'C:/Windows/Temp/evil.txt'; Why = 'drive letter' }
        @{ Name = 'C:evil.txt'; Why = 'drive letter' }
        @{ Name = 'readme.txt:hidden'; Why = 'NTFS stream' }
        @{ Name = 'NUL'; Why = 'device' }
        @{ Name = 'aux.json'; Why = 'device' }
    ) {
        $path = Join-Path $script:ZipDir ('bad-' + [guid]::NewGuid().ToString('N') + '.zip')
        $entries = @(@{ Name = 'data.json'; Text = $script:ValidJson }, @{ Name = $Name; Text = 'pwned' })
        if ($Name -like '*data.json') { $entries = @(@{ Name = $Name; Text = $script:ValidJson }) }
        New-TestZip -Path $path -Entry $entries | Out-Null
        { Import-OmniDiagSession -Path $path } | Should -Throw '*rejected*'
        $script:Outside | Should -Not -Exist
    }

    It 'refuses a package with too many entries' {
        $entries = @(@{ Name = 'data.json'; Text = $script:ValidJson }) + @(1..300 | ForEach-Object { @{ Name = "f/$_.txt"; Text = 'x' } })
        $path = New-TestZip -Path (Join-Path $script:ZipDir 'many.zip') -Entry $entries
        { Import-OmniDiagSession -Path $path } | Should -Throw '*entries*'
    }

    It 'refuses a data.json that inflates past 64 MB (zip bomb) without reading it into memory' {
        $path = New-TestZip -Path (Join-Path $script:ZipDir 'bomb.zip') -Entry @(@{ Name = 'data.json'; ZeroBytes = (65MB) })
        (Get-Item -LiteralPath $path).Length | Should -BeLessThan (1MB)
        { Import-OmniDiagSession -Path $path } | Should -Throw '*limit*'
    }

    It 'compare refuses a malicious package too' {
        $bad = New-TestZip -Path (Join-Path $script:ZipDir 'cmp-bad.zip') -Entry @(@{ Name = '../../data.json'; Text = $script:ValidJson })
        $good = New-TestZip -Path (Join-Path $script:ZipDir 'cmp-good.zip') -Entry @(@{ Name = 'data.json'; Text = $script:ValidJson })
        $r = Invoke-Cli -Arguments @('compare', $bad, $good)
        $r.Code | Should -Not -Be 0
        $r.Err | Should -Match 'rejected'
    }

    It 'install.ps1 validates the downloaded archive before Expand-Archive' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Root 'install.ps1'))
        $guard = $text.IndexOf('unsafe entry name', [System.StringComparison]::Ordinal)
        $expand = $text.IndexOf('Expand-Archive -LiteralPath', [System.StringComparison]::Ordinal)
        $guard | Should -BeGreaterThan 0
        $guard | Should -BeLessThan $expand
        $text | Should -Match 'Get-OmniZipEntryNameProblem'
    }

    It 'install.ps1 archive check refuses <Why> (the real block, run against a malicious zip)' -ForEach @(
        @{ Name = '../evil.txt'; Why = 'traversal'; ZeroBytes = $null }
        @{ Name = 'C:/evil.txt'; Why = 'a drive letter'; ZeroBytes = $null }
        @{ Name = 'repo/readme.txt:ads'; Why = 'an NTFS stream'; ZeroBytes = $null }
        @{ Name = 'repo/NUL.txt'; Why = 'a device name'; ZeroBytes = $null }
        @{ Name = "repo/bad`tname.txt"; Why = 'control characters'; ZeroBytes = $null }
        @{ Name = 'repo/bomb.bin'; Why = 'an entry inflating past 64 MB'; ZeroBytes = (65MB) }
    ) {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Root 'install.ps1'))
        $start = $text.IndexOf('# Zip-slip / zip-bomb guard', [System.StringComparison]::Ordinal)
        $end = $text.IndexOf('Expand-Archive -LiteralPath', [System.StringComparison]::Ordinal)
        $start | Should -BeGreaterThan 0
        $block = [scriptblock]::Create($text.Substring($start, $end - $start))
        $entry = @{ Name = $Name; Text = 'x' }
        if ($null -ne $ZeroBytes) { $entry = @{ Name = $Name; ZeroBytes = $ZeroBytes } }
        # The block reads $archivePath from the calling scope, as in install.ps1.
        try {
            $archivePath = New-TestZip -Path (Join-Path $script:ZipDir ('inst-' + [guid]::NewGuid().ToString('N') + '.zip')) -Entry @(@{ Name = 'repo/OmniDiag.ps1'; Text = '#' }, $entry)
        } catch {
            # .NET Framework's ZipArchive refuses to write some of these names ("Illegal
            # characters in path"), and Expand-Archive on it refuses to extract them too.
            if ($PSVersionTable.PSEdition -eq 'Desktop') { Set-ItResult -Skipped -Because "this .NET Framework cannot create the entry '$Name'"; return }
            throw
        }
        $message = $null
        try { . $block } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Match 'unsafe entry name|refusing to extract'
    }

    It 'install.ps1 archive check accepts a normal archive' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Root 'install.ps1'))
        $start = $text.IndexOf('# Zip-slip / zip-bomb guard', [System.StringComparison]::Ordinal)
        $end = $text.IndexOf('Expand-Archive -LiteralPath', [System.StringComparison]::Ordinal)
        $block = [scriptblock]::Create($text.Substring($start, $end - $start))
        $archivePath = New-TestZip -Path (Join-Path $script:ZipDir 'inst-ok.zip') -Entry @(@{ Name = 'repo/OmniDiag.ps1'; Text = '#' }, @{ Name = 'repo/src/OmniDiag.psd1'; Text = '@{}' })
        { . $block } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 3. Launchers pin the PowerShell executable
# ---------------------------------------------------------------------------
Describe 'Security 3: launcher executable resolution' {
    It '<Name> never looks pwsh / powershell up through PATH or the current directory' -ForEach @(
        @{ Name = 'OmniDiag.cmd' }, @{ Name = 'OmniDiag-GUI.cmd' }
    ) {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Root $Name))
        $code = @($lines | Where-Object { $_ -notmatch '^\s*(@?rem\b|::)' })
        # No 'where' / 'where.exe' lookups at all.
        @($code | Where-Object { $_ -match '(?i)(^|[\s&|(])where(\.exe)?\s' }) | Should -BeNullOrEmpty
        # No bare pwsh / powershell token outside a path (echo text excluded).
        $bare = @($code | Where-Object { $_ -notmatch '^\s*echo\b' -and $_ -match '(?i)(?<![\\\w.%-])(pwsh|powershell)(\.exe)?(?![\w\\])' })
        $bare | Should -BeNullOrEmpty -Because "a bare name is resolved through PATH / the current directory: $($bare -join ' | ')"
        # Every PSEXE assignment is a pinned, absolute location.
        $sets = @($code | Where-Object { $_ -match '(?i)set "PSEXE=' })
        $sets.Count | Should -BeGreaterOrEqual 2
        foreach ($s in $sets) {
            $s | Should -Match '(?i)set "PSEXE=%(SystemRoot|ProgramFiles|ProgramFiles\(x86\)|ProgramW6432)%\\'
        }
        ($code -join "`n") | Should -Match ([regex]::Escape('set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"'))
        ($code -join "`n") | Should -Match ([regex]::Escape('%ProgramFiles%\PowerShell\7\pwsh.exe'))
        ($code -join "`n") | Should -Match ([regex]::Escape('%ProgramW6432%\PowerShell\7\pwsh.exe'))
        # pwsh is still preferred: its assignments come after the Windows PowerShell default.
        $win = [array]::FindIndex([string[]]$code, [Predicate[string]] { param($l) $l -match 'set "PSEXE=%SystemRoot%' })
        $pw = [array]::FindIndex([string[]]$code, [Predicate[string]] { param($l) $l -match 'pwsh\.exe' -and $l -match 'set "PSEXE=' })
        $pw | Should -BeGreaterThan $win
        # Optional locations are guarded with 'if defined' (an unset variable would point at the drive root).
        foreach ($s in @($sets | Where-Object { $_ -match 'pwsh\.exe' })) { $s | Should -Match '(?i)^\s*if defined \S+ if exist "' }
        # The launch itself uses the pinned variable.
        @($code | Where-Object { $_ -match '"%PSEXE%" -NoProfile -ExecutionPolicy Bypass' }).Count | Should -Be 1
    }

    It '<Name> keeps the portable environment setup' -ForEach @(@{ Name = 'OmniDiag.cmd' }, @{ Name = 'OmniDiag-GUI.cmd' }) {
        $text = Get-Content -LiteralPath (Join-Path $script:Root $Name) -Raw
        $text | Should -Match 'OMNIDIAG_DATA=%HERE%OmniDiagData'
        $text | Should -Match 'OMNIDIAG_HOST_TEMP=%TEMP%'
        $text | Should -Match 'POWERSHELL_TELEMETRY_OPTOUT=1'
    }

    It 'the Restart Explorer repair starts explorer.exe from the Windows folder' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Root 'src/Repairs/RestartExplorer.psm1'))
        $text | Should -Not -Match "Start-Process\s+'explorer\.exe'"
        $text | Should -Match "Join-Path \`$windir 'explorer\.exe'"
    }

    It 'OmniDiag.cmd ignores a pwsh / powershell planted in PATH and the working directory' -Skip:(-not $script:IsWindowsHost) {
        $plant = Join-Path $TestDrive 'plant'
        New-Item -ItemType Directory -Path $plant -Force | Out-Null
        $marker = Join-Path $plant 'hijacked.txt'
        foreach ($n in @('pwsh.bat', 'pwsh.cmd', 'powershell.bat', 'powershell.cmd')) {
            [System.IO.File]::WriteAllText((Join-Path $plant $n), "@echo hijacked>`"$marker`"`r`n@exit /b 99`r`n")
        }
        $repoData = Join-Path $script:Root 'OmniDiagData'
        $repoDataExisted = Test-Path -LiteralPath $repoData
        $oldPath = $env:PATH
        $env:PATH = "$plant;$oldPath"
        Push-Location -LiteralPath $plant
        try {
            $null = & cmd.exe /d /c (Join-Path $script:Root 'OmniDiag.cmd') version
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
            $env:PATH = $oldPath
            if (-not $repoDataExisted -and (Test-Path -LiteralPath $repoData)) { Remove-Item -LiteralPath $repoData -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $marker | Should -Not -Exist
        $code | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 4. Temp files only through Get-OmniDataPath
# ---------------------------------------------------------------------------
Describe 'Security 4: temp files only through Get-OmniDataPath' {
    BeforeAll {
        # Deliberate, reviewed uses (docs/SECURITY-REVIEW.md item 4). Anything else fails.
        $script:TempAllowlist = @{
            # Last-resort data root when the tool folder is read-only (flagged IsPortable = $false).
            'src/Core/Paths.psm1|GetTempPath'          = $true
            # The temp scanner and the temp-clean repair inspect the HOST temp folder on purpose
            # (OMNIDIAG_HOST_TEMP first; the launchers redirect TEMP into the tool folder).
            'src/Modules/TempFiles.psm1|env:TEMP'      = $true
            'src/Repairs/ClearTempFiles.psm1|env:TEMP' = $true
            # The bootstrap installer runs before OmniDiag (and its data root) exists.
            'install.ps1|GetTempPath'                  = $true
        }

        function Find-OmniTempUsage {
            param([string] $Path)
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            $nodes = $ast.FindAll({
                    param($n)
                    if ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $m = $n.Member.Value
                        if ($m -in @('GetTempPath', 'GetTempFileName')) { return $true }
                        if ($m -eq 'GetEnvironmentVariable' -and $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                            @($n.Arguments).Count -gt 0 -and $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                            $n.Arguments[0].Value -in @('TEMP', 'TMP')) { return $true }
                        return $false
                    }
                    if ($n -is [System.Management.Automation.Language.CommandAst]) { return ($n.GetCommandName() -eq 'New-TemporaryFile') }
                    if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) { return ($n.VariablePath.UserPath -match '^(?i)env:(TEMP|TMP)$') }
                    return $false
                }, $true)
            foreach ($n in $nodes) {
                $kind = if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) { 'env:' + $n.VariablePath.UserPath.Substring(4).ToUpperInvariant() }
                elseif ($n -is [System.Management.Automation.Language.CommandAst]) { 'New-TemporaryFile' }
                elseif ($n.Member.Value -eq 'GetEnvironmentVariable') { 'env:' + ([string]$n.Arguments[0].Value).ToUpperInvariant() }
                else { [string]$n.Member.Value }
                [pscustomobject]@{ Kind = $kind; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text }
            }
        }

        function Get-RepoRelativePath([string] $FullName) {
            return $FullName.Substring($script:Root.Length).TrimStart('\', '/').Replace('\', '/')
        }

        $script:Scanned = @(
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) +
            @(Get-Item -LiteralPath (Join-Path $script:Root 'OmniDiag.ps1')) +
            @(Get-Item -LiteralPath (Join-Path $script:Root 'install.ps1'))
        )
        $script:TempHits = @(foreach ($f in $script:Scanned) {
                $rel = Get-RepoRelativePath $f.FullName
                foreach ($h in @(Find-OmniTempUsage -Path $f.FullName)) {
                    [pscustomobject]@{ Key = "$rel|$($h.Kind)"; Where = "${rel}:$($h.Line)"; Text = $h.Text }
                }
            })
    }

    It 'the AST check finds every temp API form in a planted sample' {
        $sample = Join-Path $TestDrive 'temp-sample.ps1'
        [System.IO.File]::WriteAllText($sample, @'
$a = [System.IO.Path]::GetTempPath()
$b = [IO.Path]::GetTempFileName()
$c = New-TemporaryFile
$d = Join-Path $env:TEMP 'x'
$e = $env:tmp
$f = [Environment]::GetEnvironmentVariable('TEMP')
'@)
        $kinds = @(Find-OmniTempUsage -Path $sample | ForEach-Object Kind)
        $kinds | Should -Be @('GetTempPath', 'GetTempFileName', 'New-TemporaryFile', 'env:TEMP', 'env:TMP', 'env:TEMP')
    }

    It 'src, OmniDiag.ps1, and install.ps1 use the system temp folder only where allowlisted' {
        $offenders = @($script:TempHits | Where-Object { -not $script:TempAllowlist.ContainsKey($_.Key) })
        $offenders | Should -BeNullOrEmpty -Because ("write scratch files through Get-OmniDataPath -Kind Temp: " + (($offenders | ForEach-Object { "$($_.Where) $($_.Text)" }) -join '; '))
    }

    It 'the allowlist has no stale entries' {
        $found = @{}
        foreach ($h in $script:TempHits) { $found[$h.Key] = $true }
        foreach ($k in $script:TempAllowlist.Keys) { $found.ContainsKey($k) | Should -BeTrue -Because "allowlist entry '$k' no longer matches code; remove it" }
    }

    It 'report packages stage their files under the data root temp folder' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Root 'src/Reporting/Package.psm1'))
        $text | Should -Match 'Get-OmniDataPath -Kind Temp'
    }
}

# ---------------------------------------------------------------------------
# 5. No secrets in reports or logs
# ---------------------------------------------------------------------------
Describe 'Security 5: no secrets in reports or logs' {
    BeforeAll {
        # The planted corpus: none of these strings may appear in any output.
        $script:Secrets = @(
            'Tr0ub4dor-Autologon', '123456-234567-345678', '345678-456789-567890', 'Env-S3cret-Value', 'Env2-S3cret', 'Env3-S3cret',
            'Pr0xy-Pa55', 'Cmd-S3cret-1', 'Tok-S3cret-2', 'WiFi-Pa55phrase', 'WiFi-Key-Material-9',
            'eyJhbGciOiJIUzI1NiJ9', 'Conn-S3cret', 'SasSig0123456789abcdef', 'Log-S3cret-Pw', 'LogData-S3cret', 'Err-S3cret'
        )
        $recoveryKey = '123456-234567-345678-456789-567890-678901-789012-890123'

        # Real collector: the proxy scanner with credentials in HTTP_PROXY (runs on any OS).
        $script:OldHttpProxy = $env:HTTP_PROXY
        $env:HTTP_PROXY = 'http://alice:Pr0xy-Pa55@proxy.corp.example:8080'
        try {
            $proxySession = Invoke-OmniDiagScan -Module 'network.proxy-configuration' -AsSession -MaxParallel 1
        } finally {
            if ($null -ne $script:OldHttpProxy) { $env:HTTP_PROXY = $script:OldHttpProxy } else { Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue }
        }
        $script:ProxyResult = @($proxySession.Results | Where-Object { $_.ModuleName -eq 'Proxy Configuration' })[0]

        # The run log: a real logger, fed secret-looking messages and data.
        $script:LogPath = Join-Path $TestDrive 'secret-run.jsonl'
        $logger = New-OmniLogger -Path $script:LogPath -MinimumLevel Debug
        $logger.Info('Read autologon DefaultPassword: Log-S3cret-Pw', 'Test')
        $logger.Warn("BitLocker protector $recoveryKey seen", 'Test', @{ password = 'LogData-S3cret'; note = 'DB_PASSWORD=Env-S3cret-Value' })

        # Findings and metrics the way collectors build them (factories + Complete-OmniResult).
        $r = New-OmniResult -ModuleName 'Secrets Fixture' -Category 'Security'
        Set-OmniResultMetric -Result $r -Name 'Winlogon' -Value ([ordered]@{ AutoAdminLogon = '1'; DefaultUserName = 'kiosk'; DefaultPassword = 'Tr0ub4dor-Autologon!' })
        Set-OmniResultMetric -Result $r -Name 'EnvironmentBlock' -Value 'PATH=C:\Tools;DB_PASSWORD=Env-S3cret-Value;password=Env2-S3cret MYSQL_PWD=Env3-S3cret'
        Set-OmniResultMetric -Result $r -Name 'Volumes' -Value @(
            [pscustomobject]@{ MountPoint = 'C:'; RecoveryPassword = $recoveryKey; Note = "Key $recoveryKey" }
        )
        Set-OmniResultMetric -Result $r -Name 'WlanProfile' -Value ("Profile CorpWifi`nKey Content            : WiFi-Pa55phrase`nCost : Unrestricted")
        Set-OmniResultMetric -Result $r -Name 'WlanKeys' -Value @{ KeyMaterial = 'WiFi-Key-Material-9' }
        Set-OmniResultMetric -Result $r -Name 'Requests' -Value @('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature', 'https://acct.blob.core.windows.net/c?sv=2020&sig=SasSig0123456789abcdef')
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Id 'secrets-autologon' -Title 'Autologon configured (DefaultPassword=Tr0ub4dor-Autologon!)' -Severity 'Warning' `
            -Component 'Security/Autologon' -Detail "Recovery key $recoveryKey is stored in plain text." `
            -LikelyCause 'Task runs: app.exe -Password Cmd-S3cret-1 --token=Tok-S3cret-2' -Recommendation 'Rotate Server=db;User ID=sa;Password=Conn-S3cret;' `
            -Data ([ordered]@{ CommandLine = 'sync.exe /secret:Cmd-S3cret-1'; Nested = [pscustomobject]@{ Token = 'Tok-S3cret-2'; Url = 'http://bob:Pr0xy-Pa55@proxy:3128' } }))
        $r.Error = 'Query failed: password=Err-S3cret'
        $null = Complete-OmniResult -Result $r

        $results = @($r, $script:ProxyResult)
        $script:Session = [pscustomobject]@{
            PSTypeName = 'OmniDiag.Session'
            StartTime  = (Get-Date).AddSeconds(-3); EndTime = (Get-Date); DurationMs = 3000; Cancelled = $false
            TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
            Host       = [pscustomobject]@{ ComputerName = 'WS-SEC'; UserName = 'tester'; PSVersion = '5.1' }
            IsAdmin    = $false
            Results    = $results
            Summary    = ($results | Get-OmniHealthScore)
            LogPath    = $script:LogPath
        }

        function Read-OutputText([string] $Path) {
            if ($Path -like '*.pdf') {
                $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($Path))
                return $raw.Replace('\\', [string][char]1).Replace('\(', '(').Replace('\)', ')').Replace([string][char]1, '\')
            }
            return [System.IO.File]::ReadAllText($Path)
        }

        # Every exporter: HTML, JSON, CSV (findings + events), Markdown, PDF, ZIP (all entries,
        # including the run log), plain and redacted; the native session; the CLI report.
        $script:Outputs = @{}
        $plain = Export-OmniDiagReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'sec-plain') -Format Html, Json, Csv, Md, Pdf, Zip
        $redacted = Export-OmniDiagReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'sec-redacted') -Format Html, Json, Csv, Md, Pdf, Zip -Redact
        $saved = Save-OmniSession -Session $script:Session -Path (Join-Path $TestDrive 'sec-session.json')
        foreach ($f in @($plain.Files) + @($redacted.Files) + @($saved) + @($script:LogPath)) {
            if ($f -like '*.zip') {
                $dest = Join-Path $TestDrive ('unzip-' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $f -DestinationPath $dest
                foreach ($e in Get-ChildItem -LiteralPath $dest -File -Recurse) { $script:Outputs["$f!$($e.Name)"] = Read-OutputText $e.FullName }
            } else {
                $script:Outputs[$f] = Read-OutputText $f
            }
        }
        $cli = Invoke-Cli -Arguments @('report', '--from-session', $saved, '--output', (Join-Path $TestDrive 'sec-cli'), '--format', 'json,csv,md')
        $script:CliCode = $cli.Code
        $script:Outputs['cli-stdout'] = $cli.Out + $cli.Err
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'sec-cli') -File -ErrorAction SilentlyContinue)) { $script:Outputs[$f.FullName] = Read-OutputText $f.FullName }
    }

    It 'Protect-OmniSecretText scrubs <In>' -ForEach @(
        @{ In = 'DefaultPassword=hunter2x'; Out = 'DefaultPassword=[REDACTED]' }
        @{ In = 'key 123456-234567-345678-456789-567890-678901-789012-890123 end'; Out = 'key [REDACTED-RECOVERY-KEY] end' }
        @{ In = 'http://u:p4ss@proxy:8080'; Out = 'http://[REDACTED]@proxy:8080' }
        @{ In = 'a.exe -Password abc123 -Force'; Out = 'a.exe -Password [REDACTED] -Force' }
        @{ In = 'X;DB_PASSWORD=abc;Y=1'; Out = 'X;DB_PASSWORD=[REDACTED];Y=1' }
        @{ In = 'Key Content : my wifi pass'; Out = 'Key Content : [REDACTED]' }
    ) {
        Protect-OmniSecretText $In | Should -BeExactly $Out
        Protect-OmniSecretText (Protect-OmniSecretText $In) | Should -BeExactly $Out
    }

    It 'Protect-OmniSecretText scrubs token formats: <In>' -ForEach @(
        @{ In = 'https://ghp_abcdefghijklmnopqrstuvwxyz0123@example.com/o/r'; Out = 'https://[REDACTED]@example.com/o/r' }
        @{ In = 'http://u:p@ss@host.example/x'; Out = 'http://[REDACTED]@host.example/x' }
        @{ In = 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abc-DEF_ghi end'; Out = 'jwt [REDACTED-JWT] end' }
        @{ In = 'pat ghp_abcdefghijklmnopqrstuvwxyz0123 end'; Out = 'pat [REDACTED-TOKEN] end' }
        @{ In = 'github_pat_11ABCDEFG0123456789_abcdefXYZ'; Out = '[REDACTED-TOKEN]' }
        @{ In = 'slack xoxb-1234567890-abcdefghij'; Out = 'slack [REDACTED-TOKEN]' }
        @{ In = 'aws AKIAIOSFODNN7EXAMPLE'; Out = 'aws [REDACTED-TOKEN]' }
    ) {
        Protect-OmniSecretText $In | Should -BeExactly $Out
        Protect-OmniSecretText (Protect-OmniSecretText $In) | Should -BeExactly $Out
    }

    It 'keeps hosts and structure when a later ''@'' is not URL user info: <_>' -ForEach @(
        '{"proxy":"http://proxy.corp:8080","owner":"ops@corp.com"}',
        'http://a;b@c',
        'Proxy,http://proxy.corp:8080,ops@corp.com',
        "see 'http://h:1' and y@z",
        'proxy (http://proxy.corp:8080) owner ops@corp.com'
    ) {
        Protect-OmniSecretText $_ | Should -BeExactly $_
    }

    It 'still masks URL user info next to JSON / CSV punctuation' {
        Protect-OmniSecretText '{"proxy":"http://bob:Hunter2@proxy:8080","owner":"ops@corp.com"}' |
            Should -BeExactly '{"proxy":"http://[REDACTED]@proxy:8080","owner":"ops@corp.com"}'
        Protect-OmniSecretText 'Proxy,http://bob:Hunter2@proxy:8080,ops@corp.com' |
            Should -BeExactly 'Proxy,http://[REDACTED]@proxy:8080,ops@corp.com'
    }

    It 'New-OmniFinding derives its Id from the scrubbed component and title' {
        $f = New-OmniFinding -Title 'Proxy http://bob:Title-S3cret@10.0.0.5 unreachable' -Severity 'Warning' -Component 'Net/http://u:Comp-S3cret@h'
        $f.Id | Should -Not -Match 'title-s3cret|comp-s3cret'
        $f.Id | Should -BeExactly (Get-OmniFindingAutoId -Component $f.Component -Title $f.Title)
    }

    It 'Protect-OmniSecretData rebuilds an auto-generated Id after scrubbing the title' {
        $title = 'Proxy http://bob:Hunter2@10.0.0.5 unreachable'
        $auto = [pscustomobject]@{ Id = (Get-OmniFindingAutoId -Component 'Network/Proxy' -Title $title); Title = $title; Component = 'Network/Proxy' }
        $fixed = [pscustomobject]@{ Id = 'network-proxy-unreachable'; Title = $title; Component = 'Network/Proxy' }
        Protect-OmniSecretData -InputObject $auto
        Protect-OmniSecretData -InputObject $fixed
        $auto.Id | Should -Not -Match 'hunter2'
        $auto.Id | Should -BeExactly (Get-OmniFindingAutoId -Component $auto.Component -Title $auto.Title)
        $fixed.Id | Should -BeExactly 'network-proxy-unreachable'
    }

    It 'a legacy session with a secret in an auto-generated Id leaks nothing into a redacted export' {
        # Saved before scrubbing existed: raw title, and the Id generated from it.
        $legacy = New-TinySession -ComputerName 'WS-IDS'
        $f = $legacy.Results[0].Findings[0]
        $f.Component = 'Network/Proxy'
        $f.Title = 'Proxy http://bob:Hunter2@10.0.0.5 unreachable'
        $f.Id = Get-OmniFindingAutoId -Component $f.Component -Title $f.Title
        $f.Id | Should -Match 'hunter2-10-0-0-5'
        $path = Save-OmniSession -Session $legacy -Path (Join-Path $TestDrive 'legacy-ids.json')

        $imported = Import-OmniDiagSession -Path $path
        $g = @($imported.Results[0].Findings)[0]
        $g.Id | Should -BeExactly (Get-OmniFindingAutoId -Component $g.Component -Title $g.Title)
        $set = Export-OmniDiagReport -Session $imported -OutputDirectory (Join-Path $TestDrive 'legacy-ids-out') -Format Html, Json, Csv, Md, Pdf, Zip -Redact
        $texts = @{}
        foreach ($file in $set.Files) {
            if ($file -like '*.zip') {
                $dest = Join-Path $TestDrive ('ids-unzip-' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $file -DestinationPath $dest
                foreach ($e in Get-ChildItem -LiteralPath $dest -File -Recurse) { $texts["$file!$($e.Name)"] = Read-OutputText $e.FullName }
            } else { $texts[$file] = Read-OutputText $file }
        }
        $texts.Count | Should -BeGreaterThan 5
        foreach ($k in $texts.Keys) {
            foreach ($needle in @('hunter2', '10.0.0.5', '10-0-0-5')) {
                $texts[$k].IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$needle' must not appear in $k"
            }
        }
    }

    It 'leaves identifiers alone: <_>' -ForEach @(
        'Thumbprint 3B1EFD3A66EA28B16697394703A72CA340A05BD5', '{6F9619FF-8B86-D011-B42D-00C04FC964FF}',
        'SHA256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'Account S-1-5-21-1004336348-1177238915-682003330-1001', 'Gateway 1.2.3.4 unreachable', 'Update KB5034441 failed'
    ) {
        Protect-OmniSecretText $_ | Should -BeExactly $_
    }

    It 'the logger scrubs a copy: the caller''s Data is not modified, ErrorRecords become text' {
        $path = Join-Path $TestDrive 'copy-log.jsonl'
        $logger = New-OmniLogger -Path $path -MinimumLevel Debug
        $data = @{ password = 'Caller-S3cret'; nested = [pscustomobject]@{ Url = 'http://a:Caller-Pw@h' } }
        $err = $null
        try { throw 'connect failed: password=Err-Rec-S3cret' } catch { $err = $_ }
        $logger.Warn('x', 'Test', $data)
        $logger.Error('y', 'Test', @{ Error = $err; Exception = $err.Exception })
        $data.password | Should -Be 'Caller-S3cret'
        $data.nested.Url | Should -Be 'http://a:Caller-Pw@h'
        $text = [System.IO.File]::ReadAllText($path)
        foreach ($secret in @('Caller-S3cret', 'Caller-Pw', 'Err-Rec-S3cret')) { $text | Should -Not -Match $secret }
        $text | Should -Match 'connect failed'
    }

    It 'New-OmniFinding leaves the caller''s -Data object unmodified' {
        $data = [ordered]@{ password = 'Finding-S3cret' }
        $null = New-OmniFinding -Title 't' -Severity 'Information' -Data $data
        $data.password | Should -Be 'Finding-S3cret'
    }

    It 'leaves ordinary diagnostic text alone: <_>' -ForEach @(
        'Elevated Token: Yes', 'Reset the password of jdoe.', 'It is a common password-guessing target.',
        'powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\x.ps1', 'Basic Display Adapter', 'PasswordNeverExpires'
    ) {
        Protect-OmniSecretText $_ | Should -BeExactly $_
    }

    It 'keeps non-secret metric names readable (PasswordLastSet, TokenCount)' {
        $x = [ordered]@{ PasswordLastSet = '2026-01-01'; TokenCount = '3'; Password = 'hunter22' }
        Protect-OmniSecretData -InputObject $x
        $x.PasswordLastSet | Should -Be '2026-01-01'
        $x.TokenCount | Should -Be '3'
        $x.Password | Should -Be '[REDACTED]'
    }

    It 'the proxy collector strips credentials from proxy URLs' {
        $script:ProxyResult | Should -Not -BeNullOrEmpty
        $script:ProxyResult.Metrics['EnvironmentProxy'] | Should -Match 'proxy\.corp\.example:8080'
        $script:ProxyResult.Metrics['EnvironmentProxy'] | Should -Not -Match 'Pr0xy-Pa55'
    }

    It 'every exporter produced output' {
        $script:Outputs.Count | Should -BeGreaterThan 15
        # 'report' exits 0-2 by the session's worst finding (docs/CLI.md); the fixture has warnings.
        $script:CliCode | Should -BeIn @(0, 1, 2)
        @($script:Outputs.Keys | Where-Object { $_ -like '*omnidiag-log.jsonl' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'no output contains the planted secret <_>' -ForEach @(
        'Tr0ub4dor-Autologon', '123456-234567-345678', '345678-456789-567890', 'Env-S3cret-Value', 'Env2-S3cret', 'Env3-S3cret',
        'Pr0xy-Pa55', 'Cmd-S3cret-1', 'Tok-S3cret-2', 'WiFi-Pa55phrase', 'WiFi-Key-Material-9',
        'eyJhbGciOiJIUzI1NiJ9', 'Conn-S3cret', 'SasSig0123456789abcdef', 'Log-S3cret-Pw', 'LogData-S3cret', 'Err-S3cret'
    ) {
        $secret = $_
        foreach ($k in $script:Outputs.Keys) {
            $script:Outputs[$k].IndexOf($secret, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$secret' must not appear in $k"
        }
    }

    It 'keeps the evidence readable (the key stays, the value is masked)' {
        $json = $script:Outputs[@($script:Outputs.Keys | Where-Object { $_ -like '*sec-plain*.json' })[0]]
        $json | Should -Match ([regex]::Escape('DB_PASSWORD=[REDACTED]'))
        $json | Should -Match ([regex]::Escape('[REDACTED-RECOVERY-KEY]'))
        $json | Should -Match 'kiosk'
    }

    It 'an imported legacy (0.7-style) session is scrubbed before any export' {
        # An older OmniDiag saved sessions unscrubbed. Reproduce that: a real session shape,
        # with secrets planted AFTER Complete-OmniResult (so nothing scrubbed them), saved raw.
        $legacy = New-TinySession -ComputerName 'WS-OLD'
        $res = $legacy.Results[0]
        $res.Metrics['Winlogon'] = [ordered]@{ DefaultUserName = 'kiosk'; DefaultPassword = 'Legacy-Autologon-Pw' }
        $res.Metrics['EnvironmentProxy'] = 'http://olduser:Legacy-Pr0xy@proxy:8080'
        $res.Findings[0].Detail = 'Uses http://olduser:Legacy-Pr0xy@proxy:8080 (DefaultPassword=Legacy-Autologon-Pw)'
        $res.Findings[0].Data = [ordered]@{ Password = 'Legacy-Data-Pw' }
        Add-Member -InputObject $legacy.Host -MemberType NoteProperty -Name Note -Value 'proxy http://olduser:Legacy-Pr0xy@proxy:8080'
        $legacyPath = Save-OmniSession -Session $legacy -Path (Join-Path $TestDrive 'legacy-session.json')
        [System.IO.File]::ReadAllText($legacyPath) | Should -Match 'Legacy-Autologon-Pw' -Because 'the fixture must start out unscrubbed'

        $imported = Import-OmniDiagSession -Path $legacyPath
        $imported.Host.Note | Should -Not -Match 'Legacy-Pr0xy'
        $set = Export-OmniDiagReport -Session $imported -OutputDirectory (Join-Path $TestDrive 'legacy-out') -Format Html, Json, Csv, Md, Pdf, Zip
        $texts = @{}
        foreach ($f in $set.Files) {
            if ($f -like '*.zip') {
                $dest = Join-Path $TestDrive ('legacy-unzip-' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $f -DestinationPath $dest
                foreach ($e in Get-ChildItem -LiteralPath $dest -File -Recurse) { $texts["$f!$($e.Name)"] = Read-OutputText $e.FullName }
            } else { $texts[$f] = Read-OutputText $f }
        }
        $texts.Count | Should -BeGreaterThan 5
        foreach ($k in $texts.Keys) {
            foreach ($secret in @('Legacy-Autologon-Pw', 'Legacy-Pr0xy', 'Legacy-Data-Pw')) {
                $texts[$k].IndexOf($secret, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$secret' must not appear in $k"
            }
        }
    }

    It 'Export-OmniReport scrubs a session changed outside the collectors (session-level fields too)' {
        $s = New-TinySession
        Add-Member -InputObject $s -MemberType NoteProperty -Name Notes -Value 'DefaultPassword=Late-Added-Pw'
        $s.Results[0].Metrics['LateMetric'] = 'http://late:Late-Metric-Pw@proxy'
        $s.Host.UserName = 'tester (token=Late-Host-Tok)'
        $set = Export-OmniDiagReport -Session $s -OutputDirectory (Join-Path $TestDrive 'late-out') -Format Json, Md, Html
        foreach ($f in $set.Files) {
            $t = [System.IO.File]::ReadAllText($f)
            foreach ($secret in @('Late-Added-Pw', 'Late-Metric-Pw', 'Late-Host-Tok')) { $t | Should -Not -Match $secret }
        }
    }

    It 'a completed result is scrubbed once (the engine does not walk it again; hot helpers are simple functions)' {
        $engine = [System.IO.File]::ReadAllText((Join-Path $script:Root 'src/Core/Engine.psm1'))
        $engine | Should -Not -Match 'Protect-OmniSecretData'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'src/Core/Models.psm1'), [ref]$tokens, [ref]$errors)
        foreach ($name in @('Protect-OmniSecretText', 'Protect-OmniSecretData')) {
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty
            @($fn.Body.ParamBlock.Attributes).Count | Should -Be 0 -Because "$name must not be an advanced function"
        }
    }
}
