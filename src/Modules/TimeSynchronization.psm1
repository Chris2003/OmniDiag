<# .SYNOPSIS OmniDiag diagnostic module: Windows time synchronization. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Time Synchronization'; Category='Identity'; Description='Windows Time service, source, synchronization, and NTP policy posture.'; RequiresAdmin=$false; Order=480; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Time Synchronization' -Category 'Identity' -HadAdmin $Context.IsAdmin
    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
    if (-not $isWindowsHost) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows time synchronization is unavailable' -Severity Information -Component 'Identity/Time')
        return (Complete-OmniResult -Result $result)
    }

    $serviceStatus = ''; $source = ''; $lastSync = ''; $type = ''; $ntpServer = ''
    try { $serviceStatus = [string](Get-Service W32Time -ErrorAction Stop).Status } catch { $Context.Logger.Debug("W32Time service query failed: $($_.Exception.Message)", 'Time Synchronization') }
    try {
        if (Get-Command w32tm.exe -ErrorAction SilentlyContinue) {
            foreach ($line in @(& w32tm.exe /query /status 2>&1)) {
                if ($line -match '^Source:\s*(.+)$') { $source = $matches[1].Trim() }
                if ($line -match '^Last Successful Sync Time:\s*(.+)$') { $lastSync = $matches[1].Trim() }
            }
        }
    } catch { $Context.Logger.Debug("w32tm query failed: $($_.Exception.Message)", 'Time Synchronization') }
    try {
        $parameters = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction Stop
        $type = [string]$parameters.Type; $ntpServer = [string]$parameters.NtpServer
    } catch { $Context.Logger.Debug("W32Time parameters failed: $($_.Exception.Message)", 'Time Synchronization') }

    Set-OmniResultMetric -Result $result -Name 'ServiceStatus' -Value $serviceStatus
    Set-OmniResultMetric -Result $result -Name 'Source' -Value $source
    Set-OmniResultMetric -Result $result -Name 'LastSuccessfulSync' -Value $lastSync
    Set-OmniResultMetric -Result $result -Name 'Type' -Value $type
    Set-OmniResultMetric -Result $result -Name 'NtpServer' -Value $ntpServer
    if ($serviceStatus -and $serviceStatus -ne 'Running') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows Time service is not running' -Severity Warning -Component 'Identity/Time' -Detail "W32Time state is '$serviceStatus'." -LikelyCause 'The service is disabled, stopped, or controlled by an incomplete policy.' -Confidence 85 -Recommendation 'Review the effective time policy and service configuration; authentication systems commonly require accurate time.')
    }
    if ($source -match 'Local CMOS Clock|Free-running System Clock') {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'System is using a local clock source' -Severity Warning -Component 'Identity/Time' -Detail "Reported source: $source." -LikelyCause 'No domain hierarchy or configured NTP source is currently available.' -Confidence 85 -Recommendation 'Verify domain connectivity or the approved NTP policy, then resynchronize and confirm the reported source.')
    }
    if ($result.Findings.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Time synchronization posture healthy' -Severity Pass -Component 'Identity/Time' -Detail "Service '$serviceStatus'; source '$source'.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
