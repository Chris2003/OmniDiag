<#
.SYNOPSIS
    OmniDiag diagnostic module: Service Persistence.

.DESCRIPTION
    Reviews services as an autostart (persistence) mechanism, from Win32_Service:
      - automatic-start services whose binary is in a user-writable location
        (AppData, Temp, Users\Public, Downloads/Desktop/Documents, directly in ProgramData)
        -> Warning;
      - automatic-start services whose binary is outside %SystemRoot%, %ProgramFiles%,
        and %ProgramFiles(x86)% -> Information (vendors commonly install to custom
        folders; only user-writable locations and unquoted paths are Warnings);
      - services (not disabled) with an unquoted image path that contains a space
        (classic unquoted-service-path hijack) -> Warning;
      - an Information summary with the counts.

    The binary path is parsed from PathName (quoted or unquoted, with arguments,
    \SystemRoot\ and \??\ prefixes, environment variables). Files are not opened and
    signatures are not checked. Read-only and local-only.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Service Persistence scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Service Persistence'
        Id            = 'startup.service-persistence'
        Group         = 'startup'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Auto-start services running from non-standard or user-writable locations, and unquoted service paths.'
        RequiresAdmin = $false
        Order         = 125
        Enabled       = $true
    }
}

function Get-OmniPersistenceService {
    <#
    .SYNOPSIS
        Returns Win32_Service instances (private; mocked in tests). Throws when CIM is unavailable.
    #>
    [OutputType([object[]])]
    param()
    return @(Get-CimInstance -ClassName 'Win32_Service' -ErrorAction Stop)
}

function Get-OmniPersistenceRoot {
    <#
    .SYNOPSIS
        Returns the standard install roots (private; mocked in tests).
    #>
    [OutputType([hashtable])]
    param()
    $get = {
        param($name, $default)
        $v = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $default }
        $v.TrimEnd('\')
    }
    return @{
        SystemRoot      = & $get 'SystemRoot' 'C:\Windows'
        ProgramFiles    = & $get 'ProgramFiles' 'C:\Program Files'
        ProgramFilesX86 = & $get 'ProgramFiles(x86)' 'C:\Program Files (x86)'
        ProgramW6432    = & $get 'ProgramW6432' 'C:\Program Files'
        ProgramData     = & $get 'ProgramData' 'C:\ProgramData'
    }
}

