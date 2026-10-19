<#
.SYNOPSIS
    Builds the per-user OmniDiag MSI(s) from the portable payload with WiX Toolset v5.

.DESCRIPTION
    1. Gets the payload: extracts -PayloadZip, or runs build/Build-Portable.ps1 into a
       work folder and extracts the zip it makes. The folder holding OmniDiag.cmd is the
       payload root.
    2. Stages it: drops install.ps1 (the quick installer would replace an MSI install),
       adds bin\omnidiag.cmd (installer/omnidiag.cmd; the only folder put on the user
       PATH) and the '.omnidiag-installed' marker (data goes to
       %LOCALAPPDATA%\OmniDiag\Data, src/Core/Paths.psm1).
    3. Checks the payload's src/OmniDiag.psd1 ModuleVersion equals -Version.
    4. Generates OmniDiag.Payload.wxs (build/OmniDiag.Installer.psm1,
       Get-OmniMsiPayloadXml): one component per folder, HKCU key paths, name-based GUIDs.
    5. Runs 'wix build' once per -Platform with installer/OmniDiag.wxs, -d Version and a
       ProductCode that is stable per version and platform (UUID v5), and writes
       <OutputDirectory>\OmniDiag-<version>-<platform>.msi.
    6. Reads each MSI back (Windows Installer COM) and checks ProductVersion, UpgradeCode,
       ProductCode, no ALLUSERS, and the "elevation not required" bit.

    Needs Windows and WiX Toolset v5 ('wix' on PATH; CI: dotnet tool install --global
    wix --version 5.0.2). No WiX extensions. Exit code 0 on success, 1 on any failure.
    -GenerateOnly stops after step 4 (any OS, no WiX) and prints the work folder.

    Platforms: the payload is architecture-neutral script, so both MSIs carry identical
    files; they differ only in the MSI platform (Template) and ProductCode. x64 and arm64
    are built by default so winget can offer a native-architecture installer on Windows 11
    ARM64 (decision 6); the x64 MSI also installs there.

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Version
    x.y.z. Must equal src/OmniDiag.psd1 ModuleVersion of the payload.

.PARAMETER OutputDirectory
    Where the .msi files go. Default <repo>/dist.

.PARAMETER PayloadZip
    A portable zip (build/Build-Portable.ps1 output) to package instead of building one.

.PARAMETER Platform
    x64, arm64, or both (default both).

.PARAMETER WixPath
    The wix executable. Default 'wix' (PATH).

.PARAMETER WorkDirectory
    Staging folder. Default a new folder under the system temp folder, removed afterwards
    unless -KeepWork.

.PARAMETER KeepWork
    Keep the work folder (staged payload, generated .wxs, wix output) for inspection.

.PARAMETER GenerateOnly
    Stage and generate the .wxs fragment only (no wix, no MSI). Implies -KeepWork.

.EXAMPLE
    ./build/Build-Msi.ps1 -Version 1.0.0 -OutputDirectory dist

.EXAMPLE
    ./build/Build-Msi.ps1 -Version 1.0.0 -OutputDirectory dist -PayloadZip dist/OmniDiag-1.0.0-portable.zip -Platform x64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Version,
    [string] $OutputDirectory,
    [string] $PayloadZip,
    [ValidateSet('x64', 'arm64')][string[]] $Platform = @('x64', 'arm64'),
    [string] $WixPath = 'wix',
    [string] $WorkDirectory,
    [switch] $KeepWork,
    [switch] $GenerateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'OmniDiag.Installer.psm1') -DisableNameChecking
$utf8 = [System.Text.UTF8Encoding]::new($false)
$constants = Get-OmniInstallerConstant
$createdWork = $false
$exitCode = 0

function Write-MsiStep { param([string] $Message) Write-Host "[msi] $Message" }

