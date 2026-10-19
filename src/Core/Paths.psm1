<#
.SYNOPSIS
    Portable data locations for OmniDiag.

.DESCRIPTION
    OmniDiag is a portable tool: it runs from whatever folder it was extracted to
    (a Downloads folder, a network share, or a USB stick) and keeps everything it
    writes - logs, reports, registry backups, and scratch files - in an
    OmniDiagData folder next to the tool. Nothing is written to %TEMP%,
    %APPDATA%, or %LOCALAPPDATA%, so removing the tool folder (or unplugging the
    USB stick) leaves no OmniDiag files behind on the host.

    Resolution order for the data root:
      1. $env:OMNIDIAG_DATA (explicit override)
      2. Installed mode: when the tool folder carries the '.omnidiag-installed' marker
         (written only by the MSI, docs/INSTALLER.md), %LOCALAPPDATA%\OmniDiag\Data,
         flagged Source='Installed', IsPortable=$false. The portable zip never has the
         marker, so portable mode is unchanged.
      3. <tool folder>\OmniDiagData, when the tool folder is writable
      4. %TEMP%\OmniDiag as a last resort (read-only media), flagged IsPortable=$false
#>

Set-StrictMode -Version Latest

# src/Core -> tool root (the folder holding OmniDiag.ps1 and the launchers).
$script:OmniToolRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:OmniDataRootCache = $null
# Marker written into the scratch folder; Clear-OmniTempData deletes only folders that carry it.
$script:OmniScratchMarker = '.omnidiag-scratch'
# Marker the MSI installs next to the launchers (never present in the portable package).
$script:OmniInstalledMarker = '.omnidiag-installed'

function Test-OmniPathWithin {
    <# .SYNOPSIS Internal: true when Path is Root or inside it (normalized, separator-aware). #>
    param([string] $Path, [string] $Root)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd($sep, '/') + $sep
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd($sep, '/') + $sep
    return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OmniDirectoryWritable {
    <# .SYNOPSIS Internal: true when a probe file can be created and removed in the folder. #>
    param([Parameter(Mandatory)][string] $Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Path ('.write-test-' + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-OmniInstalledDataPath {
    <# .SYNOPSIS Internal: %LOCALAPPDATA%\OmniDiag\Data when the tool was installed by the MSI, else $null. #>
    [OutputType([string])]
    param()
    if (-not (Test-Path -LiteralPath (Join-Path $script:OmniToolRoot $script:OmniInstalledMarker) -PathType Leaf)) { return $null }
    if (-not $env:LOCALAPPDATA) { return $null }
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $env:LOCALAPPDATA 'OmniDiag') 'Data'))
}

function Get-OmniToolRoot {
    <# .SYNOPSIS Returns the folder OmniDiag is running from. #>
    [OutputType([string])]
    param()
    return $script:OmniToolRoot
}

function Get-OmniDataRoot {
    <#
    .SYNOPSIS
        Returns where OmniDiag keeps everything it writes.

    .OUTPUTS
        OmniDiag.DataRoot with Path, IsPortable (data lives with the tool), and Source
        (Environment, Installed, ToolFolder, or TempFallback).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $Refresh)

    if ($script:OmniDataRootCache -and -not $Refresh) { return $script:OmniDataRootCache }

    $candidate = $null; $source = $null; $portable = $true
    $installedData = Get-OmniInstalledDataPath
    if ($env:OMNIDIAG_DATA -and (Test-OmniDirectoryWritable -Path $env:OMNIDIAG_DATA)) {
        $candidate = [System.IO.Path]::GetFullPath($env:OMNIDIAG_DATA); $source = 'Environment'
        $portable = Test-OmniPathWithin -Path $candidate -Root $script:OmniToolRoot
        # The launchers of an MSI install point OMNIDIAG_DATA at the installed default.
        if ($installedData -and [string]::Equals($candidate.TrimEnd('\', '/'), $installedData.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = 'Installed'; $portable = $false
        }
    } else {
        if ($env:OMNIDIAG_DATA) { Write-Warning "OMNIDIAG_DATA '$($env:OMNIDIAG_DATA)' is not writable; using the default location." }
        $toolData = Join-Path $script:OmniToolRoot 'OmniDiagData'
        if ($installedData -and (Test-OmniDirectoryWritable -Path $installedData)) {
            $candidate = $installedData; $source = 'Installed'; $portable = $false
        } elseif (Test-OmniDirectoryWritable -Path $toolData) {
            $candidate = $toolData; $source = 'ToolFolder'
        } else {
            $candidate = Join-Path ([System.IO.Path]::GetTempPath()) 'OmniDiag'; $source = 'TempFallback'; $portable = $false
        }
    }

    $script:OmniDataRootCache = [pscustomobject]@{
        PSTypeName = 'OmniDiag.DataRoot'
        Path       = $candidate
        ToolRoot   = $script:OmniToolRoot
        IsPortable = $portable
        Source     = $source
    }
    return $script:OmniDataRootCache
}

function Get-OmniDataPath {
    <#
    .SYNOPSIS
        Returns (and creates) a subfolder of the data root.

    .PARAMETER Kind
        Logs, Reports, Sessions, Backups, Temp, or Cache.

    .PARAMETER ChildPath
        Optional file name to append.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Logs', 'Reports', 'Sessions', 'Backups', 'Temp', 'Cache')][string] $Kind,
        [string] $ChildPath
    )
    $dir = Join-Path (Get-OmniDataRoot).Path $Kind.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Kind -eq 'Temp') {
        $marker = Join-Path $dir $script:OmniScratchMarker
        if (-not (Test-Path -LiteralPath $marker)) { [System.IO.File]::WriteAllText($marker, 'OmniDiag scratch folder; safe to delete.') }
    }
    if ($ChildPath) { return (Join-Path $dir $ChildPath) }
    return $dir
}

