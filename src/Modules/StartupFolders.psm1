<#
.SYNOPSIS
    OmniDiag diagnostic module: Startup Folders.

.DESCRIPTION
    Enumerates the per-user and all-users Startup folders directly
    ([Environment]::GetFolderPath('Startup' / 'CommonStartup')) and reports each entry.
    Shortcut (.lnk) targets are read through the WScript.Shell COM object when it is
    available (the shortcut is loaded, never saved); Internet shortcuts (.url) are read
    as text. Entries are flagged (Warning) when the target is in a user-writable
    location (AppData, Temp, Users\Public, Downloads/Desktop/Documents, directly in
    ProgramData), when a script host is used in a way common to malware, or when an
    executable or script file is placed directly in a Startup folder.

    Read-only and local-only.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

# File types that run code when opened from a Startup folder.
$script:RunnableExtension = @('.exe', '.com', '.bat', '.cmd', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.ps1', '.hta', '.scr', '.pif', '.msi', '.jar')

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Startup Folders scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Startup Folders'
        Id            = 'startup.startup-folders'
        Group         = 'startup'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Per-user and all-users Startup folder entries, with shortcut targets and risky locations.'
        RequiresAdmin = $false
        Order         = 115
        Enabled       = $true
    }
}

function Get-OmniStartupFolderList {
    <#
    .SYNOPSIS
        Returns the Startup folders that exist on this system (private; mocked in tests).
    #>
    [OutputType([object[]])]
    param()
    $out = foreach ($pair in @(@('CurrentUser', 'Startup'), @('AllUsers', 'CommonStartup'))) {
        $path = ''
        try { $path = [Environment]::GetFolderPath([Environment+SpecialFolder]$pair[1]) } catch { $path = '' }
        if (-not [string]::IsNullOrWhiteSpace($path)) { [pscustomobject]@{ Scope = $pair[0]; Path = $path } }
    }
    return @($out)
}

function Get-OmniStartupFolderItem {
    <#
    .SYNOPSIS
        Returns the files in one Startup folder, without desktop.ini (private; mocked in tests).
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -ne 'desktop.ini' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Extension = $_.Extension } })
}

function Resolve-OmniStartupShortcut {
    <#
    .SYNOPSIS
        Reads a .lnk target and arguments via WScript.Shell (private; mocked in tests).

    .DESCRIPTION
        CreateShortcut on an existing file loads it; Save is never called, so the file is
        not changed. Returns $null when the COM object is unavailable.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Path)
    $shell = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell' -ErrorAction Stop
        $lnk = $shell.CreateShortcut($Path)
        return [pscustomobject]@{ Target = [string]$lnk.TargetPath; Arguments = [string]$lnk.Arguments }
    } catch {
        return $null
    } finally {
        if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { $null = $_ } }
    }
}

function Get-OmniStartupUrlTarget {
    <#
    .SYNOPSIS
        Returns the URL= value of an Internet shortcut (private; mocked in tests).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    foreach ($line in @(Get-Content -LiteralPath $Path -TotalCount 50 -ErrorAction Stop)) {
        if ($line -match '^\s*URL\s*=\s*(.+)$') { return $Matches[1].Trim() }
    }
    return ''
}