try {
    if (-not (Test-OmniVersionString $Version)) { throw "-Version '$Version' must be x.y.z (MSI: major and minor up to 255, build up to 65535)." }
    $onWindows = $true
    try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { $onWindows = $true }
    if (-not $GenerateOnly -and -not $onWindows) { throw 'Building an MSI needs Windows (WiX and Windows Installer). Use -GenerateOnly elsewhere.' }
    if ($GenerateOnly) { $KeepWork = $true }

    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

    if (-not $WorkDirectory) {
        $WorkDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-msi-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    }
    if (Test-Path -LiteralPath $WorkDirectory) { Remove-Item -LiteralPath $WorkDirectory -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $WorkDirectory -Force
    $createdWork = $true
    $WorkDirectory = (Resolve-Path -LiteralPath $WorkDirectory).ProviderPath
    Write-MsiStep "Work folder: $WorkDirectory"

    # --- 1. Payload --------------------------------------------------------------------
    if (-not $PayloadZip) {
        Write-MsiStep 'Building the portable payload (build/Build-Portable.ps1).'
        $portableOut = Join-Path $WorkDirectory 'portable'
        $portable = & (Join-Path $PSScriptRoot 'Build-Portable.ps1') -OutputDirectory $portableOut 6>$null
        $PayloadZip = $portable | Where-Object { $_ -and $_.PSObject.Properties['Package'] } | Select-Object -Last 1 | ForEach-Object { [string]$_.Package }
        if (-not $PayloadZip) { $PayloadZip = Get-ChildItem -LiteralPath $portableOut -Filter '*.zip' -File | Select-Object -First 1 | ForEach-Object { $_.FullName } }
        if (-not $PayloadZip) { throw 'build/Build-Portable.ps1 did not produce a zip.' }
    }
    if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) { throw "Payload zip not found: $PayloadZip" }
    $extract = Join-Path $WorkDirectory 'extract'
    Expand-Archive -LiteralPath $PayloadZip -DestinationPath $extract -Force
    $launcher = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'OmniDiag.cmd' | Sort-Object { $_.FullName.Length } | Select-Object -First 1)
    if ($launcher.Count -eq 0) { throw "The payload zip has no OmniDiag.cmd: $PayloadZip" }
    $payloadSource = $launcher[0].DirectoryName
    Write-MsiStep "Payload: $PayloadZip"

    # --- 2. Stage ----------------------------------------------------------------------
    $stage = Join-Path $WorkDirectory 'payload'
    Copy-Item -LiteralPath $payloadSource -Destination $stage -Recurse -Force
    foreach ($drop in @('install.ps1', 'OmniDiagData')) {
        $p = Join-Path $stage $drop
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    $bin = Join-Path $stage 'bin'
    $null = New-Item -ItemType Directory -Path $bin -Force
    $shim = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'installer/omnidiag.cmd'))
    # cmd.exe parses batch files most reliably with CRLF line endings.
    $shim = ($shim -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $bin 'omnidiag.cmd'), $shim, [System.Text.Encoding]::ASCII)
    $marker = "Installed by the OmniDiag MSI (per user).`r`nData: %LOCALAPPDATA%\OmniDiag\Data (kept on uninstall). See docs\INSTALLER.md.`r`n"
    [System.IO.File]::WriteAllText((Join-Path $stage $constants.InstalledMarker), $marker, [System.Text.Encoding]::ASCII)
    foreach ($required in @('OmniDiag.cmd', 'OmniDiag-GUI.cmd', 'OmniDiag.ps1', 'src/OmniDiag.psd1', 'src/Cli/omnidiag.ps1', 'bin/omnidiag.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Staged payload is missing $required." }
    }

    # --- 3. Version --------------------------------------------------------------------
    $payloadVersion = ConvertTo-OmniThreePartVersion ([string](Import-PowerShellDataFile -Path (Join-Path $stage 'src/OmniDiag.psd1')).ModuleVersion)
    if ($payloadVersion -ne $Version) {
        throw "-Version $Version does not match the payload's src/OmniDiag.psd1 ModuleVersion ($payloadVersion)."
    }

    # --- 4. Generate -------------------------------------------------------------------
    $fragment = Get-OmniMsiPayloadXml -PayloadRoot $stage
    $fragmentPath = Join-Path $WorkDirectory 'OmniDiag.Payload.wxs'
    [System.IO.File]::WriteAllText($fragmentPath, $fragment.Xml, $utf8)
    Write-MsiStep ("Generated {0}: {1} folders (components), {2} files." -f $fragmentPath, $fragment.DirectoryCount, $fragment.FileCount)
    $mainWxs = Join-Path $repoRoot 'installer/OmniDiag.wxs'

    if ($GenerateOnly) {
        Write-MsiStep 'GenerateOnly: no MSI built.'
        return [pscustomobject]@{ Version = $Version; WorkDirectory = $WorkDirectory; Fragment = $fragmentPath; Stage = $stage; FileCount = $fragment.FileCount }
    }

    # --- 5. wix build ------------------------------------------------------------------
    $wixCommand = Get-Command $WixPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wixCommand) { throw "WiX not found ('$WixPath'). Install it: dotnet tool install --global wix --version 5.0.2" }
    $wixVersion = (& $wixCommand.Source --version 2>&1 | Out-String).Trim()
    Write-MsiStep "WiX: $($wixCommand.Source) ($wixVersion)"
    if ($wixVersion -notmatch '^5\.') { throw "WiX Toolset v5 is required (found '$wixVersion'). v6+ is not used: see docs/INSTALLER.md (licensing)." }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($arch in $Platform) {
        $productCode = Get-OmniStableGuid -Name ("product:{0}:{1}" -f $Version, $arch)
        $msiName = "OmniDiag-$Version-$arch.msi"
        $msiPath = Join-Path $OutputDirectory $msiName
        if (Test-Path -LiteralPath $msiPath) { Remove-Item -LiteralPath $msiPath -Force }
        $wixArgs = @(
            'build',
            '-arch', $arch,
            '-d', "Version=$Version",
            '-d', "ProductCode=$productCode",
            '-pdb', (Join-Path $WorkDirectory "OmniDiag-$arch.wixpdb"),
            '-o', $msiPath,
            $mainWxs,
            $fragmentPath
        )
        Write-MsiStep "wix $($wixArgs -join ' ')"
        & $wixCommand.Source @wixArgs
        if ($LASTEXITCODE -ne 0) { throw "wix build failed for $arch (exit $LASTEXITCODE)." }
        if (-not (Test-Path -LiteralPath $msiPath -PathType Leaf)) { throw "wix build did not write $msiPath." }

        # --- 6. Read back ----------------------------------------------------------------
        $info = Get-OmniMsiInfo -Path $msiPath
        $problems = [System.Collections.Generic.List[string]]::new()
        if ($info.ProductVersion -ne $Version) { $problems.Add("ProductVersion '$($info.ProductVersion)' is not $Version") }
        if ($info.UpgradeCode -ne $constants.UpgradeCode) { $problems.Add("UpgradeCode '$($info.UpgradeCode)' is not $($constants.UpgradeCode)") }
        if ($info.ProductCode -ne $productCode) { $problems.Add("ProductCode '$($info.ProductCode)' is not $productCode") }
        if ($null -ne $info.AllUsers) { $problems.Add("ALLUSERS is set ('$($info.AllUsers)'); the package must be per-user only") }
        if (-not $info.ElevationNotRequired) { $problems.Add("word count $($info.WordCount) lacks 'elevation not required' (8)") }
        $expectedTemplate = if ($arch -eq 'arm64') { 'Arm64' } else { 'x64' }
        if ($info.Template -notlike "$expectedTemplate;*") { $problems.Add("Template '$($info.Template)' is not $expectedTemplate") }
        if ($problems.Count -gt 0) { throw "$msiName failed its checks: $($problems -join '; ')." }
        $sha = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
        $results.Add([pscustomobject]@{
                Version     = $Version
                Platform    = $arch
                Path        = $msiPath
                FileName    = $msiName
                ProductCode = $info.ProductCode
                UpgradeCode = $info.UpgradeCode
                Sha256      = $sha
                SizeKB      = [math]::Round((Get-Item -LiteralPath $msiPath).Length / 1KB, 1)
            })
        Write-MsiStep "Built $msiPath (ProductCode $($info.ProductCode), SHA256 $sha)."
    }
    $results.ToArray()
} catch {
    Write-Host "::error::Build-Msi: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    if ($createdWork -and -not $KeepWork -and $WorkDirectory -and (Test-Path -LiteralPath $WorkDirectory)) {
        Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($exitCode -ne 0) { exit $exitCode }
