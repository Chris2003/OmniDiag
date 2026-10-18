<#
.SYNOPSIS
    OmniDiag diagnostic module: proxy configuration posture.

.DESCRIPTION
    Reads the user's WinINET proxy (HKCU Internet Settings: ProxyEnable, ProxyServer,
    AutoConfigURL), the machine-wide WinHTTP proxy, and the process proxy environment
    variables, and flags inconsistent combinations.

    WinHTTP: the setting is read from the binary registry value
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections\WinHttpSettings
    (the value 'netsh winhttp set proxy' writes). Microsoft does not document the layout;
    the de-facto layout used here matches Wine's WinHttpGetDefaultProxyConfiguration and
    Microsoft's published "direct access" sample (1800000000000000010000000000000000000000):

        offset 0   DWORD  header (0x18)
        offset 4   DWORD  change counter (any value)
        offset 8   DWORD  flags (1 = direct, 2 = named proxy)
        offset 12  DWORD  proxy-server length N, then N single-byte characters
        then       DWORD  bypass-list length M, then M single-byte characters

    Every length is bounds-checked; a value that does not fit is reported as
    undecodable. Only when the value is missing or undecodable does the scanner fall back
    to 'netsh winhttp show proxy', parsed structurally ("label : value" lines, first =
    proxy server, second = bypass list) so it does not depend on the display language.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Proxy Configuration'; Id='network.proxy-configuration'; Group='network'; NetworkAccess='None'; Category='Network'; Description='WinINET, WinHTTP, PAC, and process proxy configuration.'; RequiresAdmin=$false; Order=460; Enabled=$true }
}

function Test-OmniProxyWindowsHost {
    <# .SYNOPSIS Internal: true on Windows (where the WinINET / WinHTTP stores exist). #>
    [OutputType([bool])]
    param()
    try { if ($IsWindows -eq $false) { return $false } } catch { Write-Verbose 'IsWindows not defined (Windows PowerShell).' }
    return $true
}

function Get-OmniWinHttpSettingsValue {
    <#
    .SYNOPSIS
        Internal: returns the raw WinHttpSettings registry value (byte[]), or $null when
        the value does not exist.
    #>
    [OutputType([byte[]])]
    param()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
    try {
        $item = Get-ItemProperty -LiteralPath $key -Name 'WinHttpSettings' -ErrorAction Stop
        $value = $item.WinHttpSettings
        if ($value -is [byte[]]) { return , $value }
    } catch { Write-Verbose "WinHttpSettings not readable: $($_.Exception.Message)" }
    return $null
}

