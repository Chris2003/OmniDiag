<#
.SYNOPSIS
    OmniDiag diagnostic module: Routes.

.DESCRIPTION
    Reads the IPv4 and IPv6 routing table with Get-NetRoute (NetTCPIP, local CIM):
    the default routes per interface, whether more than one default route shares the
    lowest effective metric (ambiguous egress, common with VPN split tunnelling), the
    route count, and the persistent (static) routes stored in the PersistentStore.
    Read-only and local: nothing is sent on the network.

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
        Name          = 'Routes'
        Id            = 'network.routes'
        Group         = 'network'
        NetworkAccess = 'None'
        Category      = 'Network'
        Description   = 'IPv4 and IPv6 routing table: default routes per interface, ambiguous default routes, and persistent routes.'
        RequiresAdmin = $false
        Order         = 405
        Enabled       = $true
    }
}

function Get-OmniRouteTable {
    <#
    .SYNOPSIS
        Internal: reads the routes of one policy store with Get-NetRoute.

    .DESCRIPTION
        Returns an object with Available (false when Get-NetRoute does not exist, e.g.
        off Windows) and Routes (the MSFT_NetRoute instances of both address families).
        Errors propagate to the caller.

    .PARAMETER PolicyStore
        ActiveStore (the routes in use) or PersistentStore (routes saved across restarts).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [ValidateSet('ActiveStore', 'PersistentStore')] [string] $PolicyStore)
    if (-not (Get-Command -Name 'Get-NetRoute' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Routes = @() }
    }
    $routes = @(Get-NetRoute -AddressFamily IPv4, IPv6 -PolicyStore $PolicyStore -ErrorAction Stop)
    return [pscustomobject]@{ Available = $true; Routes = $routes }
}

function Get-OmniRouteProperty {
    <# .SYNOPSIS Internal: reads a property that may be missing (StrictMode-safe). #>
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-OmniRouteRecord {
    <#
    .SYNOPSIS
        Internal: flattens a route into a plain, serializable record.

    .DESCRIPTION
        The address family is derived from the destination prefix (a ':' means IPv6), so
        the record does not depend on how the CIM enum is rendered. EffectiveMetric is
        RouteMetric + InterfaceMetric, the value Windows uses to choose between routes.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [object] $Route, [string] $Store = 'ActiveStore')
    $prefix = [string](Get-OmniRouteProperty $Route 'DestinationPrefix')
    $routeMetric = Get-OmniRouteProperty $Route 'RouteMetric'
    $ifMetric = Get-OmniRouteProperty $Route 'InterfaceMetric'
    $effective = $null
    if ($null -ne $routeMetric) {
        $effective = [long]$routeMetric
        if ($null -ne $ifMetric) { $effective += [long]$ifMetric }
    }
    $index = Get-OmniRouteProperty $Route 'InterfaceIndex'
    if ($null -eq $index) { $index = Get-OmniRouteProperty $Route 'ifIndex' }
    return [pscustomobject][ordered]@{
        AddressFamily     = $(if ($prefix -match ':') { 'IPv6' } else { 'IPv4' })
        DestinationPrefix = $prefix
        NextHop           = [string](Get-OmniRouteProperty $Route 'NextHop')
        InterfaceIndex    = $index
        InterfaceAlias    = [string](Get-OmniRouteProperty $Route 'InterfaceAlias')
        RouteMetric       = $routeMetric
        InterfaceMetric   = $ifMetric
        EffectiveMetric   = $effective
        Store             = $Store
    }
}