function Clear-OmniTempData {
    <#
    .SYNOPSIS
        Removes OmniDiag's scratch folder (data root\temp). Logs and reports are kept.

    .DESCRIPTION
        Deletes the folder only when it carries OmniDiag's marker file, so pointing
        OMNIDIAG_DATA at an existing folder (e.g. %LOCALAPPDATA%, whose Temp is the
        user's real temp folder) can never wipe data OmniDiag didn't create.
    #>
    [CmdletBinding()]
    param()
    $temp = Join-Path (Get-OmniDataRoot).Path 'temp'
    if (Test-Path -LiteralPath (Join-Path $temp $script:OmniScratchMarker)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Path safety (Phase 4 security review, docs/SECURITY-REVIEW.md)
# ---------------------------------------------------------------------------

# Win32 reserved device names. A file component whose base name (before the first dot,
# trailing spaces ignored) is one of these opens the device, not a file: 'NUL.txt' is NUL.
$script:OmniReservedNameRegex = [regex]::new('^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$|CLOCK\$)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# Win32 device / raw namespace prefixes: \\.\  \\?\  \??\  (and their forward-slash spellings).
$script:OmniDevicePathRegex = [regex]::new('^(?:[\\/]{2}[.?][\\/]|\\\?\?\\)',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# Named pipes and mailslots reached through any UNC host (\\localhost\pipe\x, \\127.0.0.1\pipe\x,
# \\server\mailslot\x): the share names 'pipe' and 'mailslot' are never file shares.
$script:OmniPipeSharePathRegex = [regex]::new('^[\\/]{2}[^\\/]+[\\/]+(?:pipe|mailslot)(?:[\\/]|$)',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

function Test-OmniReservedFileName {
    <# .SYNOPSIS Internal: true when a single path component names a Win32 device (CON, NUL, COM1, ...). #>
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    $base = $Name.TrimEnd(' ', '.')
    $dot = $base.IndexOf('.')
    if ($dot -ge 0) { $base = $base.Substring(0, $dot) }
    return $script:OmniReservedNameRegex.IsMatch($base.TrimEnd(' '))
}

function ConvertTo-OmniSafeFileName {
    <#
    .SYNOPSIS
        Returns a single, safe file-name component built from untrusted text.

    .DESCRIPTION
        For names derived from host data (computer name, user name, redacted names, a
        caller-supplied base name): path separators, ':' (drive letters and NTFS
        alternate data streams), wildcard and other invalid characters, and control
        characters become '_'; trailing dots and spaces (which Windows strips) are
        removed; '.', '..', and empty results fall back to -Default; Win32 device names
        (CON, NUL, COM1, LPT1, ...) are prefixed with '_'. The result can never contain a
        separator, so joining it to a directory cannot leave that directory.

    .PARAMETER Name
        The untrusted text.

    .PARAMETER Default
        Used when nothing usable remains. Default 'file'.

    .EXAMPLE
        ConvertTo-OmniSafeFileName -Name '..\..\evil:stream'   # '.._.._evil_stream'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string] $Name,
        [string] $Default = 'file'
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Default }
    $s = [regex]::Replace($Name, '[\x00-\x1F\x7F<>:"/\\|?*\[\]]', '_')
    # Trailing dots/spaces are dropped by Windows; this also turns '.' and '..' into ''.
    $s = $s.Trim().TrimEnd('.', ' ')
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120).TrimEnd('.', ' ') }
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    if (Test-OmniReservedFileName -Name $s) { $s = '_' + $s }
    return $s
}

function Resolve-OmniOutputPath {
    <#
    .SYNOPSIS
        Canonicalizes an output path and refuses device, stream, and non-file-system targets.

    .DESCRIPTION
        Resolves the path against PowerShell's current location (not the process
        directory), then [System.IO.Path]::GetFullPath, so '..' segments are collapsed
        before anything is written. The path is refused (an exception is thrown) when it:
          * uses the Win32 device or raw namespace (\\.\, \\?\, \??\), or a named pipe or
            mailslot through any UNC host (\\localhost\pipe\x, \\127.0.0.1\mailslot\x),
          * is too long to canonicalize (PathTooLongException),
          * names a reserved device in any component (CON, PRN, AUX, NUL, COM0-9,
            LPT0-9, CONIN$, CONOUT$, CLOCK$ - with or without an extension),
          * contains ':' after the drive root (an NTFS alternate data stream, file.txt:s),
          * contains a NUL character, or resolves to a provider other than FileSystem.
        With -Root, the canonical path must also be Root itself or inside it.

    .PARAMETER Path
        The requested path (absolute or relative).

    .PARAMETER Root
        Optional containing directory the result must not leave.

    .PARAMETER Purpose
        Wording for the error message (e.g. 'output', 'report directory').

    .OUTPUTS
        The canonical, absolute path (string).

    .EXAMPLE
        Resolve-OmniOutputPath -Path '.\reports\..\out'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Path,
        [string] $Root,
        [string] $Purpose = 'output'
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "The $Purpose path is empty." }
    if ($Path.IndexOf([char]0) -ge 0) { throw "The $Purpose path contains a NUL character." }
    if ($script:OmniDevicePathRegex.IsMatch($Path)) {
        throw "The $Purpose path '$Path' is a device path (\\.\, \\?\); write to a normal folder instead."
    }
    if ($script:OmniPipeSharePathRegex.IsMatch($Path)) {
        throw "The $Purpose path '$Path' is a named pipe or mailslot (device path); write to a normal folder instead."
    }

    $resolved = $null
    try {
        $provider = $null; $drive = $null
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
        if ($null -ne $provider -and $provider.Name -ne 'FileSystem') {
            throw "provider '$($provider.Name)' is not the file system"
        }
    } catch {
        throw "The $Purpose path '$Path' is not a valid file-system path: $($_.Exception.Message)"
    }

    # Stream syntax: ':' anywhere after the root (C:\ or \\server\share\ or /).
    # (Not named $root: PowerShell variables are case-insensitive and -Root is a parameter.)
    $pathRoot = ''
    try { $pathRoot = [System.IO.Path]::GetPathRoot($resolved) } catch { $pathRoot = '' }
    if ($null -eq $pathRoot) { $pathRoot = '' }
    $rest = $resolved.Substring([math]::Min($pathRoot.Length, $resolved.Length))
    if ($rest.IndexOf(':') -ge 0) {
        throw "The $Purpose path '$Path' contains ':' (an NTFS alternate data stream or a misplaced drive letter)."
    }

    # Before GetFullPath: .NET Framework maps C:\x\NUL.txt to \\.\NUL.
    foreach ($segment in ($rest -split '[\\/]')) {
        if (Test-OmniReservedFileName -Name $segment) {
            throw "The $Purpose path '$Path' names the reserved device '$segment'; choose another file name."
        }
    }

    $full = $resolved
    try { $full = [System.IO.Path]::GetFullPath($resolved) }
    catch [System.IO.PathTooLongException] { throw "The $Purpose path '$Path' is too long to canonicalize; choose a shorter path." }
    catch { throw "The $Purpose path '$Path' is not a valid file-system path: $($_.Exception.Message)" }

    if ($script:OmniDevicePathRegex.IsMatch($full) -or $script:OmniPipeSharePathRegex.IsMatch($full)) {
        throw "The $Purpose path '$Path' resolves to a device path ($full)."
    }
    if ($Root) {
        $rootFull = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root))
        if (-not (Test-OmniPathWithin -Path $full -Root $rootFull)) {
            throw "The $Purpose path '$Path' resolves outside '$rootFull'."
        }
    }
    return $full
}

Export-ModuleMember -Function @('Get-OmniToolRoot', 'Get-OmniDataRoot', 'Get-OmniDataPath', 'Clear-OmniTempData',
    'Resolve-OmniOutputPath', 'ConvertTo-OmniSafeFileName')
