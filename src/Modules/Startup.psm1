<#
.SYNOPSIS
    OmniDiag diagnostic module: Startup.

.DESCRIPTION
    Enumerates autostart entries from the HKLM/HKCU Run and RunOnce registry keys
    and from Win32_StartupCommand, and flags when there are too many.

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
        Name          = 'Startup'
        Category      = 'System'
        Description   = 'Autostart entries from registry Run keys and startup commands.'
        RequiresAdmin = $false
        Order         = 110
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

    $result = New-OmniResult -ModuleName 'Startup' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $names = [System.Collections.Generic.List[string]]::new()

    # --- Registry Run / RunOnce keys --------------------------------------
    $runKeys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($key in $runKeys) {
        try {
            if (-not (Test-Path -Path $key)) { continue }
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                $names.Add($p.Name)
            }
        } catch {
            $log.Debug("Failed to read startup key ${key}: $($_.Exception.Message)", 'Startup')
        }
    }

    # --- Win32_StartupCommand ---------------------------------------------
    try {
        $startupCmds = Get-CimInstance -ClassName 'Win32_StartupCommand' -ErrorAction Stop
        foreach ($cmd in @($startupCmds)) {
            if ($cmd -and $cmd.Name) { $names.Add($cmd.Name) }
        }
    } catch {
        $log.Debug("CIM query failed for Win32_StartupCommand: $($_.Exception.Message)", 'Startup')
    }

    $count = $names.Count
    Set-OmniResultMetric -Result $result -Name 'StartupItemCount' -Value $count
    Set-OmniResultMetric -Result $result -Name 'StartupItems' -Value ($names | Sort-Object -Unique)

    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
        -Title ("$count startup item(s) found") -Severity 'Information' -Component 'System/Startup' `
        -Detail ("Enumerated $count autostart entries from registry Run keys and startup commands."))

    if ($count -gt 25) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title ("High number of startup items ($count)") -Severity 'Warning' -Component 'System/Startup' `
            -Detail "There are $count autostart entries configured." `
            -LikelyCause 'A large number of startup programs slows boot and consumes resources.' `
            -Confidence 65 `
            -Recommendation 'Review and disable unnecessary startup items to improve boot time.')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Startup entries within normal range' -Severity 'Pass' -Component 'System/Startup' `
            -Detail 'The number of autostart entries is within an acceptable range.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
