<#
.SYNOPSIS
    OmniDiag registry scanning, backup, and safe removal (CCleaner-style).

.DESCRIPTION
    Detection is READ-ONLY: Get-OmniInvalidRegistryEntry finds common invalid/obsolete
    registry entries (broken startup commands, dead App Paths, orphaned file associations,
    obsolete uninstall leftovers, and missing shared-DLL / sound-event / font references)
    and returns a flat list of removable entries. Nothing is changed by detection.

    Change is opt-in and reversible: Export-OmniRegistryBackup writes a .reg backup of the
    affected keys FIRST; Remove-OmniRegistryEntry then deletes a single value or key. The
    Repair Center's "Clean Invalid Registry Entries" plugin ties these together behind the
    engine's dry-run, restore-point, and confirmation safeguards.

    Every check fails soft (per-item try/catch) so a locked or exotic key never aborts a scan.

    Entry shape (one removable item):
        Category  : Startup | App Paths | File Association | Obsolete Software |
                    Shared DLL | Sound Event | Font
        Root      : HKLM | HKCU | HKCR
        SubPath   : key path under the root (no leading backslash)
        ValueName : value to delete; '(default)' for a key's default value; $null = delete the whole key
        Target    : the missing file/path that makes the entry invalid
        Detail    : one-line human description
#>

Set-StrictMode -Version Latest

$script:OmniHiveMap = @{
    HKLM = 'HKEY_LOCAL_MACHINE'
    HKCU = 'HKEY_CURRENT_USER'
    HKCR = 'HKEY_CLASSES_ROOT'
}

function ConvertTo-OmniRegProviderPath {
    param([string] $Root, [string] $SubPath)
    if ($SubPath) { "Registry::$($script:OmniHiveMap[$Root])\$SubPath" } else { "Registry::$($script:OmniHiveMap[$Root])" }
}

function ConvertTo-OmniRegExePath {
    param([string] $Root, [string] $SubPath)
    if ($SubPath) { "$Root\$SubPath" } else { $Root }
}

function New-OmniRegEntry {
    param($Category, $Root, $SubPath, $ValueName, $Target, $Detail)
    [pscustomobject]@{
        PSTypeName = 'OmniDiag.RegistryEntry'
        Category   = $Category
        Root       = $Root
        SubPath    = $SubPath
        ValueName  = $ValueName
        Target     = $Target
        Detail     = $Detail
    }
}

function Get-OmniPathFromCommand {
    <# .SYNOPSIS Internal: extract the executable path from a command line string. #>
    param([string] $Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = ([System.Environment]::ExpandEnvironmentVariables($Command)).Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($c, '^(.*?\.(?:exe|com|bat|cmd|scr|dll))\b', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}

function Test-OmniTargetMissing {
    <# .SYNOPSIS Internal: $true if a non-empty path clearly does not exist. #>
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }   # nothing to validate
    $p = ([System.Environment]::ExpandEnvironmentVariables($Path)).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    # Only judge things that look like a filesystem path (avoid flagging shell verbs, URLs, etc.).
    if ($p -notmatch '^[a-zA-Z]:\\' -and $p -notmatch '^\\\\') { return $false }
    return -not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)
}

