<#
.SYNOPSIS
    OmniDiag diagnostic module: Local Admins.

.DESCRIPTION
    Lists the members of the built-in Administrators group, found by its well-known SID
    S-1-5-32-544 so the check works whatever the display language (the group is called
    "Administratoren", "Administrateurs", ... on localized Windows). Uses
    Get-LocalGroupMember -SID, and Win32_Group / Win32_GroupUser when that cmdlet fails
    (it can throw on groups that hold an orphaned or unresolvable SID). Reports whether
    the built-in Administrator account (RID 500, found by SID with Get-LocalUser) is
    enabled, which other local accounts are administrators, and members whose SID no
    longer resolves.

    Network: both enumeration paths translate each member SID to a name through the
    Local Security Authority. For a domain or Microsoft Entra ID member that is not in
    the local lookup cache, that lookup can query a domain controller (or Entra ID). So
    on a domain- or Entra-joined device the membership is enumerated only when
    $Context.NetworkProbes is set; otherwise the built-in Administrator check still runs
    (local SAM only) and an Information finding says what was skipped. On a device that
    is not joined, every member resolves locally and the full check always runs.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

$script:OmniAdministratorsSid = 'S-1-5-32-544'

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Local Admins'
        Id            = 'security.local-admins'
        Group         = 'security'
        NetworkAccess = 'LocalNetwork'
        Category      = 'Security'
        Description   = 'Members of the built-in Administrators group (by SID) and the built-in Administrator account state.'
        RequiresAdmin = $false
        Order         = 505
        Enabled       = $true
    }
}

function Get-OmniDeviceJoinState {
    <#
    .SYNOPSIS
        Internal: reports whether the device is joined to an AD domain or Microsoft Entra ID.

    .DESCRIPTION
        Local reads only: Win32_ComputerSystem.PartOfDomain, and the presence of a join
        entry under HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $domain = $false; $entra = $false
    if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
        try { $domain = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -Property PartOfDomain -ErrorAction Stop).PartOfDomain } catch { $domain = $false }
    }
    try {
        $joinInfo = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
        if (Test-Path -LiteralPath $joinInfo) { $entra = @(Get-ChildItem -LiteralPath $joinInfo -ErrorAction Stop).Count -gt 0 }
    } catch { $entra = $false }
    return [pscustomobject]@{ DomainJoined = $domain; EntraJoined = $entra }
}

function Get-OmniLocalUserAccount {
    <#
    .SYNOPSIS
        Internal: lists local user accounts (local SAM only) with Get-LocalUser.

    .DESCRIPTION
        Returns Available (false when Get-LocalUser is missing, e.g. off Windows or in
        32-bit PowerShell on 64-bit Windows) and Users (Name, Sid, Enabled).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    if (-not (Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Users = @() }
    }
    $users = @(Get-LocalUser -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Sid = [string]$_.SID; Enabled = [bool]$_.Enabled }
        })
    return [pscustomobject]@{ Available = $true; Users = $users }
}

