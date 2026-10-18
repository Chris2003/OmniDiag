<#
.SYNOPSIS
    The curated public PowerShell cmdlets (decision 11) that are not group cmdlets, and
    the deprecation helper for the pre-1.0 names.

.DESCRIPTION
    Invoke-OmniDiagReport, Export-OmniDiagReport, Import-OmniDiagSession,
    Compare-OmniDiagSession, Get-OmniDiagRepair, Invoke-OmniDiagRepair, and
    Show-OmniDiagGui. They are thin, documented wrappers over the existing engine,
    evidence, reporting, repair, and GUI functions; Core/Groups.psm1 holds
    Get-OmniDiagGroup, Get-OmniDiagModule, Invoke-OmniDiagScan, and Get-OmniDiag<Group>.

    Deprecation (0.8.0): the old user-facing names keep working for one minor version
    and print a one-time warning "<old> is deprecated; use <new>." when called from
    outside OmniDiag. Calls made by OmniDiag's own code (any script under src\, and
    OmniDiag.ps1) never warn, and $env:OMNIDIAG_NO_DEPRECATION_WARNING (any value
    except 0 or false) silences the warning entirely.
#>

Set-StrictMode -Version Latest

$script:OmniApiSrcRoot = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$script:OmniApiToolRoot = [System.IO.Path]::GetFullPath((Split-Path $script:OmniApiSrcRoot -Parent))
$script:OmniApiRepairsPath = Join-Path $script:OmniApiSrcRoot 'Repairs'
$script:OmniApiModulesPath = Join-Path $script:OmniApiSrcRoot 'Modules'
$script:OmniDeprecationWarned = @{}

# ---------------------------------------------------------------------------
# Deprecation
# ---------------------------------------------------------------------------

function Test-OmniInternalScriptPath {
    <# .SYNOPSIS Internal: true when a script path belongs to OmniDiag itself (src\ or OmniDiag.ps1). #>
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $src = $script:OmniApiSrcRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($src, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $launcher = Join-Path $script:OmniApiToolRoot 'OmniDiag.ps1'
    return [string]::Equals($full, $launcher, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-OmniDeprecationWarning {
    <#
    .SYNOPSIS
        Internal: warns once per session that a pre-1.0 command name is deprecated.

    .DESCRIPTION
        Called as the first statement of a deprecated command. It looks at that
        command's caller: calls from OmniDiag's own scripts (src\ and OmniDiag.ps1) are
        silent, so users never see warnings caused by OmniDiag itself. Each name warns
        at most once per PowerShell session. Set $env:OMNIDIAG_NO_DEPRECATION_WARNING
        to 1 to silence every deprecation warning.

    .PARAMETER Name
        The deprecated command name.

    .PARAMETER Replacement
        The command to use instead.

    .EXAMPLE
        Write-OmniDeprecationWarning -Name 'Export-OmniReport' -Replacement 'Export-OmniDiagReport'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Replacement
    )

    $optOut = [string]$env:OMNIDIAG_NO_DEPRECATION_WARNING
    if ($optOut -and $optOut -notin @('0', 'false')) { return }
    if ($script:OmniDeprecationWarned.ContainsKey($Name)) { return }

    # Frames: [0] this helper, [1] the deprecated command, [2] whoever called it.
    $stack = @(Get-PSCallStack)
    $callerScript = $null
    if ($stack.Count -gt 2) { $callerScript = $stack[2].ScriptName }
    if (Test-OmniInternalScriptPath -Path $callerScript) { return }

    $script:OmniDeprecationWarned[$Name] = $true
    Write-Warning ("{0} is deprecated; use {1}. The old name will be removed in a future minor version (set OMNIDIAG_NO_DEPRECATION_WARNING=1 to hide this message)." -f $Name, $Replacement)
}

# ---------------------------------------------------------------------------
# Saved sessions
# ---------------------------------------------------------------------------

function Resolve-OmniSessionPath {
    <#
    .SYNOPSIS
        Resolves 'last', 'previous', or a path to a saved session / report file.

    .DESCRIPTION
        'last' is the newest saved session in OmniDiagData\sessions and 'previous' the one
        before it (scans save their session there automatically). Anything else is
        treated as a path (a saved session, a JSON report, a report .zip, or a folder) and
        resolved against the current PowerShell location.

    .PARAMETER Value
        'last', 'previous', or a path.

    .OUTPUTS
        [string] full path.

    .EXAMPLE
        Resolve-OmniSessionPath -Value last
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Value)

    $key = $Value.Trim().ToLowerInvariant()
    if ($key -in @('last', 'previous')) {
        $dir = Get-OmniDataPath -Kind Sessions
        $saved = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true })
        $index = if ($key -eq 'last') { 0 } else { 1 }
        if ($saved.Count -le $index) {
            $need = if ($key -eq 'last') { 'one saved session' } else { 'two saved sessions' }
            throw [System.IO.FileNotFoundException]::new("'$Value' needs at least $need in $dir; run a scan first.")
        }
        return $saved[$index].FullName
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)
    if (-not (Test-Path -LiteralPath $full)) { throw [System.IO.FileNotFoundException]::new("Saved session not found: $Value") }
    return $full
}

