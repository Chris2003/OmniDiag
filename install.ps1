<#
.SYNOPSIS
    Installs or updates OmniDiag for the current user and launches the GUI.

.DESCRIPTION
    Downloads a GitHub source archive, validates the expected OmniDiag layout,
    copies only the runnable files, clears Mark-of-the-Web from installed files,
    and launches OmniDiag-GUI.cmd. Existing installations are moved to a dated
    backup rather than deleted.

    This script does not require administrator rights and does not change the
    machine or user execution policy. Use -NoLaunch for deployment automation.

.PARAMETER InstallPath
    Per-user destination. Defaults to %LOCALAPPDATA%\Programs\OmniDiag.

.PARAMETER Ref
    Git branch, tag, or commit to download. Defaults to main. Pin a release tag or
    commit for repeatable enterprise deployment.

.PARAMETER ExpectedSha256
    Optional expected SHA-256 for the downloaded archive. The install stops when
    the archive does not match.

.EXAMPLE
    & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Chris2003/OmniDiag/main/install.ps1')))

.EXAMPLE
    .\install.ps1 -Ref main -NoLaunch
#>
[CmdletBinding()]
param(
    [string] $InstallPath,
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string] $Ref = 'main',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string] $ExpectedSha256,
    [switch] $NoLaunch
)

