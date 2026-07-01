<#
.SYNOPSIS
    OmniDiag diagnostic module: IP Configuration.

.DESCRIPTION
    Reports per-adapter IP configuration: IPv4/IPv6 addresses, subnet prefix,
    default gateway, and DHCP state. Flags APIPA (169.254.x.x) addresses that
    indicate a DHCP failure.

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
        Name          = 'IP Configuration'
        Category      = 'Network'
        Description   = 'Per-adapter IP addresses, gateway, and DHCP state.'
        RequiresAdmin = $false
        Order         = 410
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

    $result = New-OmniResult -ModuleName 'IP Configuration' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $configs = @()
    try {
        if (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue) {
            $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
                Where-Object { $_.NetAdapter -and "$($_.NetAdapter.Status)" -eq 'Up' })
        }
    } catch {
        $log.Warn("Get-NetIPConfiguration failed: $($_.Exception.Message)", 'IP Configuration')
        $configs = @()
    }

    Set-OmniResultMetric -Result $result -Name 'ActiveInterfaceCount' -Value (@($configs).Count)

    try {
        foreach ($c in $configs) {
            $name = "$($c.InterfaceAlias)"

            $ipv4 = @()
            $ipv6 = @()
            $prefix = ''
            try {
                if ($c.IPv4Address) {
                    $ipv4 = @($c.IPv4Address | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
                    $prefix = @($c.IPv4Address | ForEach-Object { $_.PrefixLength }) | Select-Object -First 1
                }
                if ($c.IPv6Address) {
                    $ipv6 = @($c.IPv6Address | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
                }
            } catch { }

            $gw = ''
            try {
                if ($c.IPv4DefaultGateway) {
                    $gw = @($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop } | Where-Object { $_ }) | Select-Object -First 1
                }
            } catch { }

            # DHCP state.
            $dhcp = 'Unknown'
            try {
                if (Get-Command -Name 'Get-NetIPInterface' -ErrorAction SilentlyContinue) {
                    $iface = Get-NetIPInterface -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($iface) { $dhcp = "$($iface.Dhcp)" }
                }
            } catch { }

            Set-OmniResultMetric -Result $result -Name "Iface.$name.IPv4"        -Value ($ipv4 -join ', ')
            Set-OmniResultMetric -Result $result -Name "Iface.$name.IPv6"        -Value ($ipv6 -join ', ')
            Set-OmniResultMetric -Result $result -Name "Iface.$name.PrefixLength" -Value ("$prefix")
            Set-OmniResultMetric -Result $result -Name "Iface.$name.Gateway"     -Value ("$gw")
            Set-OmniResultMetric -Result $result -Name "Iface.$name.Dhcp"        -Value $dhcp

            # APIPA detection.
            $apipa = @($ipv4 | Where-Object { $_ -like '169.254.*' })
            if ($apipa.Count -gt 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title "APIPA address on $name (DHCP failure)" -Severity 'Warning' `
                    -Component 'Network/IP' `
                    -Detail "Interface '$name' has an automatic private IP address ($($apipa -join ', '))." `
                    -LikelyCause 'The adapter could not obtain an address from a DHCP server.' `
                    -Confidence 80 `
                    -Recommendation 'Check the DHCP server/router, renew the lease (ipconfig /renew), and verify cabling.')
            }
        }
    } catch {
        $log.Warn("IP configuration enumeration failed: $($_.Exception.Message)", 'IP Configuration')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'IP configuration valid' -Severity 'Pass' -Component 'Network/IP' `
            -Detail 'Active interfaces have valid (non-APIPA) IP configuration.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