function Import-OmniDiagSession {
    <#
    .SYNOPSIS
        Loads a saved OmniDiag session, a JSON report, or a report package.

    .DESCRIPTION
        Reads a native session saved by every scan (OmniDiagData\sessions), a JSON report
        (report schema v1), or a report package .zip, and returns an OmniDiag.Session that
        Export-OmniDiagReport, Compare-OmniDiagSession, Get-OmniDiagRepair -Session, and
        Get-OmniExitCode accept. 'last' and 'previous' pick the newest and second-newest
        saved sessions. Nothing is contacted over the network.

    .PARAMETER Path
        A file or folder path, or 'last' / 'previous'. Accepts pipeline input, including
        FileInfo objects from Get-ChildItem.

    .OUTPUTS
        OmniDiag.Session (with SourcePath set to the file that was read).

    .EXAMPLE
        $session = Import-OmniDiagSession -Path last

    .EXAMPLE
        Get-ChildItem .\cases\*.zip | Import-OmniDiagSession | ForEach-Object { $_.Summary.Score }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path
    )
    process {
        Import-OmniSession -Path (Resolve-OmniSessionPath -Value $Path)
    }
}

function Compare-OmniDiagSession {
    <#
    .SYNOPSIS
        Compares two OmniDiag sessions (before and after a change).

    .DESCRIPTION
        Matches findings by their stable id (and by component plus the number-masked
        title when an id embeds a live value) and classifies them as Resolved, New, or
        Persisting (Improved / Worsened / Unchanged). Only modules that completed in both
        sessions are compared; the rest are listed in OutOfScope. Returns the health-score
        delta, per-module status changes, and an overall Verdict (Improved, Regressed,
        Mixed, Unchanged).

    .PARAMETER Before
        The earlier session: an OmniDiag.Session, a path, or 'last' / 'previous'.

    .PARAMETER After
        The later session: an OmniDiag.Session, a path, or 'last' / 'previous'.

    .OUTPUTS
        OmniDiag.SessionComparison

    .EXAMPLE
        Compare-OmniDiagSession -Before previous -After last

    .EXAMPLE
        $c = Compare-OmniDiagSession -Before .\before.json -After (Invoke-OmniDiagScan -AsSession)
        $c.New | Format-Table Severity, Title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [object] $Before,
        [Parameter(Mandatory, Position = 1)] [object] $After
    )
    if ($Before -is [string]) { $Before = Import-OmniSession -Path (Resolve-OmniSessionPath -Value $Before) }
    if ($After -is [string]) { $After = Import-OmniSession -Path (Resolve-OmniSessionPath -Value $After) }
    Compare-OmniSession -Before $Before -After $After
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

