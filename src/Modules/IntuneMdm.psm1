<#
.SYNOPSIS
    OmniDiag diagnostic module: Intune and MDM.

.DESCRIPTION
    Read-only local MDM enrollment, Intune Management Extension, related service,
    and recent DeviceManagement event posture.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Intune and MDM'; Category='Cloud'; Description='Local MDM enrollment, Intune agent, service, and policy-event posture.'; RequiresAdmin=$false; Order=720; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Intune and MDM' -Category 'Cloud' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
    if (-not $isWindowsHost) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Intune and MDM check is Windows-only' -Severity Information -Component 'Cloud/Intune' -Detail 'This scanner reads local Windows enrollment and management state.')
        return (Complete-OmniResult -Result $result)
    }

    $enrollmentCount = 0
    try {
        $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
        if (Test-Path -LiteralPath $root) {
            $enrollments = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop | Where-Object { $_.PSChildName -match '^[0-9a-fA-F-]{36}$' })
            foreach ($entry in $enrollments) {
                $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
                if ($properties -and ($properties.PSObject.Properties['ProviderID'] -or $properties.PSObject.Properties['UPN'])) { $enrollmentCount++ }
            }
        }
    } catch { $log.Debug("MDM enrollment query failed: $($_.Exception.Message)", 'Intune and MDM') }
    Set-OmniResultMetric -Result $result -Name 'EnrollmentCount' -Value $enrollmentCount

    $imeInstalled = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension'
    Set-OmniResultMetric -Result $result -Name 'IntuneManagementExtensionInstalled' -Value $imeInstalled
    if ($imeInstalled) {
        try {
            $ime = Get-Service -Name 'IntuneManagementExtension' -ErrorAction Stop
            Set-OmniResultMetric -Result $result -Name 'IntuneManagementExtensionStatus' -Value ([string]$ime.Status)
            if ($ime.Status -ne 'Running') {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Intune Management Extension is not running' -Severity Warning -Component 'Cloud/Intune/Agent' -Detail "The service state is '$($ime.Status)'." -LikelyCause 'The agent may be stopped, unhealthy, or waiting on a reboot.' -Confidence 80 -Recommendation 'Review the Intune Management Extension logs and service configuration, then restart it using approved procedures.')
            }
        } catch { $log.Debug("Intune Management Extension service query failed: $($_.Exception.Message)", 'Intune and MDM') }
    }

    $recentErrors = 0
    try {
        $logName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
        if (Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue) {
            $recentErrors = @(Get-WinEvent -FilterHashtable @{ LogName=$logName; Level=2; StartTime=$Context.TimeRange.Start; EndTime=$Context.TimeRange.End } -ErrorAction SilentlyContinue).Count
        }
    } catch { $log.Debug("MDM event query failed: $($_.Exception.Message)", 'Intune and MDM') }
    Set-OmniResultMetric -Result $result -Name 'RecentMdmErrorCount' -Value $recentErrors
    if ($recentErrors -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "$recentErrors recent MDM enrollment or policy errors" -Severity Warning -Component 'Cloud/Intune/Policy' -Detail "DeviceManagement Enterprise Diagnostics logged $recentErrors error events in the selected time range." -LikelyCause 'Enrollment, certificate, policy, or sync processing failed.' -Confidence 75 -Recommendation 'Review the DeviceManagement-Enterprise-Diagnostics-Provider Admin log and correlate the newest event IDs with the affected policy.')
    }

    if ($enrollmentCount -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No local MDM enrollment detected' -Severity Information -Component 'Cloud/Intune' -Detail 'No populated enrollment record was found.' -Recommendation 'No action is needed for unmanaged devices; otherwise verify Entra join, licensing, enrollment restrictions, and the automatic enrollment policy.')
    } elseif (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Intune and MDM posture healthy' -Severity Pass -Component 'Cloud/Intune' -Detail "$enrollmentCount local enrollment record(s) were found with no recent management errors.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
