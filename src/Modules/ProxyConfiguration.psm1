<# .SYNOPSIS OmniDiag diagnostic module: proxy configuration posture. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Proxy Configuration'; Category='Network'; Description='WinINET, WinHTTP, PAC, and process proxy configuration.'; RequiresAdmin=$false; Order=460; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Proxy Configuration' -Category 'Network' -HadAdmin $Context.IsAdmin
    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }

    $environmentProxy = (@($env:HTTP_PROXY, $env:HTTPS_PROXY, $env:ALL_PROXY) | Where-Object { $_ }) -join '; '
    Set-OmniResultMetric -Result $result -Name 'EnvironmentProxy' -Value $environmentProxy
    if (-not $isWindowsHost) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows proxy stores are unavailable' -Severity Information -Component 'Network/Proxy' -Detail "Process proxy variables: $environmentProxy")
        return (Complete-OmniResult -Result $result)
    }

    $proxyEnabled = $false; $proxyServer = ''; $pacUrl = ''
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $proxyEnabled = ([int]$settings.ProxyEnable -eq 1)
        $proxyServer = [string]$settings.ProxyServer
        $pacUrl = [string]$settings.AutoConfigURL
    } catch { $Context.Logger.Debug("WinINET proxy query failed: $($_.Exception.Message)", 'Proxy Configuration') }
    Set-OmniResultMetric -Result $result -Name 'UserProxyEnabled' -Value $proxyEnabled
    Set-OmniResultMetric -Result $result -Name 'UserProxyServer' -Value $proxyServer
    Set-OmniResultMetric -Result $result -Name 'PacUrl' -Value $pacUrl

    $winHttp = ''
    try {
        if (Get-Command netsh.exe -ErrorAction SilentlyContinue) { $winHttp = (@(& netsh.exe winhttp show proxy 2>&1) -join "`n").Trim() }
    } catch { $Context.Logger.Debug("WinHTTP proxy query failed: $($_.Exception.Message)", 'Proxy Configuration') }
    Set-OmniResultMetric -Result $result -Name 'WinHttpSummary' -Value $winHttp

    if ($proxyEnabled -and [string]::IsNullOrWhiteSpace($proxyServer)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'User proxy is enabled without a proxy server' -Severity Warning -Component 'Network/Proxy' -Detail 'ProxyEnable is set but ProxyServer is empty.' -LikelyCause 'A partially applied user or management policy left inconsistent proxy settings.' -Confidence 90 -Recommendation 'Review the effective proxy policy and correct or disable the incomplete WinINET proxy configuration.')
    }
    if ($proxyEnabled -and $environmentProxy -and $environmentProxy -notmatch [regex]::Escape($proxyServer)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Multiple proxy sources may disagree' -Severity Warning -Component 'Network/Proxy' -Detail 'WinINET and process environment proxy settings are both present and differ.' -LikelyCause 'Applications may use different proxy stacks and reach different destinations.' -Confidence 70 -Recommendation 'Compare WinINET, WinHTTP, application, and environment proxy policy with the organization standard.')
    }
    if ($result.Findings.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Proxy configuration collected' -Severity Pass -Component 'Network/Proxy' -Detail 'No internally inconsistent local proxy setting was detected.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
