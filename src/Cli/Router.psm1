<#
.SYNOPSIS
    The omnidiag command-line router (GNU-style arguments).

.DESCRIPTION
    Invoke-OmniDiagCli parses an argument vector such as
        list modules --format json
        scan --group network --module security.bitlocker -o out\
        report --output C:\Reports
    runs the command, and returns a process exit code (see Get-OmniExitCodeTable).
    It is surface code only: discovery, execution, projection, and export are the
    existing core and reporting functions.

    Output contract:
      * Data (JSON report schema v1, CSV, Markdown) goes to stdout only when
        --format is given without --output.
      * Progress and status go to stderr (suppressed by --quiet); usage errors go
        to stderr with exit code 10.
      * When no data is emitted, the human-readable result (tables, summary, help)
        goes to stdout.

    Both writers are parameters so tests (and hosts) can capture them; by default
    they are the process's standard output and standard error.

    Group shorthand: 'omnidiag <group-id> [options]' is 'omnidiag scan --group <group-id>
    [options]' (e.g. 'omnidiag network --network-probes --format json').

    Network policy (decision 1): every scanner runs by default, but connectivity probes
    (pinging the gateway / a public address, resolving a public name, the domain
    secure-channel check) run only with --network-probes. Without it, scanners that
    declare NetworkAccess other than 'None' do their local work and add an Information
    finding saying how to run the probe.
#>

Set-StrictMode -Version Latest

$script:OmniCliCommands = @('list', 'scan', 'report', 'version', 'help')
$script:OmniCliFormats = @('json', 'csv', 'md', 'html', 'pdf')
$script:OmniCliStdoutFormats = @('json', 'csv', 'md')
$script:OmniCliListKinds = @('modules', 'groups', 'repairs', 'plans')
$script:OmniCliDocSchemaVersion = '1.0.0'

# Long options: name -> [kind, target]. kind: list (repeatable, comma-separated), value, flag.
$script:OmniCliOptions = @{
    'format'   = @('list', 'Format')
    'output'   = @('value', 'Output')
    'group'    = @('list', 'Group')
    'module'   = @('list', 'Module')
    'profile'  = @('value', 'Profile')
    'workflow' = @('value', 'Workflow')
    'range'    = @('value', 'Range')
    'network-probes' = @('flag', 'NetworkProbes')
    'verbose'  = @('flag', 'Verbose')
    'quiet'    = @('flag', 'Quiet')
    'no-color' = @('flag', 'NoColor')
    'help'     = @('flag', 'Help')
    'version'  = @('flag', 'Version')
}
$script:OmniCliShortOptions = @{ 'h' = 'help'; '?' = 'help'; 'q' = 'quiet'; 'o' = 'output'; 'f' = 'format'; 'g' = 'group'; 'm' = 'module' }

# Which options each command accepts (global options are accepted everywhere).
$script:OmniCliGlobalOptions = @('format', 'output', 'verbose', 'quiet', 'no-color', 'help', 'version')
$script:OmniCliCommandOptions = @{
    list    = @()
    scan    = @('group', 'module', 'profile', 'workflow', 'range', 'network-probes')
    report  = @('range', 'network-probes')
    version = @()
    help    = @()
}