function Assert-OmniRedactionAvailable {
    <# .SYNOPSIS Internal: throws a clear error when the redaction module is missing. #>
    param()
    $ok = (Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue) -and
        (Get-Command ConvertTo-OmniRedacted -ErrorAction SilentlyContinue)
    if ($ok) {
        $export = Get-Command Export-OmniReport -ErrorAction SilentlyContinue
        $ok = [bool]($export -and $export.Parameters.ContainsKey('Redact'))
    }
    if (-not $ok) {
        throw [System.NotSupportedException]::new('Redaction is not available in this build of OmniDiag (New-OmniRedactionContext / Export-OmniReport -Redact are missing).')
    }
}

function Export-OmniDiagReport {
    <#
    .SYNOPSIS
        Writes report files (HTML, JSON, CSV, Markdown, PDF, ZIP package) for a session.

    .DESCRIPTION
        Exports an existing session - from Invoke-OmniDiagScan -AsSession,
        Import-OmniDiagSession, or a saved file - into a folder with one consistent base
        name. JSON follows report schema v1. With -Redact, host names, user names,
        domains, SIDs, profile paths, and IP/MAC addresses are replaced with stable
        pseudonyms in every file and file name; the session itself is not changed.

    .PARAMETER Session
        An OmniDiag.Session, or a path / 'last' / 'previous'. Accepts pipeline input.

    .PARAMETER OutputDirectory
        Folder to write into (created if missing). Default: OmniDiagData\reports.

    .PARAMETER Format
        Any of Html, Json, Csv, Md, Pdf, Zip. Default: Html, Json.

    .PARAMETER Bundle
        Also write the report package (.zip with the HTML, JSON, and CSV files).

    .PARAMETER Redact
        Replace identifying values with stable pseudonyms in every output.

    .PARAMETER RedactionMapPath
        With -Redact: also write the pseudonym-to-value map to this local file (keep it
        private; it reverses the redaction).

    .PARAMETER BaseName
        Base file name without extension. Default: OmniDiag-<computer>-<timestamp>.

    .PARAMETER BrandName
        Organization name for the report header.

    .PARAMETER BrandLogo
        Logo image for HTML and PDF headers.

    .PARAMETER BrandColor
        Accent color (#RRGGBB) for HTML and PDF.

    .PARAMETER Option
        Run options recorded in the JSON report's 'options' object.

    .OUTPUTS
        OmniDiag.ReportSet (OutputDirectory, BaseName, Formats, Files, Warnings).

    .EXAMPLE
        Invoke-OmniDiagScan -Group storage -AsSession | Export-OmniDiagReport -OutputDirectory C:\Cases\1234

    .EXAMPLE
        Export-OmniDiagReport -Session last -Format Html, Json -Bundle -Redact
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [object] $Session,
        [string] $OutputDirectory,
        [ValidateSet('Html', 'Json', 'Csv', 'Md', 'Pdf', 'Zip')]
        [string[]] $Format = @('Html', 'Json'),
        [switch] $Bundle,
        [switch] $Redact,
        [string] $RedactionMapPath,
        [string] $BaseName,
        [string] $BrandName,
        [string] $BrandLogo,
        [string] $BrandColor,
        [hashtable] $Option
    )
    process {
        if ($Session -is [string]) { $Session = Import-OmniSession -Path (Resolve-OmniSessionPath -Value $Session) }
        if ($RedactionMapPath -and -not $Redact) { throw [System.ArgumentException]::new('-RedactionMapPath needs -Redact.') }
        $formats = @($Format)
        if ($Bundle -and 'Zip' -notin $formats) { $formats += 'Zip' }
        $params = @{ Session = $Session; Format = $formats }
        if ($OutputDirectory) { $params.OutputDirectory = $OutputDirectory }
        foreach ($k in @('BaseName', 'BrandName', 'BrandLogo', 'BrandColor', 'Option')) {
            if ($PSBoundParameters.ContainsKey($k)) { $params[$k] = $PSBoundParameters[$k] }
        }
        if ($Redact) {
            Assert-OmniRedactionAvailable
            $params.Redact = $true
            if ($RedactionMapPath) { $params.RedactionMapPath = $RedactionMapPath }
        }
        Export-OmniReport @params
    }
}