function Test-OmniStartupUserWritablePath {
    <#
    .SYNOPSIS
        True when a path is in a location standard users can write (private).
    #>
    [OutputType([bool])]
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Replace('/', '\')
    $patterns = @(
        '(?i)\\Users\\[^\\]+\\AppData\\',
        '(?i)\\Users\\Public\\',
        '(?i)\\Users\\[^\\]+\\(Downloads|Desktop|Documents)\\',
        '(?i)\\(Temp|Tmp)\\',
        '(?i)^[a-z]:\\ProgramData\\[^\\]+$'
    )
    foreach ($re in $patterns) { if ($p -match $re) { return $true } }
    return $false
}

function Get-OmniStartupScriptHostRisk {
    <#
    .SYNOPSIS
        Returns why a target/arguments pair uses a script host suspiciously (private; empty when not).
    #>
    [OutputType([string[]])]
    param([string] $Target, [string] $Arguments)
    $reasons = [System.Collections.Generic.List[string]]::new()
    $leaf = ((([string]$Target).Replace('/', '\')) -split '\\')[-1].ToLowerInvariant()
    $argText = [string]$Arguments
    $url = '(?i)(https?://|\\\\[^\\]+\\|javascript:|vbscript:)'
    switch ($leaf) {
        { $_ -in @('powershell.exe', 'pwsh.exe') } {
            foreach ($tok in @($argText -split '\s+')) {
                if ($tok -notmatch '^[-/]') { continue }
                $name = $tok.Substring(1).ToLowerInvariant()
                if ($name -eq 'ec' -or ($name.StartsWith('e') -and 'encodedcommand'.StartsWith($name))) { $reasons.Add('PowerShell encoded command'); break }
            }
            if ($argText -match $url) { $reasons.Add('PowerShell with a URL') }
        }
        { $_ -in @('wscript.exe', 'cscript.exe') } { $reasons.Add('Windows Script Host') }
        'mshta.exe' { $reasons.Add('mshta (HTML application host)') }
        'rundll32.exe' { if ($argText -match $url) { $reasons.Add('rundll32 with a URL or script') } }
        'regsvr32.exe' { if ($argText -match $url) { $reasons.Add('regsvr32 with a URL') } }
    }
    return [string[]]@($reasons)
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the Startup Folders scan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Startup Folders' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $folders = @(Get-OmniStartupFolderList)
    if ($folders.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'startup-folders-unavailable' `
            -Title 'Startup folders not available' -Severity 'Information' -Component 'System/StartupFolders' `
            -Detail 'The per-user and all-users Startup folders are not defined on this platform.')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $unresolved = 0
    foreach ($folder in $folders) {
        if ($Context.CancellationToken.IsCancellationRequested) { break }
        $items = @()
        try {
            $items = @(Get-OmniStartupFolderItem -Path $folder.Path)
        } catch {
            $log.Debug("Failed to list Startup folder '$($folder.Path)': $($_.Exception.Message)", 'Startup Folders')
            continue
        }
        foreach ($item in $items) {
            if ($Context.CancellationToken.IsCancellationRequested) { break }
            $ext = ([string]$item.Extension).ToLowerInvariant()
            $type = 'File'; $target = [string]$item.FullName; $argText = ''
            $reasons = [System.Collections.Generic.List[string]]::new()
            if ($ext -eq '.lnk') {
                $type = 'Shortcut'
                $lnk = Resolve-OmniStartupShortcut -Path $item.FullName
                if ($null -eq $lnk -or -not $lnk.Target) { $target = '(target not resolved)'; $unresolved++ }
                else {
                    $target = [Environment]::ExpandEnvironmentVariables([string]$lnk.Target)
                    $argText = [string]$lnk.Arguments
                    if (Test-OmniStartupUserWritablePath -Path $target) { $reasons.Add('target in a user-writable location') }
                    foreach ($r in @(Get-OmniStartupScriptHostRisk -Target $target -Arguments $argText)) { $reasons.Add($r) }
                }
            } elseif ($ext -eq '.url') {
                $type = 'InternetShortcut'
                try { $target = Get-OmniStartupUrlTarget -Path $item.FullName } catch { $target = '(URL not readable)' }
                if ($target -match '^(?i)file:') { $reasons.Add('Internet shortcut opens a local or network file') }
            } elseif ($ext -in $script:RunnableExtension) {
                $reasons.Add('executable or script placed directly in the Startup folder')
            }
            $entries.Add([pscustomobject]@{
                Scope = $folder.Scope; Name = [string]$item.Name; Type = $type
                Target = $target; Arguments = $argText; Reasons = [string[]]@($reasons)
            })
        }
    }

    $flagged = @($entries | Where-Object { @($_.Reasons).Count -gt 0 })
    Set-OmniResultMetric -Result $result -Name 'StartupFolderEntryCount' -Value $entries.Count
    Set-OmniResultMetric -Result $result -Name 'SuspiciousStartupFolderEntryCount' -Value $flagged.Count
    Set-OmniResultMetric -Result $result -Name 'StartupFolders' -Value @($folders | ForEach-Object { [pscustomobject]@{ Scope = $_.Scope; Path = $_.Path } })

    $describe = { param($e) ('[{0}] {1} -> {2} {3}' -f $e.Scope, $e.Name, $e.Target, $e.Arguments).Trim() }
    $detail = if ($entries.Count -gt 0) {
        "$($entries.Count) item(s) in the Startup folders (first 25): " + (@($entries | Select-Object -First 25 | ForEach-Object { & $describe $_ }) -join '; ')
    } else { 'The per-user and all-users Startup folders are empty.' }
    if ($unresolved -gt 0) { $detail += " $unresolved shortcut target(s) could not be resolved (WScript.Shell unavailable or the shortcut is damaged)." }
    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'startup-folders-summary' `
        -Title ("$($entries.Count) Startup folder item(s)") -Severity 'Information' -Component 'System/StartupFolders' `
        -Detail $detail -Data @($entries))

    if ($flagged.Count -gt 0) {
        $list = @($flagged | Select-Object -First 20 | ForEach-Object { '{0} ({1})' -f (& $describe $_), ($_.Reasons -join ', ') })
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'startup-folders-suspicious-entry' `
            -Title ("$($flagged.Count) Startup folder item(s) need review") -Severity 'Warning' `
            -Component 'System/StartupFolders' `
            -Detail ('Startup folder entries that start from a user-writable location, use a script host, or are executables/scripts placed directly in the folder: ' + ($list -join '; ')) `
            -LikelyCause 'Persistence by unwanted software or malware; some per-user applications also start from AppData.' `
            -Confidence 55 `
            -Recommendation 'Verify each entry belongs to software you trust; remove entries you cannot attribute and scan the target with your antimalware tool.' `
            -Data @($flagged))
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'startup-folders-ok' `
            -Title 'Startup folder entries look normal' -Severity 'Pass' -Component 'System/StartupFolders' `
            -Detail 'No Startup folder entry starts from a user-writable location or uses a script host.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