function Get-OmniInvalidRegistryEntry {
    <#
    .SYNOPSIS
        Read-only scan for invalid/obsolete registry entries (returns removable entries).

    .PARAMETER Category
        Optional filter: only return entries in these categories.

    .PARAMETER Logger
        Optional OmniDiag logger for soft-failure diagnostics.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]] $Category,
        [pscustomobject] $Logger
    )

    $found = [System.Collections.Generic.List[object]]::new()
    $warn = { param($m) if ($Logger) { $Logger.Debug($m, 'RegistryScan') } }

    # --- Startup: Run / RunOnce values whose target is gone --------------------
    try {
        $runKeys = @(
            @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
            @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' }
            @{ Root = 'HKLM'; Sub = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
            @{ Root = 'HKCU'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
            @{ Root = 'HKCU'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' }
        )
        foreach ($rk in $runKeys) {
            $pp = ConvertTo-OmniRegProviderPath -Root $rk.Root -SubPath $rk.Sub
            $key = Get-Item -LiteralPath $pp -ErrorAction SilentlyContinue
            if (-not $key) { continue }
            foreach ($name in $key.Property) {
                if ($name -eq '') { continue }
                try {
                    $exe = Get-OmniPathFromCommand ([string]$key.GetValue($name))
                    if (Test-OmniTargetMissing $exe) {
                        $found.Add((New-OmniRegEntry -Category 'Startup' -Root $rk.Root -SubPath $rk.Sub -ValueName $name -Target $exe `
                            -Detail "Startup '$name' -> missing $exe"))
                    }
                } catch { & $warn "Startup value '$name' failed: $($_.Exception.Message)" }
            }
        }
    } catch { & $warn "Startup scan failed: $($_.Exception.Message)" }

    # --- App Paths: subkeys whose (Default) exe is gone -----------------------
    try {
        foreach ($base in @(
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' }
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths' })) {
            $pp = ConvertTo-OmniRegProviderPath -Root $base.Root -SubPath $base.Sub
            foreach ($sub in @(Get-ChildItem -LiteralPath $pp -ErrorAction SilentlyContinue)) {
                try {
                    $def = [string]$sub.GetValue('')
                    if (Test-OmniTargetMissing $def) {
                        $found.Add((New-OmniRegEntry -Category 'App Paths' -Root $base.Root -SubPath "$($base.Sub)\$($sub.PSChildName)" -ValueName $null -Target $def `
                            -Detail "App Path '$($sub.PSChildName)' -> missing $def"))
                    }
                } catch { & $warn "App Path '$($sub.PSChildName)' failed: $($_.Exception.Message)" }
            }
        }
    } catch { & $warn "App Paths scan failed: $($_.Exception.Message)" }

    # --- File associations: HKCR\.ext whose ProgID key no longer exists --------
    try {
        $crRoot = ConvertTo-OmniRegProviderPath -Root 'HKCR' -SubPath ''
        foreach ($ext in @(Get-ChildItem -LiteralPath $crRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '.*' })) {
            try {
                $progId = [string]$ext.GetValue('')
                if ([string]::IsNullOrWhiteSpace($progId)) { continue }
                $progPath = ConvertTo-OmniRegProviderPath -Root 'HKCR' -SubPath $progId
                if (-not (Test-Path -LiteralPath $progPath -ErrorAction SilentlyContinue)) {
                    $found.Add((New-OmniRegEntry -Category 'File Association' -Root 'HKCR' -SubPath $ext.PSChildName -ValueName $null -Target $progId `
                        -Detail "Extension '$($ext.PSChildName)' -> missing ProgID '$progId'"))
                }
            } catch { & $warn "File assoc '$($ext.PSChildName)' failed: $($_.Exception.Message)" }
        }
    } catch { & $warn "File association scan failed: $($_.Exception.Message)" }

    # --- Obsolete software: Uninstall entries whose InstallLocation is gone ----
    try {
        foreach ($base in @(
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
                @{ Root = 'HKCU'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' })) {
            $pp = ConvertTo-OmniRegProviderPath -Root $base.Root -SubPath $base.Sub
            foreach ($sub in @(Get-ChildItem -LiteralPath $pp -ErrorAction SilentlyContinue)) {
                try {
                    $loc = [string]$sub.GetValue('InstallLocation')
                    # Only flag a clear, present-but-missing install directory (avoids MSI false positives).
                    if ($loc -and $loc -match '^[a-zA-Z]:\\' -and -not (Test-Path -LiteralPath $loc.Trim('"') -ErrorAction SilentlyContinue)) {
                        $name = [string]$sub.GetValue('DisplayName'); if (-not $name) { $name = $sub.PSChildName }
                        $found.Add((New-OmniRegEntry -Category 'Obsolete Software' -Root $base.Root -SubPath "$($base.Sub)\$($sub.PSChildName)" -ValueName $null -Target $loc `
                            -Detail "Uninstall leftover '$name' -> missing $loc"))
                    }
                } catch { & $warn "Uninstall '$($sub.PSChildName)' failed: $($_.Exception.Message)" }
            }
        }
    } catch { & $warn "Uninstall scan failed: $($_.Exception.Message)" }

    # --- Shared DLLs: refcount values whose file is gone (value name = path) ---
    try {
        foreach ($base in @(
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs' }
                @{ Root = 'HKLM'; Sub = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\SharedDLLs' })) {
            $pp = ConvertTo-OmniRegProviderPath -Root $base.Root -SubPath $base.Sub
            $key = Get-Item -LiteralPath $pp -ErrorAction SilentlyContinue
            if (-not $key) { continue }
            foreach ($name in $key.Property) {
                try {
                    if ($name -and (Test-OmniTargetMissing $name)) {
                        $found.Add((New-OmniRegEntry -Category 'Shared DLL' -Root $base.Root -SubPath $base.Sub -ValueName $name -Target $name `
                            -Detail "Shared DLL reference -> missing $name"))
                    }
                } catch { & $warn "SharedDLL '$name' failed: $($_.Exception.Message)" }
            }
        }
    } catch { & $warn "Shared DLL scan failed: $($_.Exception.Message)" }

    # --- Sound events: .Current default = missing .wav ------------------------
    try {
        $appsRoot = ConvertTo-OmniRegProviderPath -Root 'HKCU' -SubPath 'AppEvents\Schemes\Apps'
        foreach ($current in @(Get-ChildItem -LiteralPath $appsRoot -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq '.Current' })) {
            try {
                $wav = [string]$current.GetValue('')
                if (Test-OmniTargetMissing $wav) {
                    $rel = ($current.Name -replace '^HKEY_CURRENT_USER\\', '')
                    $found.Add((New-OmniRegEntry -Category 'Sound Event' -Root 'HKCU' -SubPath $rel -ValueName '(default)' -Target $wav `
                        -Detail "Sound event -> missing $wav"))
                }
            } catch { & $warn "Sound event failed: $($_.Exception.Message)" }
        }
    } catch { & $warn "Sound event scan failed: $($_.Exception.Message)" }

    # --- Fonts: registered fonts whose file is gone ---------------------------
    try {
        $fontsDir = Join-Path $env:WINDIR 'Fonts'
        $base = @{ Root = 'HKLM'; Sub = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' }
        $pp = ConvertTo-OmniRegProviderPath -Root $base.Root -SubPath $base.Sub
        $key = Get-Item -LiteralPath $pp -ErrorAction SilentlyContinue
        if ($key) {
            foreach ($name in $key.Property) {
                try {
                    if ($name -eq '') { continue }
                    $file = [string]$key.GetValue($name)
                    if ([string]::IsNullOrWhiteSpace($file)) { continue }
                    $path = if ($file -match '^[a-zA-Z]:\\') { $file } else { Join-Path $fontsDir $file }
                    if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
                        $found.Add((New-OmniRegEntry -Category 'Font' -Root $base.Root -SubPath $base.Sub -ValueName $name -Target $path `
                            -Detail "Font '$name' -> missing $file"))
                    }
                } catch { & $warn "Font '$name' failed: $($_.Exception.Message)" }
            }
        }
    } catch { & $warn "Font scan failed: $($_.Exception.Message)" }

    $result = $found.ToArray()
    if ($Category) { $result = @($result | Where-Object { $_.Category -in $Category }) }
    # Emit as a flat sequence; callers wrap with @() and get correct counts.
    return $result
}

function Export-OmniRegistryBackup {
    <#
    .SYNOPSIS
        Exports a .reg backup of every key affected by the given entries (import to restore).

    .PARAMETER Entries
        Entries from Get-OmniInvalidRegistryEntry.

    .PARAMETER Path
        Destination .reg file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [string] $Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Unique keys to capture (a value deletion is restored by re-importing its key).
    $keys = $Entries | ForEach-Object { ConvertTo-OmniRegExePath -Root $_.Root -SubPath $_.SubPath } | Select-Object -Unique

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Windows Registry Editor Version 5.00')
    [void]$sb.AppendLine('')
    foreach ($k in $keys) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $null = & reg.exe export "$k" "$tmp" /y 2>&1
            if ((Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) {
                $content = Get-Content -LiteralPath $tmp -Raw
                $content = $content -replace '(?s)^\s*﻿?Windows Registry Editor Version 5\.00\s*', ''
                [void]$sb.AppendLine($content.Trim())
                [void]$sb.AppendLine('')
            }
        } catch {
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    # .reg files are UTF-16 LE with BOM.
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UnicodeEncoding]::new($false, $true))
    return $Path
}

function Remove-OmniRegistryEntry {
    <#
    .SYNOPSIS
        Deletes one registry entry: a value, a key's default value, or a whole key.
        Throws on failure (callers wrap it). Back up FIRST with Export-OmniRegistryBackup.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [pscustomobject] $Entry)

    $pp = ConvertTo-OmniRegProviderPath -Root $Entry.Root -SubPath $Entry.SubPath
    if ($null -ne $Entry.ValueName) {
        $name = if ($Entry.ValueName -eq '(default)') { '(default)' } else { $Entry.ValueName }
        if ($PSCmdlet.ShouldProcess("$pp :: $name", 'Remove registry value')) {
            Remove-ItemProperty -LiteralPath $pp -Name $name -Force -ErrorAction Stop
        }
    } else {
        if ($PSCmdlet.ShouldProcess($pp, 'Remove registry key')) {
            Remove-Item -LiteralPath $pp -Recurse -Force -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function @(
    'Get-OmniInvalidRegistryEntry', 'Export-OmniRegistryBackup', 'Remove-OmniRegistryEntry',
    'ConvertTo-OmniRegProviderPath', 'ConvertTo-OmniRegExePath'
)