function Invoke-OmniDiagReport {
    <#
    .SYNOPSIS
        Runs a scan and writes the report files in one step.

    .DESCRIPTION
        The PowerShell equivalent of 'omnidiag report': runs every scanner (or the
        selection), saves the session to OmniDiagData\sessions, and writes HTML + JSON
        (report schema v1) by default. Connectivity probes run only with -NetworkProbes.
        The returned report set also carries the Session and the scan's ExitCode (see
        Get-OmniExitCodeTable).

    .PARAMETER Group
        Group ids to run. Default: every group.

    .PARAMETER Module
        Scanner ids or names to run (combined with -Group).

    .PARAMETER Profile
        Run a role profile instead (e.g. HelpDesk).

    .PARAMETER Workflow
        Run a task workflow instead (e.g. QuickTriage).

    .PARAMETER NetworkProbes
        Also run connectivity probes (contacts the network).

    .PARAMETER ElevatedOnly
        Run only scanners that need elevation (the process must be elevated).

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER OutputDirectory
        Folder to write into. Default: OmniDiagData\reports.

    .PARAMETER Format
        Any of Html, Json, Csv, Md, Pdf. Default: Html, Json.

    .PARAMETER Bundle
        Also write a single report package (.zip).

    .PARAMETER Redact
        Replace identifying values with stable pseudonyms in every file.

    .PARAMETER RedactionMapPath
        With -Redact: write the local pseudonym map to this file.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src\Modules.

    .OUTPUTS
        OmniDiag.ReportSet with extra Session, SessionPath, and ExitCode properties.

    .EXAMPLE
        Invoke-OmniDiagReport -OutputDirectory C:\Cases\1234

    .EXAMPLE
        $set = Invoke-OmniDiagReport -Group network -NetworkProbes -Bundle -Redact; $set.Files
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Group,
        [string[]] $Module,
        [ValidateSet('HelpDesk', 'DesktopSupport', 'SystemsAdmin', 'NetworkAdmin', 'SecurityAdmin', 'CloudAdmin', 'Full')]
        [string] $Profile,
        [ValidateSet('QuickTriage', 'SlowComputer', 'NetworkConnectivity', 'Printing', 'WindowsUpdate', 'LoginAndIdentity', 'StorageCleanup', 'SecurityPosture', 'CloudReadiness', 'FullScan')]
        [string] $Workflow,
        [switch] $NetworkProbes,
        [switch] $ElevatedOnly,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
        [string] $Range = 'Last7Days',
        [string] $OutputDirectory,
        [ValidateSet('Html', 'Json', 'Csv', 'Md', 'Pdf')]
        [string[]] $Format = @('Html', 'Json'),
        [switch] $Bundle,
        [switch] $Redact,
        [string] $RedactionMapPath,
        [string[]] $ModulesPath = $script:OmniApiModulesPath
    )

    if ($Redact) { Assert-OmniRedactionAvailable }
    $scan = @{ AsSession = $true; Range = $Range; ModulesPath = $ModulesPath }
    foreach ($k in @('Group', 'Module', 'Profile', 'Workflow', 'NetworkProbes', 'ElevatedOnly')) {
        if ($PSBoundParameters.ContainsKey($k)) { $scan[$k] = $PSBoundParameters[$k] }
    }
    $session = Invoke-OmniDiagScan @scan
    $saved = $null
    try { $saved = Save-OmniSession -Session $session } catch { Write-Warning "Could not save the session: $($_.Exception.Message)" }

    $option = @{ command = 'report'; range = $Range }
    if ($Group) { $option.groups = @($Group) }
    if ($Module) { $option.modules = @($Module) }
    if ($Profile) { $option.plan = $Profile } elseif ($Workflow) { $option.plan = $Workflow }
    if ($NetworkProbes) { $option.networkProbes = $true }

    $export = @{ Session = $session; Format = $Format; Bundle = $Bundle; Redact = $Redact; Option = $option }
    if ($OutputDirectory) { $export.OutputDirectory = $OutputDirectory }
    if ($RedactionMapPath) { $export.RedactionMapPath = $RedactionMapPath }
    $set = Export-OmniDiagReport @export
    Add-Member -InputObject $set -MemberType NoteProperty -Name Session -Value $session -Force
    Add-Member -InputObject $set -MemberType NoteProperty -Name SessionPath -Value $saved -Force
    Add-Member -InputObject $set -MemberType NoteProperty -Name ExitCode -Value (Get-OmniExitCode -Session $session -ExplicitSelection:([bool]$Module)) -Force
    return $set
}

