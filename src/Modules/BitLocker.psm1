<# .SYNOPSIS OmniDiag diagnostic module: BitLocker and recovery policy posture. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='BitLocker'; Category='Security'; Description='Volume protection and local recovery-key escrow policy evidence.'; RequiresAdmin=$false; Order=530; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'BitLocker' -Category 'Security' -HadAdmin $Context.IsAdmin
    $volumes = @()
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) { $volumes = @(Get-BitLockerVolume -ErrorAction Stop) }
    } catch { $Context.Logger.Debug("BitLocker volume query failed: $($_.Exception.Message)", 'BitLocker') }

    $osVolume = @($volumes | Where-Object { $_.VolumeType -eq 'OperatingSystem' -or $_.MountPoint -eq $env:SystemDrive } | Select-Object -First 1)
    Set-OmniResultMetric -Result $result -Name 'VolumeCount' -Value $volumes.Count
    if ($osVolume.Count -gt 0) {
        $os = $osVolume[0]
        Set-OmniResultMetric -Result $result -Name 'OsVolumeProtectionStatus' -Value ([string]$os.ProtectionStatus)
        Set-OmniResultMetric -Result $result -Name 'OsVolumeStatus' -Value ([string]$os.VolumeStatus)
        Set-OmniResultMetric -Result $result -Name 'OsEncryptionPercentage' -Value $os.EncryptionPercentage
        if ([string]$os.ProtectionStatus -ne 'On') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'BitLocker protection is not active on the OS volume' -Severity Warning -Component 'Security/BitLocker' -Detail "Protection '$($os.ProtectionStatus)', volume '$($os.VolumeStatus)', encryption $($os.EncryptionPercentage)%." -LikelyCause 'Protection is suspended, encryption is incomplete, or BitLocker is not enabled.' -Confidence 90 -Recommendation 'Confirm organizational encryption policy and recovery-key availability before enabling or resuming BitLocker.')
        }
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'BitLocker volume status could not be read' -Severity Information -Component 'Security/BitLocker' -Detail 'Get-BitLockerVolume was unavailable or returned no operating-system volume.' -Recommendation 'Re-run elevated on a supported Windows edition for complete volume protection evidence.')
    }

    $escrowPolicy = $false; $policyValues = [ordered]@{}
    try {
        $fve = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -ErrorAction Stop
        foreach ($name in @('OSActiveDirectoryBackup','FDVActiveDirectoryBackup','RequireActiveDirectoryBackup','OSRequireActiveDirectoryBackup','OSRecovery')) {
            if ($fve.PSObject.Properties[$name]) { $policyValues[$name] = $fve.$name }
        }
        $escrowPolicy = @($policyValues.GetEnumerator() | Where-Object { $_.Key -match 'ActiveDirectoryBackup' -and [int]$_.Value -eq 1 }).Count -gt 0
    } catch { $Context.Logger.Debug("BitLocker policy query failed: $($_.Exception.Message)", 'BitLocker') }
    Set-OmniResultMetric -Result $result -Name 'RecoveryEscrowPolicyEvidence' -Value $escrowPolicy
    Set-OmniResultMetric -Result $result -Name 'RecoveryPolicyValues' -Value $policyValues
    if ($osVolume.Count -gt 0 -and [string]$osVolume[0].ProtectionStatus -eq 'On' -and -not $escrowPolicy) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Recovery-key escrow is not locally verifiable' -Severity Information -Component 'Security/BitLocker/Escrow' -Detail 'BitLocker is protected, but no AD escrow policy evidence was found locally.' -Recommendation 'Verify the recovery key exists in the authoritative Entra ID, Active Directory, or approved escrow system. Local inspection cannot prove server-side custody.')
    }
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank Warning) }).Count -eq 0 -and $osVolume.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'BitLocker protection posture healthy' -Severity Pass -Component 'Security/BitLocker' -Detail 'The operating-system volume reports active protection.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