function Get-OmniPersistenceValue {
    <#
    .SYNOPSIS
        Reads a property that may be absent (private).
    #>
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertFrom-OmniServicePathName {
    <#
    .SYNOPSIS
        Splits a service PathName into its image path and flags (private).

    .OUTPUTS
        Object with Image (normalized full path or ''), Quoted, and UnquotedWithSpace.
    #>
    [OutputType([pscustomobject])]
    param([string] $PathName, [string] $SystemRoot)
    $raw = if ($PathName) { $PathName.Trim() } else { '' }
    $quoted = $false
    $image = ''
    if ($raw.StartsWith('"')) {
        $quoted = $true
        $close = $raw.IndexOf('"', 1)
        $image = if ($close -gt 0) { $raw.Substring(1, $close - 1) } else { $raw.Substring(1) }
    } elseif ($raw -match '^(?i)(.+?\.(exe|com|bat|cmd|sys|dll|scr))(?=\s|$)') {
        $image = $Matches[1]
    } elseif ($raw) {
        $image = ($raw -split '\s+')[0]
    }
    $unquotedSpace = (-not $quoted) -and $image.Contains(' ')

    $p = [Environment]::ExpandEnvironmentVariables($image.Replace('/', '\'))
    if ($p -match '^\\\?\?\\') { $p = $p.Substring(4) }
    if ($p -match '^(?i)\\SystemRoot\\') { $p = $SystemRoot + $p.Substring(11) }
    elseif ($p -match '^(?i)system32\\') { $p = $SystemRoot + '\' + $p }

    return [pscustomobject]@{ Image = $p; Quoted = $quoted; UnquotedWithSpace = $unquotedSpace }
}

function Test-OmniPersistenceUserWritablePath {
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

function Test-OmniPersistenceStandardPath {
    <#
    .SYNOPSIS
        True when a path is under %SystemRoot%, a Program Files folder, or a known-good exception (private).
    #>
    [OutputType([bool])]
    param([string] $Path, [hashtable] $Root)
    $prefixes = @(
        ($Root.SystemRoot + '\'), ($Root.ProgramFiles + '\'), ($Root.ProgramFilesX86 + '\'), ($Root.ProgramW6432 + '\'),
        # Microsoft Defender's platform binaries are serviced under ProgramData.
        ($Root.ProgramData + '\Microsoft\Windows Defender\'),
        ($Root.ProgramData + '\Microsoft\Windows Defender Advanced Threat Protection\')
    )
    foreach ($pre in $prefixes) {
        if ($Path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the Service Persistence scan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Service Persistence' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $services = $null
    try {
        $services = @(Get-OmniPersistenceService)
    } catch {
        $log.Warn("CIM query failed for Win32_Service: $($_.Exception.Message)", 'Service Persistence')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-unavailable' `
            -Title 'Service inventory not available' -Severity 'Information' -Component 'Startup/Services' `
            -Detail 'Win32_Service could not be queried (CIM is not available on this platform or the query failed).')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $root = Get-OmniPersistenceRoot
    $autoCount = 0
    $userWritable = [System.Collections.Generic.List[object]]::new()
    $nonStandard = [System.Collections.Generic.List[object]]::new()
    $unquoted = [System.Collections.Generic.List[object]]::new()

    foreach ($s in $services) {
        if ($Context.CancellationToken.IsCancellationRequested) { break }
        $mode = [string](Get-OmniPersistenceValue $s 'StartMode')
        if ($mode -eq 'Disabled') { continue }
        $pathName = [string](Get-OmniPersistenceValue $s 'PathName')
        if (-not $pathName) { continue }
        $parsed = ConvertFrom-OmniServicePathName -PathName $pathName -SystemRoot $root.SystemRoot
        $entry = [pscustomobject]@{
            Name = [string](Get-OmniPersistenceValue $s 'Name'); DisplayName = [string](Get-OmniPersistenceValue $s 'DisplayName')
            StartMode = $mode; State = [string](Get-OmniPersistenceValue $s 'State'); Image = $parsed.Image; PathName = $pathName
        }
        if ($parsed.UnquotedWithSpace) { $unquoted.Add($entry) }
        if ($mode -ne 'Auto') { continue }
        $autoCount++
        # Relative image names (no folder) resolve through the system path; nothing to judge.
        if ($parsed.Image -notmatch '^(?i)([a-z]:\\|\\\\)') { continue }
        if (Test-OmniPersistenceUserWritablePath -Path $parsed.Image) { $userWritable.Add($entry) }
        elseif (-not (Test-OmniPersistenceStandardPath -Path $parsed.Image -Root $root)) { $nonStandard.Add($entry) }
    }

    Set-OmniResultMetric -Result $result -Name 'AutoStartServiceCount' -Value $autoCount
    Set-OmniResultMetric -Result $result -Name 'UserWritableServiceCount' -Value $userWritable.Count
    Set-OmniResultMetric -Result $result -Name 'NonStandardLocationServiceCount' -Value $nonStandard.Count
    Set-OmniResultMetric -Result $result -Name 'UnquotedServicePathCount' -Value $unquoted.Count

    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-summary' `
        -Title 'Auto-start service locations reviewed' -Severity 'Information' -Component 'Startup/Services' `
        -Detail ("$autoCount automatic-start service(s): $($userWritable.Count) in a user-writable location, $($nonStandard.Count) outside Windows and Program Files; $($unquoted.Count) service(s) with an unquoted path containing spaces."))

    $fmt = { param($e) '{0} ({1}): {2}' -f $e.DisplayName, $e.Name, $e.Image }

    if ($userWritable.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-user-writable' `
            -Title ("$($userWritable.Count) auto-start service(s) run from a user-writable location") -Severity 'Warning' `
            -Component 'Startup/Services' `
            -Detail ('Automatic services whose binary is in a folder standard users can write (first 20): ' + (@($userWritable | Select-Object -First 20 | ForEach-Object { & $fmt $_ }) -join '; ')) `
            -LikelyCause 'Malware or unwanted software persisting as a service, or software installed per-user; anyone who can replace the binary gets code execution as the service account.' `
            -Confidence 70 `
            -Recommendation 'Verify the owning software; reinstall it under Program Files or remove the service. Scan the binary with your antimalware tool.' `
            -Data @($userWritable))
    }

    if ($nonStandard.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-nonstandard-location' `
            -Title ("$($nonStandard.Count) auto-start service(s) run from outside Windows and Program Files") -Severity 'Information' `
            -Component 'Startup/Services' `
            -Detail ('Automatic services whose binary is outside %SystemRoot%, %ProgramFiles%, and %ProgramFiles(x86)% (first 20): ' + (@($nonStandard | Select-Object -First 20 | ForEach-Object { & $fmt $_ }) -join '; ')) `
            -LikelyCause 'Software installed to a custom folder or ProgramData; less commonly, a service planted for persistence. Such folders may have weaker permissions.' `
            -Confidence 45 `
            -Recommendation 'Confirm each service belongs to trusted software and that its folder is not writable by standard users.' `
            -Data @($nonStandard))
    }

    if ($unquoted.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-unquoted-path' `
            -Title ("$($unquoted.Count) service(s) with an unquoted path containing spaces") -Severity 'Warning' `
            -Component 'Startup/Services' `
            -Detail ('Services whose PathName has spaces but no quotes (first 20): ' + (@($unquoted | Select-Object -First 20 | ForEach-Object { '{0} ({1}): {2}' -f $_.DisplayName, $_.Name, $_.PathName }) -join '; ')) `
            -LikelyCause 'The installer registered the service without quoting its path. Windows tries each space-separated prefix (e.g. C:\Program.exe) first, which allows privilege escalation if any of those folders is writable.' `
            -Confidence 80 `
            -Recommendation 'Ask the vendor for a fixed version, or quote the ImagePath value under HKLM\SYSTEM\CurrentControlSet\Services\<name> (change control required).' `
            -Data @($unquoted))
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        $okDetail = if ($nonStandard.Count -gt 0) {
            'No automatic-start service binary is in a user-writable location, and no service has an unquoted path with spaces (services in custom folders are listed separately).'
        } else {
            'Every automatic-start service binary is under Windows or Program Files, and no service has an unquoted path with spaces.'
        }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'service-persistence-ok' `
            -Title 'Auto-start services run from standard locations' -Severity 'Pass' -Component 'Startup/Services' `
            -Detail $okDetail)
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
