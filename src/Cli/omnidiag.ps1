<#
.SYNOPSIS
    omnidiag - the OmniDiag command-line interface (script entry point).

.DESCRIPTION
    Thin entry point for the CLI router: imports the OmniDiag module from the tool
    folder, hands every argument to Invoke-OmniDiagCli unchanged (GNU-style:
    'omnidiag scan --group network --format json'), and exits with the router's
    exit code. Normally started by OmniDiag.cmd, which sets up the portable,
    zero-footprint environment and dispatches subcommands here.

    This script deliberately has no param() block: PowerShell parameter binding
    would otherwise try to interpret '--format' and friends. Everything arrives in
    $args.

    Exit codes: see docs/CLI.md or 'omnidiag help'.

.EXAMPLE
    .\src\Cli\omnidiag.ps1 list modules --format json

.EXAMPLE
    .\src\Cli\omnidiag.ps1 report --output .\out
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$code = 20
try {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'OmniDiag.psd1'
    Import-Module $manifest -Force -DisableNameChecking
    try {
        $code = Invoke-OmniDiagCli -Arguments ([string[]]@($args))
    } finally {
        # Remove OmniDiag's scratch files on every exit path; logs, reports, and
        # saved sessions stay in OmniDiagData.
        try { Clear-OmniTempData } catch { }
    }
} catch {
    [Console]::Error.WriteLine("omnidiag: internal error: $($_.Exception.Message)")
    $code = 20
}
exit $code