$script:OmniCliRanges = [ordered]@{
    'last24hours' = 'Last24Hours'; '24h' = 'Last24Hours'
    'last7days'   = 'Last7Days';   '7d'  = 'Last7Days'
    'last30days'  = 'Last30Days';  '30d' = 'Last30Days'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-OmniCliUsageError {
    <# .SYNOPSIS Internal: an exception the router maps to exit code 10. #>
    param([string] $Message)
    $ex = [System.ArgumentException]::new($Message)
    $ex.Data['OmniCliUsage'] = $true
    return $ex
}

function Get-OmniCliUsage {
    <#
    .SYNOPSIS
        Returns the omnidiag CLI usage text (optionally for one command).

    .PARAMETER Command
        list, scan, report, version, help, or a group id (the 'omnidiag <group>'
        shorthand). Omit for the overview.

    .EXAMPLE
        Get-OmniCliUsage -Command scan
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Command)

    $groups = (Get-OmniGroupNames) -join ', '
    $nl = [Environment]::NewLine
    if ($Command -and $Command -in (Get-OmniGroupNames)) {
        $display = [string](@(Get-OmniGroup | Where-Object { $_.Id -eq $Command })[0].DisplayName)
        return (@(
            "Usage: omnidiag $Command [--module <id>]... [--network-probes] [--range <preset>] [--format <fmt>] [--output <path>]",
            '',
            "Runs the '$display' group: the same as 'omnidiag scan --group $Command'. Every scanner",
            'runs locally; --network-probes also runs the connectivity probes (it contacts the network).',
            "List the group's scanners with 'omnidiag list modules'."
        ) -join $nl)
    }
    switch ($Command) {
        'list' {
            return (@(
                'Usage: omnidiag list [modules|groups|repairs|plans] [--format json|csv|md] [--output <file>]',
                '',
                'Lists the scanners (default), module groups, repairs, or role profiles and task',
                'workflows. --format json emits a versioned document (schemaVersion, kind, items).'
            ) -join $nl)
        }
        'scan' {
            return (@(
                'Usage: omnidiag scan [--group <id>]... [--module <id>]... [--profile <name> | --workflow <name>]',
                '                     [--network-probes] [--range Last24Hours|Last7Days|Last30Days]',
                '                     [--format <fmt>] [--output <path>]',
                '       omnidiag <group> [options]     (same as scan --group <group>)',
                '',
                'Runs scanners and summarizes the findings. With no selection every scanner runs.',
                '--group and --module may be repeated or given as a comma list and are combined.',
                'Connectivity probes (ping the gateway and 1.1.1.1, resolve www.microsoft.com, the',
                'domain secure-channel check) run only with --network-probes; without it those',
                'scanners do their local checks and say how to run the probe.',
                '',
                "Groups: $groups",
                'Profiles: ' + ((Get-OmniRoleProfile).Name -join ', '),
                'Workflows: ' + ((Get-OmniTaskWorkflow).Name -join ', ')
            ) -join $nl)
        }
        'report' {
            return (@(
                'Usage: omnidiag report [--output <directory>] [--format <fmt>] [--range <preset>] [--network-probes]',
                '',
                'Runs every scanner (connectivity probes only with --network-probes) and writes an',
                'HTML report plus a JSON report (schema v1) to --output, or to OmniDiagData\reports',
                'next to the tool. --format replaces the default html,json set (json, csv, md, html, pdf).'
            ) -join $nl)
        }
        'version' { return 'Usage: omnidiag version [--format json]' }
        'help'    { return 'Usage: omnidiag help [command]' }
    }

    return (@(
        'Usage: omnidiag <command> [options]',
        '',
        'Commands:',
        '  list [modules|groups|repairs|plans]  List scanners (default), groups, repairs, or plans',
        '  scan [selection]                     Run scanners and summarize the findings',
        '  <group> [options]                    Run one group (same as scan --group <group>)',
        '  report                               Run every scanner; write HTML + JSON',
        '  version                              Show the OmniDiag version',
        '  help [command|group]                 Show help for a command',
        '',
        'Scan selection:',
        '  -g, --group <id>       Run a module group (repeatable or comma list)',
        '  -m, --module <id>      Run one scanner by id (repeatable or comma list)',
        '      --profile <name>   Run a role profile (e.g. HelpDesk)',
        '      --workflow <name>  Run a task workflow (e.g. QuickTriage)',
        '      --range <preset>   Event time range: Last24Hours, Last7Days (default), Last30Days',
        '      --network-probes   Also run connectivity probes (contacts the network; off by default)',
        '',
        'Global options:',
        '  -f, --format <fmt>     json, csv, md, html, pdf (repeatable or comma list)',
        '  -o, --output <path>    Write to a file or directory instead of stdout',
        '      --verbose          Record Debug-level entries in the local log file',
        '  -q, --quiet            No progress or status messages on stderr',
        '      --no-color         Plain output (no colors)',
        '  -h, --help             Show help',
        '',
        'Data (json, csv, md) goes to stdout only when --format is given without --output;',
        'progress and status go to stderr.',
        '',
        'Exit codes: 0 ok, 1 warnings, 2 critical, 3 partial, 4 needs elevation, 5 cancelled,',
        '            10 usage error, 11 repair failed, 12 reboot required, 20 internal error.',
        "Groups: $groups"
    ) -join $nl)
}

function ConvertFrom-OmniCliArgument {
    <#
    .SYNOPSIS
        Internal: parses GNU-style arguments into a command, positionals, and options.
        Throws a usage error (exit 10) for unknown or malformed options.
    #>
    param([string[]] $Arguments)

    $opts = @{
        Format = [System.Collections.Generic.List[string]]::new()
        Group  = [System.Collections.Generic.List[string]]::new()
        Module = [System.Collections.Generic.List[string]]::new()
        Output = $null; Profile = $null; Workflow = $null; Range = $null
        Verbose = $false; Quiet = $false; NoColor = $false; Help = $false; Version = $false
        NetworkProbes = $false
    }
    $given = [System.Collections.Generic.List[string]]::new()
    $positionals = [System.Collections.Generic.List[string]]::new()
    $endOfOptions = $false
    $args2 = @($Arguments | Where-Object { $null -ne $_ })

    for ($i = 0; $i -lt $args2.Count; $i++) {
        $tok = [string]$args2[$i]
        if ($endOfOptions) { $positionals.Add($tok); continue }
        if ($tok -eq '--') { $endOfOptions = $true; continue }
        if ($tok -eq '/?') { $opts.Help = $true; continue }

        $name = $null; $value = $null; $hasValue = $false; $display = $tok
        if ($tok.StartsWith('--')) {
            $name = $tok.Substring(2)
            $eq = $name.IndexOf('=')
            if ($eq -ge 0) { $value = $name.Substring($eq + 1); $name = $name.Substring(0, $eq); $hasValue = $true; $display = "--$name" }
            $name = $name.ToLowerInvariant()
        } elseif ($tok.StartsWith('-') -and $tok.Length -gt 1) {
            $short = $tok.Substring(1)
            if ($short.Length -ne 1 -or -not $script:OmniCliShortOptions.ContainsKey($short.ToLowerInvariant())) {
                throw (New-OmniCliUsageError "unknown option '$tok'")
            }
            $name = $script:OmniCliShortOptions[$short.ToLowerInvariant()]
        } else {
            $positionals.Add($tok)
            continue
        }

        if (-not $script:OmniCliOptions.ContainsKey($name)) { throw (New-OmniCliUsageError "unknown option '$display'") }
        $kind = $script:OmniCliOptions[$name][0]
        $target = $script:OmniCliOptions[$name][1]
        if ($kind -eq 'flag') {
            if ($hasValue) { throw (New-OmniCliUsageError "option '--$name' does not take a value") }
            $opts[$target] = $true
        } else {
            if (-not $hasValue) {
                if ($i + 1 -ge $args2.Count) { throw (New-OmniCliUsageError "option '--$name' requires a value") }
                $i++
                $value = [string]$args2[$i]
            }
            if ([string]::IsNullOrWhiteSpace($value)) { throw (New-OmniCliUsageError "option '--$name' requires a value") }
            if ($kind -eq 'list') {
                foreach ($part in ($value -split ',')) {
                    $p = $part.Trim()
                    if ($p) { $opts[$target].Add($p) }
                }
            } else {
                $opts[$target] = $value
            }
        }
        if (-not $given.Contains($name)) { $given.Add($name) }
    }

    $command = $null
    if ($positionals.Count -gt 0) {
        $command = $positionals[0].ToLowerInvariant()
        $positionals.RemoveAt(0)
    }
    return [pscustomobject]@{
        Command     = $command
        Positionals = @($positionals)
        Options     = $opts
        Given       = @($given)
    }
}

