<# .SYNOPSIS OmniDiag diagnostic module: managed Windows update policy and ring posture. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Update Rings'; Category='Cloud'; Description='Local Windows Update for Business and MDM update policy posture.'; RequiresAdmin=$false; Order=550; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Update Rings' -Category 'Cloud' -HadAdmin $Context.IsAdmin
    $policy = [ordered]@{}
    foreach ($path in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update')) {
        try {
            if (Test-Path -LiteralPath $path) {
                $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
                foreach ($property in ($item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                    $policy["${path}::$($property.Name)"] = $property.Value
                }
            }
        } catch { $Context.Logger.Debug("Update policy '$path' failed: $($_.Exception.Message)", 'Update Rings') }
    }
    Set-OmniResultMetric -Result $result -Name 'PolicyValueCount' -Value $policy.Count
    Set-OmniResultMetric -Result $result -Name 'PolicyValues' -Value $policy

    $pauseValues = @($policy.GetEnumerator() | Where-Object { $_.Key -match 'Pause|Paused' -and $_.Value })
    Set-OmniResultMetric -Result $result -Name 'PauseValueCount' -Value $pauseValues.Count
    if ($pauseValues.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows Update pause policy is present' -Severity Information -Component 'Cloud/UpdateRings' -Detail (($pauseValues | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ') -Recommendation 'Confirm the pause is intentional, time-bounded, and consistent with the assigned update ring.')
    }
    if ($policy.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No managed update-ring policy detected locally' -Severity Information -Component 'Cloud/UpdateRings' -Detail 'No Windows Update for Business or PolicyManager Update values were found.' -Recommendation 'No action is needed for unmanaged devices; otherwise verify MDM enrollment, policy assignment, and the latest device sync.')
    } elseif ($pauseValues.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Managed update policy detected' -Severity Pass -Component 'Cloud/UpdateRings' -Detail "$($policy.Count) local update policy value(s) were collected with no pause value present.")
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