function Test-OmniRoutesCancelled {
    <# .SYNOPSIS Internal: true when the scan context's cancellation token is signalled. #>
    param([object] $Context)
    $p = $Context.PSObject.Properties['CancellationToken']
    return [bool]($p -and $null -ne $p.Value -and $p.Value.IsCancellationRequested)
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the routing-table check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, CancellationToken, ...).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Routes' -Category 'Network' -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $active = $null
    try {
        $active = Get-OmniRouteTable -PolicyStore ActiveStore
    } catch {
        $log.Debug("Get-NetRoute (ActiveStore) failed: $($_.Exception.Message)", 'Routes')
    }
    if ($null -eq $active -or -not $active.Available) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-routes-unavailable' `
            -Title 'Routing table not available' -Severity 'Information' -Component 'Network/Routes' `
            -Detail 'Get-NetRoute (NetTCPIP module) is not available or could not read the routing table on this system, so routes were not checked.')
        return (Complete-OmniResult -Result $result)
    }
    if (Test-OmniRoutesCancelled $Context) { return (Complete-OmniResult -Result $result) }

    $routes = @($active.Routes | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-OmniRouteRecord -Route $_ -Store 'ActiveStore' })
    $v4 = @($routes | Where-Object AddressFamily -eq 'IPv4')
    $v6 = @($routes | Where-Object AddressFamily -eq 'IPv6')
    $defaults = @($routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') })

    Set-OmniResultMetric -Result $result -Name 'RouteCount' -Value $routes.Count
    Set-OmniResultMetric -Result $result -Name 'IPv4RouteCount' -Value $v4.Count
    Set-OmniResultMetric -Result $result -Name 'IPv6RouteCount' -Value $v6.Count
    Set-OmniResultMetric -Result $result -Name 'DefaultRouteCount' -Value $defaults.Count
    Set-OmniResultMetric -Result $result -Name 'DefaultRoutes' -Value @($defaults | Sort-Object AddressFamily, EffectiveMetric)

    if ($defaults.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-routes-no-default' `
            -Title 'No default route' -Severity 'Warning' -Component 'Network/Routes' `
            -Detail 'The active routing table has no IPv4 (0.0.0.0/0) or IPv6 (::/0) default route, so only directly connected or explicitly routed networks are reachable.' `
            -LikelyCause 'No adapter is connected, DHCP did not supply a gateway, or a static configuration is missing its default gateway.' `
            -Confidence 80 `
            -Recommendation 'Check the adapter connection and its IP configuration (DHCP lease or static default gateway).')
    }

    # Ambiguity: more than one interface shares the lowest effective metric for a family.
    foreach ($family in @('IPv4', 'IPv6')) {
        $famDefaults = @($defaults | Where-Object { $_.AddressFamily -eq $family -and $null -ne $_.EffectiveMetric })
        if ($famDefaults.Count -lt 2) { continue }
        $lowest = ($famDefaults | Measure-Object -Property EffectiveMetric -Minimum).Minimum
        $tied = @($famDefaults | Where-Object { $_.EffectiveMetric -eq $lowest })
        $tiedInterfaces = @($tied | ForEach-Object { $_.InterfaceIndex } | Select-Object -Unique)
        if ($tied.Count -ge 2 -and $tiedInterfaces.Count -ge 2) {
            $list = ($tied | ForEach-Object { '{0} (ifIndex {1}) via {2}' -f $_.InterfaceAlias, $_.InterfaceIndex, $_.NextHop }) -join '; '
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id ('network-routes-ambiguous-default-' + $family.ToLowerInvariant()) `
                -Title ("Multiple {0} default routes with equal metric" -f $family) -Severity 'Information' -Component 'Network/Routes' `
                -Detail ("{0} default routes share the lowest effective metric ({1}): {2}. Windows may spread or switch outbound traffic between them." -f $tied.Count, $lowest, $list) `
                -LikelyCause 'Two active connections (for example Wi-Fi and Ethernet, or a VPN using split tunnelling) both supply a default gateway with the same metric.' `
                -Confidence 60 `
                -Recommendation 'If traffic leaves through the wrong connection, give the preferred interface a lower interface metric (or disconnect the unused one).' `
                -Data $tied)
        }
    }

    if (Test-OmniRoutesCancelled $Context) { return (Complete-OmniResult -Result $result) }

    # Persistent (static) routes, listed for the technician.
    $persistent = @()
    try {
        $store = Get-OmniRouteTable -PolicyStore PersistentStore
        if ($store -and $store.Available) {
            $persistent = @($store.Routes | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-OmniRouteRecord -Route $_ -Store 'PersistentStore' })
        }
    } catch {
        $log.Debug("Get-NetRoute (PersistentStore) failed: $($_.Exception.Message)", 'Routes')
    }
    Set-OmniResultMetric -Result $result -Name 'PersistentRouteCount' -Value $persistent.Count
    Set-OmniResultMetric -Result $result -Name 'PersistentRoutes' -Value $persistent
    if ($persistent.Count -gt 0) {
        $shown = ($persistent | Select-Object -First 20 | ForEach-Object { '{0} via {1} (ifIndex {2})' -f $_.DestinationPrefix, $_.NextHop, $_.InterfaceIndex }) -join '; '
        if ($persistent.Count -gt 20) { $shown += ('; and {0} more' -f ($persistent.Count - 20)) }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-routes-persistent' `
            -Title ("{0} persistent route(s) configured" -f $persistent.Count) -Severity 'Information' -Component 'Network/Routes' `
            -Detail ("Routes saved across restarts (a static default gateway is stored here too): {0}." -f $shown) `
            -Recommendation 'Confirm each persistent route is still wanted; stale static routes can send traffic to networks that no longer exist.' `
            -Data $persistent)
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        $summary = ($defaults | ForEach-Object { '{0} via {1} on {2}' -f $_.AddressFamily, $_.NextHop, $_.InterfaceAlias }) -join '; '
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-routes-healthy' `
            -Title 'Default route present' -Severity 'Pass' -Component 'Network/Routes' `
            -Detail ("{0} route(s) in the active table; default route(s): {1}." -f $routes.Count, $summary))
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