function Write-OmniCliStatus {
    <# .SYNOPSIS Internal: human status line on stderr unless --quiet. #>
    param($Io, [string] $Message)
    if (-not $Io.Quiet) { $Io.Err.WriteLine($Message) }
}

function Get-OmniCliFormat {
    <# .SYNOPSIS Internal: normalized, validated, de-duplicated --format values. #>
    param([System.Collections.Generic.List[string]] $Format)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Format) {
        $n = $f.ToLowerInvariant()
        if ($n -eq 'markdown') { $n = 'md' }
        if ($n -notin $script:OmniCliFormats) {
            throw (New-OmniCliUsageError "unknown format '$f' (valid: $($script:OmniCliFormats -join ', '))")
        }
        if (-not $out.Contains($n)) { $out.Add($n) }
    }
    return , $out.ToArray()
}

function Get-OmniCliFormatFromPath {
    <# .SYNOPSIS Internal: format implied by an --output file extension, or $null. #>
    param([string] $Path)
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    switch ($ext) {
        'json'     { return 'json' }
        'csv'      { return 'csv' }
        'md'       { return 'md' }
        'markdown' { return 'md' }
        'html'     { return 'html' }
        'htm'      { return 'html' }
        'pdf'      { return 'pdf' }
    }
    return $null
}