function ConvertFrom-OmniWinHttpBlob {
    <#
    .SYNOPSIS
        Internal: decodes the binary WinHttpSettings registry value.

    .DESCRIPTION
        Returns Valid, Version (header DWORD), Flags, AccessType (Direct | NamedProxy),
        ProxyServer, and BypassList. Valid is $false when the value is too short or a
        length field points past its end. Strings are single-byte; each byte is widened to
        a character, as WinHTTP does.

    .PARAMETER Bytes
        The registry value.

    .EXAMPLE
        ConvertFrom-OmniWinHttpBlob -Bytes ([byte[]](0x18,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0))
    #>
    [OutputType([pscustomobject])]
    param([AllowNull()] [byte[]] $Bytes)

    $invalid = [pscustomobject]@{ Valid = $false; Version = $null; Flags = $null; AccessType = ''; ProxyServer = ''; BypassList = '' }
    if ($null -eq $Bytes -or $Bytes.Length -lt 20) { return $invalid }

    $version = [System.BitConverter]::ToUInt32($Bytes, 0)
    $flags = [System.BitConverter]::ToUInt32($Bytes, 8)
    $offset = 12
    $strings = @()
    foreach ($field in 1..2) {
        if ($offset + 4 -gt $Bytes.Length) { return $invalid }
        $len = [long][System.BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        if ($offset + $len -gt $Bytes.Length) { return $invalid }
        $text = ''
        if ($len -gt 0) { $text = (-join [char[]]$Bytes[$offset..($offset + $len - 1)]).TrimEnd([char]0) }
        $strings += $text
        $offset += [int]$len
    }
    $proxy = $strings[0].Trim()
    $access = if (($flags -band 2) -and $proxy) { 'NamedProxy' } else { 'Direct' }
    return [pscustomobject]@{
        Valid       = $true
        Version     = $version
        Flags       = $flags
        AccessType  = $access
        ProxyServer = $(if ($access -eq 'NamedProxy') { $proxy } else { '' })
        BypassList  = $(if ($access -eq 'NamedProxy') { $strings[1].Trim() } else { '' })
    }
}

function Invoke-OmniNetshWinHttp {
    <# .SYNOPSIS Internal: returns the text of 'netsh winhttp show proxy', or '' when netsh is unavailable. #>
    [OutputType([string])]
    param()
    if (-not (Get-Command -Name 'netsh.exe' -ErrorAction SilentlyContinue)) { return '' }
    return ((@(& netsh.exe winhttp show proxy 2>&1) | ForEach-Object { [string]$_ }) -join "`n")
}

function ConvertFrom-OmniNetshWinHttpText {
    <#
    .SYNOPSIS
        Internal: parses 'netsh winhttp show proxy' output without relying on its labels.

    .DESCRIPTION
        The labels are translated on localized Windows, so only the structure is used:
        lines of the form "<label> : <value>". The first such line is the proxy server and
        the second the bypass list; a value wrapped in parentheses (e.g. "(none)") counts
        as empty. With no such line the setting is direct access. Valid is $false for
        empty text.

    .PARAMETER Text
        The command output.
    #>
    [OutputType([pscustomobject])]
    param([AllowNull()] [AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Valid = $false; AccessType = ''; ProxyServer = ''; BypassList = '' }
    }
    $values = @(foreach ($line in ($Text -split "`r?`n")) {
            $m = [regex]::Match($line, '^\s*[^:]+?\s*:\s+(\S.*?)\s*$')
            if ($m.Success) {
                $v = $m.Groups[1].Value
                if ($v -match '^\(.*\)\.?$') { $v = '' }
                $v
            }
        })
    $proxy = if ($values.Count -ge 1) { [string]$values[0] } else { '' }
    $bypass = if ($values.Count -ge 2) { [string]$values[1] } else { '' }
    return [pscustomobject]@{
        Valid       = $true
        AccessType  = $(if ($proxy) { 'NamedProxy' } else { 'Direct' })
        ProxyServer = $proxy
        BypassList  = $(if ($proxy) { $bypass } else { '' })
    }
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the proxy configuration check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, ...).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Proxy Configuration' -Category 'Network' -HadAdmin $Context.IsAdmin

    $environmentProxy = (@($env:HTTP_PROXY, $env:HTTPS_PROXY, $env:ALL_PROXY) | Where-Object { $_ }) -join '; '
    Set-OmniResultMetric -Result $result -Name 'EnvironmentProxy' -Value $environmentProxy
    if (-not (Test-OmniProxyWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows proxy stores are unavailable' -Severity Information -Component 'Network/Proxy' -Detail "Process proxy variables: $environmentProxy")
        return (Complete-OmniResult -Result $result)
    }

    $proxyEnabled = $false; $proxyServer = ''; $pacUrl = ''
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($settings.PSObject.Properties['ProxyEnable']) { $proxyEnabled = ([int]$settings.ProxyEnable -eq 1) }
        if ($settings.PSObject.Properties['ProxyServer']) { $proxyServer = [string]$settings.ProxyServer }
        if ($settings.PSObject.Properties['AutoConfigURL']) { $pacUrl = [string]$settings.AutoConfigURL }
    } catch { $Context.Logger.Debug("WinINET proxy query failed: $($_.Exception.Message)", 'Proxy Configuration') }
    Set-OmniResultMetric -Result $result -Name 'UserProxyEnabled' -Value $proxyEnabled
    Set-OmniResultMetric -Result $result -Name 'UserProxyServer' -Value $proxyServer
    Set-OmniResultMetric -Result $result -Name 'PacUrl' -Value $pacUrl

    # --- WinHTTP: registry value first, netsh only as a fallback ---------------
    $winHttp = $null; $source = 'Unavailable'; $undecodable = $false
    try {
        $raw = Get-OmniWinHttpSettingsValue
        if ($null -ne $raw) {
            $decoded = ConvertFrom-OmniWinHttpBlob -Bytes ([byte[]]@($raw))
            if ($decoded.Valid) { $winHttp = $decoded; $source = 'Registry' } else { $undecodable = $true }
        }
    } catch { $Context.Logger.Debug("WinHttpSettings decode failed: $($_.Exception.Message)", 'Proxy Configuration'); $undecodable = $true }
    if ($null -eq $winHttp) {
        try {
            $parsed = ConvertFrom-OmniNetshWinHttpText -Text (Invoke-OmniNetshWinHttp)
            if ($parsed.Valid) { $winHttp = $parsed; $source = 'netsh' }
        } catch { $Context.Logger.Debug("WinHTTP proxy query failed: $($_.Exception.Message)", 'Proxy Configuration') }
    }
    Set-OmniResultMetric -Result $result -Name 'WinHttpSource' -Value $source
    $summary = ''
    if ($winHttp) {
        Set-OmniResultMetric -Result $result -Name 'WinHttpAccessType' -Value $winHttp.AccessType
        Set-OmniResultMetric -Result $result -Name 'WinHttpProxyServer' -Value $winHttp.ProxyServer
        Set-OmniResultMetric -Result $result -Name 'WinHttpBypassList' -Value $winHttp.BypassList
        $summary = if ($winHttp.AccessType -eq 'NamedProxy') { "Proxy: $($winHttp.ProxyServer); bypass: $($winHttp.BypassList)" } else { 'Direct access (no proxy server)' }
    }
    Set-OmniResultMetric -Result $result -Name 'WinHttpSummary' -Value $summary

    if ($undecodable) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-proxy-winhttp-undecodable' -Title 'WinHTTP proxy setting could not be decoded' -Severity Information -Component 'Network/Proxy' -Detail ("The WinHttpSettings registry value has an unexpected layout{0}." -f $(if ($source -eq 'netsh') { ", so the WinHTTP proxy was read from 'netsh winhttp show proxy' instead" } else { ' and no other source was available' })) -Recommendation "Run 'netsh winhttp show proxy' to review the machine-wide proxy.")
    }
    if ($winHttp -and $winHttp.AccessType -eq 'NamedProxy') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-proxy-winhttp-named-proxy' -Title 'Machine-wide WinHTTP proxy is configured' -Severity Information -Component 'Network/Proxy' -Detail ("WinHTTP (used by Windows services such as Windows Update and by many agents) sends traffic through '{0}'; bypass list: '{1}'." -f $winHttp.ProxyServer, $winHttp.BypassList) -Recommendation 'Confirm the proxy matches the organization standard; a stale WinHTTP proxy breaks service traffic while browsers keep working.')
    }

    if ($proxyEnabled -and [string]::IsNullOrWhiteSpace($proxyServer)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'User proxy is enabled without a proxy server' -Severity Warning -Component 'Network/Proxy' -Detail 'ProxyEnable is set but ProxyServer is empty.' -LikelyCause 'A partially applied user or management policy left inconsistent proxy settings.' -Confidence 90 -Recommendation 'Review the effective proxy policy and correct or disable the incomplete WinINET proxy configuration.')
    }
    if ($proxyEnabled -and $environmentProxy -and $proxyServer -and $environmentProxy -notmatch [regex]::Escape($proxyServer)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Multiple proxy sources may disagree' -Severity Warning -Component 'Network/Proxy' -Detail 'WinINET and process environment proxy settings are both present and differ.' -LikelyCause 'Applications may use different proxy stacks and reach different destinations.' -Confidence 70 -Recommendation 'Compare WinINET, WinHTTP, application, and environment proxy policy with the organization standard.')
    }
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Proxy configuration collected' -Severity Pass -Component 'Network/Proxy' -Detail 'No internally inconsistent local proxy setting was detected.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
