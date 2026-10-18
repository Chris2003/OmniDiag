<#
.SYNOPSIS
    OmniDiag diagnostic module: Update History.

.DESCRIPTION
    Reads the LOCAL Windows Update history through the Windows Update Agent COM API
    (Microsoft.Update.Session -> CreateUpdateSearcher -> GetTotalHistoryCount /
    QueryHistory). QueryHistory "synchronously queries the computer for the history
    of the update events" (Microsoft Learn, IUpdateSearcher::QueryHistory): it reads
    the agent's local datastore. The scanner never calls IUpdateSearcher.Search or
    any other online method, and installs nothing.

    Reports:
      - the last successful installation (Warning when older than 45 days, Error when
        older than 90 days), excluding Microsoft Defender definition updates (KB2267602,
        KB915597, KB4052623, "Security Intelligence Update", "Definition Update", or the
        Definition Updates category E0789628-CE08-4437-BE74-2495B842F43B when
        IUpdateHistoryEntry2.Categories is available); the last definition update is a
        separate metric (LastDefinitionUpdate);
      - failed or aborted installations (OperationResultCode 4 / 5) inside the scan
        time range, grouped by update with the most recent failure and its HRESULT;
      - a summary of what was read.

    Bounds: at most 200 history entries (newest first); failures only inside
    $Context.TimeRange.

    Fallback: when the COM API is unavailable, the newest Get-HotFix InstalledOn date
    grades the last install, and failed-install history is reported as unavailable.

    Per-run options (via $Context.Config):
        UpdateHistoryMaxEntries  int  Entries to read (1-200). Default 200.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

$script:OmniUpdateHistoryMax = 200
$script:OmniUpdateWarnDays = 45
$script:OmniUpdateErrorDays = 90

# Defender / antimalware definition updates (excluded from the last-install grade).
$script:OmniDefinitionTitlePattern = '(?i)(KB2267602|KB915597|KB4052623|Security Intelligence Update|Definition Update)'
$script:OmniDefinitionCategoryId = 'E0789628-CE08-4437-BE74-2495B842F43B'

function Get-OmniModuleManifest {
    <#
    .SYNOPSIS
        Returns the Update History scanner manifest.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Update History'
        Id            = 'updates.update-history'
        Group         = 'updates'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Local Windows Update history: last successful install and failed installs.'
        RequiresAdmin = $false
        Order         = 193
        Enabled       = $true
    }
}

function Get-OmniUpdateHistoryEntry {
    <#
    .SYNOPSIS
        Reads up to MaxEntries local Windows Update history entries through the WUA COM
        API (history only; never Search). Throws when the COM API is unavailable.
    .OUTPUTS
        A pscustomobject with TotalCount and Entries (Date, Title, Operation,
        ResultCode, HResult, UpdateId).
    #>
    [OutputType([pscustomobject])]
    param([int] $MaxEntries = 200)

    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $null
    $history = $null
    try {
        $searcher = $session.CreateUpdateSearcher()
        $total = [int]$searcher.GetTotalHistoryCount()
        $entries = [System.Collections.Generic.List[object]]::new()
        if ($total -gt 0) {
            $count = [math]::Min($total, $MaxEntries)
            # IUpdateHistoryEntryCollection: walk it with Count/Item(i) and release each entry.
            $history = $searcher.QueryHistory(0, $count)
            $n = [int]$history.Count
            for ($i = 0; $i -lt $n; $i++) {
                $e = $null
                try {
                    $e = $history.Item($i)
                    if ($null -eq $e) { continue }
                    $updateId = ''
                    try { $updateId = "$($e.UpdateIdentity.UpdateID)" } catch { $updateId = '' }
                    $entries.Add([pscustomobject]@{
                        Date        = $e.Date
                        Title       = "$($e.Title)"
                        Operation   = [int]$e.Operation
                        ResultCode  = [int]$e.ResultCode
                        HResult     = $e.HResult
                        UpdateId    = $updateId
                        CategoryIds = [string[]]@(Get-OmniUpdateHistoryCategoryId -Entry $e)
                    })
                } finally {
                    Remove-OmniUpdateComObject -InputObject $e
                }
            }
        }
        return [pscustomobject]@{ TotalCount = $total; Entries = $entries.ToArray() }
    } finally {
        foreach ($o in @($history, $searcher, $session)) { Remove-OmniUpdateComObject -InputObject $o }
    }
}

function Remove-OmniUpdateComObject {
    <#
    .SYNOPSIS
        Releases a COM object, ignoring $null and objects that are not COM objects (private).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Releases an in-process COM reference only.')]
    param([object] $InputObject)
    if ($null -eq $InputObject) { return }
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($InputObject) } catch { $null = $_ }
}

