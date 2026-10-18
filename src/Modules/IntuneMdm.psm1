<#
.SYNOPSIS
    OmniDiag diagnostic module: Intune and MDM.

.DESCRIPTION
    Read-only local MDM enrollment, Intune Management Extension, related service,
    and recent DeviceManagement event posture. The event query is bounded: errors
    (level 2) in the scan time range only, at most MaxEventsPerChannel events (run
    Config; default 500). The errors finding is a Warning at 10 or more error events in
    the range, Information below that, and says "at least N" when the cap is reached.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Intune and MDM'; Id='extras.intune-and-mdm'; Group='extras'; NetworkAccess='None'; Category='Cloud'; Description='Local MDM enrollment, Intune agent, service, and policy-event posture.'; RequiresAdmin=$false; Order=740; Enabled=$true }
}

$script:OmniMdmDefaultMaxEvents = 500
$script:OmniMdmWarnErrorCount = 10

function Test-OmniIntuneWindowsHost {
    <# .SYNOPSIS Internal: $true on Windows (Windows PowerShell 5.1 is always Windows). #>
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmniIntuneMdmErrorCount {
    <#
    .SYNOPSIS
        Internal: number of error events (level 2) in the DeviceManagement Enterprise
        Diagnostics Admin log between Start and End, capped at MaxEvents.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [datetime] $Start,
        [Parameter(Mandatory)] [datetime] $End,
        [Parameter(Mandatory)] [int] $MaxEvents
    )
    $logName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
    if (-not (Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue)) { return 0 }
    return @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Level = 2; StartTime = $Start; EndTime = $End } -MaxEvents $MaxEvents -ErrorAction SilentlyContinue).Count
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Intune and MDM' -Category 'Cloud' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    if (-not (Test-OmniIntuneWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.intune-and-mdm.windows-only' -Title 'Intune and MDM check is Windows-only' -Severity Information -Component 'Cloud/Intune' -Detail 'This scanner reads local Windows enrollment and management state.')
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
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.intune-and-mdm.ime-not-running' -Title 'Intune Management Extension is not running' -Severity Warning -Component 'Cloud/Intune/Agent' -Detail "The service state is '$($ime.Status)'." -LikelyCause 'The agent may be stopped, unhealthy, or waiting on a reboot.' -Confidence 80 -Recommendation 'Review the Intune Management Extension logs and service configuration, then restart it using approved procedures.')
            }
        } catch { $log.Debug("Intune Management Extension service query failed: $($_.Exception.Message)", 'Intune and MDM') }
    }

    $recentErrors = 0
    $maxEvents = $script:OmniMdmDefaultMaxEvents
    $cfg = $null
    if ($Context.PSObject.Properties['Config']) { $cfg = $Context.Config }
    if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('MaxEventsPerChannel') -and [int]$cfg['MaxEventsPerChannel'] -gt 0) { $maxEvents = [int]$cfg['MaxEventsPerChannel'] }
    $range = $null
    if ($Context.PSObject.Properties['TimeRange']) { $range = $Context.TimeRange }
    if (-not $range) { $range = Get-OmniTimeRange -Preset Last7Days }
    if (-not ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested)) {
        try {
            $recentErrors = Get-OmniIntuneMdmErrorCount -Start $range.Start -End $range.End -MaxEvents $maxEvents
        } catch { $log.Debug("MDM event query failed: $($_.Exception.Message)", 'Intune and MDM') }
    }
    $capped = ($recentErrors -ge $maxEvents)
    Set-OmniResultMetric -Result $result -Name 'RecentMdmErrorCount' -Value $recentErrors
    Set-OmniResultMetric -Result $result -Name 'RecentMdmErrorCountCapped' -Value $capped
    if ($recentErrors -gt 0) {
        # A few errors are routine on managed devices (transient sync and policy retries);
        # a Warning needs at least $script:OmniMdmWarnErrorCount error events in the range.
        $countText = if ($capped) { "at least $recentErrors" } else { "$recentErrors" }
        $sev = if ($recentErrors -ge $script:OmniMdmWarnErrorCount) { 'Warning' } else { 'Information' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.intune-and-mdm.recent-mdm-errors' -Title "$countText recent MDM enrollment or policy errors" -Severity $sev -Component 'Cloud/Intune/Policy' -Detail "DeviceManagement Enterprise Diagnostics logged $countText error events in the selected time range (query capped at $maxEvents events). A Warning is raised at $($script:OmniMdmWarnErrorCount) or more." -LikelyCause 'Enrollment, certificate, policy, or sync processing failed.' -Confidence 75 -Recommendation 'Review the DeviceManagement-Enterprise-Diagnostics-Provider Admin log and correlate the newest event IDs with the affected policy.')
    }

    if ($enrollmentCount -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.intune-and-mdm.no-enrollment' -Title 'No local MDM enrollment detected' -Severity Information -Component 'Cloud/Intune' -Detail 'No populated enrollment record was found.' -Recommendation 'No action is needed for unmanaged devices; otherwise verify Entra join, licensing, enrollment restrictions, and the automatic enrollment policy.')
    } elseif (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'extras.intune-and-mdm.healthy' -Title 'Intune and MDM posture healthy' -Severity Pass -Component 'Cloud/Intune' -Detail "$enrollmentCount local enrollment record(s) were found with no recent management errors.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
