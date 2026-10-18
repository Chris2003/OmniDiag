<#
.SYNOPSIS
    OmniDiag core: shared, read-only system inventory (operating system, computer system,
    firmware, board, processor, graphics, sound, page file).

.DESCRIPTION
    One place for the CIM queries behind the device inventory, used by the System
    Information scanner, the System scanner (boot time, processor architecture), and the
    GUI's System Information panel. Every query fails soft: a class that cannot be read
    (non-Windows host, WMI repository problem, sandbox) is left $null and its error is
    recorded in Errors, so callers never have to catch.

    Only local CIM classes in root/cimv2 are queried; nothing here contacts another host.
#>

Set-StrictMode -Version Latest

# Section name -> CIM class and the properties copied into the inventory. Copying into
# plain objects keeps callers independent of CimInstance (and easy to fake in tests).
$script:OmniInventorySections = [ordered]@{
    OperatingSystem = @{ Class = 'Win32_OperatingSystem'; Many = $false; Properties = @('Caption', 'Version', 'BuildNumber', 'OSArchitecture', 'InstallDate', 'LastBootUpTime') }
    ComputerSystem  = @{ Class = 'Win32_ComputerSystem';  Many = $false; Properties = @('Name', 'Manufacturer', 'Model', 'SystemType', 'Domain', 'Workgroup', 'PartOfDomain', 'TotalPhysicalMemory', 'UserName') }
    Bios            = @{ Class = 'Win32_BIOS';            Many = $false; Properties = @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate', 'SerialNumber') }
    BaseBoard       = @{ Class = 'Win32_BaseBoard';       Many = $false; Properties = @('Manufacturer', 'Product') }
    Processor       = @{ Class = 'Win32_Processor';       Many = $false; Properties = @('Name', 'NumberOfCores', 'NumberOfLogicalProcessors', 'MaxClockSpeed', 'Architecture', 'VirtualizationFirmwareEnabled') }
    VideoController = @{ Class = 'Win32_VideoController'; Many = $true;  Properties = @('Name', 'VideoProcessor', 'AdapterCompatibility', 'AdapterRAM', 'CurrentHorizontalResolution', 'CurrentVerticalResolution', 'CurrentRefreshRate', 'DriverVersion', 'DriverDate') }
    SoundDevice     = @{ Class = 'Win32_SoundDevice';     Many = $true;  Properties = @('Name') }
    PageFile        = @{ Class = 'Win32_PageFileUsage';   Many = $false; Properties = @('CurrentUsage', 'AllocatedBaseSize') }
}

function Get-OmniInventoryCimInstance {
    <#
    .SYNOPSIS
        Internal: run one local CIM query (seam for tests). Throws on failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClassName)
    return Get-CimInstance -ClassName $ClassName -Namespace 'root/cimv2' -ErrorAction Stop
}

function Get-OmniSystemInventory {
    <#
    .SYNOPSIS
        Returns the device inventory as plain objects, one property per section.

    .DESCRIPTION
        Queries the CIM classes behind each requested section and returns a
        pscustomobject with these properties:

          OperatingSystem  Win32_OperatingSystem: Caption, Version, BuildNumber,
                           OSArchitecture, InstallDate, LastBootUpTime
          ComputerSystem   Win32_ComputerSystem: Name, Manufacturer, Model, SystemType,
                           Domain, Workgroup, PartOfDomain, TotalPhysicalMemory, UserName
          Bios             Win32_BIOS: Manufacturer, SMBIOSBIOSVersion, ReleaseDate, SerialNumber
          BaseBoard        Win32_BaseBoard: Manufacturer, Product
          Processor        first Win32_Processor: Name, NumberOfCores,
                           NumberOfLogicalProcessors, MaxClockSpeed, Architecture,
                           VirtualizationFirmwareEnabled
          VideoController  every Win32_VideoController (array)
          SoundDevice      every Win32_SoundDevice (array of objects with Name)
          PageFile         first Win32_PageFileUsage: CurrentUsage, AllocatedBaseSize
          Errors           list of 'Class: message' strings for queries that failed

        A section that was not requested, or whose query failed or returned nothing, is
        $null (arrays: empty). Read-only; local CIM only; never throws.

    .PARAMETER Section
        Sections to collect. Default: all of them.

    .EXAMPLE
        $inv = Get-OmniSystemInventory -Section OperatingSystem, Processor
        $inv.OperatingSystem.LastBootUpTime
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('OperatingSystem', 'ComputerSystem', 'Bios', 'BaseBoard', 'Processor', 'VideoController', 'SoundDevice', 'PageFile')]
        [string[]] $Section = @('OperatingSystem', 'ComputerSystem', 'Bios', 'BaseBoard', 'Processor', 'VideoController', 'SoundDevice', 'PageFile')
    )

    $inventory = [ordered]@{}
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $script:OmniInventorySections.Keys) {
        $spec = $script:OmniInventorySections[$name]
        $value = $null
        if ($spec.Many) { $value = @() }
        if ($Section -contains $name) {
            try {
                $raw = @(Get-OmniInventoryCimInstance -ClassName $spec.Class | Where-Object { $null -ne $_ })
                $copies = @(foreach ($item in $raw) {
                    $o = [ordered]@{}
                    foreach ($p in $spec.Properties) {
                        $prop = $item.PSObject.Properties[$p]
                        $o[$p] = if ($prop) { $prop.Value } else { $null }
                    }
                    [pscustomobject]$o
                })
                if ($spec.Many) { $value = [object[]]$copies }
                elseif ($copies.Count -gt 0) { $value = $copies[0] }
            } catch {
                $errors.Add(('{0}: {1}' -f $spec.Class, $_.Exception.Message))
            }
        }
        $inventory[$name] = $value
    }
    $inventory['Errors'] = $errors.ToArray()
    return [pscustomobject]$inventory
}

Export-ModuleMember -Function @('Get-OmniSystemInventory')
