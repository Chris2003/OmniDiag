<#
.SYNOPSIS
    The omnidiag command-line router (GNU-style arguments).

.DESCRIPTION
    Invoke-OmniDiagCli parses an argument vector such as
        list modules --format json
        scan --group network --module security.bitlocker -o out\
        report --output C:\Reports --bundle --redact
        repair run flush-dns-cache --what-if
        compare previous last --format md
    runs the command, and returns a process exit code (see Get-OmniExitCodeTable).
    It is surface code only: discovery, execution, projection, export, repair, and
    comparison are the existing core, reporting, repair, and evidence functions.

    Output contract:
      * Data (JSON report schema v1, CSV, Markdown) goes to stdout only when
        --format is given without --output.
      * Progress and status go to stderr (suppressed by --quiet); usage errors go
        to stderr with exit code 10. Repair confirmation prompts go to stderr and
        read standard input.
      * When no data is emitted, the human-readable result (tables, summary, help)
        goes to stdout.

    The writers and the input reader are parameters so tests (and hosts) can capture
    or feed them; by default they are the process's standard streams.

    Group shorthand: 'omnidiag <group-id> [options]' is 'omnidiag scan --group <group-id>
    [options]' (e.g. 'omnidiag network --network-probes --format json').

    Network policy (decision 1): every scanner runs by default, but connectivity probes
    (pinging the gateway / a public address, resolving a public name, the domain
    secure-channel check) run only with --network-probes. Without it, scanners that
    declare NetworkAccess other than 'None' do their local work and add an Information
    finding saying how to run the probe.

    Repair safety: 'repair run' changes nothing unless --apply is given, and then asks
    per repair (y/N on stderr) unless --yes. --what-if is a dry run. Without an
    interactive standard input, --apply needs --yes.
#>

Set-StrictMode -Version Latest

$script:OmniCliCommands = @('list', 'scan', 'report', 'repair', 'compare', 'gui', 'version', 'help')
$script:OmniCliFormats = @('json', 'csv', 'md', 'html', 'pdf')
$script:OmniCliStdoutFormats = @('json', 'csv', 'md')
$script:OmniCliListKinds = @('modules', 'groups', 'repairs', 'plans')
$script:OmniCliDocSchemaVersion = '1.0.0'

# Test seam: $null = ask Test-OmniIsAdministrator; $true / $false = pretend.
$script:OmniCliElevatedOverride = $null

# Long options: name -> [kind, target]. kind: list (repeatable, comma-separated), value, flag.
$script:OmniCliOptions = @{
    'format'         = @('list', 'Format')
    'output'         = @('value', 'Output')
    'group'          = @('list', 'Group')
    'module'         = @('list', 'Module')
    'profile'        = @('value', 'Profile')
    'workflow'       = @('value', 'Workflow')
    'range'          = @('value', 'Range')
    'network-probes' = @('flag', 'NetworkProbes')
    'from-session'   = @('value', 'FromSession')
    'redact'         = @('flag', 'Redact')
    'redaction-map'  = @('value', 'RedactionMap')
    'elevated-only'  = @('flag', 'ElevatedOnly')
    'bundle'         = @('flag', 'Bundle')
    'what-if'        = @('flag', 'WhatIf')
    'apply'          = @('flag', 'Apply')
    'yes'            = @('flag', 'Yes')
    'allow-without-restore-point' = @('flag', 'AllowWithoutRestorePoint')
    'verbose'        = @('flag', 'Verbose')
    'quiet'          = @('flag', 'Quiet')
    'no-color'       = @('flag', 'NoColor')
    'help'           = @('flag', 'Help')
    'version'        = @('flag', 'Version')
}
$script:OmniCliShortOptions = @{ 'h' = 'help'; '?' = 'help'; 'q' = 'quiet'; 'o' = 'output'; 'f' = 'format'; 'g' = 'group'; 'm' = 'module'; 'y' = 'yes' }