function Resolve-OmniCliPath {
    <# .SYNOPSIS Internal: resolve a path against PowerShell's location (not the process directory). #>
    param([string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-OmniCliDirectoryTarget {
    <# .SYNOPSIS Internal: true when --output names a directory (existing, trailing separator, or no extension). #>
    param([string] $Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return $true }
    if ($Path.EndsWith('/') -or $Path.EndsWith('\')) { return $true }
    return (-not [System.IO.Path]::GetExtension($Path))
}

function Write-OmniCliFile {
    <# .SYNOPSIS Internal: write text as UTF-8 without BOM, creating the folder. #>
    param([string] $Path, [string] $Content)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-OmniCliCsv {
    <# .SYNOPSIS Internal: rows -> CSV text with spreadsheet formulas neutralized. #>
    param([object[]] $Rows)
    if (@($Rows).Count -eq 0) { return '' }
    $safe = foreach ($row in $Rows) {
        $copy = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [System.Array]) { $v = (@($v) | ForEach-Object { [string]$_ }) -join ';' }
            if ($v -is [string] -and $v -match '^[=+\-@\t\r]') { $v = "'" + $v }
            $copy[$p.Name] = $v
        }
        [pscustomobject]$copy
    }
    return ((@($safe) | ConvertTo-Csv -NoTypeInformation) -join "`n") + "`n"
}

function ConvertTo-OmniCliMarkdownTable {
    <# .SYNOPSIS Internal: rows -> Markdown table (cells escaped). #>
    param([object[]] $Rows, [string] $Title)
    $nl = "`n"
    $sb = [System.Text.StringBuilder]::new()
    if ($Title) { [void]$sb.Append('# ').Append($Title).Append($nl).Append($nl) }
    if (@($Rows).Count -eq 0) { [void]$sb.Append('_No items._').Append($nl); return $sb.ToString() }
    $cols = @($Rows[0].PSObject.Properties.Name)
    $esc = {
        param($v)
        if ($v -is [System.Array]) { $v = (@($v) | ForEach-Object { [string]$_ }) -join ', ' }
        $s = [string]$v
        $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('|', '\|')
        [regex]::Replace($s, '\r?\n', ' ')
    }
    [void]$sb.Append('| ').Append(($cols -join ' | ')).Append(' |').Append($nl)
    [void]$sb.Append('|').Append((@($cols | ForEach-Object { ' --- ' }) -join '|')).Append('|').Append($nl)
    foreach ($r in $Rows) {
        $cells = foreach ($c in $cols) { & $esc $r.$c }
        [void]$sb.Append('| ').Append((@($cells) -join ' | ')).Append(' |').Append($nl)
    }
    return $sb.ToString()
}

function Format-OmniCliTable {
    <# .SYNOPSIS Internal: fixed-width text table (no colors) for human output. #>
    param([object[]] $Rows, [string[]] $Column)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (@($Rows).Count -eq 0) { $lines.Add('(none)'); return , $lines.ToArray() }
    $widths = @{}
    foreach ($c in $Column) {
        $w = $c.Length
        foreach ($r in $Rows) { $len = ([string]$r.$c).Length; if ($len -gt $w) { $w = $len } }
        $widths[$c] = [math]::Min($w, 60)
    }
    $fmt = { param($vals) ((@(for ($k = 0; $k -lt $Column.Count; $k++) {
        $v = [string]$vals[$k]
        if ($v.Length -gt $widths[$Column[$k]]) { $v = $v.Substring(0, $widths[$Column[$k]] - 3) + '...' }
        if ($k -lt $Column.Count - 1) { $v.PadRight($widths[$Column[$k]]) } else { $v }
    })) -join '  ').TrimEnd() }
    $lines.Add((& $fmt ([object[]]@($Column | ForEach-Object { $_.ToUpperInvariant() }))))
    foreach ($r in $Rows) { $lines.Add((& $fmt ([object[]]@($Column | ForEach-Object { $r.$_ })))) }
    return , $lines.ToArray()
}

function Get-OmniCliToolVersion {
    <# .SYNOPSIS Internal: OmniDiag version string from the manifest. #>
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'OmniDiag.psd1'
    return [string](Import-PowerShellDataFile -Path $manifest).ModuleVersion
}

function New-OmniCliLogger {
    <# .SYNOPSIS Internal: per-run JSONL logger in OmniDiagData\logs (Debug with --verbose). #>
    param([bool] $VerboseLog, [string] $Name = 'omnidiag-cli')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $path = Get-OmniDataPath -Kind Logs -ChildPath "$Name-$stamp.jsonl"
    $level = if ($VerboseLog) { 'Debug' } else { 'Info' }
    return (New-OmniLogger -Path $path -MinimumLevel $level)
}

function Write-OmniCliDiscoveryError {
    <# .SYNOPSIS Internal: surface plugin load failures (logged as Error) on stderr. #>
    param($Io, $Logger)
    foreach ($rec in @($Logger.Buffer | Where-Object { $_.Level -eq 'Error' -and $_.Component -in @('Registry', 'RepairRegistry') })) {
        Write-OmniCliStatus $Io ("omnidiag: warning: {0}" -f $rec.Message)
    }
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

function Get-OmniCliListItem {
    <# .SYNOPSIS Internal: the items for 'list <kind>' as ordered rows. #>
    param([string] $Kind, [string[]] $ModulesPath, [string] $RepairsPath, $Logger)

    switch ($Kind) {
        'modules' {
            foreach ($r in @(Get-OmniModule -Path $ModulesPath -Logger $Logger)) {
                [pscustomobject][ordered]@{
                    id                     = $r.Id
                    name                   = $r.Name
                    group                  = $r.Group
                    category               = $r.Category
                    requiresElevation      = [bool]$r.RequiresElevation
                    networkAccess          = $r.NetworkAccess
                    timeoutSec             = [int]$r.TimeoutSec
                    supportedArchitectures = @($r.SupportedArchitectures)
                    enabled                = [bool]$r.Enabled
                    description            = $r.Description
                }
            }
        }
        'groups' {
            $regs = @(Get-OmniModule -Path $ModulesPath -Logger $Logger)
            foreach ($g in @(Get-OmniGroup)) {
                [pscustomobject][ordered]@{
                    id          = $g.Id
                    name        = $g.DisplayName
                    moduleCount = @($regs | Where-Object { $_.Group -eq $g.Id }).Count
                }
            }
        }
        'repairs' {
            foreach ($r in @(Get-OmniRepair -Path $RepairsPath -Logger $Logger)) {
                [pscustomobject][ordered]@{
                    id                = $r.Id
                    name              = $r.Name
                    category          = $r.Category
                    risk              = $r.Risk
                    requiresElevation = [bool]$r.RequiresElevation
                    networkAccess     = $r.NetworkAccess
                    restorePoint      = [bool]$r.RestorePoint
                    rebootHint        = [bool]$r.RebootHint
                    description       = $r.Description
                }
            }
        }
        'plans' {
            $regs = @(Get-OmniModule -Path $ModulesPath -Logger $Logger)
            $idOf = @{}
            foreach ($r in $regs) { $idOf[$r.Name] = $r.Id }
            $plans = @(foreach ($p in @(Get-OmniRoleProfile)) { , @('profile', $p) }) + @(foreach ($w in @(Get-OmniTaskWorkflow)) { , @('workflow', $w) })
            foreach ($pair in $plans) {
                $plan = $pair[1]
                $ids = @(foreach ($n in @($plan.Modules)) {
                    if ($idOf.ContainsKey($n)) { $idOf[$n] } else { (Resolve-OmniModuleIdentity -Name $n).Id }
                })
                [pscustomobject][ordered]@{
                    name        = $plan.Name
                    type        = $pair[0]
                    description = $plan.Description
                    allModules  = (@($plan.Modules).Count -eq 0)
                    moduleIds   = $ids
                }
            }
        }
    }
}

function Invoke-OmniCliList {
    <# .SYNOPSIS Internal: 'omnidiag list'. #>
    param($Parsed, $Io, [string[]] $ModulesPath, [string] $RepairsPath)

    if (@($Parsed.Positionals).Count -gt 1) { throw (New-OmniCliUsageError "unexpected argument '$($Parsed.Positionals[1])'") }
    $kind = if (@($Parsed.Positionals).Count -eq 1) { $Parsed.Positionals[0].ToLowerInvariant() } else { 'modules' }
    if ($kind -notin $script:OmniCliListKinds) { throw (New-OmniCliUsageError "unknown list kind '$kind' (valid: $($script:OmniCliListKinds -join ', '))") }

    $formats = Get-OmniCliFormat $Parsed.Options.Format
    $output = $Parsed.Options.Output
    if ($output) { $output = Resolve-OmniCliPath $output }
    if (@($formats).Count -eq 0 -and $output) {
        $implied = Get-OmniCliFormatFromPath $output
        $formats = @(if ($implied) { $implied } else { 'json' })
    }
    foreach ($f in $formats) {
        if ($f -notin $script:OmniCliStdoutFormats) { throw (New-OmniCliUsageError "list supports --format json, csv, or md (not '$f')") }
    }
    if (@($formats).Count -gt 1 -and -not ($output -and (Test-OmniCliDirectoryTarget $output))) {
        throw (New-OmniCliUsageError 'several formats need --output <directory>')
    }

    $logger = New-OmniLogger -MinimumLevel Error
    $items = @(Get-OmniCliListItem -Kind $kind -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Logger $logger)
    Write-OmniCliDiscoveryError $Io $logger

    if (@($formats).Count -eq 0) {
        $columns = switch ($kind) {
            'modules' { @('id', 'group', 'networkAccess', 'requiresElevation', 'name') }
            'groups'  { @('id', 'moduleCount', 'name') }
            'repairs' { @('id', 'risk', 'networkAccess', 'requiresElevation', 'name') }
            'plans'   { @('name', 'type', 'description') }
        }
        foreach ($line in (Format-OmniCliTable -Rows $items -Column $columns)) { $Io.Out.WriteLine($line) }
        return 0
    }

    foreach ($fmt in $formats) {
        $text = switch ($fmt) {
            'json' {
                (ConvertTo-OmniJsonText -InputObject ([ordered]@{
                    schemaVersion = $script:OmniCliDocSchemaVersion
                    kind          = $kind
                    tool          = [ordered]@{ name = 'OmniDiag'; version = (Get-OmniCliToolVersion) }
                    items         = $items
                })) + "`n"
            }
            'csv' { ConvertTo-OmniCliCsv -Rows $items }
            'md'  { ConvertTo-OmniCliMarkdownTable -Rows $items -Title "OmniDiag $kind" }
        }
        if ($output) {
            $target = $output
            if (Test-OmniCliDirectoryTarget $output) { $target = Join-Path $output ("omnidiag-{0}.{1}" -f $kind, $fmt) }
            Write-OmniCliFile -Path $target -Content $text
            Write-OmniCliStatus $Io "Wrote $target"
        } else {
            $Io.Out.Write($text)
        }
    }
    return 0
}

# ---------------------------------------------------------------------------
# scan / report
# ---------------------------------------------------------------------------

function Resolve-OmniCliRange {
    <# .SYNOPSIS Internal: --range value -> time-range preset name. #>
    param([string] $Range)
    if (-not $Range) { return 'Last7Days' }
    $key = $Range.ToLowerInvariant()
    if (-not $script:OmniCliRanges.Contains($key)) {
        throw (New-OmniCliUsageError "unknown range '$Range' (valid: Last24Hours, Last7Days, Last30Days)")
    }
    return $script:OmniCliRanges[$key]
}

function Invoke-OmniCliSession {
    <# .SYNOPSIS Internal: run registrations with stderr progress; returns the session. #>
    param($Io, [object[]] $Registration, [string] $Range, $Logger, $Plan, [bool] $NetworkProbes)

    $total = @($Registration).Count
    $err = $Io.Err
    $quiet = [bool]$Io.Quiet
    $progress = {
        param($p)
        if ($quiet) { return }
        if ($p.Phase -eq 'Done' -and $p.Result) {
            $err.WriteLine(('[{0,3}/{1}] {2,-28} {3}' -f $p.Index, $p.Total, $p.Name, $p.Result.Status))
        } elseif ($p.Phase -eq 'Skipped') {
            $why = if ($p.Result -and $p.Result.PSObject.Properties['SkippedReason'] -and $p.Result.SkippedReason) { [string]$p.Result.SkippedReason } else { 'RequiresElevation' }
            $err.WriteLine(('[{0,3}/{1}] {2,-28} {3}' -f $p.Index, $p.Total, $p.Name, "Skipped ($why)"))
        }
    }.GetNewClosure()

    $probeNote = if ($NetworkProbes) { ' with connectivity probes' } else { '' }
    Write-OmniCliStatus $Io ("Running {0} scanner(s){1}..." -f $total, $probeNote)
    $context = New-OmniContext -Logger $Logger -TimeRange (Get-OmniTimeRange -Preset $Range) -NetworkProbes:$NetworkProbes
    $session = Invoke-OmniSession -Registration $Registration -Context $context -ProgressCallback $progress
    Add-Member -InputObject $session -MemberType NoteProperty -Name LogPath -Value $Logger.Path -Force
    if ($Plan) { Add-Member -InputObject $session -MemberType NoteProperty -Name ScanPlan -Value $Plan -Force }
    return $session
}

function Write-OmniCliSummary {
    <# .SYNOPSIS Internal: human-readable scan summary. #>
    param([System.IO.TextWriter] $Writer, $Session)
    $v1 = ConvertTo-OmniReportV1 -Session $Session
    $score = if ($null -ne $v1.summary.healthScore) { "$($v1.summary.healthScore)/100 ($($v1.summary.grade))" } else { 'n/a (no modules completed)' }
    $c = $v1.summary.counts
    $Writer.WriteLine(('OmniDiag {0} - {1} - health score {2}' -f $v1.tool.version, $v1.host.computerName, $score))
    $Writer.WriteLine(('Findings: {0} critical, {1} warning, {2} info, {3} passed' -f $c.critical, $c.warning, $c.info, $c.passed))
    if ($v1.scan.cancelled) { $Writer.WriteLine('Scan was cancelled before every module finished.') }
    $rows = @(foreach ($m in $v1.modules) {
        $status = [string]$m.status
        if ($m.skippedReason) { $status = "$status ($($m.skippedReason))" }
        [pscustomobject]@{ status = $status; id = $m.id; name = $m.name }
    })
    $Writer.WriteLine('')
    foreach ($line in (Format-OmniCliTable -Rows $rows -Column @('status', 'id', 'name'))) { $Writer.WriteLine($line) }
    $issues = @(foreach ($m in $v1.modules) {
        if ($m.status -eq 'Skipped') { continue }
        foreach ($f in $m.findings) { if ($f.severity -ne 'Info') { [pscustomobject]@{ M = $m; F = $f } } }
    })
    if ($issues.Count -gt 0) {
        $Writer.WriteLine('')
        $Writer.WriteLine('Issues:')
        foreach ($it in @($issues | Sort-Object @{ Expression = { if ($_.F.severity -eq 'Critical') { 0 } else { 1 } } })) {
            $Writer.WriteLine(('  [{0}] {1} ({2})' -f $it.F.severity, $it.F.title, $it.M.id))
            if ($it.F.recommendation) { $Writer.WriteLine(('      -> {0}' -f $it.F.recommendation)) }
        }
    }
}

function Write-OmniCliSessionOutput {
    <# .SYNOPSIS Internal: render a finished session per --format / --output. #>
    param($Io, $Session, [string[]] $Formats, [string] $Output, [hashtable] $Option, [string[]] $DefaultFormats, [bool] $DirectoryOnly)

    $exportName = @{ json = 'Json'; csv = 'Csv'; md = 'Md'; html = 'Html'; pdf = 'Pdf' }

    if (-not $Output -and @($Formats).Count -eq 0) {
        Write-OmniCliSummary -Writer $Io.Out -Session $Session
        return
    }

    if (-not $Output) {
        $fmt = $Formats[0]
        if ($fmt -in $script:OmniCliStdoutFormats) {
            $text = switch ($fmt) {
                'json' { (ConvertTo-OmniReportV1 -Session $Session -Option $Option | ConvertTo-OmniJsonText) + "`n" }
                'csv' {
                    $rows = @(ConvertTo-OmniFindingTable -Session $Session |
                        Select-Object Module, Category, Severity, Component, Title, Detail, LikelyCause, Confidence, Recommendation)
                    ConvertTo-OmniCliCsv -Rows $rows
                }
                'md' { ConvertTo-OmniMarkdownReport -Session $Session }
            }
            $Io.Out.Write($text)
            if (-not $Io.Quiet) { Write-OmniCliSummary -Writer $Io.Err -Session $Session }
            return
        }
        # html / pdf are files: write them to OmniDiagData\reports and say where.
        $set = Export-OmniReport -Session $Session -Format @($exportName[$fmt]) -Option $Option
        Write-OmniCliSummary -Writer $Io.Out -Session $Session
        foreach ($f in $set.Files) { Write-OmniCliStatus $Io "Wrote $f" }
        foreach ($w in $set.Warnings) { $Io.Err.WriteLine("omnidiag: warning: $w") }
        return
    }

    if (@($Formats).Count -eq 0) {
        $implied = if ($DirectoryOnly) { $null } else { Get-OmniCliFormatFromPath $Output }
        $Formats = if ($implied) { @($implied) } else { $DefaultFormats }
    }

    if ($DirectoryOnly -or (Test-OmniCliDirectoryTarget $Output) -or @($Formats).Count -gt 1) {
        $set = Export-OmniReport -Session $Session -OutputDirectory $Output -Format @($Formats | ForEach-Object { $exportName[$_] }) -Option $Option
        foreach ($f in $set.Files) { $Io.Out.WriteLine($f) }
        foreach ($w in $set.Warnings) { $Io.Err.WriteLine("omnidiag: warning: $w") }
    } else {
        $fmt = $Formats[0]
        $written = switch ($fmt) {
            'json' { Export-OmniJsonReport -Session $Session -Path $Output -Option $Option }
            'csv'  { Export-OmniCsvReport -Session $Session -Path $Output }
            'md'   { Export-OmniMarkdownReport -Session $Session -Path $Output }
            'html' { Export-OmniHtmlReport -Session $Session -Path $Output }
            'pdf'  { Export-OmniPdfReport -Session $Session -Path $Output }
        }
        $Io.Out.WriteLine($written)
    }
    if (-not $Io.Quiet) { Write-OmniCliSummary -Writer $Io.Err -Session $Session }
}

function Invoke-OmniCliScan {
    <# .SYNOPSIS Internal: 'omnidiag scan' and 'omnidiag report'. #>
    param($Parsed, $Io, [string[]] $ModulesPath, [switch] $Report)

    $command = if ($Report) { 'report' } else { 'scan' }
    if (@($Parsed.Positionals).Count -gt 0) { throw (New-OmniCliUsageError "unexpected argument '$($Parsed.Positionals[0])'") }
    $o = $Parsed.Options
    $formats = Get-OmniCliFormat $o.Format
    $output = if ($o.Output) { Resolve-OmniCliPath $o.Output } else { $null }
    $range = Resolve-OmniCliRange $o.Range

    if (-not $Report -and -not $output -and @($formats).Count -gt 1) {
        throw (New-OmniCliUsageError 'only one --format can go to stdout; use --output <directory> for several')
    }
    if ($Report -and $output -and (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw (New-OmniCliUsageError "report --output must be a directory, not a file: $output")
    }
    if ($o.Profile -and $o.Workflow) { throw (New-OmniCliUsageError 'choose either --profile or --workflow, not both') }
    if (($o.Profile -or $o.Workflow) -and ($o.Group.Count -gt 0 -or $o.Module.Count -gt 0)) {
        throw (New-OmniCliUsageError 'do not combine --profile/--workflow with --group/--module')
    }
    foreach ($g in $o.Group) {
        if ($g.ToLowerInvariant() -notin (Get-OmniGroupNames)) { throw (New-OmniCliUsageError "unknown group '$g' (valid: $((Get-OmniGroupNames) -join ', '))") }
    }
    $plan = $null; $planInfo = $null
    try {
        if ($o.Profile) { $plan = Get-OmniRoleProfile -Name $o.Profile; $planInfo = [pscustomobject]@{ Type = 'RoleProfile'; Name = $plan.Name; Description = $plan.Description } }
        if ($o.Workflow) { $plan = Get-OmniTaskWorkflow -Name $o.Workflow; $planInfo = [pscustomobject]@{ Type = 'TaskWorkflow'; Name = $plan.Name; Description = $plan.Description } }
    } catch { throw (New-OmniCliUsageError $_.Exception.Message) }

    $logger = New-OmniCliLogger -VerboseLog ([bool]$o.Verbose)
    $logger.Info("omnidiag $command (OmniDiag $(Get-OmniCliToolVersion))", 'Cli')
    $regs = @(Get-OmniModule -Path $ModulesPath -Logger $logger | Where-Object { $_.Enabled })
    Write-OmniCliDiscoveryError $Io $logger

    # Selection.
    $explicitIds = @{}
    foreach ($m in $o.Module) {
        $hit = @($regs | Where-Object { $_.Id -ieq $m -or $_.Name -ieq $m })
        if ($hit.Count -eq 0) { throw (New-OmniCliUsageError "unknown module '$m'; run 'omnidiag list modules' for ids") }
        foreach ($h in $hit) { $explicitIds[$h.Id] = $true }
    }
    $groups = @($o.Group | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    if ($groups.Count -gt 0 -or $explicitIds.Count -gt 0) {
        $selected = @($regs | Where-Object { $_.Group -in $groups -or $explicitIds.ContainsKey($_.Id) })
    } elseif ($plan -and @($plan.Modules).Count -gt 0) {
        $selected = @($regs | Where-Object { $_.Name -in @($plan.Modules) })
    } else {
        $selected = $regs
    }

    # Network policy (decision 1): every selected scanner runs; connectivity probes only
    # with --network-probes (the scanners themselves check Context.NetworkProbes).
    $probes = [bool]$o.NetworkProbes
    if (-not $probes) {
        $probeCapable = @($selected | Where-Object { $_.NetworkAccess -ne 'None' })
        if ($probeCapable.Count -gt 0) {
            Write-OmniCliStatus $Io ("Connectivity probes are off ({0}); add --network-probes to run them." -f (($probeCapable | ForEach-Object { $_.Id }) -join ', '))
        }
    }
    if ($selected.Count -eq 0) { throw (New-OmniCliUsageError 'no scanners match the selection') }

    $session = Invoke-OmniCliSession -Io $Io -Registration $selected -Range $range -Logger $logger -Plan $planInfo -NetworkProbes $probes

    try {
        $saved = Save-OmniSession -Session $session
        Write-OmniCliStatus $Io "Session saved to $saved (local only)"
    } catch { $Io.Err.WriteLine("omnidiag: warning: could not save the session: $($_.Exception.Message)") }

    $option = @{ command = $command; range = $range }
    if ($groups.Count -gt 0) { $option.groups = $groups }
    if ($explicitIds.Count -gt 0) { $option.modules = @($explicitIds.Keys | Sort-Object) }
    if ($planInfo) { $option.plan = $planInfo.Name }
    if ($probes) { $option.networkProbes = $true }
    if (@($formats).Count -gt 0) { $option.formats = $formats }

    if ($Report) {
        if (-not $output) { $output = Get-OmniDataPath -Kind Reports }
        $fmts = if (@($formats).Count -gt 0) { $formats } else { @('html', 'json') }
        Write-OmniCliSessionOutput -Io $Io -Session $session -Formats $fmts -Output $output -Option $option -DefaultFormats @('html', 'json') -DirectoryOnly $true
    } else {
        Write-OmniCliSessionOutput -Io $Io -Session $session -Formats $formats -Output $output -Option $option -DefaultFormats @('json', 'html') -DirectoryOnly $false
    }
    Write-OmniCliStatus $Io "Log: $($logger.Path)"

    return (Get-OmniExitCode -Session $session -ExplicitSelection:($explicitIds.Count -gt 0))
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-OmniDiagCli {
    <#
    .SYNOPSIS
        Runs one omnidiag CLI command from GNU-style arguments and returns the exit code.

    .DESCRIPTION
        Commands: list [modules|groups|repairs|plans], scan, report, version, help, and
        '<group-id>' as shorthand for 'scan --group <group-id>'.
        Global options: --format json|csv|md|html|pdf, --output <path>, --verbose,
        --quiet, --no-color, --help. See docs/CLI.md and Get-OmniCliUsage.

        Never throws: usage errors return 10 (usage on stderr), unexpected failures
        return 20 (message on stderr).

    .PARAMETER Arguments
        The argument vector, e.g. @('scan', '--group', 'network', '--format', 'json').

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: src/Modules.

    .PARAMETER RepairsPath
        Repair plugin folder. Default: src/Repairs.

    .PARAMETER Out
        Writer for stdout (data and human results). Default: [Console]::Out.

    .PARAMETER Err
        Writer for stderr (progress, status, errors). Default: [Console]::Error.

    .OUTPUTS
        [int] process exit code.

    .EXAMPLE
        exit (Invoke-OmniDiagCli -Arguments $args)

    .EXAMPLE
        $code = Invoke-OmniDiagCli -Arguments @('list', 'modules', '--format', 'json')

    .EXAMPLE
        $code = Invoke-OmniDiagCli -Arguments @('network', '--network-probes', '--format', 'json')
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Arguments = @(),
        [string[]] $ModulesPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'),
        [string] $RepairsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Repairs'),
        [System.IO.TextWriter] $Out = [Console]::Out,
        [System.IO.TextWriter] $Err = [Console]::Error
    )

    $io = [pscustomobject]@{ Out = $Out; Err = $Err; Quiet = $false }
    $parsed = $null
    try {
        $parsed = ConvertFrom-OmniCliArgument -Arguments @($Arguments)
        $io.Quiet = [bool]$parsed.Options.Quiet
        $command = $parsed.Command
        if (-not $command) {
            if ($parsed.Options.Help) { $command = 'help' }
            elseif ($parsed.Options.Version) { $command = 'version' }
            else { throw (New-OmniCliUsageError 'no command given') }
        }
        # Group shorthand: 'omnidiag network ...' == 'omnidiag scan --group network ...'.
        $groupShorthand = $null
        if ($command -notin $script:OmniCliCommands -and $command -in (Get-OmniGroupNames)) {
            $groupShorthand = $command
            $command = 'scan'
            $parsed.Command = 'scan'
            $parsed.Options.Group.Insert(0, $groupShorthand)
        }
        if ($command -notin $script:OmniCliCommands) { throw (New-OmniCliUsageError "unknown command '$command'") }

        foreach ($name in $parsed.Given) {
            if ($name -notin $script:OmniCliGlobalOptions -and $name -notin $script:OmniCliCommandOptions[$command]) {
                throw (New-OmniCliUsageError "option '--$name' does not apply to '$command'")
            }
        }

        if ($parsed.Options.Help -or $command -eq 'help') {
            $topic = $null
            if ($command -eq 'help') {
                if (@($parsed.Positionals).Count -gt 1) { throw (New-OmniCliUsageError "unexpected argument '$($parsed.Positionals[1])'") }
                if (@($parsed.Positionals).Count -eq 1) {
                    $topic = $parsed.Positionals[0].ToLowerInvariant()
                    if ($topic -notin $script:OmniCliCommands -and $topic -notin (Get-OmniGroupNames)) { throw (New-OmniCliUsageError "unknown command '$topic'") }
                }
            } elseif ($groupShorthand) { $topic = $groupShorthand } else { $topic = $command }
            $Out.WriteLine((Get-OmniCliUsage -Command $topic))
            return 0
        }

        switch ($command) {
            'version' {
                if (@($parsed.Positionals).Count -gt 0) { throw (New-OmniCliUsageError "unexpected argument '$($parsed.Positionals[0])'") }
                $formats = Get-OmniCliFormat $parsed.Options.Format
                if (@($formats).Count -gt 1 -or (@($formats).Count -eq 1 -and $formats[0] -ne 'json')) {
                    throw (New-OmniCliUsageError 'version supports --format json only')
                }
                $version = Get-OmniCliToolVersion
                $text = if (@($formats).Count -eq 1) {
                    (ConvertTo-OmniJsonText -InputObject ([ordered]@{
                        schemaVersion       = $script:OmniCliDocSchemaVersion
                        kind                = 'version'
                        tool                = [ordered]@{ name = 'OmniDiag'; version = $version }
                        reportSchemaVersion = (Get-OmniReportSchemaVersion)
                        powershell          = [ordered]@{ version = $PSVersionTable.PSVersion.ToString(); edition = [string]$PSVersionTable.PSEdition }
                    })) + "`n"
                } else { "OmniDiag $version`n" }
                if ($parsed.Options.Output) {
                    $target = Resolve-OmniCliPath $parsed.Options.Output
                    Write-OmniCliFile -Path $target -Content $text
                    Write-OmniCliStatus $io "Wrote $target"
                } else { $Out.Write($text) }
                return 0
            }
            'list'   { return (Invoke-OmniCliList -Parsed $parsed -Io $io -ModulesPath $ModulesPath -RepairsPath $RepairsPath) }
            'scan'   { return (Invoke-OmniCliScan -Parsed $parsed -Io $io -ModulesPath $ModulesPath) }
            'report' { return (Invoke-OmniCliScan -Parsed $parsed -Io $io -ModulesPath $ModulesPath -Report) }
        }
        return 20
    } catch {
        $ex = $_.Exception
        if ($ex.Data.Contains('OmniCliUsage')) {
            $Err.WriteLine("omnidiag: $($ex.Message)")
            $Err.WriteLine('')
            $topic = $null
            if ($parsed -and $parsed.Command -and $parsed.Command -in $script:OmniCliCommands) { $topic = $parsed.Command }
            $Err.WriteLine((Get-OmniCliUsage -Command $topic))
            return 10
        }
        $Err.WriteLine("omnidiag: internal error: $($ex.Message)")
        return 20
    }
}

Export-ModuleMember -Function @('Invoke-OmniDiagCli', 'Get-OmniCliUsage')
