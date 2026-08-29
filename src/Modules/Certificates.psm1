<#
.SYNOPSIS
    OmniDiag diagnostic module: certificate health.

.DESCRIPTION
    Read-only inspection of personal machine and user certificate stores for
    expired and soon-to-expire certificates. Private keys are never exported.
#>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='Certificates'; Category='Security'; Description='Expired and expiring local machine and user certificates.'; RequiresAdmin=$false; Order=520; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'Certificates' -Category 'Security' -HadAdmin $Context.IsAdmin
    $isWindowsHost = $true
    try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
    if (-not $isWindowsHost) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows certificate stores are unavailable' -Severity Information -Component 'Security/Certificates')
        return (Complete-OmniResult -Result $result)
    }

    $certificates = @()
    foreach ($store in @('Cert:\LocalMachine\My','Cert:\CurrentUser\My')) {
        try {
            if (Test-Path -LiteralPath $store) {
                $certificates += @(Get-ChildItem -LiteralPath $store -ErrorAction Stop | Where-Object { $_.NotAfter })
            }
        } catch { $Context.Logger.Debug("Certificate store '$store' failed: $($_.Exception.Message)", 'Certificates') }
    }

    $now = Get-Date
    $expired = @($certificates | Where-Object { $_.NotAfter -lt $now })
    $expiring = @($certificates | Where-Object { $_.NotAfter -ge $now -and $_.NotAfter -le $now.AddDays(30) })
    Set-OmniResultMetric -Result $result -Name 'PersonalCertificateCount' -Value $certificates.Count
    Set-OmniResultMetric -Result $result -Name 'ExpiredCount' -Value $expired.Count
    Set-OmniResultMetric -Result $result -Name 'ExpiringWithin30DaysCount' -Value $expiring.Count

    foreach ($cert in @($expired | Select-Object -First 10)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id "certificate-expired-$($cert.Thumbprint)" -Title "Expired certificate: $($cert.Subject)" -Severity Error -Component 'Security/Certificates' -Detail "Expired $($cert.NotAfter.ToString('u')); thumbprint $($cert.Thumbprint)." -LikelyCause 'A personal certificate was not renewed or removed after replacement.' -Confidence 95 -Recommendation 'Identify the owning service or user, renew or replace the certificate through the approved PKI process, and remove obsolete certificates only after dependency review.')
    }
    foreach ($cert in @($expiring | Select-Object -First 10)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id "certificate-expiring-$($cert.Thumbprint)" -Title "Certificate expires soon: $($cert.Subject)" -Severity Warning -Component 'Security/Certificates' -Detail "Expires $($cert.NotAfter.ToString('u')); thumbprint $($cert.Thumbprint)." -LikelyCause 'The certificate is within the 30-day renewal window.' -Confidence 95 -Recommendation 'Confirm the certificate owner and begin the approved renewal and deployment process before expiration.')
    }
    if ($expired.Count -eq 0 -and $expiring.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Personal certificate expiration posture healthy' -Severity Pass -Component 'Security/Certificates' -Detail 'No expired or 30-day-expiring certificates were found in the inspected personal stores.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