# Which options each command accepts (global options are accepted everywhere).
$script:OmniCliGlobalOptions = @('format', 'output', 'verbose', 'quiet', 'no-color', 'help', 'version')
$script:OmniCliCommandOptions = @{
    list    = @()
    scan    = @('group', 'module', 'profile', 'workflow', 'range', 'network-probes', 'redact', 'redaction-map', 'elevated-only')
    report  = @('range', 'network-probes', 'redact', 'redaction-map', 'elevated-only', 'bundle', 'from-session')
    repair  = @('what-if', 'apply', 'yes', 'allow-without-restore-point', 'from-session')
    compare = @()
    gui     = @()
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

function New-OmniCliExit {
    <# .SYNOPSIS Internal: an exception the router maps to a specific exit code (message on stderr, no usage). #>
    param([int] $Code, [string] $Message)
    $ex = [System.InvalidOperationException]::new($Message)
    $ex.Data['OmniCliExitCode'] = $Code
    return $ex
}

function Test-OmniCliElevated {
    <# .SYNOPSIS Internal: whether the process is elevated (honors the test seam). #>
    if ($null -ne $script:OmniCliElevatedOverride) { return [bool]$script:OmniCliElevatedOverride }
    return [bool](Test-OmniIsAdministrator)
}

function Test-OmniCliWindows {
    <# .SYNOPSIS Internal: true on Windows (5.1 and 7). #>
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Assert-OmniCliRedaction {
    <# .SYNOPSIS Internal: --redact needs the redaction module (exit 20 with a clear message otherwise). #>
    $ok = [bool](Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue) -and
        [bool](Get-Command ConvertTo-OmniRedacted -ErrorAction SilentlyContinue)
    if ($ok) {
        $export = Get-Command Export-OmniReport -ErrorAction SilentlyContinue
        $ok = [bool]($export -and $export.Parameters.ContainsKey('Redact'))
    }
    if (-not $ok) {
        throw (New-OmniCliExit 20 '--redact is not available in this build: the redaction module (New-OmniRedactionContext, ConvertTo-OmniRedacted, Export-OmniReport -Redact) is missing.')
    }
}

function Get-OmniCliUsage {
    <#
    .SYNOPSIS
        Returns the omnidiag CLI usage text (optionally for one command).

    .PARAMETER Command
        list, scan, report, repair, compare, gui, version, help, or a group id (the
        'omnidiag <group>' shorthand). Omit for the overview.

    .EXAMPLE
        Get-OmniCliUsage -Command scan

    .EXAMPLE
        Get-OmniCliUsage -Command repair
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Command)

    $groups = (Get-OmniGroupNames) -join ', '
    $nl = [Environment]::NewLine
    if ($Command -and $Command -in (Get-OmniGroupNames)) {
        $display = [string](@(Get-OmniGroup | Where-Object { $_.Id -eq $Command })[0].DisplayName)
        return (@(
            "Usage: omnidiag $Command [--module <id>]... [--network-probes] [--elevated-only] [--range <preset>]",
            '                [--redact] [--format <fmt>] [--output <path>]',
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
                '                     [--network-probes] [--elevated-only] [--range Last24Hours|Last7Days|Last30Days]',
                '                     [--redact [--redaction-map <file>]] [--format <fmt>] [--output <path>]',
                '       omnidiag <group> [options]     (same as scan --group <group>)',
                '',
                'Runs scanners and summarizes the findings. With no selection every scanner runs.',
                '--group and --module may be repeated or given as a comma list and are combined.',
                'Connectivity probes (ping the gateway and 1.1.1.1, resolve www.microsoft.com, the',
                'domain secure-channel check) run only with --network-probes; without it those',
                'scanners do their local checks and say how to run the probe.',
                '--elevated-only runs only the selected scanners that need elevation (exit 4 when',
                'the prompt is not elevated). --redact replaces host, user, and domain names, SIDs,',
                'profile paths, and IP/MAC addresses with stable pseudonyms in every output.',
                '',
                "Groups: $groups",
                'Profiles: ' + ((Get-OmniRoleProfile).Name -join ', '),
                'Workflows: ' + ((Get-OmniTaskWorkflow).Name -join ', ')
            ) -join $nl)
        }
        'report' {
            return (@(
                'Usage: omnidiag report [--output <directory>] [--format <fmt>] [--bundle] [--redact [--redaction-map <file>]]',
                '                       [--range <preset>] [--network-probes] [--elevated-only]',
                '       omnidiag report --from-session <path|last|previous> [--output <directory>] [--format <fmt>] [--bundle] [--redact]',
                '',
                'Runs every scanner (connectivity probes only with --network-probes) and writes an',
                'HTML report plus a JSON report (schema v1) to --output, or to OmniDiagData\reports',
                'next to the tool. --format replaces the default html,json set (json, csv, md, html, pdf).',
                '--bundle also writes one .zip report package. --from-session exports a saved session',
                'instead of scanning. --redact pseudonymizes identifiers in every file and file name.'
            ) -join $nl)
        }
        'repair' {
            return (@(
                'Usage: omnidiag repair list [--from-session <path|last|previous>] [--format json|csv|md] [--output <file>]',
                '       omnidiag repair run <id>... --what-if',
                '       omnidiag repair run <id>... --apply [--yes] [--allow-without-restore-point]',
                '',
                "'repair list' shows the repairs (id, risk, elevation, restore point); with --from-session",
                "it marks the ones recommended for that scan. 'repair run' changes nothing without a mode:",
                '  --what-if   dry run: each repair describes what it would do; nothing runs or changes',
                '  --apply     run the repairs, asking y/N per repair on stderr',
                '  --yes, -y   with --apply: do not ask (required when standard input is not interactive)',
                '  --allow-without-restore-point  run repairs that want a System Restore point even when',
                '              none could be created',
                'Ids are the full id (repair.flush-dns-cache), the id without "repair.", or the name.',
                'Applied steps are appended to OmniDiagData\logs\repair-audit.jsonl.',
                'Exit codes: 0 done, 4 every repair needs elevation (not elevated), 10 usage,',
                '            11 a repair failed, 12 a reboot is required.'
            ) -join $nl)
        }
        'compare' {
            return (@(
                'Usage: omnidiag compare <before> <after> [--format text|json|md] [--output <file>]',
                '',
                'Compares two sessions: saved sessions, JSON reports, report .zip packages, or',
                "'last' / 'previous' (the newest two saved sessions). Lists resolved, new, and",
                'persisting findings, the health-score change, and a verdict. Exits 0 whenever the',
                'comparison ran, also when the verdict is Regressed (read the verdict from the output).'
            ) -join $nl)
        }
        'gui' {
            return (@(
                'Usage: omnidiag gui',
                '',
                'Opens the OmniDiag window (Windows only; exits 10 on other systems).'
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
        '  report                               Run every scanner; write HTML + JSON (--bundle: + .zip)',
        '  repair list | run <id>...            List repairs; run them (--what-if | --apply [--yes])',
        '  compare <before> <after>             Compare two sessions (paths, .zip, last, previous)',
        '  gui                                  Open the OmniDiag window (Windows)',
        '  version                              Show the OmniDiag version',
        '  help [command|group]                 Show help for a command',
        '',
        'Scan selection (scan, <group>, report):',
        '  -g, --group <id>       Run a module group (repeatable or comma list)',
        '  -m, --module <id>      Run one scanner by id (repeatable or comma list)',
        '      --profile <name>   Run a role profile (e.g. HelpDesk)',
        '      --workflow <name>  Run a task workflow (e.g. QuickTriage)',
        '      --range <preset>   Event time range: Last24Hours, Last7Days (default), Last30Days',
        '      --network-probes   Also run connectivity probes (contacts the network; off by default)',
        '      --elevated-only    Run only scanners that need elevation (exit 4 when not elevated)',
        '      --redact           Pseudonymize host/user/domain names, SIDs, paths, IP/MAC addresses',
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
        NetworkProbes = $false; FromSession = $null; Redact = $false; RedactionMap = $null
        ElevatedOnly = $false; Bundle = $false; WhatIf = $false; Apply = $false; Yes = $false
        AllowWithoutRestorePoint = $false
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

function Write-OmniCliRedactedStatus {
    <#
    .SYNOPSIS
        Internal: a status line on stderr (unless --quiet), redacted with the run's
        redaction context when --redact is on (paths can contain user and host names).
    #>
    param($Io, [string] $Message, $Redaction)
    if ($Redaction) { $Message = [string](ConvertTo-OmniRedacted -InputObject $Message -Context $Redaction) }
    Write-OmniCliStatus $Io $Message
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

function ConvertTo-OmniCliRepairItem {
    <# .SYNOPSIS Internal: a repair registration as a list row (schema: omnidiag-list.v1 'repair'). #>
    param($Registration, [switch] $WithRecommended)
    $row = [ordered]@{
        id                = $Registration.Id
        name              = $Registration.Name
        category          = $Registration.Category
        risk              = $Registration.Risk
        requiresElevation = [bool]$Registration.RequiresElevation
        networkAccess     = $Registration.NetworkAccess
        restorePoint      = [bool]$Registration.RestorePoint
        rebootHint        = [bool]$Registration.RebootHint
        description       = $Registration.Description
    }
    if ($WithRecommended) { $row.recommended = [bool]$Registration.Recommended }
    return [pscustomobject]$row
}

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
            foreach ($r in @(Get-OmniRepair -Path $RepairsPath -Logger $Logger)) { ConvertTo-OmniCliRepairItem -Registration $r }
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

function Get-OmniCliListFormat {
    <# .SYNOPSIS Internal: validated --format / --output for list-style commands (json, csv, md). #>
    param($Parsed, [string] $Command)
    $formats = Get-OmniCliFormat $Parsed.Options.Format
    $output = $Parsed.Options.Output
    if ($output) { $output = Resolve-OmniCliPath $output }
    if (@($formats).Count -eq 0 -and $output) {
        $implied = Get-OmniCliFormatFromPath $output
        $formats = @(if ($implied) { $implied } else { 'json' })
    }
    foreach ($f in $formats) {
        if ($f -notin $script:OmniCliStdoutFormats) { throw (New-OmniCliUsageError "$Command supports --format json, csv, or md (not '$f')") }
    }
    if (@($formats).Count -gt 1 -and -not ($output -and (Test-OmniCliDirectoryTarget $output))) {
        throw (New-OmniCliUsageError 'several formats need --output <directory>')
    }
    return [pscustomobject]@{ Formats = @($formats); Output = $output }
}

function Write-OmniCliListOutput {
    <# .SYNOPSIS Internal: write list rows as a table, or as a versioned JSON / CSV / Markdown document. #>
    param($Io, [string] $Kind, [object[]] $Items, [string[]] $Formats, [string] $Output, [string[]] $Column, [string] $FileStem)

    if (@($Formats).Count -eq 0) {
        foreach ($line in (Format-OmniCliTable -Rows $Items -Column $Column)) { $Io.Out.WriteLine($line) }
        return
    }
    foreach ($fmt in $Formats) {
        $text = switch ($fmt) {
            'json' {
                (ConvertTo-OmniJsonText -InputObject ([ordered]@{
                    schemaVersion = $script:OmniCliDocSchemaVersion
                    kind          = $Kind
                    tool          = [ordered]@{ name = 'OmniDiag'; version = (Get-OmniCliToolVersion) }
                    items         = @($Items)
                })) + "`n"
            }
            'csv' { ConvertTo-OmniCliCsv -Rows $Items }
            'md'  { ConvertTo-OmniCliMarkdownTable -Rows $Items -Title "OmniDiag $Kind" }
        }
        if ($Output) {
            $target = $Output
            if (Test-OmniCliDirectoryTarget $Output) { $target = Join-Path $Output ("{0}.{1}" -f $FileStem, $fmt) }
            Write-OmniCliFile -Path $target -Content $text
            Write-OmniCliStatus $Io "Wrote $target"
        } else {
            $Io.Out.Write($text)
        }
    }
}

function Invoke-OmniCliList {
    <# .SYNOPSIS Internal: 'omnidiag list'. #>
    param($Parsed, $Io, [string[]] $ModulesPath, [string] $RepairsPath)

    if (@($Parsed.Positionals).Count -gt 1) { throw (New-OmniCliUsageError "unexpected argument '$($Parsed.Positionals[1])'") }
    $kind = if (@($Parsed.Positionals).Count -eq 1) { $Parsed.Positionals[0].ToLowerInvariant() } else { 'modules' }
    if ($kind -notin $script:OmniCliListKinds) { throw (New-OmniCliUsageError "unknown list kind '$kind' (valid: $($script:OmniCliListKinds -join ', '))") }

    $target = Get-OmniCliListFormat -Parsed $Parsed -Command 'list'

    $logger = New-OmniLogger -MinimumLevel Error
    $items = @(Get-OmniCliListItem -Kind $kind -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Logger $logger)
    Write-OmniCliDiscoveryError $Io $logger

    $columns = switch ($kind) {
        'modules' { @('id', 'group', 'networkAccess', 'requiresElevation', 'name') }
        'groups'  { @('id', 'moduleCount', 'name') }
        'repairs' { @('id', 'risk', 'networkAccess', 'requiresElevation', 'name') }
        'plans'   { @('name', 'type', 'description') }
    }
    Write-OmniCliListOutput -Io $Io -Kind $kind -Items $items -Formats $target.Formats -Output $target.Output -Column $columns -FileStem "omnidiag-$kind"
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

function ConvertTo-OmniCliRedacted {
    <# .SYNOPSIS Internal: redact one value with the run's redaction context ($null context = unchanged). #>
    param($InputObject, $Redaction)
    if ($null -eq $Redaction -or $null -eq $InputObject) { return $InputObject }
    return (ConvertTo-OmniRedacted -InputObject $InputObject -Context $Redaction)
}

function Write-OmniCliSummary {
    <# .SYNOPSIS Internal: human-readable scan summary (redacted with --redact). #>
    param([System.IO.TextWriter] $Writer, $Session, $Redaction)
    $v1 = ConvertTo-OmniReportV1 -Session $Session
    if ($Redaction) { $v1 = ConvertTo-OmniCliRedacted -InputObject $v1 -Redaction $Redaction }
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

function Get-OmniCliSessionText {
    <# .SYNOPSIS Internal: a session as JSON (schema v1), CSV, or Markdown text, redacted when a context is given. #>
    param($Session, [string] $Format, [hashtable] $Option, $Redaction)
    switch ($Format) {
        'json' {
            $v1 = ConvertTo-OmniReportV1 -Session $Session -Option $Option
            if ($Redaction) { $v1 = ConvertTo-OmniCliRedacted -InputObject $v1 -Redaction $Redaction }
            return ((ConvertTo-OmniJsonText -InputObject $v1) + "`n")
        }
        'csv' {
            $rows = @(ConvertTo-OmniFindingTable -Session $Session |
                Select-Object Module, Category, Severity, Component, Title, Detail, LikelyCause, Confidence, Recommendation)
            if ($Redaction) { $rows = @(foreach ($r in $rows) { ConvertTo-OmniCliRedacted -InputObject $r -Redaction $Redaction }) }
            return (ConvertTo-OmniCliCsv -Rows $rows)
        }
        'md' {
            $text = ConvertTo-OmniMarkdownReport -Session $Session
            if ($Redaction) { $text = [string](ConvertTo-OmniCliRedacted -InputObject ([string]$text) -Redaction $Redaction) }
            return $text
        }
    }
    throw "format '$Format' is not a text format"
}

function Write-OmniCliSessionOutput {
    <# .SYNOPSIS Internal: render a finished session per --format / --output (and --redact). #>
    param($Io, $Session, [string[]] $Formats, [string] $Output, [hashtable] $Option, [string[]] $DefaultFormats,
        [bool] $DirectoryOnly, $Redaction, [string] $RedactionMap, [string[]] $ExtraExport = @())

    $exportName = @{ json = 'Json'; csv = 'Csv'; md = 'Md'; html = 'Html'; pdf = 'Pdf'; zip = 'Zip' }
    $redactParams = @{}
    if ($Redaction) {
        $redactParams.Redact = $true
        if ($RedactionMap) { $redactParams.RedactionMapPath = $RedactionMap }
        # Same context as stdout and the summary, so a value has one pseudonym everywhere.
        if ((Get-Command Export-OmniReport).Parameters.ContainsKey('RedactionContext')) { $redactParams.RedactionContext = $Redaction }
    }

    if (-not $Output -and @($Formats).Count -eq 0) {
        Write-OmniCliSummary -Writer $Io.Out -Session $Session -Redaction $Redaction
        return
    }

    if (-not $Output) {
        $fmt = $Formats[0]
        if ($fmt -in $script:OmniCliStdoutFormats) {
            $Io.Out.Write((Get-OmniCliSessionText -Session $Session -Format $fmt -Option $Option -Redaction $Redaction))
            if (-not $Io.Quiet) { Write-OmniCliSummary -Writer $Io.Err -Session $Session -Redaction $Redaction }
            return
        }
        # html / pdf are files: write them to OmniDiagData\reports and say where.
        $set = Export-OmniReport -Session $Session -Format @($exportName[$fmt]) -Option $Option @redactParams
        Write-OmniCliSummary -Writer $Io.Out -Session $Session -Redaction $Redaction
        foreach ($f in $set.Files) { Write-OmniCliRedactedStatus $Io "Wrote $f" $Redaction }
        foreach ($w in $set.Warnings) { $Io.Err.WriteLine("omnidiag: warning: $w") }
        return
    }

    if (@($Formats).Count -eq 0) {
        $implied = if ($DirectoryOnly) { $null } else { Get-OmniCliFormatFromPath $Output }
        $Formats = if ($implied) { @($implied) } else { $DefaultFormats }
    }

    if ($DirectoryOnly -or (Test-OmniCliDirectoryTarget $Output) -or @($Formats).Count -gt 1 -or @($ExtraExport).Count -gt 0) {
        $names = @(@($Formats) + @($ExtraExport) | ForEach-Object { $exportName[$_] } | Select-Object -Unique)
        $set = Export-OmniReport -Session $Session -OutputDirectory $Output -Format $names -Option $Option @redactParams
        foreach ($f in $set.Files) { $Io.Out.WriteLine($f) }
        foreach ($w in $set.Warnings) { $Io.Err.WriteLine("omnidiag: warning: $w") }
    } else {
        $fmt = $Formats[0]
        if ($Redaction -and $fmt -in $script:OmniCliStdoutFormats) {
            Write-OmniCliFile -Path $Output -Content (Get-OmniCliSessionText -Session $Session -Format $fmt -Option $Option -Redaction $Redaction)
            $written = $Output
        } elseif ($Redaction) {
            # A single redacted HTML / PDF file: export (redacted) into a scratch folder, then move.
            $scratch = Get-OmniDataPath -Kind Temp -ChildPath ('redact-' + [guid]::NewGuid().ToString('N'))
            try {
                $set = Export-OmniReport -Session $Session -OutputDirectory $scratch -Format @($exportName[$fmt]) -Option $Option @redactParams
                foreach ($w in $set.Warnings) { $Io.Err.WriteLine("omnidiag: warning: $w") }
                $produced = @($set.Files | Where-Object { $_ })
                if ($produced.Count -eq 0) { throw "the $fmt export produced no file" }
                $dir = Split-Path -Path $Output -Parent
                if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item -LiteralPath $produced[0] -Destination $Output -Force
                $written = $Output
            } finally {
                Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            $written = switch ($fmt) {
                'json' { Export-OmniJsonReport -Session $Session -Path $Output -Option $Option }
                'csv'  { Export-OmniCsvReport -Session $Session -Path $Output }
                'md'   { Export-OmniMarkdownReport -Session $Session -Path $Output }
                'html' { Export-OmniHtmlReport -Session $Session -Path $Output }
                'pdf'  { Export-OmniPdfReport -Session $Session -Path $Output }
            }
        }
        $Io.Out.WriteLine($written)
    }
    if (-not $Io.Quiet) { Write-OmniCliSummary -Writer $Io.Err -Session $Session -Redaction $Redaction }
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
    if ($o.RedactionMap -and -not $o.Redact) { throw (New-OmniCliUsageError '--redaction-map needs --redact') }
    if ($o.FromSession) {
        foreach ($pair in @(@('range', $o.Range), @('network-probes', $o.NetworkProbes), @('elevated-only', $o.ElevatedOnly))) {
            if ($pair[1]) { throw (New-OmniCliUsageError "--from-session exports a saved session; --$($pair[0]) does not apply") }
        }
    }
    foreach ($g in $o.Group) {
        if ($g.ToLowerInvariant() -notin (Get-OmniGroupNames)) { throw (New-OmniCliUsageError "unknown group '$g' (valid: $((Get-OmniGroupNames) -join ', '))") }
    }
    $plan = $null; $planInfo = $null
    try {
        if ($o.Profile) { $plan = Get-OmniRoleProfile -Name $o.Profile; $planInfo = [pscustomobject]@{ Type = 'RoleProfile'; Name = $plan.Name; Description = $plan.Description } }
        if ($o.Workflow) { $plan = Get-OmniTaskWorkflow -Name $o.Workflow; $planInfo = [pscustomobject]@{ Type = 'TaskWorkflow'; Name = $plan.Name; Description = $plan.Description } }
    } catch { throw (New-OmniCliUsageError $_.Exception.Message) }
    if ($o.Redact) { Assert-OmniCliRedaction }
    if ($o.ElevatedOnly -and -not (Test-OmniCliElevated)) {
        throw (New-OmniCliExit 4 '--elevated-only runs only the scanners that need elevation, and this prompt is not elevated. Re-run from an elevated (Run as administrator) prompt.')
    }

    $logger = New-OmniCliLogger -VerboseLog ([bool]$o.Verbose)
    $logger.Info("omnidiag $command (OmniDiag $(Get-OmniCliToolVersion))", 'Cli')

    $explicitIds = @{}
    $statusLines = [System.Collections.Generic.List[string]]::new()
    $groups = @($o.Group | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    $option = @{ command = $command; range = $range }

    if ($o.FromSession) {
        # report --from-session: export a saved session instead of scanning.
        try {
            $sourcePath = Resolve-OmniSessionPath -Value $o.FromSession
            $session = Import-OmniSession -Path $sourcePath
        } catch { throw (New-OmniCliUsageError "cannot read --from-session '$($o.FromSession)': $($_.Exception.Message)") }
        $statusLines.Add("Loaded saved session $sourcePath")
        $option = @{ command = $command; fromSession = $true }
    } else {
        $regs = @(Get-OmniModule -Path $ModulesPath -Logger $logger | Where-Object { $_.Enabled })
        Write-OmniCliDiscoveryError $Io $logger

        # Selection.
        foreach ($m in $o.Module) {
            $hit = @($regs | Where-Object { $_.Id -ieq $m -or $_.Name -ieq $m })
            if ($hit.Count -eq 0) { throw (New-OmniCliUsageError "unknown module '$m'; run 'omnidiag list modules' for ids") }
            foreach ($h in $hit) { $explicitIds[$h.Id] = $true }
        }
        if ($groups.Count -gt 0 -or $explicitIds.Count -gt 0) {
            $selected = @($regs | Where-Object { $_.Group -in $groups -or $explicitIds.ContainsKey($_.Id) })
        } elseif ($plan -and @($plan.Modules).Count -gt 0) {
            $selected = @($regs | Where-Object { $_.Name -in @($plan.Modules) })
        } else {
            $selected = $regs
        }
        if ($o.ElevatedOnly) {
            $selected = @($selected | Where-Object { $_.RequiresElevation })
            if ($selected.Count -eq 0) { throw (New-OmniCliUsageError 'no selected scanner requires elevation (--elevated-only)') }
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
            $statusLines.Add("Session saved to $saved (local only)")
        } catch { $Io.Err.WriteLine("omnidiag: warning: could not save the session: $($_.Exception.Message)") }

        if ($groups.Count -gt 0) { $option.groups = $groups }
        if ($explicitIds.Count -gt 0) { $option.modules = @($explicitIds.Keys | Sort-Object) }
        if ($planInfo) { $option.plan = $planInfo.Name }
        if ($probes) { $option.networkProbes = $true }
        if ($o.ElevatedOnly) { $option.elevatedOnly = $true }
    }
    if (@($formats).Count -gt 0) { $option.formats = $formats }
    if ($o.Redact) { $option.redacted = $true }

    $redaction = $null
    if ($o.Redact) { $redaction = New-OmniRedactionContext -Session $session }
    # Deferred until the redaction context exists: with --redact these paths are redacted too.
    foreach ($line in $statusLines) { Write-OmniCliRedactedStatus $Io $line $redaction }
    $redactionMap = if ($o.RedactionMap) { Resolve-OmniCliPath $o.RedactionMap } else { $null }

    if ($Report) {
        if (-not $output) { $output = Get-OmniDataPath -Kind Reports }
        $fmts = if (@($formats).Count -gt 0) { $formats } else { @('html', 'json') }
        $extra = @(if ($o.Bundle) { 'zip' })
        Write-OmniCliSessionOutput -Io $Io -Session $session -Formats $fmts -Output $output -Option $option -DefaultFormats @('html', 'json') `
            -DirectoryOnly $true -Redaction $redaction -RedactionMap $redactionMap -ExtraExport $extra
    } else {
        Write-OmniCliSessionOutput -Io $Io -Session $session -Formats $formats -Output $output -Option $option -DefaultFormats @('json', 'html') `
            -DirectoryOnly $false -Redaction $redaction -RedactionMap $redactionMap
    }
    Write-OmniCliRedactedStatus $Io "Log: $($logger.Path)" $redaction

    return (Get-OmniExitCode -Session $session -ExplicitSelection:($explicitIds.Count -gt 0))
}

# ---------------------------------------------------------------------------
# repair
# ---------------------------------------------------------------------------

function Select-OmniCliRepair {
    <# .SYNOPSIS Internal: repair ids / names -> registrations (usage error for unknown ones). #>
    param([object[]] $Registration, [string[]] $Id)
    $chosen = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($want in $Id) {
        $w = $want.Trim()
        $hit = @($Registration | Where-Object { $_.Id -ieq $w -or $_.Id -ieq "repair.$w" -or $_.Name -ieq $w })
        if ($hit.Count -eq 0) { $unknown.Add($w); continue }
        if (-not ($chosen | Where-Object { $_.Id -eq $hit[0].Id })) { $chosen.Add($hit[0]) }
    }
    if ($unknown.Count -gt 0) {
        throw (New-OmniCliUsageError ("unknown repair '{0}'; run 'omnidiag repair list' for ids" -f ($unknown -join "', '")))
    }
    return , $chosen.ToArray()
}

function Invoke-OmniCliRepairList {
    <# .SYNOPSIS Internal: 'omnidiag repair list [--from-session <s>]'. #>
    param($Parsed, $Io, [string] $RepairsPath)

    $target = Get-OmniCliListFormat -Parsed $Parsed -Command 'repair list'
    $logger = New-OmniLogger -MinimumLevel Error
    $regs = @(Get-OmniRepair -Path $RepairsPath -Logger $logger)
    Write-OmniCliDiscoveryError $Io $logger

    $withRecommended = $false
    if ($Parsed.Options.FromSession) {
        try {
            $sourcePath = Resolve-OmniSessionPath -Value $Parsed.Options.FromSession
            $session = Import-OmniSession -Path $sourcePath
        } catch { throw (New-OmniCliUsageError "cannot read --from-session '$($Parsed.Options.FromSession)': $($_.Exception.Message)") }
        $regs = @(Get-OmniApplicableRepair -Registration $regs -Session $session)
        $withRecommended = $true
        Write-OmniCliStatus $Io "Recommendations from $sourcePath"
    }
    $items = @(foreach ($r in $regs) { ConvertTo-OmniCliRepairItem -Registration $r -WithRecommended:$withRecommended })
    $columns = @('id', 'risk', 'requiresElevation', 'restorePoint')
    if ($withRecommended) { $columns += 'recommended' }
    $columns += 'name'
    Write-OmniCliListOutput -Io $Io -Kind 'repairs' -Items $items -Formats $target.Formats -Output $target.Output -Column $columns -FileStem 'omnidiag-repairs'
    return 0
}

function ConvertTo-OmniCliRepairDocument {
    <# .SYNOPSIS Internal: a repair session as the 'repair-run' JSON document. #>
    param($RepairSession, [object[]] $Registration, [int] $ExitCode, [string] $AuditPath)
    $idOf = @{}
    foreach ($r in $Registration) { $idOf[[string]$r.Name] = [string]$r.Id }
    $rp = $null
    if ($RepairSession.RestorePoint) {
        $rp = [ordered]@{ status = [string]$RepairSession.RestorePoint.Status; message = [string]$RepairSession.RestorePoint.Message }
    }
    $results = @(foreach ($res in @($RepairSession.Results)) {
        [ordered]@{
            id             = $(if ($idOf.ContainsKey([string]$res.Name)) { $idOf[[string]$res.Name] } else { $null })
            name           = [string]$res.Name
            status         = [string]$res.Status
            rebootRequired = [bool]$res.RebootRequired
            error          = $(if ($res.Error) { [string]$res.Error } else { $null })
            steps          = @(foreach ($s in @($res.Steps)) {
                [ordered]@{ description = [string]$s.Description; succeeded = [bool]$s.Succeeded; dryRun = [bool]$s.DryRun; output = [string]$s.Output }
            })
        }
    })
    return [ordered]@{
        schemaVersion  = $script:OmniCliDocSchemaVersion
        kind           = 'repair-run'
        tool           = [ordered]@{ name = 'OmniDiag'; version = (Get-OmniCliToolVersion) }
        dryRun         = [bool]$RepairSession.DryRun
        cancelled      = [bool]$RepairSession.Cancelled
        restorePoint   = $rp
        rebootRequired = [bool]$RepairSession.RebootRequired
        exitCode       = $ExitCode
        auditLog       = $(if ($AuditPath) { $AuditPath } else { $null })
        results        = $results
    }
}

function Invoke-OmniCliRepairRun {
    <# .SYNOPSIS Internal: 'omnidiag repair run <id>... (--what-if | --apply [--yes])'. #>
    param($Parsed, $Io, [string] $RepairsPath, [string[]] $Id)

    $o = $Parsed.Options
    if (@($Id).Count -eq 0) { throw (New-OmniCliUsageError "repair run needs at least one repair id ('omnidiag repair list' shows them)") }
    if ($o.WhatIf -and $o.Apply) { throw (New-OmniCliUsageError 'choose either --what-if or --apply, not both') }
    if (-not $o.WhatIf -and -not $o.Apply) {
        throw (New-OmniCliUsageError 'repair run changes nothing without a mode: add --what-if to see what each repair would do (dry run, no changes), or --apply to run the repairs (asks per repair; --yes skips the questions)')
    }
    if ($o.Yes -and -not $o.Apply) { throw (New-OmniCliUsageError '--yes only applies with --apply') }
    if ($o.AllowWithoutRestorePoint -and -not $o.Apply) { throw (New-OmniCliUsageError '--allow-without-restore-point only applies with --apply') }
    $formats = Get-OmniCliFormat $o.Format
    foreach ($f in $formats) { if ($f -ne 'json') { throw (New-OmniCliUsageError "repair run supports --format json only (not '$f')") } }
    $output = if ($o.Output) { Resolve-OmniCliPath $o.Output } else { $null }
    if ($output -and (Test-OmniCliDirectoryTarget $output)) { $output = Join-Path $output 'omnidiag-repair-run.json' }
    $asJson = (@($formats).Count -eq 1) -or [bool]$output

    $dryRun = [bool]$o.WhatIf
    $logger = New-OmniCliLogger -VerboseLog ([bool]$o.Verbose) -Name 'omnidiag-repair'
    $logger.Info("omnidiag repair run (dryRun=$dryRun)", 'Cli')
    $all = @(Get-OmniRepair -Path $RepairsPath -Logger $logger)
    Write-OmniCliDiscoveryError $Io $logger
    $regs = Select-OmniCliRepair -Registration $all -Id $Id
    $isAdmin = Test-OmniCliElevated

    if (-not $dryRun) {
        if (-not $o.Yes -and -not $Io.Interactive) {
            throw (New-OmniCliUsageError 'refusing to apply repairs without confirmation: standard input is not interactive. Add --yes to confirm in a script, or use --what-if for a dry run.')
        }
        if (-not $isAdmin -and @($regs | Where-Object { -not $_.RequiresElevation }).Count -eq 0) {
            throw (New-OmniCliExit 4 ("every requested repair needs elevation ({0}); nothing was changed. Re-run from an elevated (Run as administrator) prompt." -f (($regs | ForEach-Object { $_.Id }) -join ', ')))
        }
    }

    # Per-repair confirmation (stderr prompt, stdin answer) unless --yes or a dry run.
    $confirmed = [System.Collections.Generic.List[object]]::new()
    foreach ($reg in $regs) {
        if ($dryRun -or $o.Yes) { $confirmed.Add($reg); continue }
        $notes = [System.Collections.Generic.List[string]]::new()
        $notes.Add("risk $($reg.Risk)")
        if ($reg.RequiresElevation -and -not $isAdmin) { $notes.Add('needs elevation: will be skipped') }
        if ($reg.RestorePoint) { $notes.Add('creates a restore point first') }
        if ($reg.RebootHint) { $notes.Add('may need a reboot') }
        $Io.Err.Write(("Apply repair '{0}' [{1}] ({2})? [y/N] " -f $reg.Name, $reg.Id, ($notes -join '; ')))
        $Io.Err.Flush()
        $answer = $Io.In.ReadLine()
        if ($null -ne $answer -and $answer.Trim() -match '^(?i:y|yes)$') { $confirmed.Add($reg) }
        else { Write-OmniCliStatus $Io "Not applied: $($reg.Id)" }
    }
    if ($confirmed.Count -eq 0) {
        Write-OmniCliStatus $Io 'No repairs confirmed; nothing was changed.'
        return 0
    }

    if ($dryRun) { Write-OmniCliStatus $Io ("Dry run of {0} repair(s): describing only, nothing will be changed." -f $confirmed.Count) }
    else { Write-OmniCliStatus $Io ("Applying {0} repair(s)..." -f $confirmed.Count) }

    $err = $Io.Err
    $quiet = [bool]$Io.Quiet
    $progress = {
        param($p)
        if ($quiet) { return }
        if ($p.Phase -in @('Done', 'Skipped') -and $p.Result) {
            $err.WriteLine(('[{0,3}/{1}] {2,-36} {3}' -f $p.Index, $p.Total, $p.Name, $p.Result.Status))
        }
    }.GetNewClosure()

    $ctx = New-OmniRepairContext -Logger $logger -DryRun:$dryRun
    $session = Invoke-OmniRepair -Registration $confirmed.ToArray() -Context $ctx -ProgressCallback $progress `
        -AllowWithoutRestorePoint:([bool]$o.AllowWithoutRestorePoint) -Confirm:$false -WhatIf:$false
    $code = Get-OmniRepairRunExitCode -RepairSession $session -Registration $regs -IsAdmin $isAdmin -DryRun:$dryRun
    $auditPath = if ($dryRun) { $null } else { Get-OmniRepairAuditPath }

    if ($asJson) {
        $text = (ConvertTo-OmniJsonText -InputObject (ConvertTo-OmniCliRepairDocument -RepairSession $session -Registration $regs -ExitCode $code -AuditPath $auditPath)) + "`n"
        if ($output) {
            Write-OmniCliFile -Path $output -Content $text
            Write-OmniCliStatus $Io "Wrote $output"
        } else { $Io.Out.Write($text) }
    } else {
        $w = $Io.Out
        if ($session.DryRun) { $w.WriteLine('DRY RUN - nothing was changed.') }
        if ($session.RestorePoint) { $w.WriteLine(('Restore point: {0} - {1}' -f $session.RestorePoint.Status, $session.RestorePoint.Message)) }
        foreach ($res in @($session.Results)) {
            $w.WriteLine(('{0,-15} {1}' -f $res.Status, $res.Name))
            foreach ($s in @($res.Steps)) {
                $mark = if ($s.DryRun) { 'would' } elseif ($s.Succeeded) { 'ok' } else { 'FAILED' }
                $w.WriteLine(('    [{0}] {1}' -f $mark, $s.Description))
                if (-not $s.Succeeded -and $s.Output) { $w.WriteLine(('          {0}' -f ([string]$s.Output -replace '\r?\n', ' '))) }
            }
        }
        if ($session.RebootRequired) { $w.WriteLine('A reboot is required to finish.') }
    }
    if ($auditPath) { Write-OmniCliStatus $Io "Audit log: $auditPath" }
    Write-OmniCliStatus $Io "Log: $($logger.Path)"
    return $code
}

function Invoke-OmniCliRepair {
    <# .SYNOPSIS Internal: 'omnidiag repair list | run'. #>
    param($Parsed, $Io, [string] $RepairsPath)
    $pos = @($Parsed.Positionals)
    if ($pos.Count -eq 0) { throw (New-OmniCliUsageError "repair needs a subcommand: 'repair list' or 'repair run <id>...'") }
    $sub = $pos[0].ToLowerInvariant()
    $rest = @($pos | Select-Object -Skip 1)
    $o = $Parsed.Options
    switch ($sub) {
        'list' {
            if ($rest.Count -gt 0) { throw (New-OmniCliUsageError "unexpected argument '$($rest[0])'") }
            foreach ($flag in @(@('what-if', $o.WhatIf), @('apply', $o.Apply), @('yes', $o.Yes), @('allow-without-restore-point', $o.AllowWithoutRestorePoint))) {
                if ($flag[1]) { throw (New-OmniCliUsageError "--$($flag[0]) applies to 'repair run', not 'repair list'") }
            }
            return (Invoke-OmniCliRepairList -Parsed $Parsed -Io $Io -RepairsPath $RepairsPath)
        }
        'run' {
            if ($o.FromSession) { throw (New-OmniCliUsageError "--from-session applies to 'repair list', not 'repair run'") }
            return (Invoke-OmniCliRepairRun -Parsed $Parsed -Io $Io -RepairsPath $RepairsPath -Id ([string[]]$rest))
        }
    }
    throw (New-OmniCliUsageError "unknown repair subcommand '$sub' (valid: list, run)")
}

# ---------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------

function ConvertTo-OmniCliComparisonDocument {
    <# .SYNOPSIS Internal: a Compare-OmniSession result as the 'comparison' JSON document. #>
    param($Comparison, [string] $BeforePath, [string] $AfterPath)
    $finding = { param($f) [ordered]@{ id = [string]$f.Id; title = [string]$f.Title; severity = [string]$f.Severity; component = [string]$f.Component; module = [string]$f.ModuleName } }
    $improved = @($Comparison.Persisting | Where-Object { $_.Change -eq 'Improved' }).Count
    $worsened = @($Comparison.Persisting | Where-Object { $_.Change -eq 'Worsened' }).Count
    return [ordered]@{
        schemaVersion = $script:OmniCliDocSchemaVersion
        kind          = 'comparison'
        tool          = [ordered]@{ name = 'OmniDiag'; version = (Get-OmniCliToolVersion) }
        before        = [ordered]@{ path = $BeforePath; startTime = (ConvertTo-OmniIsoTimestamp $Comparison.BeforeTime); score = $Comparison.BeforeScore }
        after         = [ordered]@{ path = $AfterPath; startTime = (ConvertTo-OmniIsoTimestamp $Comparison.AfterTime); score = $Comparison.AfterScore }
        verdict       = [string]$Comparison.Verdict
        scoreDelta    = $Comparison.ScoreDelta
        counts        = [ordered]@{
            resolved = @($Comparison.Resolved).Count; new = @($Comparison.New).Count; persisting = @($Comparison.Persisting).Count
            improved = $improved; worsened = $worsened; outOfScope = @($Comparison.OutOfScope).Count
        }
        resolved      = @(foreach ($f in @($Comparison.Resolved)) { & $finding $f })
        new           = @(foreach ($f in @($Comparison.New)) { & $finding $f })
        persisting    = @(foreach ($p in @($Comparison.Persisting)) {
            [ordered]@{ id = [string]$p.Id; title = [string]$p.Title; component = [string]$p.Component
                beforeSeverity = [string]$p.BeforeSeverity; afterSeverity = [string]$p.AfterSeverity; change = [string]$p.Change }
        })
        moduleChanges = @(foreach ($m in @($Comparison.ModuleChanges)) {
            [ordered]@{ module = [string]$m.ModuleName; before = [string]$m.BeforeStatus; after = [string]$m.AfterStatus }
        })
    }
}

function ConvertTo-OmniCliComparisonText {
    <# .SYNOPSIS Internal: a comparison as plain text or Markdown. #>
    param($Document, [switch] $Markdown)
    $nl = "`n"
    $sb = [System.Text.StringBuilder]::new()
    $score = { param($s) if ($null -eq $s) { 'n/a' } else { "$s/100" } }
    $delta = if ($null -eq $Document.scoreDelta) { 'n/a' } elseif ($Document.scoreDelta -gt 0) { "+$($Document.scoreDelta)" } else { [string]$Document.scoreDelta }
    $c = $Document.counts
    if ($Markdown) {
        [void]$sb.Append('# OmniDiag comparison: ').Append($Document.verdict).Append($nl).Append($nl)
        $head = @(
            [pscustomobject][ordered]@{ session = 'Before'; path = $Document.before.path; started = $Document.before.startTime; score = (& $score $Document.before.score) }
            [pscustomobject][ordered]@{ session = 'After'; path = $Document.after.path; started = $Document.after.startTime; score = (& $score $Document.after.score) }
        )
        [void]$sb.Append((ConvertTo-OmniCliMarkdownTable -Rows $head)).Append($nl)
        [void]$sb.Append(('Score change: {0}. Resolved {1}, new {2}, persisting {3} ({4} improved, {5} worsened); {6} finding(s) not compared.' -f $delta, $c.resolved, $c.new, $c.persisting, $c.improved, $c.worsened, $c.outOfScope)).Append($nl).Append($nl)
        foreach ($section in @(@('Resolved', $Document.resolved), @('New', $Document.new))) {
            [void]$sb.Append('## ').Append($section[0]).Append($nl).Append($nl)
            $rows = @(foreach ($f in @($section[1])) { [pscustomobject][ordered]@{ severity = $f.severity; title = $f.title; component = $f.component; module = $f.module } })
            [void]$sb.Append((ConvertTo-OmniCliMarkdownTable -Rows $rows)).Append($nl)
        }
        [void]$sb.Append('## Persisting').Append($nl).Append($nl)
        $rows = @(foreach ($p in @($Document.persisting)) { [pscustomobject][ordered]@{ change = $p.change; before = $p.beforeSeverity; after = $p.afterSeverity; title = $p.title } })
        [void]$sb.Append((ConvertTo-OmniCliMarkdownTable -Rows $rows)).Append($nl)
        if (@($Document.moduleChanges).Count -gt 0) {
            [void]$sb.Append('## Module status changes').Append($nl).Append($nl)
            $rows = @(foreach ($m in @($Document.moduleChanges)) { [pscustomobject][ordered]@{ module = $m.module; before = $m.before; after = $m.after } })
            [void]$sb.Append((ConvertTo-OmniCliMarkdownTable -Rows $rows)).Append($nl)
        }
        return $sb.ToString()
    }

    [void]$sb.Append('OmniDiag comparison: ').Append($Document.verdict).Append($nl)
    [void]$sb.Append(('Before: {0} ({1}), score {2}' -f $Document.before.path, $Document.before.startTime, (& $score $Document.before.score))).Append($nl)
    [void]$sb.Append(('After:  {0} ({1}), score {2}' -f $Document.after.path, $Document.after.startTime, (& $score $Document.after.score))).Append($nl)
    [void]$sb.Append(('Score change: {0}' -f $delta)).Append($nl)
    foreach ($section in @(@('Resolved', $Document.resolved), @('New', $Document.new))) {
        [void]$sb.Append($nl).Append(('{0} ({1}):' -f $section[0], @($section[1]).Count)).Append($nl)
        foreach ($f in @($section[1])) { [void]$sb.Append(('  [{0}] {1} ({2})' -f $f.severity, $f.title, $f.module)).Append($nl) }
    }
    [void]$sb.Append($nl).Append(('Persisting ({0}):' -f @($Document.persisting).Count)).Append($nl)
    foreach ($p in @($Document.persisting)) {
        [void]$sb.Append(('  [{0} -> {1}] {2} ({3})' -f $p.beforeSeverity, $p.afterSeverity, $p.title, $p.change)).Append($nl)
    }
    if (@($Document.moduleChanges).Count -gt 0) {
        [void]$sb.Append($nl).Append('Module status changes:').Append($nl)
        foreach ($m in @($Document.moduleChanges)) { [void]$sb.Append(('  {0}: {1} -> {2}' -f $m.module, $m.before, $m.after)).Append($nl) }
    }
    if ($c.outOfScope -gt 0) {
        [void]$sb.Append($nl).Append(('{0} finding(s) not compared: their modules did not complete in both sessions.' -f $c.outOfScope)).Append($nl)
    }
    return $sb.ToString()
}

function Invoke-OmniCliCompare {
    <# .SYNOPSIS Internal: 'omnidiag compare <before> <after>'. #>
    param($Parsed, $Io)
    $pos = @($Parsed.Positionals)
    if ($pos.Count -ne 2) {
        throw (New-OmniCliUsageError "compare needs two sessions: compare <before> <after> (paths, report .zip files, 'last', or 'previous')")
    }
    $formats = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Parsed.Options.Format) {
        $n = $f.ToLowerInvariant()
        if ($n -eq 'markdown') { $n = 'md' }
        if ($n -eq 'txt') { $n = 'text' }
        if ($n -notin @('text', 'json', 'md')) { throw (New-OmniCliUsageError "compare supports --format text, json, or md (not '$f')") }
        if (-not $formats.Contains($n)) { $formats.Add($n) }
    }
    if ($formats.Count -gt 1) { throw (New-OmniCliUsageError 'compare writes one format at a time') }
    $output = if ($Parsed.Options.Output) { Resolve-OmniCliPath $Parsed.Options.Output } else { $null }
    $fmt = 'text'
    if ($formats.Count -eq 1) { $fmt = $formats[0] }
    elseif ($output) {
        $implied = Get-OmniCliFormatFromPath $output
        if ($implied -in @('json', 'md')) { $fmt = $implied }
    }

    $paths = @()
    $sessions = @()
    foreach ($ref in $pos) {
        try {
            $p = Resolve-OmniSessionPath -Value $ref
            $sessions += , (Import-OmniSession -Path $p)
            $paths += $p
        } catch { throw (New-OmniCliUsageError "cannot read session '$ref': $($_.Exception.Message)") }
    }
    $cmp = Compare-OmniSession -Before $sessions[0] -After $sessions[1]
    $doc = ConvertTo-OmniCliComparisonDocument -Comparison $cmp -BeforePath $paths[0] -AfterPath $paths[1]
    $text = switch ($fmt) {
        'json' { (ConvertTo-OmniJsonText -InputObject $doc) + "`n" }
        'md'   { ConvertTo-OmniCliComparisonText -Document $doc -Markdown }
        default { ConvertTo-OmniCliComparisonText -Document $doc }
    }
    if ($output) {
        $target = $output
        if (Test-OmniCliDirectoryTarget $output) {
            $ext = if ($fmt -eq 'text') { 'txt' } else { $fmt }
            $target = Join-Path $output "omnidiag-compare.$ext"
        }
        Write-OmniCliFile -Path $target -Content $text
        Write-OmniCliStatus $Io "Wrote $target"
    } else {
        $Io.Out.Write($text)
    }
    Write-OmniCliStatus $Io "Verdict: $($doc.verdict)"
    # Exit 0 whenever the comparison ran, also for a Regressed verdict (see docs/CLI.md).
    return 0
}

# ---------------------------------------------------------------------------
# gui
# ---------------------------------------------------------------------------

function Invoke-OmniCliGui {
    <# .SYNOPSIS Internal: 'omnidiag gui' (Windows only). #>
    param($Parsed, $Io, [string[]] $ModulesPath, [string] $RepairsPath)
    if (@($Parsed.Positionals).Count -gt 0) { throw (New-OmniCliUsageError "unexpected argument '$($Parsed.Positionals[0])'") }
    if ($Parsed.Options.Format.Count -gt 0 -or $Parsed.Options.Output) { throw (New-OmniCliUsageError 'gui takes no --format or --output') }
    if (-not (Test-OmniCliWindows)) { throw (New-OmniCliUsageError 'the GUI needs Windows (WPF); use the other omnidiag commands on this system') }
    Write-OmniCliStatus $Io 'Opening the OmniDiag window...'
    Show-OmniDiagGui -ModulesPath @($ModulesPath)[0] -RepairsPath $RepairsPath
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-OmniDiagCli {
    <#
    .SYNOPSIS
        Runs one omnidiag CLI command from GNU-style arguments and returns the exit code.

    .DESCRIPTION
        Commands: list [modules|groups|repairs|plans], scan, report, repair list | run,
        compare, gui, version, help, and '<group-id>' as shorthand for
        'scan --group <group-id>'. Global options: --format json|csv|md|html|pdf,
        --output <path>, --verbose, --quiet, --no-color, --help. See docs/CLI.md and
        Get-OmniCliUsage.

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
        Writer for stderr (progress, status, prompts, errors). Default: [Console]::Error.

    .PARAMETER In
        Reader for the answers to 'repair run --apply' prompts. Default: [Console]::In,
        treated as interactive only when standard input is not redirected. A reader passed
        here is treated as interactive unless -NonInteractive.

    .PARAMETER NonInteractive
        Treat standard input as non-interactive ('repair run --apply' then needs --yes).

    .OUTPUTS
        [int] process exit code.

    .EXAMPLE
        exit (Invoke-OmniDiagCli -Arguments $args)

    .EXAMPLE
        $code = Invoke-OmniDiagCli -Arguments @('list', 'modules', '--format', 'json')

    .EXAMPLE
        $code = Invoke-OmniDiagCli -Arguments @('repair', 'run', 'flush-dns-cache', '--what-if')
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Arguments = @(),
        [string[]] $ModulesPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'),
        [string] $RepairsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Repairs'),
        [System.IO.TextWriter] $Out = [Console]::Out,
        [System.IO.TextWriter] $Err = [Console]::Error,
        [System.IO.TextReader] $In,
        [switch] $NonInteractive
    )

    $interactive = $false
    if ($In) {
        $interactive = -not $NonInteractive
    } else {
        $In = [Console]::In
        try { $interactive = (-not $NonInteractive) -and (-not [Console]::IsInputRedirected) } catch { $interactive = $false }
    }
    $io = [pscustomobject]@{ Out = $Out; Err = $Err; In = $In; Interactive = $interactive; Quiet = $false }
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
            'list'    { return (Invoke-OmniCliList -Parsed $parsed -Io $io -ModulesPath $ModulesPath -RepairsPath $RepairsPath) }
            'scan'    { return (Invoke-OmniCliScan -Parsed $parsed -Io $io -ModulesPath $ModulesPath) }
            'report'  { return (Invoke-OmniCliScan -Parsed $parsed -Io $io -ModulesPath $ModulesPath -Report) }
            'repair'  { return (Invoke-OmniCliRepair -Parsed $parsed -Io $io -RepairsPath $RepairsPath) }
            'compare' { return (Invoke-OmniCliCompare -Parsed $parsed -Io $io) }
            'gui'     { return (Invoke-OmniCliGui -Parsed $parsed -Io $io -ModulesPath $ModulesPath -RepairsPath $RepairsPath) }
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
        if ($ex.Data.Contains('OmniCliExitCode')) {
            $Err.WriteLine("omnidiag: $($ex.Message)")
            return [int]$ex.Data['OmniCliExitCode']
        }
        $Err.WriteLine("omnidiag: internal error: $($ex.Message)")
        return 20
    }
}

Export-ModuleMember -Function @('Invoke-OmniDiagCli', 'Get-OmniCliUsage')
