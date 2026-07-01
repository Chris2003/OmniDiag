<#
.SYNOPSIS
    OmniDiag diagnostic module: Hosts File.

.DESCRIPTION
    Inspects the Windows hosts file for custom (non-comment) entries, flags possible
    hijacks of well-known public domains to non-loopback addresses, and recognizes
    large block-lists (ad-blockers) that map many hosts to loopback/null addresses.

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
        Name          = 'Hosts File'
        Category      = 'Network'
        Description   = 'Inspects the Windows hosts file for custom entries and possible hijacks.'
        RequiresAdmin = $false
        Order         = 430
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

    $result = New-OmniResult -ModuleName 'Hosts File' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = @()

    try {
        $lines = Get-Content -LiteralPath $hostsPath -ErrorAction Stop
        foreach ($line in $lines) {
            $trimmed = ($line -as [string])
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $trimmed = $trimmed.Trim()
            if ($trimmed.StartsWith('#')) { continue }
            # Strip trailing inline comments.
            $noComment = ($trimmed -split '#', 2)[0].Trim()
            if ([string]::IsNullOrWhiteSpace($noComment)) { continue }
            $tokens = $noComment -split '\s+'
            if ($tokens.Count -lt 2) { continue }
            $ip = $tokens[0]
            foreach ($h in $tokens[1..($tokens.Count - 1)]) {
                if ([string]::IsNullOrWhiteSpace($h)) { continue }
                $entries += [pscustomobject]@{ IP = $ip; Host = $h }
            }
        }
    } catch {
        $log.Warn("Could not read hosts file: $($_.Exception.Message)", 'Hosts File')
    }

    Set-OmniResultMetric -Result $result -Name 'HostsEntryCount' -Value (@($entries).Count)

    $loopbacks = @('127.0.0.1', '::1', '0.0.0.0')

    try {
        if (@($entries).Count -gt 0) {
            Set-OmniResultMetric -Result $result -Name 'CustomEntries' `
                -Value (@($entries | ForEach-Object { "{0} {1}" -f $_.IP, $_.Host }))

            $blockEntries = @($entries | Where-Object { $loopbacks -contains $_.IP })
            $realEntries  = @($entries | Where-Object { $loopbacks -notcontains $_.IP })
            Set-OmniResultMetric -Result $result -Name 'BlockEntryCount' -Value ($blockEntries.Count)
            Set-OmniResultMetric -Result $result -Name 'RedirectEntryCount' -Value ($realEntries.Count)

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Hosts file has {0} custom entr{1}" -f $entries.Count, $(if ($entries.Count -eq 1) { 'y' } else { 'ies' })) `
                -Severity 'Information' -Component 'Network/Hosts' `
                -Detail ('Custom mappings: ' + ((@($entries | Select-Object -First 25 | ForEach-Object { "{0} -> {1}" -f $_.IP, $_.Host }) -join '; '))) `
                -Data $entries)
        }
    } catch {
        $log.Warn("Failed summarizing hosts entries: $($_.Exception.Message)", 'Hosts File')
    }

    # Large block list -> likely ad-blocker (Information).
    try {
        $blockCount = @($entries | Where-Object { $loopbacks -contains $_.IP }).Count
        if ($blockCount -ge 50) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Large block list detected ({0} entries)" -f $blockCount) `
                -Severity 'Information' -Component 'Network/Hosts' `
                -Detail "The hosts file maps $blockCount hostnames to loopback/null addresses." `
                -LikelyCause 'A hosts-based ad/tracker block list is installed.' `
                -Confidence 70 `
                -Recommendation 'This is usually intentional. Confirm the block list is the expected source.')
        }
    } catch {
        $log.Debug("Block-list check failed: $($_.Exception.Message)", 'Hosts File')
    }

    # Possible hijack: well-known public domain mapped to a non-loopback address.
    try {
        $wellKnown = @(
            'google.com', 'www.google.com', 'microsoft.com', 'www.microsoft.com',
            'windowsupdate.com', 'update.microsoft.com', 'login.microsoftonline.com',
            'office.com', 'www.office.com', 'apple.com', 'amazon.com', 'facebook.com',
            'bank', 'paypal.com', 'live.com', 'outlook.com', 'github.com'
        )
        foreach ($e in $entries) {
            if ($loopbacks -contains $e.IP) { continue }
            $hostLower = $e.Host.ToLowerInvariant()
            foreach ($wk in $wellKnown) {
                if ($hostLower -eq $wk -or $hostLower.EndsWith('.' + $wk) -or $hostLower.Contains($wk)) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title ("Possible hosts hijack: {0}" -f $e.Host) `
                        -Severity 'Warning' -Component 'Network/Hosts' `
                        -Detail ("The well-known domain '{0}' is mapped to '{1}' in the hosts file." -f $e.Host, $e.IP) `
                        -LikelyCause 'A hosts entry redirects a public domain to a custom IP; may indicate malware or misconfiguration.' `
                        -Confidence 60 `
                        -Recommendation 'Verify this mapping is intentional; remove it if unexpected.' `
                        -Data $e)
                    break
                }
            }
        }
    } catch {
        $log.Debug("Hijack check failed: $($_.Exception.Message)", 'Hosts File')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Hosts file is clean' -Severity 'Pass' -Component 'Network/Hosts' `
            -Detail 'No suspicious or hijacking hosts entries were detected.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