# ---------------------------------------------------------------------------
# Repairs
# ---------------------------------------------------------------------------

function Resolve-OmniRepairSelection {
    <#
    .SYNOPSIS
        Internal: maps repair ids / names to registrations, in the order given.
    .DESCRIPTION
        Accepts the full id (repair.flush-dns-cache), the id without the 'repair.' prefix
        (flush-dns-cache), or the display name (Flush DNS Cache), case-insensitively. Throws an
        ArgumentException naming every unknown value.
    #>
    param([object[]] $Registration, [string[]] $Id)
    $chosen = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($want in @($Id | Where-Object { $_ })) {
        $w = ([string]$want).Trim()
        $hit = @($Registration | Where-Object { $_.Id -ieq $w -or $_.Id -ieq "repair.$w" -or $_.Name -ieq $w })
        if ($hit.Count -eq 0) { $unknown.Add($w); continue }
        if (-not ($chosen | Where-Object { $_.Id -eq $hit[0].Id })) { $chosen.Add($hit[0]) }
    }
    if ($unknown.Count -gt 0) {
        $ex = [System.ArgumentException]::new("Unknown repair: $($unknown -join ', '). List the ids with Get-OmniDiagRepair or 'omnidiag repair list'.")
        $ex.Data['OmniUnknownRepair'] = @($unknown)
        throw $ex
    }
    return , $chosen.ToArray()
}

function Get-OmniRepairRunExitCode {
    <#
    .SYNOPSIS
        Exit code for a repair run: 4, 11, 12, or 0.

    .DESCRIPTION
        4 when the run applied changes (not a dry run), the process is not elevated, and
        every requested repair needs elevation; otherwise Get-OmniRepairExitCode
        (11 a repair failed, 12 a reboot is required, 0 otherwise).

    .PARAMETER RepairSession
        The OmniDiag.RepairSession (or $null when nothing ran).

    .PARAMETER Registration
        The requested repair registrations.

    .PARAMETER IsAdmin
        Whether the process is elevated.

    .PARAMETER DryRun
        Whether the run was a dry run.

    .EXAMPLE
        Get-OmniRepairRunExitCode -RepairSession $s -Registration $regs -IsAdmin $false
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()] [object] $RepairSession,
        [object[]] $Registration = @(),
        [bool] $IsAdmin,
        [switch] $DryRun
    )
    $regs = @($Registration | Where-Object { $_ })
    if (-not $DryRun -and -not $IsAdmin -and $regs.Count -gt 0 -and
        @($regs | Where-Object { -not $_.RequiresElevation }).Count -eq 0) { return 4 }
    return (Get-OmniRepairExitCode -RepairSession $RepairSession)
}