function Get-OmniAdministratorsMember {
    <#
    .SYNOPSIS
        Internal: lists the members of the built-in Administrators group (S-1-5-32-544).

    .DESCRIPTION
        Tries Get-LocalGroupMember -SID first, then Win32_Group + Win32_GroupUser. Both
        resolve member SIDs to names through the LSA, which can query a domain
        controller for domain members; the caller decides whether that is allowed.
        Returns Available, Source, Error (the first failure, if any), and Members
        (Name, Sid, Source = Local | ActiveDirectory | AzureAD | MicrosoftAccount | Unknown).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $firstError = ''
    if (Get-Command -Name 'Get-LocalGroupMember' -ErrorAction SilentlyContinue) {
        try {
            $members = @(Get-LocalGroupMember -SID $script:OmniAdministratorsSid -ErrorAction Stop | ForEach-Object {
                    $src = ''
                    if ($_.PSObject.Properties['PrincipalSource'] -and $null -ne $_.PrincipalSource) { $src = [string]$_.PrincipalSource }
                    [pscustomobject]@{ Name = [string]$_.Name; Sid = [string]$_.SID; Source = $(if ($src) { $src } else { 'Unknown' }) }
                })
            return [pscustomobject]@{ Available = $true; Source = 'Get-LocalGroupMember'; Error = ''; Members = $members }
        } catch { $firstError = $_.Exception.Message }
    }
    if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
        try {
            $group = Get-CimInstance -ClassName Win32_Group -Filter "LocalAccount = TRUE AND SID = '$($script:OmniAdministratorsSid)'" -ErrorAction Stop
            if ($group) {
                $members = @(Get-CimAssociatedInstance -InputObject $group -Association Win32_GroupUser -ErrorAction Stop | ForEach-Object {
                        $local = $_.PSObject.Properties['LocalAccount'] -and [bool]$_.LocalAccount
                        $name = if ($_.PSObject.Properties['Domain'] -and $_.Domain) { '{0}\{1}' -f $_.Domain, $_.Name } else { [string]$_.Name }
                        [pscustomobject]@{ Name = $name; Sid = [string]$_.SID; Source = $(if ($local) { 'Local' } else { 'Unknown' }) }
                    })
                return [pscustomobject]@{ Available = $true; Source = 'Win32_GroupUser'; Error = $firstError; Members = $members }
            }
        } catch { if (-not $firstError) { $firstError = $_.Exception.Message } }
    }
    return [pscustomobject]@{ Available = $false; Source = ''; Error = $firstError; Members = @() }
}

