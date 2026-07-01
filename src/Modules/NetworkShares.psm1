<#
.SYNOPSIS
    OmniDiag diagnostic module: Network Shares.

.DESCRIPTION
    Enumerates SMB file shares on the local machine, excludes default administrative
    shares from the user-share count, and flags overly permissive shares that grant
    Everyone Full/Change access.

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
        Name          = 'Network Shares'
        Category      = 'Network'
        Description   = 'Enumerates SMB shares and flags overly permissive access.'
        RequiresAdmin = $false
        Order         = 440
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

    $result = New-OmniResult -ModuleName 'Network Shares' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $shares = @()

    # Prefer Get-SmbShare; fall back to Win32_Share.
    try {
        $shares = @(Get-SmbShare -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Path = $_.Path }
        })
    } catch {
        $log.Debug("Get-SmbShare unavailable, falling back to Win32_Share: $($_.Exception.Message)", 'Network Shares')
        try {
            $shares = @(Get-CimInstance -ClassName 'Win32_Share' -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Path = $_.Path }
            })
        } catch {
            $log.Warn("Could not enumerate shares: $($_.Exception.Message)", 'Network Shares')
        }
    }

    # A default admin share name ends in '$' (C$, ADMIN$, IPC$, etc.).
    $userShares = @($shares | Where-Object { $_.Name -and -not $_.Name.EndsWith('$') })

    Set-OmniResultMetric -Result $result -Name 'TotalShareCount' -Value (@($shares).Count)
    Set-OmniResultMetric -Result $result -Name 'UserShareCount' -Value (@($userShares).Count)

    try {
        if (@($userShares).Count -gt 0) {
            Set-OmniResultMetric -Result $result -Name 'UserShares' `
                -Value (@($userShares | ForEach-Object { "{0} -> {1}" -f $_.Name, $_.Path }))

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("{0} user share(s) present" -f $userShares.Count) `
                -Severity 'Information' -Component 'Network/Shares' `
                -Detail ('Shares: ' + ((@($userShares | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Path }) -join '; '))) `
                -Data $userShares)
        }
    } catch {
        $log.Warn("Failed summarizing user shares: $($_.Exception.Message)", 'Network Shares')
    }

    # Best-effort: flag shares granting Everyone Full/Change.
    foreach ($s in $userShares) {
        try {
            $access = Get-SmbShareAccess -Name $s.Name -ErrorAction Stop
            $everyoneRw = @($access | Where-Object {
                $_.AccountName -match '(?i)\bEveryone\b' -and
                $_.AccessControlType -eq 'Allow' -and
                ($_.AccessRight -eq 'Full' -or $_.AccessRight -eq 'Change')
            })
            if ($everyoneRw.Count -gt 0) {
                $rights = (@($everyoneRw | ForEach-Object { $_.AccessRight }) -join ', ')
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Share '{0}' grants Everyone {1} access" -f $s.Name, $rights) `
                    -Severity 'Warning' -Component 'Network/Shares' `
                    -Detail ("The share '{0}' ({1}) grants the Everyone group {2} permission." -f $s.Name, $s.Path, $rights) `
                    -LikelyCause 'Share ACL is overly permissive, exposing data to any network user.' `
                    -Confidence 75 `
                    -Recommendation 'Restrict share access to specific users/groups instead of Everyone.' `
                    -Data $s)
            }
        } catch {
            $log.Debug("Get-SmbShareAccess failed for $($s.Name): $($_.Exception.Message)", 'Network Shares')
        }
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No overly permissive shares detected' -Severity 'Pass' -Component 'Network/Shares' `
            -Detail 'Share configuration was reviewed without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
