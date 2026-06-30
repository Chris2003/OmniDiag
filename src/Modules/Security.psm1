<#
.SYNOPSIS
    OmniDiag diagnostic module: Security.

.DESCRIPTION
    Reports security posture: Microsoft Defender state and signature age, firewall
    profiles, BitLocker protection, Secure Boot, TPM, Credential Guard, UAC, RDP
    exposure, registered antivirus, and local administrator count.

    Several checks (BitLocker, local admins) need elevation; when not elevated they
    are skipped with a note instead of failing the module.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Security'
        Category      = 'Security'
        Description   = 'Defender, firewall, BitLocker, Secure Boot, TPM, UAC, and RDP posture.'
        RequiresAdmin = $false
        Order         = 60
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Security' -Category 'Security' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Microsoft Defender ----------------------------------------------
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'DefenderRealTime' -Value ([bool]$mp.RealTimeProtectionEnabled)
        Set-OmniResultMetric -Result $result -Name 'DefenderAntivirus' -Value ([bool]$mp.AntivirusEnabled)
        Set-OmniResultMetric -Result $result -Name 'DefenderSignatureAgeDays' -Value $mp.AntivirusSignatureAge

        if (-not $mp.RealTimeProtectionEnabled) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Defender real-time protection is OFF' -Severity 'Warning' `
                -Component 'Security/Defender' -Detail 'Real-time protection is disabled.' `
                -LikelyCause 'Disabled manually, by another AV, or by policy.' -Confidence 75 `
                -Recommendation 'Re-enable real-time protection unless a third-party AV is managing the endpoint.')
        }
        if ($null -ne $mp.AntivirusSignatureAge -and $mp.AntivirusSignatureAge -gt 7) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Defender signatures are $($mp.AntivirusSignatureAge) days old" -Severity 'Warning' `
                -Component 'Security/Defender' -Detail "Antivirus signature age is $($mp.AntivirusSignatureAge) days." `
                -LikelyCause 'Definition updates are not completing.' -Confidence 70 `
                -Recommendation 'Update signatures (Update-MpSignature); verify connectivity to update sources.')
        }
    } catch { $log.Debug("Get-MpComputerStatus unavailable: $($_.Exception.Message)", 'Security') }

    # --- Registered antivirus (Security Center) --------------------------
    try {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'RegisteredAV' -Value (($av | ForEach-Object { $_.displayName }) -join ', ')
        if ($av.Count -eq 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No antivirus product registered' -Severity 'Critical' `
                -Component 'Security/Antivirus' -Detail 'Windows Security Center reports no registered AV product.' `
                -LikelyCause 'No active antivirus, or AV not registering with Security Center.' -Confidence 60 `
                -Recommendation 'Ensure Defender or a third-party AV is active and registered.')
        }
    } catch { $log.Debug("SecurityCenter2 query unavailable: $($_.Exception.Message)", 'Security') }

    # --- Firewall ---------------------------------------------------------
    try {
        $fw = Get-NetFirewallProfile -ErrorAction Stop
        $disabled = @($fw | Where-Object { -not $_.Enabled })
        if ($disabled.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Firewall disabled on $($disabled.Count) profile(s)" -Severity 'Warning' `
                -Component 'Security/Firewall' -Detail ("Disabled profiles: {0}" -f (($disabled.Name) -join ', ')) `
                -LikelyCause 'Firewall turned off.' -Confidence 70 `
                -Recommendation 'Re-enable the firewall unless a managed policy intentionally disables it.')
        }
    } catch { $log.Debug("Get-NetFirewallProfile unavailable: $($_.Exception.Message)", 'Security') }

    # --- BitLocker (admin) -----------------------------------------------
    if ($Context.IsAdmin) {
        try {
            $sysDrive = $env:SystemDrive
            $blv = Get-BitLockerVolume -MountPoint $sysDrive -ErrorAction Stop
            Set-OmniResultMetric -Result $result -Name 'BitLockerOSDrive' -Value $blv.ProtectionStatus
            if ($blv.ProtectionStatus -ne 'On') {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "BitLocker is not protecting $sysDrive" -Severity 'Warning' `
                    -Component 'Security/BitLocker' -Detail "Protection status: $($blv.ProtectionStatus)." `
                    -LikelyCause 'Drive encryption is off or suspended.' -Confidence 70 `
                    -Recommendation 'Enable BitLocker on the OS drive (requires TPM and a recovery key escrow plan).')
            }
        } catch { $log.Debug("Get-BitLockerVolume unavailable: $($_.Exception.Message)", 'Security') }
    } else {
        $log.Debug('Skipping BitLocker check (requires administrator).', 'Security')
    }

    # --- Secure Boot ------------------------------------------------------
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'SecureBoot' -Value ([bool]$sb)
        if (-not $sb) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Secure Boot is disabled' -Severity 'Warning' `
                -Component 'Security/SecureBoot' -Detail 'Secure Boot is supported but off.' `
                -LikelyCause 'Disabled in UEFI firmware.' -Confidence 80 `
                -Recommendation 'Enable Secure Boot in UEFI for boot integrity.')
        }
    } catch { $log.Debug("Secure Boot state unavailable: $($_.Exception.Message)", 'Security') }

    # --- Credential Guard -------------------------------------------------
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root/Microsoft/Windows/DeviceGuard' -ErrorAction Stop
        $cgRunning = ($dg.SecurityServicesRunning -contains 1)
        Set-OmniResultMetric -Result $result -Name 'CredentialGuard' -Value $cgRunning
    } catch { $log.Debug("DeviceGuard query unavailable: $($_.Exception.Message)", 'Security') }

    # --- UAC --------------------------------------------------------------
    try {
        $uac = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'UAC' -Value ([bool]$uac.EnableLUA)
        if ($uac.EnableLUA -ne 1) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'User Account Control (UAC) is disabled' -Severity 'Warning' `
                -Component 'Security/UAC' -Detail 'EnableLUA is not set to 1.' `
                -LikelyCause 'UAC turned off.' -Confidence 80 `
                -Recommendation 'Re-enable UAC; running without it weakens privilege isolation.')
        }
    } catch { $log.Debug("UAC registry read failed: $($_.Exception.Message)", 'Security') }

    # --- RDP --------------------------------------------------------------
    try {
        $rdp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction Stop
        $rdpEnabled = ($rdp.fDenyTSConnections -eq 0)
        Set-OmniResultMetric -Result $result -Name 'RDPEnabled' -Value $rdpEnabled
        if ($rdpEnabled) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Remote Desktop (RDP) is enabled' -Severity 'Information' `
                -Component 'Security/RDP' -Detail 'Incoming RDP connections are allowed.' `
                -LikelyCause 'RDP turned on for remote access.' `
                -Recommendation 'If unexpected, disable RDP. If needed, require NLA and restrict access by firewall/VPN.')
        }
    } catch { $log.Debug("RDP registry read failed: $($_.Exception.Message)", 'Security') }

    # --- Local administrators (admin) ------------------------------------
    if ($Context.IsAdmin) {
        try {
            $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
            Set-OmniResultMetric -Result $result -Name 'LocalAdministrators' -Value (($admins | ForEach-Object { $_.Name }) -join ', ')
            if ($admins.Count -gt 5) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "$($admins.Count) members in local Administrators" -Severity 'Warning' `
                    -Component 'Security/Accounts' -Detail "The local Administrators group has $($admins.Count) members." `
                    -LikelyCause 'Excess accounts with admin rights increase attack surface.' -Confidence 50 `
                    -Recommendation 'Review and prune unnecessary local administrators.' `
                    -Data ($admins | ForEach-Object { $_.Name }))
            }
        } catch { $log.Debug("Get-LocalGroupMember failed: $($_.Exception.Message)", 'Security') }
    }

    if (-not $Context.IsAdmin) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Some security checks skipped (not elevated)' -Severity 'Information' `
            -Component 'Security' -Detail 'BitLocker and local administrator checks require elevation.' `
            -Recommendation 'Re-run OmniDiag as Administrator for a complete security assessment.')
    }

    if (($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Security posture looks good' -Severity 'Pass' `
            -Component 'Security' -Detail 'Defender, firewall, and platform protections are in expected states.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
