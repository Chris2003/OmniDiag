<#
.SYNOPSIS
    OmniDiag diagnostic module: Firewall Rules.

.DESCRIPTION
    Summarizes enabled Windows Firewall rules by direction and flags the count of
    enabled inbound Allow rules (broad exposure), warning when unusually high.

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
        Name          = 'Firewall Rules'
        Category      = 'Security'
        Description   = 'Summarizes enabled firewall rules and inbound exposure.'
        RequiresAdmin = $false
        Order         = 510
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

    $result = New-OmniResult -ModuleName 'Firewall Rules' -Category 'Security' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $inbound = @()
    $outbound = @()

    # Fetch enabled rules per direction (server-side filtered for speed).
    try {
        $inbound = @(Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction Stop)
    } catch {
        $log.Warn("Failed to enumerate inbound firewall rules: $($_.Exception.Message)", 'Firewall Rules')
    }

    try {
        $outbound = @(Get-NetFirewallRule -Enabled True -Direction Outbound -ErrorAction Stop)
    } catch {
        $log.Warn("Failed to enumerate outbound firewall rules: $($_.Exception.Message)", 'Firewall Rules')
    }

    Set-OmniResultMetric -Result $result -Name 'EnabledInboundCount' -Value (@($inbound).Count)
    Set-OmniResultMetric -Result $result -Name 'EnabledOutboundCount' -Value (@($outbound).Count)

    # Best-effort: enabled inbound Allow rules -> broad exposure.
    try {
        $inboundAllow = @($inbound | Where-Object { "$($_.Action)" -eq 'Allow' })
        $inboundAllowCount = $inboundAllow.Count
        Set-OmniResultMetric -Result $result -Name 'EnabledInboundAllowCount' -Value $inboundAllowCount

        if ($inboundAllowCount -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("{0} enabled inbound allow rule(s)" -f $inboundAllowCount) `
                -Severity 'Information' -Component 'Security/Firewall' `
                -Detail "There are $inboundAllowCount enabled inbound Allow firewall rules permitting incoming connections.")
        }

        if ($inboundAllowCount -gt 150) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Unusually high number of inbound allow rules ({0})" -f $inboundAllowCount) `
                -Severity 'Warning' -Component 'Security/Firewall' `
                -Detail "The system has $inboundAllowCount enabled inbound Allow rules, a large attack surface." `
                -LikelyCause 'Many applications or services have added inbound firewall exceptions over time.' `
                -Confidence 55 `
                -Recommendation 'Review inbound Allow rules and remove exceptions for apps that are no longer needed.')
        }
    } catch {
        $log.Debug("Inbound allow analysis failed: $($_.Exception.Message)", 'Firewall Rules')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Firewall rule set reviewed' -Severity 'Pass' -Component 'Security/Firewall' `
            -Detail 'Enabled firewall rules were summarized without concerns.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
