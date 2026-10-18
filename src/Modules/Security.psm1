<#
.SYNOPSIS
    OmniDiag diagnostic module: Security.

.DESCRIPTION
    Reviews baseline endpoint security posture: Microsoft Defender real-time
    protection and signature freshness, Windows Firewall profile state, and UAC
    (EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop under
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System; registry values,
    so the result does not depend on the display language). Emits metrics for each and
    warns on any weakened setting.

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
        Id            = 'security.security'
        Group         = 'security'
        NetworkAccess = 'None'
        Category      = 'Security'
        Description   = 'Checks Defender, firewall profiles, and UAC posture (EnableLUA, admin prompt behavior, secure desktop).'
        RequiresAdmin = $false
        Order         = 500
        Enabled       = $true
    }
}

function Get-OmniUacPolicy {
    <#
    .SYNOPSIS
        Internal: reads the UAC policy values from the registry.

    .DESCRIPTION
        Returns EnableLUA, ConsentPromptBehaviorAdmin, and PromptOnSecureDesktop from
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System ($null for a
        missing value; Windows then uses the default: 1, 5, 1). Throws when the key
        cannot be read.
    #>
    [OutputType([pscustomobject])]
    param()
    $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
    $read = { param($n) if ($key.PSObject.Properties[$n]) { [int]$key.$n } else { $null } }
    return [pscustomobject]@{
        EnableLUA                  = & $read 'EnableLUA'
        ConsentPromptBehaviorAdmin = & $read 'ConsentPromptBehaviorAdmin'
        PromptOnSecureDesktop      = & $read 'PromptOnSecureDesktop'
    }
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the baseline security check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, ...).
    #>
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
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-defender-signatures-outdated' `
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

    # --- UAC (registry policy values) ------------------------------------
    try {
        $uac = Get-OmniUacPolicy
        # A missing value means the Windows default: EnableLUA 1, ConsentPromptBehaviorAdmin 5, PromptOnSecureDesktop 1.
        $uacOn = ($null -eq $uac.EnableLUA -or [int]$uac.EnableLUA -ne 0)
        $consentAdmin = if ($null -eq $uac.ConsentPromptBehaviorAdmin) { 5 } else { [int]$uac.ConsentPromptBehaviorAdmin }
        $secureDesktop = ($null -eq $uac.PromptOnSecureDesktop -or [int]$uac.PromptOnSecureDesktop -ne 0)
        Set-OmniResultMetric -Result $result -Name 'UACEnabled' -Value $uacOn
        Set-OmniResultMetric -Result $result -Name 'UACConsentPromptBehaviorAdmin' -Value $consentAdmin
        Set-OmniResultMetric -Result $result -Name 'UACPromptOnSecureDesktop' -Value $secureDesktop
        if (-not $uacOn) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'User Account Control (UAC) is disabled' -Severity 'Warning' -Component 'Security/UAC' `
                -Detail 'EnableLUA is set to 0; UAC elevation prompts are disabled.' `
                -LikelyCause 'UAC turned off manually or by policy.' `
                -Confidence 80 `
                -Recommendation 'Re-enable UAC (EnableLUA = 1) to protect against silent privilege escalation.')
        } else {
            if ($consentAdmin -eq 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-uac-elevate-without-prompting' `
                    -Title 'UAC elevates administrators without prompting' -Severity 'Warning' -Component 'Security/UAC' `
                    -Detail 'ConsentPromptBehaviorAdmin is 0 (Elevate without prompting): any program an administrator starts can gain full rights silently.' `
                    -LikelyCause 'The "Behavior of the elevation prompt for administrators in Admin Approval Mode" policy was relaxed manually or by policy.' `
                    -Confidence 85 `
                    -Recommendation 'Set ConsentPromptBehaviorAdmin to 5 (default, prompt for consent for non-Windows binaries) or to 2 / 1 (prompt on the secure desktop).')
            }
            if (-not $secureDesktop) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'security-uac-secure-desktop-disabled' `
                    -Title 'UAC prompts do not use the secure desktop' -Severity 'Warning' -Component 'Security/UAC' `
                    -Detail 'PromptOnSecureDesktop is 0: elevation prompts appear on the interactive desktop, where other programs running as the user can interact with them.' `
                    -LikelyCause 'The "Switch to the secure desktop when prompting for elevation" policy was disabled, often to work around remote-support tools.' `
                    -Confidence 80 `
                    -Recommendation 'Set PromptOnSecureDesktop to 1 (default) unless a documented remote-support requirement needs otherwise.')
            }
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
