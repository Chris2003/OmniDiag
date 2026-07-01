<#
.SYNOPSIS
    OmniDiag diagnostic module: Processes.

.DESCRIPTION
    Enumerates running processes, reports the top CPU and memory consumers, and
    flags any processes that are not responding.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Processes'
        Category      = 'Performance'
        Description   = 'Running process count and top CPU/memory consumers.'
        RequiresAdmin = $false
        Order         = 230
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

    $result = New-OmniResult -ModuleName 'Processes' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    try {
        $procs = @(Get-Process -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'ProcessCount' -Value $procs.Count

        # --- Top 5 by CPU ------------------------------------------------
        try {
            $topCpu = $procs | Where-Object { $null -ne $_.CPU } |
                Sort-Object -Property CPU -Descending | Select-Object -First 5 |
                ForEach-Object {
                    [pscustomobject]@{ Name = $_.ProcessName; Value = [math]::Round([double]$_.CPU, 1) }
                }
            Set-OmniResultMetric -Result $result -Name 'TopCpu' -Value @($topCpu)
        } catch {
            $log.Debug("Top-CPU enumeration failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Top 5 by working set ---------------------------------------
        try {
            $topMem = $procs | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object {
                    [pscustomobject]@{ Name = $_.ProcessName; Value = [math]::Round($_.WorkingSet64 / 1MB, 1) }
                }
            Set-OmniResultMetric -Result $result -Name 'TopMemory' -Value @($topMem)
        } catch {
            $log.Debug("Top-memory enumeration failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Not-responding processes -----------------------------------
        try {
            $notResponding = @($procs | Where-Object {
                $_.MainWindowHandle -ne 0 -and $_.Responding -eq $false
            } | Select-Object -ExpandProperty ProcessName -Unique)
            Set-OmniResultMetric -Result $result -Name 'NotRespondingCount' -Value $notResponding.Count
            if ($notResponding.Count -gt 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("{0} process(es) not responding" -f $notResponding.Count) -Severity 'Warning' `
                    -Component 'Performance/Processes' `
                    -Detail ("Not responding: {0}" -f ($notResponding -join ', ')) `
                    -LikelyCause 'An application is hung or blocked waiting on a resource.' `
                    -Confidence 60 `
                    -Recommendation 'Investigate or restart the affected applications.')
            }
        } catch {
            $log.Debug("Not-responding evaluation failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Informational summary of top consumers ---------------------
        try {
            $topCpuNames = @($procs | Where-Object { $null -ne $_.CPU } |
                Sort-Object -Property CPU -Descending | Select-Object -First 5 -ExpandProperty ProcessName)
            if ($topCpuNames.Count -gt 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title 'Top resource consumers' -Severity 'Information' `
                    -Component 'Performance/Processes' `
                    -Detail ("Top CPU processes: {0}" -f ($topCpuNames -join ', ')))
            }
        } catch {
            $log.Debug("Top-consumer summary failed: $($_.Exception.Message)", 'Processes')
        }
    } catch {
        $log.Warn("Get-Process failed: $($_.Exception.Message)", 'Processes')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Process inventory collected' -Severity 'Pass' -Component 'Performance/Processes' `
            -Detail 'Running processes were enumerated without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
