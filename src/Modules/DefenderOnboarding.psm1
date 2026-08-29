<# .SYNOPSIS OmniDiag diagnostic module: Microsoft Defender for Endpoint onboarding. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Defender Onboarding'; Category='Security'; Description='Microsoft Defender Antivirus and Defender for Endpoint onboarding posture.'; RequiresAdmin=$false; Order=540; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Defender Onboarding' -Category 'Security' -HadAdmin $Context.IsAdmin
    $onboardingState = $null; $senseStatus = ''; $antivirusEnabled = $null; $realTimeEnabled = $null
    try {
        $status = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -ErrorAction Stop
        if ($status.PSObject.Properties['OnboardingState']) { $onboardingState = [int]$status.OnboardingState }
    } catch { $Context.Logger.Debug("MDE onboarding registry query failed: $($_.Exception.Message)", 'Defender Onboarding') }
    try { $senseStatus = [string](Get-Service Sense -ErrorAction Stop).Status } catch { $Context.Logger.Debug("Sense service query failed: $($_.Exception.Message)", 'Defender Onboarding') }
    try {
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $antivirusEnabled = [bool]$mp.AntivirusEnabled; $realTimeEnabled = [bool]$mp.RealTimeProtectionEnabled
        }
    } catch { $Context.Logger.Debug("Defender status query failed: $($_.Exception.Message)", 'Defender Onboarding') }
    Set-OmniResultMetric -Result $result -Name 'MdeOnboardingState' -Value $onboardingState
    Set-OmniResultMetric -Result $result -Name 'SenseServiceStatus' -Value $senseStatus
    Set-OmniResultMetric -Result $result -Name 'AntivirusEnabled' -Value $antivirusEnabled
    Set-OmniResultMetric -Result $result -Name 'RealTimeProtectionEnabled' -Value $realTimeEnabled

    if ($null -eq $onboardingState) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Defender for Endpoint onboarding is not locally evident' -Severity Information -Component 'Security/MDE' -Detail 'No readable MDE OnboardingState value was found.' -Recommendation 'No action is needed when MDE is not licensed or intended; otherwise verify onboarding policy and the device record in the Defender portal.')
    } elseif ($onboardingState -ne 1) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Defender for Endpoint is not onboarded' -Severity Warning -Component 'Security/MDE' -Detail "Local OnboardingState is '$onboardingState'." -LikelyCause 'The onboarding package or management policy is missing, failed, or offboarded.' -Confidence 90 -Recommendation 'Review the approved MDE onboarding policy, Sense service events, connectivity, and device inventory in Microsoft Defender XDR.')
    } elseif ($senseStatus -and $senseStatus -ne 'Running') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'MDE sensor service is not running' -Severity Warning -Component 'Security/MDE' -Detail "Sense service state is '$senseStatus'." -LikelyCause 'The sensor is stopped, unhealthy, or awaiting a restart.' -Confidence 90 -Recommendation 'Review Microsoft Defender for Endpoint sensor health and service events before restarting through approved procedures.')
    }
    if ($antivirusEnabled -eq $false -or $realTimeEnabled -eq $false) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Microsoft Defender Antivirus protection is reduced' -Severity Warning -Component 'Security/DefenderAV' -Detail "AntivirusEnabled=$antivirusEnabled; RealTimeProtectionEnabled=$realTimeEnabled." -Recommendation 'Confirm whether an approved third-party antivirus is active; otherwise restore Defender protection through policy.')
    }
    if ($result.Findings.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Defender onboarding posture healthy' -Severity Pass -Component 'Security/MDE' -Detail 'MDE onboarding and inspected Defender protection signals are healthy.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