function Get-OmniDiagRepair {
    <#
    .SYNOPSIS
        Lists the repairs OmniDiag can run.

    .DESCRIPTION
        Discovers the repair plugins (src\Repairs) and returns one registration per
        repair: Id, Name, Category, Risk (Safe, Moderate, Destructive), RequiresElevation,
        RestorePoint, RebootHint, NetworkAccess, and Description. With -Session, each
        repair's Recommended flag says whether it addresses a finding in that session.
        Listing never runs or changes anything.

    .PARAMETER Id
        Only these repairs (full id, id without 'repair.', or name).

    .PARAMETER Session
        An OmniDiag.Session, a path, or 'last' / 'previous'; sets Recommended.

    .PARAMETER RecommendedOnly
        With -Session: return only the recommended repairs.

    .PARAMETER RepairsPath
        Repair plugin folder. Default: the bundled src\Repairs.

    .OUTPUTS
        OmniDiag.RepairRegistration

    .EXAMPLE
        Get-OmniDiagRepair | Format-Table Id, Risk, RequiresElevation, Name

    .EXAMPLE
        Get-OmniDiagRepair -Session last -RecommendedOnly | Invoke-OmniDiagRepair -WhatIf
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)] [string[]] $Id,
        [object] $Session,
        [switch] $RecommendedOnly,
        [string] $RepairsPath = $script:OmniApiRepairsPath
    )
    $logger = New-OmniLogger -MinimumLevel Error
    $repairs = @(Get-OmniRepair -Path $RepairsPath -Logger $logger)
    if ($Session) {
        if ($Session -is [string]) { $Session = Import-OmniSession -Path (Resolve-OmniSessionPath -Value $Session) }
        $repairs = @(Get-OmniApplicableRepair -Registration $repairs -Session $Session)
        if ($RecommendedOnly) { $repairs = @($repairs | Where-Object { $_.Recommended }) }
    } elseif ($RecommendedOnly) {
        throw [System.ArgumentException]::new('-RecommendedOnly needs -Session.')
    }
    if ($Id) { $repairs = Resolve-OmniRepairSelection -Registration $repairs -Id $Id }
    $repairs
}

