<#
.SYNOPSIS
    Shared helpers for the per-user MSI and the winget manifest (docs/INSTALLER.md).

.DESCRIPTION
    Used by build/Build-Msi.ps1, build/New-WingetManifest.ps1,
    build/Test-WingetManifest.ps1, build/Test-MsiInstall.ps1, and
    Tests/Build.Installer.Tests.ps1. Everything here is pure (no network, no state)
    and cross-platform, except Get-OmniMsiInfo, which reads an MSI through the
    Windows Installer COM object and therefore needs Windows.

    Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

Set-StrictMode -Version Latest

# Identity shared by the MSI and the winget manifest. The UpgradeCode must match
# installer/OmniDiag.wxs and never change (Tests/Build.Installer.Tests.ps1 checks both).
$script:OmniInstallerConstants = [ordered]@{
    PackageIdentifier = 'Chris2003.OmniDiag'
    PackageName       = 'OmniDiag'
    Publisher         = 'OmniDiag Contributors'
    UpgradeCode       = '{7A225708-9A90-4726-8BE4-3480CB561715}'
    # Namespace for the name-based (UUID v5) component GUIDs and ProductCodes.
    GuidNamespace     = '958E1C7B-0865-4EF6-BB22-D9F3BB043FF1'
    RepositoryUrl     = 'https://github.com/Chris2003/OmniDiag'
    PayloadRegistry   = 'Software\OmniDiag\Installer\Components'
    InstalledMarker   = '.omnidiag-installed'
    Platforms         = @('x64', 'arm64')
}

function Get-OmniInstallerConstant {
    <#
    .SYNOPSIS
        Returns the installer identity constants (package id, publisher, UpgradeCode, ...).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return $script:OmniInstallerConstants
}

function Get-OmniStableGuid {
    <#
    .SYNOPSIS
        Name-based GUID (RFC 4122 version 5, SHA-1) in the OmniDiag installer namespace.

    .DESCRIPTION
        The same name always gives the same GUID, on every machine and run, so component
        GUIDs and per-version ProductCodes are reproducible without storing them.
        Returned upper-case in braces, as WiX and MSI tables write them.

    .PARAMETER Name
        The name to hash, e.g. 'component:src/core' or 'product:1.0.0:x64'.

    .PARAMETER Namespace
        Namespace GUID. Defaults to the OmniDiag installer namespace.

    .EXAMPLE
        Get-OmniStableGuid -Name 'product:1.0.0:x64'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Namespace = $script:OmniInstallerConstants.GuidNamespace
    )
    $ns = ([guid]$Namespace).ToByteArray()
    # .NET keeps the first three fields little-endian; RFC 4122 hashes network order.
    [array]::Reverse($ns, 0, 4); [array]::Reverse($ns, 4, 2); [array]::Reverse($ns, 6, 2)
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $data = [byte[]]::new($ns.Length + $nameBytes.Length)
    [array]::Copy($ns, 0, $data, 0, $ns.Length)
    [array]::Copy($nameBytes, 0, $data, $ns.Length, $nameBytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($data) } finally { $sha1.Dispose() }
    $b = [byte[]]::new(16)
    [array]::Copy($hash, 0, $b, 0, 16)
    $b[6] = [byte](($b[6] -band 0x0F) -bor 0x50)
    $b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)
    [array]::Reverse($b, 0, 4); [array]::Reverse($b, 4, 2); [array]::Reverse($b, 6, 2)
    return ([guid]::new($b)).ToString('B').ToUpperInvariant()
}

function Get-OmniShortHash {
    <# .SYNOPSIS Internal: first 24 hex characters of SHA-256(text), lower-case (WiX identifiers). #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return (-join ($h[0..11] | ForEach-Object { $_.ToString('x2') }))
}

function ConvertTo-OmniXmlAttribute {
    <# .SYNOPSIS Internal: escapes text for an XML attribute value. #>
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
}

function Test-OmniVersionString {
    <# .SYNOPSIS True when Version is a plain x.y.z that MSI accepts (major/minor <= 255, build <= 65535). #>
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Version)
    if ($Version -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,5})$') { return $false }
    return ([int]$Matches[1] -le 255 -and [int]$Matches[2] -le 255 -and [int]$Matches[3] -le 65535)
}

