<#
.SYNOPSIS
    OmniDiag diagnostic module: DNS Resolver.

.DESCRIPTION
    Reports configured DNS servers per active adapter and performs a live
    resolution test. Warns when an active adapter has no DNS servers configured or
    when name resolution fails.

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
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'DNS Resolver'
        Category      = 'Network'
        Description   = 'Configured DNS servers per adapter and resolution test.'
        RequiresAdmin = $false
        Order         = 420
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'DNS Resolver' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Active adapter aliases --------------------------------------------
    $activeAliases = @()
    try {
        if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
            $activeAliases = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Status)" -eq 'Up' } | ForEach-Object { $_.Name })
        }
    } catch {
        $log.Debug("Adapter list failed: $($_.Exception.Message)", 'DNS Resolver')
    }

    # --- DNS servers per adapter -------------------------------------------
    $allServers = @()
    try {
        if (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue) {
            $entries = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop)
            foreach ($e in $entries) {
                $alias = "$($e.InterfaceAlias)"
                $servers = @($e.ServerAddresses | Where-Object { $_ })
                if ($servers.Count -gt 0) {
                    Set-OmniResultMetric -Result $result -Name "Dns.$alias.Servers" -Value ($servers -join ', ')
                    $allServers += $servers
                }

                # Only warn about missing DNS on active adapters.
                if ($activeAliases -contains $alias -and $servers.Count -eq 0) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title "No DNS servers configured on $alias" -Severity 'Warning' `
                        -Component 'Network/DNS' `
                        -Detail "Active interface '$alias' has no IPv4 DNS servers configured." `
                        -LikelyCause 'DHCP did not supply DNS servers, or static config is incomplete.' `
                        -Confidence 70 `
                        -Recommendation 'Configure valid DNS servers or renew the DHCP lease.')
                }
            }
        }
    } catch {
        $log.Warn("Get-DnsClientServerAddress failed: $($_.Exception.Message)", 'DNS Resolver')
    }

    Set-OmniResultMetric -Result $result -Name 'ConfiguredDnsServers' -Value (($allServers | Select-Object -Unique) -join ', ')

    # --- Resolution test ---------------------------------------------------
    $resolved = $false
    try {
        if (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
            $r = Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop
            $resolved = (@($r | Where-Object { $_.IPAddress }).Count -gt 0)
        } else {
            $entry = [System.Net.Dns]::GetHostEntry('www.microsoft.com')
            $resolved = ($null -ne $entry -and @($entry.AddressList).Count -gt 0)
        }
    } catch {
        # Fall back to .NET resolver before concluding failure.
        try {
            $entry = [System.Net.Dns]::GetHostEntry('www.microsoft.com')
            $resolved = ($null -ne $entry -and @($entry.AddressList).Count -gt 0)
        } catch {
            $resolved = $false
            $log.Debug("DNS resolution failed: $($_.Exception.Message)", 'DNS Resolver')
        }
    }

    Set-OmniResultMetric -Result $result -Name 'DnsResolutionOk' -Value $resolved

    if (-not $resolved) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'DNS resolution failed' -Severity 'Warning' `
            -Component 'Network/DNS' `
            -Detail 'Resolving www.microsoft.com did not return any address.' `
            -LikelyCause 'DNS server unreachable/misconfigured, or no network connectivity.' `
            -Confidence 70 `
            -Recommendation 'Verify DNS server settings and connectivity; try flushing the DNS cache (ipconfig /flushdns).')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'DNS resolver healthy' -Severity 'Pass' -Component 'Network/DNS' `
            -Detail 'DNS servers are configured and name resolution succeeded.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