function Invoke-OmniDiagRepair {
    <#
    .SYNOPSIS
        Runs repairs, with a dry run (-WhatIf) and per-repair confirmation.

    .DESCRIPTION
        Runs the named repairs through the repair engine and returns the repair session.
        Nothing changes without confirmation: ConfirmImpact is High, so PowerShell asks
        before each repair. -WhatIf is a dry run: every repair describes what it would
        do, no action runs, and nothing is written to the audit log. For scripts, pass
        -Confirm:$false (or -Force) to skip the prompts.

        Applied repair steps are appended to OmniDiagData\logs\repair-audit.jsonl (one
        JSON line per step). Repairs that need elevation are skipped (not failed) when
        PowerShell is not elevated; repairs that promise a System Restore point are
        skipped when none can be created, unless -AllowWithoutRestorePoint.

        The returned session carries ExitCode, the same value 'omnidiag repair run'
        exits with: 11 a repair failed, 12 a reboot is required, 4 every requested
        repair needs elevation and the process is not elevated, 0 otherwise.

    .PARAMETER Id
        Repairs to run: full id (repair.flush-dns-cache), id without 'repair.', or name.
        Accepts pipeline input from Get-OmniDiagRepair.

    .PARAMETER Force
        Do not ask for confirmation (same as -Confirm:$false), unless -Confirm is given.

    .PARAMETER AllowWithoutRestorePoint
        Run repairs that require a System Restore point even when none could be created.

    .PARAMETER RepairsPath
        Repair plugin folder. Default: the bundled src\Repairs.

    .PARAMETER Config
        Options handed to the repairs through the repair context.

    .PARAMETER CancellationToken
        Cooperative cancellation token.

    .OUTPUTS
        OmniDiag.RepairSession (DryRun, RestorePoint, RebootRequired, Results, ExitCode).

    .EXAMPLE
        Invoke-OmniDiagRepair -Id flush-dns-cache -WhatIf

    .EXAMPLE
        Invoke-OmniDiagRepair -Id flush-dns-cache, restart-print-spooler -Confirm:$false

    .EXAMPLE
        Get-OmniDiagRepair -Session last -RecommendedOnly | Invoke-OmniDiagRepair
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]] $Id,
        [switch] $Force,
        [switch] $AllowWithoutRestorePoint,
        [string] $RepairsPath = $script:OmniApiRepairsPath,
        [hashtable] $Config = @{},
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None)
    )

    begin {
        $requested = [System.Collections.Generic.List[string]]::new()
    }
    process {
        foreach ($i in @($Id)) { if ($i) { $requested.Add([string]$i) } }
    }
    end {
        $dryRun = [bool]$WhatIfPreference
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $logger = New-OmniLogger -Path (Get-OmniDataPath -Kind Logs -ChildPath "omnidiag-repair-$stamp.jsonl") -MinimumLevel Info -Console:$false
        $all = @(Get-OmniRepair -Path $RepairsPath -Logger $logger)
        $regs = Resolve-OmniRepairSelection -Registration $all -Id $requested.ToArray()
        if (@($regs).Count -eq 0) { throw [System.ArgumentException]::new('No repairs were named.') }

        $confirmed = [System.Collections.Generic.List[object]]::new()
        foreach ($reg in $regs) {
            $target = '{0} [{1}]' -f $reg.Name, $reg.Id
            $action = 'Apply repair (risk: {0}{1})' -f $reg.Risk, $(if ($reg.RequiresElevation) { ', needs elevation' } else { '' })
            # Under -WhatIf this prints "What if: ..." and returns $false; the dry run below
            # then describes every repair without running any action.
            if ($PSCmdlet.ShouldProcess($target, $action) -or $dryRun) { $confirmed.Add($reg) }
        }
        if ($confirmed.Count -eq 0) { return }

        $ctx = New-OmniRepairContext -Logger $logger -DryRun:$dryRun -CancellationToken $CancellationToken -Config $Config
        $session = Invoke-OmniRepair -Registration $confirmed.ToArray() -Context $ctx `
            -AllowWithoutRestorePoint:$AllowWithoutRestorePoint -Confirm:$false -WhatIf:$false
        $code = Get-OmniRepairRunExitCode -RepairSession $session -Registration $regs -IsAdmin ([bool]$ctx.IsAdmin) -DryRun:$dryRun
        Add-Member -InputObject $session -MemberType NoteProperty -Name ExitCode -Value $code -Force
        Add-Member -InputObject $session -MemberType NoteProperty -Name LogPath -Value $logger.Path -Force
        return $session
    }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

function Test-OmniWindowsHost {
    <# .SYNOPSIS Internal: true on Windows (works on Windows PowerShell 5.1 and PowerShell 7). #>
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Show-OmniDiagGui {
    <#
    .SYNOPSIS
        Opens the OmniDiag window (Windows only).

    .DESCRIPTION
        Starts the WPF GUI: scan by group, drill into findings, export (including
        redacted reports), compare sessions, and run repairs after confirmation. On
        PowerShell 7 (an MTA thread) the window is hosted on a dedicated STA thread. The
        call returns when the window closes. Throws PlatformNotSupportedException on
        non-Windows hosts.

    .PARAMETER Theme
        Initial theme: Light (default) or Dark.

    .PARAMETER ModulesPath
        Scanner plugin folder. Default: the bundled src\Modules.

    .PARAMETER RepairsPath
        Repair plugin folder. Default: the bundled src\Repairs.

    .OUTPUTS
        None.

    .EXAMPLE
        Show-OmniDiagGui

    .EXAMPLE
        Show-OmniDiagGui -Theme Dark
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Dark', 'Light')] [string] $Theme = 'Light',
        [string] $ModulesPath = $script:OmniApiModulesPath,
        [string] $RepairsPath = $script:OmniApiRepairsPath
    )
    if (-not (Test-OmniWindowsHost)) { throw [System.PlatformNotSupportedException]::new('The OmniDiag GUI needs Windows (WPF).') }
    if (-not (Get-Command Show-OmniDiagWindow -ErrorAction SilentlyContinue)) { throw [System.NotSupportedException]::new('The OmniDiag GUI module is not loaded.') }
    Show-OmniDiagWindow -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme
}

Export-ModuleMember -Function @(
    'Write-OmniDeprecationWarning', 'Resolve-OmniSessionPath', 'Get-OmniRepairRunExitCode',
    'Import-OmniDiagSession', 'Compare-OmniDiagSession',
    'Export-OmniDiagReport', 'Invoke-OmniDiagReport',
    'Get-OmniDiagRepair', 'Invoke-OmniDiagRepair', 'Show-OmniDiagGui'
)