function Get-OmniUpdateHistoryCategoryId {
    <#
    .SYNOPSIS
        Returns the CategoryID values of a history entry (IUpdateHistoryEntry2.Categories),
        or an empty array when the interface is not available (private).
    #>
    [OutputType([string[]])]
    param([object] $Entry)
    $ids = [System.Collections.Generic.List[string]]::new()
    $cats = $null
    try {
        $cats = $Entry.Categories
        if ($null -ne $cats) {
            $n = [int]$cats.Count
            for ($j = 0; $j -lt $n; $j++) {
                $c = $null
                try {
                    $c = $cats.Item($j)
                    if ($null -ne $c) { $ids.Add("$($c.CategoryID)") }
                } finally {
                    Remove-OmniUpdateComObject -InputObject $c
                }
            }
        }
    } catch {
        $null = $_   # IUpdateHistoryEntry2 is not available on this agent version.
    } finally {
        Remove-OmniUpdateComObject -InputObject $cats
    }
    return [string[]]@($ids)
}

function Test-OmniUpdateDefinitionEntry {
    <#
    .SYNOPSIS
        True when a history entry is a Microsoft Defender / antimalware definition update (private).
    .DESCRIPTION
        Definition updates install several times a day, so they would hide a stale
        Windows patch level if they counted as "the last successful install".
    #>
    [OutputType([bool])]
    param([object] $Entry)
    if ($null -eq $Entry) { return $false }
    $title = ''
    $p = $Entry.PSObject.Properties['Title']
    if ($p) { $title = "$($p.Value)" }
    if ($title -match $script:OmniDefinitionTitlePattern) { return $true }
    $c = $Entry.PSObject.Properties['CategoryIds']
    if ($c -and $null -ne $c.Value) {
        foreach ($id in @($c.Value)) { if ("$id" -eq $script:OmniDefinitionCategoryId) { return $true } }
    }
    return $false
}

function Get-OmniUpdateHistoryHotFixDate {
    <#
    .SYNOPSIS
        Fallback: the newest Get-HotFix InstalledOn date, or $null.
    #>
    [OutputType([object])]
    param()
    if (-not (Get-Command -Name 'Get-HotFix' -ErrorAction SilentlyContinue)) { return $null }
    $dated = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.PSObject.Properties['InstalledOn'] -and $_.InstalledOn })
    if ($dated.Count -eq 0) { return $null }
    return ($dated | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1).InstalledOn
}

function ConvertTo-OmniHResultHex {
    <#
    .SYNOPSIS
        Formats an HRESULT (signed or unsigned) as 0xXXXXXXXX.
    #>
    [OutputType([string])]
    param([AllowNull()] [object] $HResult)
    if ($null -eq $HResult -or "$HResult" -eq '') { return '' }
    $v = [long]$HResult
    if ($v -lt 0) { $v += 4294967296 }
    return ('0x{0:X8}' -f $v)
}

function Get-OmniUpdateGroupKey {
    <#
    .SYNOPSIS
        Groups history entries by update: the KB number when the title has one, else
        the UpdateIdentity.UpdateID GUID (so version strings in titles never reach the
        finding Id), else the title without a trailing version parenthesis.
    #>
    [OutputType([string])]
    param([string] $Title, [string] $UpdateId)
    $m = [regex]::Match("$Title", 'KB\d{6,8}', 'IgnoreCase')
    if ($m.Success) { return $m.Value.ToUpperInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($UpdateId)) { return "$UpdateId".Trim().ToLowerInvariant() }
    $t = ("$Title" -replace '\s*\([^()]*\d+\.\d+[^()]*\)\s*$', '').Trim()
    return $t
}