function Get-OmniSidRid {
    <# .SYNOPSIS Internal: the last sub-authority (RID) of a SID string, or -1. #>
    [OutputType([long])]
    param([string] $Sid)
    if ($Sid -match '^S-1-5-21-\d+-\d+-\d+-(\d+)$') { return [long]$Matches[1] }
    return [long]-1
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the local-administrators check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, NetworkProbes, CancellationToken, ...).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Local Admins' -Category 'Security' -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $component = 'Security/LocalAdmins'

    # --- Built-in Administrator account (local SAM, never leaves the machine) ---
    $users = $null
    try { $users = Get-OmniLocalUserAccount } catch { $log.Debug("Get-LocalUser failed: $($_.Exception.Message)", 'Local Admins') }
    $builtin = $null
    if ($users -and $users.Available) {
        $builtin = @($users.Users | Where-Object { (Get-OmniSidRid $_.Sid) -eq 500 } | Select-Object -First 1)
        $builtin = if ($builtin.Count -gt 0) { $builtin[0] } else { $null }
    }
    Set-OmniResultMetric -Result $result -Name 'BuiltinAdministratorEnabled' -Value $(if ($builtin) { $builtin.Enabled } else { $null })
    if ($builtin -and $builtin.Enabled) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-builtin-administrator-enabled' `
            -Title 'Built-in Administrator account is enabled' -Severity 'Warning' -Component $component `
            -Detail ("The built-in Administrator account (RID 500, currently named '{0}') is enabled. It cannot be locked out and is a common password-guessing target." -f $builtin.Name) `
            -LikelyCause 'The account was enabled during setup or troubleshooting and left on, or an image enables it.' `
            -Confidence 85 `
            -Recommendation 'Disable the built-in Administrator account and use named administrator accounts (with Windows LAPS if a local admin is needed).')
    }

    $cancel = $Context.PSObject.Properties['CancellationToken']
    if ($cancel -and $null -ne $cancel.Value -and $cancel.Value.IsCancellationRequested) { return (Complete-OmniResult -Result $result) }

    # --- Group membership (name resolution may contact a DC on joined devices) ---
    $join = $null
    try { $join = Get-OmniDeviceJoinState } catch { $log.Debug("Join state query failed: $($_.Exception.Message)", 'Local Admins') }
    $joined = [bool]($join -and ($join.DomainJoined -or $join.EntraJoined))
    Set-OmniResultMetric -Result $result -Name 'DeviceJoined' -Value $joined

    if ($joined -and -not (Test-OmniNetworkProbeEnabled -Context $Context)) {
        Set-OmniResultMetric -Result $result -Name 'MembershipEnumerated' -Value $false
        Add-OmniFinding -Result $result -Finding (New-OmniProbeSkippedFinding -Component $component `
            -Probe 'list the members of the local Administrators group: on this domain- or Entra-joined device, resolving member names can query a domain controller or Microsoft Entra ID')
        return (Complete-OmniResult -Result $result)
    }

    $group = $null
    try { $group = Get-OmniAdministratorsMember } catch { $log.Debug("Administrators group query failed: $($_.Exception.Message)", 'Local Admins') }
    if ($null -eq $group -or -not $group.Available) {
        Set-OmniResultMetric -Result $result -Name 'MembershipEnumerated' -Value $false
        $why = if ($group -and $group.Error) { " ($($group.Error))" } else { '' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-unavailable' `
            -Title 'Administrators group membership not available' -Severity 'Information' -Component $component `
            -Detail ("Neither Get-LocalGroupMember nor Win32_GroupUser could list the members of the Administrators group (S-1-5-32-544){0}." -f $why) `
            -Recommendation 'Run Get-LocalGroupMember -SID S-1-5-32-544 in 64-bit PowerShell to review the members manually.')
        return (Complete-OmniResult -Result $result)
    }

    $members = @($group.Members | Where-Object { $null -ne $_ })
    Set-OmniResultMetric -Result $result -Name 'MembershipEnumerated' -Value $true
    Set-OmniResultMetric -Result $result -Name 'MembershipSource' -Value $group.Source
    Set-OmniResultMetric -Result $result -Name 'AdministratorsMemberCount' -Value $members.Count
    Set-OmniResultMetric -Result $result -Name 'AdministratorsMembers' -Value $members

    $listText = ($members | ForEach-Object { '{0} ({1})' -f $(if ($_.Name) { $_.Name } else { $_.Sid }), $_.Source }) -join '; '
    $sourceNote = if ($group.Source -eq 'Win32_GroupUser') { ' Get-LocalGroupMember failed, so the list comes from Win32_GroupUser.' } else { '' }
    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-members' `
        -Title ("{0} member(s) in the local Administrators group" -f $members.Count) -Severity 'Information' -Component $component `
        -Detail ("Members of the built-in Administrators group (S-1-5-32-544): {0}.{1}" -f $(if ($listText) { $listText } else { 'none' }), $sourceNote) `
        -Data $members)

    # Local accounts other than the built-in Administrator.
    $extraLocal = @($members | Where-Object { $_.Source -eq 'Local' -and $_.Sid -match '^S-1-5-21-' -and (Get-OmniSidRid $_.Sid) -ne 500 })
    if ($extraLocal.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-extra-local-accounts' `
            -Title ("{0} additional local account(s) with administrator rights" -f $extraLocal.Count) -Severity 'Information' -Component $component `
            -Detail ("Local accounts besides the built-in Administrator are members: {0}." -f (($extraLocal | ForEach-Object { $_.Name }) -join ', ')) `
            -Recommendation 'Confirm each account is expected; daily-use accounts should be standard users, with administrator rights only where needed.' `
            -Data $extraLocal)
    }

    # Orphaned / unresolvable SIDs.
    $unresolved = @($members | Where-Object { -not $_.Name -or $_.Name -eq $_.Sid -or $_.Name -match '^S-1-\d+(-\d+)+$' })
    if ($unresolved.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-unresolved' `
            -Title ("{0} Administrators member(s) could not be resolved to a name" -f $unresolved.Count) -Severity 'Information' -Component $component `
            -Detail ("These member SIDs did not resolve: {0}. They usually belong to deleted accounts, or to a domain or tenant that cannot be reached." -f (($unresolved | ForEach-Object { $_.Sid }) -join ', ')) `
            -Recommendation 'Identify the SIDs and remove orphaned entries through the approved change process.' `
            -Data $unresolved)
    }

    # No administrator besides the built-in account.
    $others = @($members | Where-Object { (Get-OmniSidRid $_.Sid) -ne 500 })
    if ($others.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-only-builtin' `
            -Title 'No administrator besides the built-in account' -Severity 'Information' -Component $component `
            -Detail 'The Administrators group holds no member other than the built-in Administrator account (if any).' `
            -Recommendation 'Make sure an administrator account remains usable for support (for example a LAPS-managed account) before disabling the built-in one.')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-local-admins-reviewed' `
            -Title 'Local administrator posture reviewed' -Severity 'Pass' -Component $component `
            -Detail 'The Administrators group membership was listed and no weakened local-administrator setting was found.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
