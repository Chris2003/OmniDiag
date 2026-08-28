<#
.SYNOPSIS
    OmniDiag diagnostic module: Microsoft Entra ID join posture.

.DESCRIPTION
    Parses the built-in dsregcmd status locally. It does not authenticate to
    Microsoft Graph, upload data, or change device registration.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Entra ID'; Category='Cloud'; Description='Microsoft Entra join, registration, tenant, and device-auth posture from dsregcmd.'; RequiresAdmin=$false; Order=710; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Entra ID' -Category 'Cloud' -HadAdmin $Context.IsAdmin
    $command = Get-Command -Name 'dsregcmd.exe' -ErrorAction SilentlyContinue
    if (-not $command) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Entra join status is unavailable' -Severity Information -Component 'Cloud/EntraID' -Detail 'The built-in dsregcmd utility was not found on this host.' -Recommendation 'Run this workflow on a supported Windows device to inspect its Entra registration.')
        return (Complete-OmniResult -Result $result)
    }

    try { $lines = @(& $command.Source /status 2>&1) } catch {
        $Context.Logger.Warn("dsregcmd failed: $($_.Exception.Message)", 'Entra ID')
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Could not read Entra join status' -Severity Warning -Component 'Cloud/EntraID' -Detail $_.Exception.Message -Recommendation 'Run dsregcmd /status manually and review the Device State and SSO State sections.')
        return (Complete-OmniResult -Result $result)
    }

    $values = @{}
    foreach ($line in $lines) {
        if ([string]$line -match '^\s*(AzureAdJoined|DomainJoined|WorkplaceJoined|DeviceId|TenantId|TenantName|DeviceAuthStatus|AzureAdPrt)\s*:\s*(.*?)\s*$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    foreach ($key in $values.Keys) { Set-OmniResultMetric -Result $result -Name $key -Value $values[$key] }

    $joined = ($values['AzureAdJoined'] -eq 'YES')
    $registered = ($values['WorkplaceJoined'] -eq 'YES')
    $authStatus = [string]$values['DeviceAuthStatus']
    $hasPrt = ($values['AzureAdPrt'] -eq 'YES')

    if (-not $joined -and -not $registered) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Device is not joined or registered with Entra ID' -Severity Information -Component 'Cloud/EntraID' -Detail 'AzureAdJoined and WorkplaceJoined are both NO.' -Recommendation 'No action is needed for intentionally on-premises devices; otherwise confirm the organization join or registration process.')
    }
    if ($authStatus -and $authStatus -ne 'SUCCESS') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Entra device authentication is not healthy' -Severity Warning -Component 'Cloud/EntraID/Authentication' -Detail "dsregcmd reports DeviceAuthStatus '$authStatus'." -LikelyCause 'The Entra device object may be disabled, deleted, or unable to authenticate.' -Confidence 80 -Recommendation 'Check the device object in Entra admin center and review dsregcmd /status diagnostics before re-registering the device.')
    }
    if ($joined -and -not $hasPrt) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No Entra primary refresh token for the current user' -Severity Warning -Component 'Cloud/EntraID/SSO' -Detail 'The device is Entra joined but AzureAdPrt is not YES.' -LikelyCause 'The current sign-in session did not obtain an Entra PRT, affecting seamless Microsoft 365 SSO.' -Confidence 75 -Recommendation 'Verify time, network/proxy access, user credentials, and Conditional Access; review the SSO State in dsregcmd /status.')
    }
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0 -and ($joined -or $registered)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Entra registration posture healthy' -Severity Pass -Component 'Cloud/EntraID' -Detail "Join or registration is present for tenant '$($values['TenantName'])'.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
