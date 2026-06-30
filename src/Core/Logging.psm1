<#
.SYNOPSIS
    Structured, leveled logging for OmniDiag.

.DESCRIPTION
    Produces a logger object whose methods emit structured records (timestamp,
    level, component, message, optional data) to:
      * an in-memory ring buffer (for surfacing in the UI / reports),
      * a JSON-lines file on disk (durable audit trail),
      * optionally the host console (for the CLI runner).

    Honors the project requirement of "no silent failures": every module run is
    logged, and exceptions are captured rather than swallowed.
#>

Set-StrictMode -Version Latest

$script:OmniLogLevels = [ordered]@{
    Debug   = 0
    Info    = 1
    Warn    = 2
    Error   = 3
}

function New-OmniLogger {
    <#
    .SYNOPSIS
        Creates a logger instance.

    .PARAMETER Path
        Path to a .jsonl log file. Created if missing. When omitted, file logging
        is disabled (in-memory + optional console only).

    .PARAMETER MinimumLevel
        Lowest level to record. Default Info.

    .PARAMETER Console
        When set, also writes human-readable lines to the host.

    .PARAMETER MaxBufferSize
        Max in-memory records retained (ring buffer). Default 5000.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string] $MinimumLevel = 'Info',
        [switch] $Console,
        [int] $MaxBufferSize = 5000
    )

    if ($Path) {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $logger = [pscustomobject]@{
        PSTypeName    = 'OmniDiag.Logger'
        Path          = $Path
        MinimumLevel  = $MinimumLevel
        Console       = [bool]$Console
        MaxBufferSize = $MaxBufferSize
        Buffer        = [System.Collections.Generic.List[object]]::new()
    }

    $writer = {
        param([string] $Level, [string] $Message, [string] $Component, [object] $Data)

        $levels = $script:OmniLogLevels
        if ($levels[$Level] -lt $levels[$this.MinimumLevel]) { return }

        $record = [pscustomobject]@{
            Timestamp = (Get-Date).ToString('o')
            Level     = $Level
            Component = $Component
            Message   = $Message
            Data      = $Data
        }

        # In-memory ring buffer.
        $this.Buffer.Add($record)
        if ($this.Buffer.Count -gt $this.MaxBufferSize) {
            $this.Buffer.RemoveAt(0)
        }

        # Durable JSON-lines file. Never throw from the logger itself.
        if ($this.Path) {
            try {
                $json = $record | ConvertTo-Json -Compress -Depth 6
                Add-Content -LiteralPath $this.Path -Value $json -Encoding UTF8 -ErrorAction Stop
            } catch {
                Write-Warning "OmniDiag logger could not write to '$($this.Path)': $($_.Exception.Message)"
            }
        }

        if ($this.Console) {
            $color = switch ($Level) {
                'Debug' { 'DarkGray' }
                'Info'  { 'Gray' }
                'Warn'  { 'Yellow' }
                'Error' { 'Red' }
            }
            $prefix = "[{0:HH:mm:ss}] {1,-5}" -f (Get-Date), $Level.ToUpper()
            $comp = if ($Component) { " ($Component)" } else { '' }
            Write-Host "$prefix$comp $Message" -ForegroundColor $color
        }
    }

    Add-Member -InputObject $logger -MemberType ScriptMethod -Name Log -Value $writer
    Add-Member -InputObject $logger -MemberType ScriptMethod -Name Debug -Value {
        param([string] $Message, [string] $Component = '', [object] $Data = $null)
        $this.Log('Debug', $Message, $Component, $Data)
    }
    Add-Member -InputObject $logger -MemberType ScriptMethod -Name Info -Value {
        param([string] $Message, [string] $Component = '', [object] $Data = $null)
        $this.Log('Info', $Message, $Component, $Data)
    }
    Add-Member -InputObject $logger -MemberType ScriptMethod -Name Warn -Value {
        param([string] $Message, [string] $Component = '', [object] $Data = $null)
        $this.Log('Warn', $Message, $Component, $Data)
    }
    Add-Member -InputObject $logger -MemberType ScriptMethod -Name Error -Value {
        param([string] $Message, [string] $Component = '', [object] $Data = $null)
        $this.Log('Error', $Message, $Component, $Data)
    }

    return $logger
}

Export-ModuleMember -Function 'New-OmniLogger'