& {
    param($RequestedPath, $RequestedRef, $ExpectedHash, $SkipLaunch)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
    if (-not $isWindowsHost) { throw 'The OmniDiag quick installer requires Windows.' }

    if (-not $env:LOCALAPPDATA -and -not $RequestedPath) {
        throw 'LOCALAPPDATA is unavailable. Supply an explicit -InstallPath.'
    }
    if (-not $RequestedPath) { $RequestedPath = Join-Path $env:LOCALAPPDATA 'Programs\OmniDiag' }
    $destination = [System.IO.Path]::GetFullPath($RequestedPath)
    $destinationRoot = [System.IO.Path]::GetPathRoot($destination)
    if ($destination.TrimEnd('\') -eq $destinationRoot.TrimEnd('\')) {
        throw 'InstallPath cannot be the root of a drive.'
    }

    # Windows PowerShell 5.1 may not enable TLS 1.2 by default on older hosts.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $runId = [guid]::NewGuid().ToString('N')
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag-install-$runId"
    $archivePath = Join-Path $tempRoot 'OmniDiag.zip'
    $extractPath = Join-Path $tempRoot 'extract'
    $newPath = "$destination.new-$runId"
    $backupPath = $null

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

        $escapedRef = [uri]::EscapeDataString($RequestedRef)
        $archiveUrl = "https://github.com/Chris2003/OmniDiag/archive/$escapedRef.zip"
        Write-Host "Downloading OmniDiag '$RequestedRef'..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $archiveUrl -UseBasicParsing -OutFile $archivePath

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($ExpectedHash -and $actualHash -ne $ExpectedHash.ToUpperInvariant()) {
            throw "Archive SHA-256 mismatch. Expected $($ExpectedHash.ToUpperInvariant()), received $actualHash."
        }
        Write-Host "Archive SHA-256: $actualHash" -ForegroundColor DarkGray

        # Zip-slip / zip-bomb guard: refuse the archive before anything is extracted.
        # Entry-name rules are a copy of Get-OmniZipEntryNameProblem in src/Core/Evidence.psm1
        # (this bootstrapper runs standalone, before OmniDiag is installed): no empty names,
        # control characters, absolute paths, drive letters, ':' (NTFS streams), '..'
        # segments, or Win32 device names. Sizes are enforced on the bytes actually
        # inflated (streamed with a cap), not on the header, which an attacker controls.
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $reservedName = '^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$|CLOCK\$)$'
        $maxEntryBytes = [long]64MB
        $maxTotalBytes = [long]512MB
        $zipCheck = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            if ($zipCheck.Entries.Count -gt 20000) { throw "Downloaded archive has too many entries ($($zipCheck.Entries.Count))." }
            $inflatedBytes = [long]0
            $chunk = New-Object byte[] 81920
            foreach ($zipEntry in $zipCheck.Entries) {
                $entryName = $zipEntry.FullName
                $unsafe = [string]::IsNullOrEmpty($entryName) -or ($entryName -match '[\x00-\x1F]')
                $normalized = ([string]$entryName).Replace('\', '/')
                if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized.Contains(':')) { $unsafe = $true }
                foreach ($segment in $normalized.Split('/')) {
                    if ($segment -eq '..') { $unsafe = $true }
                    $base = $segment.TrimEnd(' ', '.')
                    $dot = $base.IndexOf('.')
                    if ($dot -ge 0) { $base = $base.Substring(0, $dot) }
                    if ($base.TrimEnd(' ') -match $reservedName) { $unsafe = $true }
                }
                if ($unsafe) { throw "Downloaded archive contains an unsafe entry name: '$entryName'." }

                # Stream the entry to count what it really inflates to.
                $entryBytes = [long]0
                $entryStream = $zipEntry.Open()
                try {
                    while (($read = $entryStream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                        $entryBytes += $read
                        $inflatedBytes += $read
                        if ($entryBytes -gt $maxEntryBytes) { throw "Downloaded archive entry '$entryName' inflates past $maxEntryBytes bytes; refusing to extract." }
                        if ($inflatedBytes -gt $maxTotalBytes) { throw "Downloaded archive inflates past $maxTotalBytes bytes; refusing to extract." }
                    }
                } finally { $entryStream.Dispose() }
            }
        } finally { $zipCheck.Dispose() }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        $sourceRoot = @(Get-ChildItem -LiteralPath $extractPath -Directory -ErrorAction Stop |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'OmniDiag.ps1')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'src\OmniDiag.psd1'))
            } | Select-Object -First 1)
        if ($sourceRoot.Count -ne 1) { throw 'Downloaded archive does not contain a valid OmniDiag layout.' }

        $required = @('OmniDiag.ps1','OmniDiag-GUI.cmd','src\OmniDiag.psd1','src\UI\MainWindow.xaml')
        foreach ($relativePath in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot[0].FullName $relativePath))) {
                throw "Downloaded archive is missing required file '$relativePath'."
            }
        }

        $parent = Split-Path $destination -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        New-Item -ItemType Directory -Path $newPath -Force | Out-Null

        # Keep the installed surface small and exclude tests/repository metadata.
        $include = @(
            'OmniDiag.ps1','OmniDiag.cmd','OmniDiag-GUI.cmd','install.ps1','src','schemas','docs','runbooks',
            'README.md','PORTABLE.md','ROADMAP.md','CHANGELOG.md','LICENSE','SECURITY.md'
        )
        foreach ($item in $include) {
            $sourceItem = Join-Path $sourceRoot[0].FullName $item
            if (Test-Path -LiteralPath $sourceItem) {
                Copy-Item -LiteralPath $sourceItem -Destination $newPath -Recurse -Force
            }
        }

        # Clear Zone.Identifier on every installed file. This is safe after the
        # archive layout validation and optional hash verification above.
        Get-ChildItem -LiteralPath $newPath -Recurse -File -ErrorAction Stop |
            Unblock-File -ErrorAction Stop

        # Keep logs, saved sessions, reports, and registry backups across upgrades.
        $oldData = Join-Path $destination 'OmniDiagData'
        if (Test-Path -LiteralPath $oldData) {
            Copy-Item -LiteralPath $oldData -Destination $newPath -Recurse -Force
        }

        if (Test-Path -LiteralPath $destination) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupPath = "$destination.backup-$stamp-$($runId.Substring(0, 6))"
            Move-Item -LiteralPath $destination -Destination $backupPath
        }

        try {
            Move-Item -LiteralPath $newPath -Destination $destination
        } catch {
            if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $destination)) {
                Move-Item -LiteralPath $backupPath -Destination $destination -ErrorAction SilentlyContinue
            }
            throw
        }

        Write-Host "OmniDiag installed to: $destination" -ForegroundColor Green
        if ($backupPath) { Write-Host "Previous installation backed up to: $backupPath" -ForegroundColor DarkGray }

        if (-not $SkipLaunch) {
            $launcher = Join-Path $destination 'OmniDiag-GUI.cmd'
            Write-Host 'Launching OmniDiag GUI...' -ForegroundColor Cyan
            Start-Process -FilePath $launcher -WorkingDirectory $destination
        }

        [pscustomobject]@{
            PSTypeName = 'OmniDiag.InstallResult'
            InstallPath = $destination
            BackupPath = $backupPath
            Ref = $RequestedRef
            ArchiveSha256 = $actualHash
            GuiLaunched = (-not $SkipLaunch)
        }
    } finally {
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
} $InstallPath $Ref $ExpectedSha256 ([bool]$NoLaunch)