function ConvertTo-OmniUpdateFindingId {
    <#
    .SYNOPSIS
        Builds a stable lowercase kebab finding id from a group key.
    #>
    [OutputType([string])]
    param([string] $Key)
    $k = ($Key.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($k.Length -gt 60) { $k = $k.Substring(0, 60).TrimEnd('-') }
    return "update-history-failed-$k"
}

function Add-OmniLastInstallFinding {
    <#
    .SYNOPSIS
        Grades the age of the last successful install and adds the finding.
    #>
    param([pscustomobject] $Result, [object] $LastInstall, [string] $Source)

    if ($null -eq $LastInstall) {
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'update-history-no-successful-install' `
            -Title 'No successful update installation recorded' -Severity 'Warning' -Component 'Updates/History' `
            -Detail "The $Source shows no successful update installation." `
            -LikelyCause 'Updates have never installed on this device, or the history was cleared.' -Confidence 50 `
            -Recommendation 'Open Settings > Windows Update and install the latest updates; check update policy if they are managed centrally.')
        return
    }
    $last = [datetime]$LastInstall
    $ageDays = [int][math]::Floor(((Get-Date) - $last).TotalDays)
    if ($ageDays -lt 0) { $ageDays = 0 }
    Set-OmniResultMetric -Result $Result -Name 'LastSuccessfulInstall' -Value $last
    Set-OmniResultMetric -Result $Result -Name 'LastSuccessfulInstallAgeDays' -Value $ageDays

    $detail = "The last successful update installation was on {0:yyyy-MM-dd} ({1} days ago), from the {2}." -f $last, $ageDays, $Source
    if ($ageDays -gt $script:OmniUpdateErrorDays) {
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'update-history-last-install-stale' `
            -Title "No update installed in over $($script:OmniUpdateErrorDays) days" -Severity 'Error' -Component 'Updates/History' `
            -Detail $detail -LikelyCause 'Updates are failing, paused, blocked by policy, or the device has been offline.' -Confidence 75 `
            -Recommendation 'Run Windows Update now; if it fails, review the failed updates below and the WindowsUpdateClient event log.')
    } elseif ($ageDays -gt $script:OmniUpdateWarnDays) {
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'update-history-last-install-stale' `
            -Title "No update installed in over $($script:OmniUpdateWarnDays) days" -Severity 'Warning' -Component 'Updates/History' `
            -Detail $detail -LikelyCause 'The device may be missing the latest monthly security update.' -Confidence 65 `
            -Recommendation 'Run Windows Update and install the latest cumulative update.')
    } else {
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'update-history-last-install-recent' `
            -Title 'Updates installed recently' -Severity 'Pass' -Component 'Updates/History' -Detail $detail)
    }
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Reads the local update history and returns an OmniDiag.Result.
    .PARAMETER Context
        The scan context from New-OmniContext.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Update History' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = $Context.Config

    $max = $script:OmniUpdateHistoryMax
    if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('UpdateHistoryMaxEntries')) {
        $max = [int]$cfg['UpdateHistoryMaxEntries']
        if ($max -lt 1) { $max = 1 }
        if ($max -gt $script:OmniUpdateHistoryMax) { $max = $script:OmniUpdateHistoryMax }
    }
    $rangeStart = $Context.TimeRange.Start
    $rangeEnd = $Context.TimeRange.End

    # --- Read the local history (COM) -------------------------------------
    $history = $null
    try { $history = Get-OmniUpdateHistoryEntry -MaxEntries $max } catch {
        $log.Debug("Windows Update Agent COM API unavailable: $($_.Exception.Message)", 'Update History')
        $history = $null
    }
    if ($Context.CancellationToken.IsCancellationRequested) { return (Complete-OmniResult -Result $result) }

    if ($null -eq $history) {
        # --- Fallback: Get-HotFix ---------------------------------------------
        $hotfixDate = $null
        $hotfixOk = $true
        try { $hotfixDate = Get-OmniUpdateHistoryHotFixDate } catch {
            $log.Debug("Get-HotFix failed: $($_.Exception.Message)", 'Update History')
            $hotfixOk = $false
        }
        Set-OmniResultMetric -Result $result -Name 'HistorySource' -Value 'Get-HotFix'
        if ($hotfixOk -and $null -ne $hotfixDate) {
            Add-OmniLastInstallFinding -Result $result -LastInstall $hotfixDate -Source 'installed hotfix list (Get-HotFix)'
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'update-history-com-unavailable' `
                -Title 'Failed-update history not available' -Severity 'Information' -Component 'Updates/History' `
                -Detail 'The Windows Update Agent history could not be read, so failed installations cannot be listed. The last install date comes from the installed hotfix list, which covers Windows updates only.')
        } else {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'update-history-not-available' `
                -Title 'Update history not available' -Severity 'Information' -Component 'Updates/History' `
                -Detail 'Neither the Windows Update Agent history nor the installed hotfix list could be read (they exist only on Windows).')
        }
        return (Complete-OmniResult -Result $result)
    }

    $entries = @($history.Entries)
    Set-OmniResultMetric -Result $result -Name 'HistorySource' -Value 'Windows Update Agent'
    Set-OmniResultMetric -Result $result -Name 'HistoryTotalCount' -Value $history.TotalCount
    Set-OmniResultMetric -Result $result -Name 'HistoryEntriesRead' -Value $entries.Count

    # --- Last successful installation (all entries read) -------------------
    # Defender definition updates install several times a day; they are reported as a
    # separate metric and never count as "the last successful install".
    $installs = @($entries | Where-Object { $_.Operation -eq 1 })
    $succeeded = @($installs | Where-Object { $_.ResultCode -eq 2 -or $_.ResultCode -eq 3 } | Sort-Object -Property Date -Descending)
    $definitions = @($succeeded | Where-Object { Test-OmniUpdateDefinitionEntry -Entry $_ })
    $productUpdates = @($succeeded | Where-Object { -not (Test-OmniUpdateDefinitionEntry -Entry $_) })
    if ($definitions.Count -gt 0) {
        $lastDef = [datetime]$definitions[0].Date
        $defAge = [int][math]::Floor(((Get-Date) - $lastDef).TotalDays)
        if ($defAge -lt 0) { $defAge = 0 }
        Set-OmniResultMetric -Result $result -Name 'LastDefinitionUpdate' -Value $lastDef
        Set-OmniResultMetric -Result $result -Name 'LastDefinitionUpdateAgeDays' -Value $defAge
    }
    $lastInstall = if ($productUpdates.Count -gt 0) { $productUpdates[0].Date } else { $null }
    Add-OmniLastInstallFinding -Result $result -LastInstall $lastInstall -Source 'Windows Update history (definition updates excluded)'

    # --- Failed / aborted installations inside the time range --------------
    $failed = @($installs | Where-Object {
            ($_.ResultCode -eq 4 -or $_.ResultCode -eq 5) -and $_.Date -ge $rangeStart -and $_.Date -le $rangeEnd
        })
    Set-OmniResultMetric -Result $result -Name 'FailedInstallsInRange' -Value $failed.Count

    $groups = @($failed | Group-Object -Property { Get-OmniUpdateGroupKey -Title $_.Title -UpdateId $_.UpdateId } |
            ForEach-Object {
                $sorted = @($_.Group | Sort-Object -Property Date -Descending)
                [pscustomobject]@{ Key = $_.Name; Count = $_.Count; Latest = $sorted[0] }
            } | Sort-Object -Property { $_.Latest.Date } -Descending)
    Set-OmniResultMetric -Result $result -Name 'FailedUpdates' -Value $groups.Count

    foreach ($g in ($groups | Select-Object -First 15)) {
        if ($Context.CancellationToken.IsCancellationRequested) { break }
        $latest = $g.Latest
        $hex = ConvertTo-OmniHResultHex -HResult $latest.HResult
        $resultText = if ($latest.ResultCode -eq 5) { 'aborted' } else { 'failed' }
        # Did the same update install successfully after its last failure?
        $laterSuccess = @($succeeded | Where-Object {
                $_.Date -gt $latest.Date -and (Get-OmniUpdateGroupKey -Title $_.Title -UpdateId $_.UpdateId) -eq $g.Key
            })
        $sev = if ($laterSuccess.Count -gt 0) { 'Information' } else { 'Warning' }
        $tail = if ($laterSuccess.Count -gt 0) { ' It installed successfully afterwards.' } else { ' No later successful installation was recorded.' }
        $label = if ($g.Key -match '^KB\d+$') { $g.Key } else { "$($latest.Title)" }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id (ConvertTo-OmniUpdateFindingId -Key $g.Key) `
            -Title "Update failed to install: $label" -Severity $sev -Component 'Updates/History' `
            -Detail ("'{0}' {1} {2} time(s) in the scan range; most recently on {3:yyyy-MM-dd HH:mm} with error {4}.{5}" -f $latest.Title, $resultText, $g.Count, $latest.Date, $hex, $tail) `
            -LikelyCause 'Download, servicing-stack, disk-space, or component-store problems are the usual causes; the error code identifies which.' -Confidence 60 `
            -Recommendation ("Look up error {0} (Windows Update error code reference), check free space on the system drive, then retry the update. Persistent servicing errors may need the DISM RestoreHealth or SFC repairs." -f $hex) `
            -Data @{ Title = $latest.Title; Count = $g.Count; LastFailure = $latest.Date; HResult = $hex; ResultCode = $latest.ResultCode; UpdateId = $latest.UpdateId })
    }

    # --- Summary ----------------------------------------------------------
    $lastText = if ($null -ne $lastInstall) { '{0:yyyy-MM-dd}' -f [datetime]$lastInstall } else { 'none recorded' }
    $defText = if ($definitions.Count -gt 0) { '{0:yyyy-MM-dd}' -f [datetime]$definitions[0].Date } else { 'none recorded' }
    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'update-history-summary' `
        -Title 'Windows Update history summary' -Severity 'Information' -Component 'Updates/History' `
        -Detail ("Read {0} of {1} history entries. Last successful install (definition updates excluded): {2}. Last definition update: {6}. Failed or aborted installs in {3}: {4} ({5} distinct update(s))." -f `
                $entries.Count, $history.TotalCount, $lastText, $Context.TimeRange.Label, $failed.Count, $groups.Count, $defText))

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