function ConvertTo-OmniThreePartVersion {
    <# .SYNOPSIS '1.0' / '1.0.0' / '1.0.0.0' -> '1.0.0' (a non-zero fourth part is refused). #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Version)
    $v = [version]$Version
    if ($v.Revision -gt 0) { throw "Version '$Version' has a fourth part; MSI and the release tags use x.y.z." }
    $build = if ($v.Build -lt 0) { 0 } else { $v.Build }
    return ('{0}.{1}.{2}' -f $v.Major, $v.Minor, $build)
}

function Get-OmniMsiPayloadXml {
    <#
    .SYNOPSIS
        Generates the WiX v4/v5 fragment that installs a staged payload folder.

    .DESCRIPTION
        One <Directory> per folder (nested under -RootDirectoryId) and one <Component> per
        folder holding that folder's files. Each component's key path is an HKCU registry
        value (ICE38: per-user profile components), and each has a RemoveFolder so
        uninstall removes the folder when it is empty (ICE64). Component GUIDs are name-based
        (Get-OmniStableGuid on the folder's relative path), identifiers are hashes of the
        relative path, and folders and files are sorted ordinally, so the same payload
        always gives the same XML. Symbolic links and junctions are refused.

    .PARAMETER PayloadRoot
        The staged folder whose contents go to the install folder.

    .PARAMETER RootDirectoryId
        Directory Id of the install folder in the main .wxs. Default INSTALLFOLDER.

    .PARAMETER ComponentGroupId
        ComponentGroup Id the main .wxs references. Default OmniDiagPayload.

    .OUTPUTS
        Object with Xml (string, LF line endings), DirectoryCount, FileCount, and
        Components (relative folder -> GUID).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $PayloadRoot,
        [string] $RootDirectoryId = 'INSTALLFOLDER',
        [string] $ComponentGroupId = 'OmniDiagPayload'
    )
    if (-not (Test-Path -LiteralPath $PayloadRoot -PathType Container)) { throw "Payload folder not found: $PayloadRoot" }
    $root = (Resolve-Path -LiteralPath $PayloadRoot).ProviderPath.TrimEnd('\', '/')
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    $dirs = [System.Collections.Generic.List[string]]::new()
    $files = [System.Collections.Generic.List[string]]::new()
    $dirs.Add('')
    foreach ($item in $items) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Payload contains a symbolic link or junction (refused): $($item.FullName)"
        }
        $rel = $item.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -match '[^\x20-\x7E]') { throw "Payload path is not printable ASCII: $rel" }
        if ($item.PSIsContainer) { $dirs.Add($rel) } else { $files.Add($rel) }
    }
    $dirArray = $dirs.ToArray(); [array]::Sort($dirArray, [System.StringComparer]::Ordinal)
    $fileArray = $files.ToArray(); [array]::Sort($fileArray, [System.StringComparer]::Ordinal)

    $dirId = @{}
    foreach ($d in $dirArray) {
        $dirId[$d] = if ($d -eq '') { $RootDirectoryId } else { 'dir_' + (Get-OmniShortHash -Text ('dir:' + $d.ToLowerInvariant())) }
    }
    $children = @{}
    foreach ($d in $dirArray) {
        if ($d -eq '') { continue }
        $slash = $d.LastIndexOf('/')
        $parent = if ($slash -lt 0) { '' } else { $d.Substring(0, $slash) }
        if (-not $children.ContainsKey($parent)) { $children[$parent] = [System.Collections.Generic.List[string]]::new() }
        $children[$parent].Add($d)
    }
    $filesByDir = @{}
    foreach ($f in $fileArray) {
        $slash = $f.LastIndexOf('/')
        $parent = if ($slash -lt 0) { '' } else { $f.Substring(0, $slash) }
        if (-not $filesByDir.ContainsKey($parent)) { $filesByDir[$parent] = [System.Collections.Generic.List[string]]::new() }
        $filesByDir[$parent].Add($f)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<!-- Generated by build/Build-Msi.ps1 from the staged portable payload. Do not edit. -->')
    $lines.Add('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
    $lines.Add('  <Fragment>')
    $lines.Add(('    <DirectoryRef Id="{0}">' -f $RootDirectoryId))
    # Iterative depth-first emission of the directory tree (sorted).
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $rootKids = @(if ($children.ContainsKey('')) { $children[''] })
    for ($i = $rootKids.Count - 1; $i -ge 0; $i--) { $stack.Push(@('open', $rootKids[$i], 3)) }
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $op = $entry[0]; $d = $entry[1]; $depth = [int]$entry[2]
        $pad = '  ' * $depth
        if ($op -eq 'close') { $lines.Add($pad + '</Directory>'); continue }
        $name = $d.Substring($d.LastIndexOf('/') + 1)
        $kids = @(if ($children.ContainsKey($d)) { $children[$d] })
        if ($kids.Count -eq 0) {
            $lines.Add(('{0}<Directory Id="{1}" Name="{2}" />' -f $pad, $dirId[$d], (ConvertTo-OmniXmlAttribute $name)))
        } else {
            $lines.Add(('{0}<Directory Id="{1}" Name="{2}">' -f $pad, $dirId[$d], (ConvertTo-OmniXmlAttribute $name)))
            $stack.Push(@('close', $d, $depth))
            for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@('open', $kids[$i], $depth + 1)) }
        }
    }
    $lines.Add('    </DirectoryRef>')
    $lines.Add(('    <ComponentGroup Id="{0}">' -f $ComponentGroupId))
    $components = [ordered]@{}
    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($d in $dirArray) {
        $key = if ($d -eq '') { '.' } else { $d }
        $guid = Get-OmniStableGuid -Name ('component:' + $d.ToLowerInvariant())
        $components[$key] = $guid
        $cmpId = 'cmp_' + (Get-OmniShortHash -Text ('cmp:' + $d.ToLowerInvariant()))
        $rmId = 'rmf_' + (Get-OmniShortHash -Text ('rmf:' + $d.ToLowerInvariant()))
        $lines.Add(('      <Component Id="{0}" Directory="{1}" Guid="{2}">' -f $cmpId, $dirId[$d], $guid))
        $lines.Add(('        <RegistryValue Root="HKCU" Key="{0}" Name="{1}" Type="integer" Value="1" KeyPath="yes" />' -f
                $script:OmniInstallerConstants.PayloadRegistry, (ConvertTo-OmniXmlAttribute $key.Replace('/', '\'))))
        $lines.Add(('        <RemoveFolder Id="{0}" On="uninstall" />' -f $rmId))
        $dirFiles = @(if ($filesByDir.ContainsKey($d)) { $filesByDir[$d] })
        if ($dirFiles.Count -eq 0) { $lines.Add('        <CreateFolder />') }
        foreach ($f in $dirFiles) {
            $filId = 'fil_' + (Get-OmniShortHash -Text ('fil:' + $f.ToLowerInvariant()))
            $source = $root + $sep + $f.Replace('/', $sep)
            $lines.Add(('        <File Id="{0}" Source="{1}" />' -f $filId, (ConvertTo-OmniXmlAttribute $source)))
        }
        $lines.Add('      </Component>')
    }
    $lines.Add('    </ComponentGroup>')
    $lines.Add('  </Fragment>')
    $lines.Add('</Wix>')
    return [pscustomobject]@{
        Xml            = (($lines -join "`n") + "`n")
        DirectoryCount = $dirArray.Count
        FileCount      = $fileArray.Count
        Components     = $components
    }
}

function Get-OmniMsiInfo {
    <#
    .SYNOPSIS
        Reads identity properties from a built MSI (Windows only; Windows Installer COM).

    .OUTPUTS
        Object with ProductCode, UpgradeCode, ProductVersion, ProductName, Manufacturer,
        AllUsers (null when the property is absent), Template (e.g. 'x64;1033'),
        WordCount, and ElevationNotRequired (word count bit 8).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $flags = [System.Reflection.BindingFlags]
    $invoke = { param($Target, [string] $Member, $Kind, [object[]] $Arguments) $Target.GetType().InvokeMember($Member, $Kind, $null, $Target, $Arguments) }
    $db = & $invoke $installer 'OpenDatabase' $flags::InvokeMethod @($full, 0)
    $props = @{}
    try {
        foreach ($name in @('ProductCode', 'UpgradeCode', 'ProductVersion', 'ProductName', 'Manufacturer', 'ALLUSERS', 'MSIINSTALLPERUSER')) {
            $view = & $invoke $db 'OpenView' $flags::InvokeMethod @("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$name'")
            try {
                [void](& $invoke $view 'Execute' $flags::InvokeMethod @())
                $record = & $invoke $view 'Fetch' $flags::InvokeMethod @()
                if ($null -ne $record) {
                    $props[$name] = [string](& $invoke $record 'StringData' $flags::GetProperty @(1))
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
                } else { $props[$name] = $null }
            } finally {
                [void](& $invoke $view 'Close' $flags::InvokeMethod @())
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
            }
        }
    } finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
    $summary = & $invoke $installer 'SummaryInformation' $flags::GetProperty @($full, 0)
    try {
        $template = [string](& $invoke $summary 'Property' $flags::GetProperty @(7))
        $wordCount = [int](& $invoke $summary 'Property' $flags::GetProperty @(15))
    } finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($summary) }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    return [pscustomobject]@{
        Path                 = $full
        ProductCode          = $props['ProductCode']
        UpgradeCode          = $props['UpgradeCode']
        ProductVersion       = $props['ProductVersion']
        ProductName          = $props['ProductName']
        Manufacturer         = $props['Manufacturer']
        AllUsers             = $props['ALLUSERS']
        MsiInstallPerUser    = $props['MSIINSTALLPERUSER']
        Template             = $template
        WordCount            = $wordCount
        ElevationNotRequired = [bool]($wordCount -band 8)
    }
}

# ---------------------------------------------------------------------------------------
# winget manifest (v1.6.0) - data and a deterministic YAML subset
# ---------------------------------------------------------------------------------------

function Get-OmniWingetManifestSet {
    <#
    .SYNOPSIS
        Builds the three winget v1.6.0 manifests (version, installer, defaultLocale) as
        ordered dictionaries.

    .PARAMETER Version
        Package version, x.y.z.

    .PARAMETER Installer
        One hashtable per MSI: Architecture (x64/arm64), FileName, Sha256, ProductCode.

    .PARAMETER UpgradeCode
        MSI UpgradeCode (AppsAndFeaturesEntries). Defaults to the OmniDiag constant.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][hashtable[]] $Installer,
        [string] $UpgradeCode = $script:OmniInstallerConstants.UpgradeCode
    )
    if (-not (Test-OmniVersionString $Version)) { throw "Version '$Version' is not x.y.z." }
    $c = $script:OmniInstallerConstants
    $id = $c.PackageIdentifier
    $manifestVersion = '1.6.0'

    $installers = [System.Collections.Generic.List[object]]::new()
    foreach ($i in @($Installer | Sort-Object { [string]$_.Architecture })) {
        if ([string]$i.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw "Installer '$($i.FileName)': SHA256 must be 64 hex characters." }
        if ([string]$i.ProductCode -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { throw "Installer '$($i.FileName)': ProductCode must be a braced GUID." }
        if ([string]$i.Architecture -notin @('x64', 'arm64', 'x86')) { throw "Installer '$($i.FileName)': unsupported architecture '$($i.Architecture)'." }
        if ([string]$i.FileName -notmatch '^[A-Za-z0-9._-]+\.msi$') { throw "Installer file name '$($i.FileName)' is not a plain .msi name." }
        $installers.Add([ordered]@{
                Architecture           = [string]$i.Architecture
                InstallerUrl           = ('{0}/releases/download/v{1}/{2}' -f $c.RepositoryUrl, $Version, $i.FileName)
                InstallerSha256        = ([string]$i.Sha256).ToUpperInvariant()
                ProductCode            = ([string]$i.ProductCode).ToUpperInvariant()
                AppsAndFeaturesEntries = @([ordered]@{ UpgradeCode = $UpgradeCode.ToUpperInvariant() })
            })
    }
    if ($installers.Count -eq 0) { throw 'At least one installer is required.' }

    $versionManifest = [ordered]@{
        PackageIdentifier = $id
        PackageVersion    = $Version
        DefaultLocale     = 'en-US'
        ManifestType      = 'version'
        ManifestVersion   = $manifestVersion
    }
    $installerManifest = [ordered]@{
        PackageIdentifier = $id
        PackageVersion    = $Version
        MinimumOSVersion  = '10.0.19045.0'
        InstallerType     = 'msi'
        Scope             = 'user'
        InstallModes      = @('interactive', 'silent', 'silentWithProgress')
        UpgradeBehavior   = 'install'
        Commands          = @('omnidiag')
        Installers        = $installers.ToArray()
        ManifestType      = 'installer'
        ManifestVersion   = $manifestVersion
    }
    $localeManifest = [ordered]@{
        PackageIdentifier   = $id
        PackageVersion      = $Version
        PackageLocale       = 'en-US'
        Publisher           = $c.Publisher
        PublisherUrl        = 'https://github.com/Chris2003'
        PublisherSupportUrl = "$($c.RepositoryUrl)/issues"
        Author              = 'Chris B'
        PackageName         = $c.PackageName
        PackageUrl          = $c.RepositoryUrl
        License             = 'MIT'
        LicenseUrl          = "$($c.RepositoryUrl)/blob/v$Version/LICENSE"
        Copyright           = 'Copyright (c) 2026 OmniDiag Contributors'
        ShortDescription    = 'Local-only Windows diagnostics: scans, reports, and guided repairs.'
        Description         = 'OmniDiag is an open-source, local-only Windows diagnostic tool for IT professionals and power users. It scans the system, event logs, storage, network, security, and more; writes HTML, JSON, Markdown, and PDF reports; and offers guarded repairs. It runs on Windows PowerShell 5.1 or PowerShell 7, needs no administrator rights for most checks, and sends no network traffic during a default scan.'
        Moniker             = 'omnidiag'
        Tags                = @('diagnostics', 'powershell', 'repair', 'troubleshooting', 'windows')
        ReleaseNotesUrl     = "$($c.RepositoryUrl)/releases/tag/v$Version"
        ManifestType        = 'defaultLocale'
        ManifestVersion     = $manifestVersion
    }
    return [ordered]@{
        version       = $versionManifest
        installer     = $installerManifest
        defaultLocale = $localeManifest
    }
}

function ConvertTo-OmniYamlScalar {
    <# .SYNOPSIS Internal: plain scalar when unambiguous, else single-quoted. #>
    [OutputType([string])]
    param([AllowEmptyString()][string] $Value)
    if ($Value -match '[\r\n]') { throw 'Multi-line YAML values are not supported.' }
    if ($Value -match '[^\x20-\x7E]') { throw "YAML value is not printable ASCII: $Value" }
    if ($Value -match '^[A-Za-z][A-Za-z0-9._/+-]*$' -and $Value -notmatch '^(?i)(y|n|yes|no|true|false|on|off|null)$') { return $Value }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-OmniYamlMap {
    <# .SYNOPSIS Internal: true for hashtables and ordered dictionaries. #>
    [OutputType([bool])]
    param($Value)
    return ($Value -is [System.Collections.IDictionary])
}

function Add-OmniYamlMapping {
    <# .SYNOPSIS Internal: emits a mapping; the first key uses FirstPrefix (for '- ' list items). #>
    param($Map, [string] $Indent, [string] $FirstPrefix, [System.Collections.Generic.List[string]] $Lines)
    $first = $true
    foreach ($key in $Map.Keys) {
        if ([string]$key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "Unsupported YAML key '$key'." }
        $prefix = if ($first) { $FirstPrefix } else { $Indent }
        $first = $false
        $value = $Map[$key]
        if ($null -eq $value) { throw "YAML key '$key' has no value." }
        if (Test-OmniYamlMap $value) {
            $Lines.Add("$prefix${key}:")
            Add-OmniYamlMapping -Map $value -Indent ($Indent + '  ') -FirstPrefix ($Indent + '  ') -Lines $Lines
        } elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $Lines.Add("$prefix${key}:")
            # Sequences sit at the key's column (the winget-pkgs style).
            foreach ($item in $value) {
                if (Test-OmniYamlMap $item) {
                    Add-OmniYamlMapping -Map $item -Indent ($Indent + '  ') -FirstPrefix ($Indent + '- ') -Lines $Lines
                } else {
                    $Lines.Add($Indent + '- ' + (ConvertTo-OmniYamlScalar ([string]$item)))
                }
            }
        } else {
            $Lines.Add("$prefix${key}: " + (ConvertTo-OmniYamlScalar ([string]$value)))
        }
    }
}

function ConvertTo-OmniWingetYaml {
    <#
    .SYNOPSIS
        Serializes one winget manifest (ordered dictionary) to YAML, deterministically.

    .DESCRIPTION
        Emits only the subset ConvertFrom-OmniWingetYaml reads back: nested mappings,
        sequences of scalars or mappings, and string scalars (plain when unambiguous,
        otherwise single-quoted). LF line endings, trailing newline, ASCII only.

    .PARAMETER Manifest
        The manifest dictionary (ManifestType selects the schema comment).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    $type = [string]$Manifest['ManifestType']
    $mv = [string]$Manifest['ManifestVersion']
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by build/New-WingetManifest.ps1 (OmniDiag). Do not edit by hand.')
    $lines.Add("# yaml-language-server: `$schema=https://aka.ms/winget-manifest.$type.$mv.schema.json")
    $lines.Add('')
    Add-OmniYamlMapping -Map $Manifest -Indent '' -FirstPrefix '' -Lines $lines
    return (($lines -join "`n") + "`n")
}

function ConvertFrom-OmniWingetYaml {
    <#
    .SYNOPSIS
        Parses the YAML subset ConvertTo-OmniWingetYaml writes into ordered dictionaries.

    .DESCRIPTION
        Not a general YAML parser: it accepts block mappings, block sequences (also at the
        parent key's column), plain and single-quoted string scalars, and '#' comment
        lines. Anything else (flow collections, anchors, tabs, multi-line scalars) throws.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Yaml)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in ($Yaml -split "`r?`n")) {
        if ($raw -match '^\s*(#.*)?$') { continue }
        if ($raw.Contains("`t")) { throw "Tabs are not supported: '$raw'" }
        $text = $raw.TrimStart(' ')
        $rows.Add([pscustomobject]@{ Indent = $raw.Length - $text.Length; Text = $text.TrimEnd() })
    }
    $state = [pscustomobject]@{ Index = 0 }

    $parseScalar = {
        param([string] $s)
        if ($s.StartsWith("'")) {
            if ($s.Length -lt 2 -or -not $s.EndsWith("'")) { throw "Unterminated quoted scalar: $s" }
            $inner = $s.Substring(1, $s.Length - 2)
            if ($inner -match "(^|[^'])'([^']|$)") { throw "Bad quoting in scalar: $s" }
            return $inner.Replace("''", "'")
        }
        if ($s -match '^[\[\]{}&*!|>"%@`]' -or $s -match ': |\s#') { throw "Unsupported YAML scalar: $s" }
        return $s
    }

    $parseMapping = $null; $parseSequence = $null
    $parseMapping = {
        param([int] $Indent)
        $map = [ordered]@{}
        while ($state.Index -lt $rows.Count) {
            $row = $rows[$state.Index]
            if ($row.Indent -ne $Indent -or $row.Text.StartsWith('- ') -or $row.Text -eq '-') {
                if ($row.Indent -gt $Indent) { throw "Unexpected indentation at '$($row.Text)'." }
                break
            }
            if ($row.Text -notmatch '^([A-Za-z][A-Za-z0-9]*):(?: (.*))?$') { throw "Expected 'Key: value' at '$($row.Text)'." }
            $key = $Matches[1]; $rest = $Matches[2]
            if ($map.Contains($key)) { throw "Duplicate key '$key'." }
            $state.Index++
            if ($rest) { $map[$key] = & $parseScalar $rest; continue }
            if ($state.Index -ge $rows.Count) { throw "Key '$key' has no value." }
            $next = $rows[$state.Index]
            if ($next.Text.StartsWith('- ') -and $next.Indent -ge $Indent) {
                $map[$key] = & $parseSequence $next.Indent
            } elseif ($next.Indent -gt $Indent) {
                $map[$key] = & $parseMapping $next.Indent
            } else { throw "Key '$key' has no value." }
        }
        return $map
    }
    $parseSequence = {
        param([int] $Indent)
        $list = [System.Collections.Generic.List[object]]::new()
        while ($state.Index -lt $rows.Count) {
            $row = $rows[$state.Index]
            if ($row.Indent -ne $Indent -or -not $row.Text.StartsWith('- ')) { break }
            $item = $row.Text.Substring(2)
            if ($item -match '^[A-Za-z][A-Za-z0-9]*:( |$)') {
                # A mapping item: re-read this row as the mapping's first key, two columns in.
                $rows[$state.Index] = [pscustomobject]@{ Indent = $Indent + 2; Text = $item }
                $list.Add((& $parseMapping ($Indent + 2)))
            } else {
                $list.Add((& $parseScalar $item))
                $state.Index++
            }
        }
        return , $list.ToArray()
    }

    $result = & $parseMapping 0
    if ($state.Index -lt $rows.Count) { throw "Unexpected content at '$($rows[$state.Index].Text)'." }
    return $result
}

Export-ModuleMember -Function @(
    'Get-OmniInstallerConstant', 'Get-OmniStableGuid', 'Test-OmniVersionString', 'ConvertTo-OmniThreePartVersion',
    'Get-OmniMsiPayloadXml', 'Get-OmniMsiInfo', 'Get-OmniWingetManifestSet',
    'ConvertTo-OmniWingetYaml', 'ConvertFrom-OmniWingetYaml'
)
