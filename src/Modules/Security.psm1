<#
.SYNOPSIS
    OmniDiag diagnostic module: Security.

.DESCRIPTION
    Reviews baseline endpoint security posture: Microsoft Defender real-time
    protection and signature freshness, Windows Firewall profile state, and UAC.
    Emits metrics for each and warns on any weakened setting.

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
        Name          = 'Security'
        Category      = 'Security'
        Description   = 'Checks Defender, firewall profiles, and UAC posture.'
        RequiresAdmin = $false
        Order         = 500
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

    $result = New-OmniResult -ModuleName 'Security' -Category 'Security' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Microsoft Defender ----------------------------------------------
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop

        $rtp = [bool]$mp.RealTimeProtectionEnabled
        $amService = [bool]$mp.AMServiceEnabled
        $sigAge = [int]$mp.AntivirusSignatureAge

        Set-OmniResultMetric -Result $result -Name 'RealTimeProtectionEnabled' -Value $rtp
        Set-OmniResultMetric -Result $result -Name 'AMServiceEnabled' -Value $amService
        Set-OmniResultMetric -Result $result -Name 'AntivirusSignatureAgeDays' -Value $sigAge

        if (-not $rtp) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Real-time protection is disabled' -Severity 'Warning' -Component 'Security/Defender' `
                -Detail 'Microsoft Defender real-time protection is turned off.' `
                -LikelyCause 'Disabled by user, policy, or a third-party antivirus taking over.' `
                -Confidence 75 `
                -Recommendation 'Enable real-time protection, or verify a supported third-party AV is active.')
        }

        if (-not $amService) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Antimalware service is not running' -Severity 'Warning' -Component 'Security/Defender' `
                -Detail 'The Microsoft Defender antimalware service is not enabled.' `
                -LikelyCause 'Service disabled or replaced by third-party AV.' `
                -Confidence 65 `
                -Recommendation 'Verify endpoint protection is provided by an active AV solution.')
        }

        if ($sigAge -gt 7) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Antivirus signatures are {0} days old" -f $sigAge) -Severity 'Warning' -Component 'Security/Defender' `
                -Detail "Defender signature definitions have not been updated in $sigAge days." `
                -LikelyCause 'Update failures, no internet connectivity, or a paused update service.' `
                -Confidence 70 `
                -Recommendation 'Run a signature update and confirm the device can reach update servers.')
        }
    } catch {
        $log.Warn("Get-MpComputerStatus unavailable: $($_.Exception.Message)", 'Security')
        Set-OmniResultMetric -Result $result -Name 'DefenderStatus' -Value 'Unknown'
    }

    # --- Windows Firewall profiles ---------------------------------------
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            $enabled = [bool]$p.Enabled
            Set-OmniResultMetric -Result $result -Name ("Firewall{0}Enabled" -f $p.Name) -Value $enabled
            if (-not $enabled) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Firewall disabled for {0} profile" -f $p.Name) -Severity 'Warning' -Component 'Security/Firewall' `
                    -Detail ("The Windows Firewall is turned off for the {0} network profile." -f $p.Name) `
                    -LikelyCause 'Disabled by user, group policy, or a third-party firewall.' `
                    -Confidence 75 `
                    -Recommendation 'Enable the firewall for this profile, or confirm a managed firewall is in place.')
            }
        }
    } catch {
        $log.Warn("Get-NetFirewallProfile unavailable: $($_.Exception.Message)", 'Security')
        Set-OmniResultMetric -Result $result -Name 'FirewallStatus' -Value 'Unknown'
    }

    # --- UAC (EnableLUA) --------------------------------------------------
    try {
        $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $enableLua = (Get-ItemProperty -Path $uacKey -Name 'EnableLUA' -ErrorAction Stop).EnableLUA
        $uacOn = ([int]$enableLua -eq 1)
        Set-OmniResultMetric -Result $result -Name 'UACEnabled' -Value $uacOn
        if (-not $uacOn) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'User Account Control (UAC) is disabled' -Severity 'Warning' -Component 'Security/UAC' `
                -Detail 'EnableLUA is set to 0; UAC elevation prompts are disabled.' `
                -LikelyCause 'UAC turned off manually or by policy.' `
                -Confidence 80 `
                -Recommendation 'Re-enable UAC (EnableLUA = 1) to protect against silent privilege escalation.')
        }
    } catch {
        $log.Debug("UAC registry read failed: $($_.Exception.Message)", 'Security')
        Set-OmniResultMetric -Result $result -Name 'UACEnabled' -Value 'Unknown'
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Baseline security posture is healthy' -Severity 'Pass' -Component 'Security' `
            -Detail 'Defender, firewall, and UAC settings were reviewed without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
