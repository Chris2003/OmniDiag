#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Module contract v1: every scanner and repair registration has a unique, well-formed
    Id, a valid Group / NetworkAccess / TimeoutSec / SupportedArchitectures, and matches
    the agreed conventions table. Also covers derived defaults for older manifests and
    the rejection of invalid values and duplicate Ids. OS-independent (discovery only;
    the fake plugins used for the engine check run on any host).
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:Logger = New-OmniLogger -MinimumLevel Error
    $script:Scanners = @(Get-OmniModule -Path (Join-Path $root 'src/Modules') -Logger $script:Logger)
    $script:Repairs = @(Get-OmniRepair -Path (Join-Path $root 'src/Repairs') -Logger $script:Logger)

    # The conventions table (binding for 0.5.0): scanner name -> group; anything else is 'extras'.
    $script:ExpectedGroup = @{
        'System Information' = 'system'; 'System' = 'system'
        'Performance' = 'performance'; 'CPU' = 'performance'; 'Memory' = 'performance'; 'Processes' = 'performance'; 'Startup Performance' = 'performance'
        'Services' = 'services'; 'Drivers' = 'services'
        'Startup' = 'startup'; 'Scheduled Tasks' = 'startup'; 'Registry Health' = 'startup'
        'Event Logs' = 'events'; 'Error Summary' = 'events'
        'Reliability' = 'reliability'
        'Storage' = 'storage'; 'Disk' = 'storage'; 'Disk Usage' = 'storage'
        'Network' = 'network'; 'IP Configuration' = 'network'; 'DNS Resolver' = 'network'; 'Hosts File' = 'network'
        'Network Shares' = 'network'; 'WiFi Networks' = 'network'; 'Proxy Configuration' = 'network'; 'VPN' = 'network'
        'Windows Health' = 'updates'; 'Windows Update' = 'updates'; 'System Health' = 'updates'; 'Update Rings' = 'updates'
        'Security' = 'security'; 'Firewall Rules' = 'security'; 'Certificates' = 'security'; 'BitLocker' = 'security'; 'Defender Onboarding' = 'security'
    }
    $script:ExpectedNetwork = @{ 'Network' = 'Internet'; 'DNS Resolver' = 'Internet'; 'Active Directory' = 'LocalNetwork'; 'Repair Component Store (DISM)' = 'Internet'; 'Release / Renew IP Address' = 'LocalNetwork' }
    $script:IdPattern = '^[a-z0-9]+(?:[.-][a-z0-9]+)*$'

    function ConvertTo-TestKebab([string] $Name) { ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }

    function New-PluginFolder {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function New-ScannerPlugin {
        param([string] $Folder, [string] $File, [string] $ManifestBody)
        $text = @"
function Get-OmniModuleManifest { @{ $ManifestBody } }
function Invoke-OmniModuleScan {
    param(`$Context)
    `$m = Get-OmniModuleManifest
    `$r = New-OmniResult -ModuleName `$m.Name -Category `$m.Category
    Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'ok' -Severity 'Pass')
    return (Complete-OmniResult -Result `$r)
}
Export-ModuleMember -Function 'Get-OmniModuleManifest', 'Invoke-OmniModuleScan'
"@
        Set-Content -LiteralPath (Join-Path $Folder $File) -Value $text -Encoding ascii
    }

    function New-RepairPlugin {
        param([string] $Folder, [string] $File, [string] $ManifestBody)
        $text = @"
function Get-OmniRepairManifest { @{ $ManifestBody } }
function Invoke-OmniRepairAction { param(`$Context) }
Export-ModuleMember -Function 'Get-OmniRepairManifest', 'Invoke-OmniRepairAction'
"@
        Set-Content -LiteralPath (Join-Path $Folder $File) -Value $text -Encoding ascii
    }
}

Describe 'Scanner registrations (contract v1)' {
    It 'discovers all 49 built-in scanners' {
        $script:Scanners.Count | Should -Be 49
    }

    It 'gives every scanner a unique, well-formed Id' {
        foreach ($r in $script:Scanners) { $r.Id | Should -Match $script:IdPattern -Because "$($r.Name) needs a kebab/dotted id" }
        @($script:Scanners.Id | Select-Object -Unique).Count | Should -Be $script:Scanners.Count
    }

    It 'gives every scanner a valid Group, NetworkAccess, TimeoutSec, and architecture list' {
        foreach ($r in $script:Scanners) {
            $r.Group | Should -BeIn (Get-OmniGroupNames)
            $r.NetworkAccess | Should -BeIn @('None', 'LocalNetwork', 'Internet')
            $r.TimeoutSec | Should -BeGreaterThan 0
            @($r.SupportedArchitectures) | Should -Not -BeNullOrEmpty
            foreach ($a in $r.SupportedArchitectures) { $a | Should -BeIn @('x64', 'arm64') }
            $r.RequiresElevation | Should -Be $r.RequiresAdmin
        }
    }

    It 'matches the conventions table (group, id, network access)' {
        foreach ($r in $script:Scanners) {
            $group = if ($script:ExpectedGroup.ContainsKey($r.Name)) { $script:ExpectedGroup[$r.Name] } else { 'extras' }
            $net = if ($script:ExpectedNetwork.ContainsKey($r.Name)) { $script:ExpectedNetwork[$r.Name] } else { 'None' }
            $r.Group | Should -Be $group -Because "$($r.Name) belongs to '$group'"
            $r.Id | Should -Be ("{0}.{1}" -f $group, (ConvertTo-TestKebab $r.Name))
            $r.NetworkAccess | Should -Be $net -Because "$($r.Name) network access"
        }
    }

    It 'declares Id, Group, and NetworkAccess explicitly in every manifest (no derived defaults)' {
        foreach ($r in $script:Scanners) {
            $m = & $r.ModuleInfo { Get-OmniModuleManifest }
            foreach ($key in @('Id', 'Group', 'NetworkAccess')) {
                $m.ContainsKey($key) | Should -BeTrue -Because "$($r.Name) must declare $key"
            }
        }
    }

    It 'uses every v1.0 group at least once' {
        foreach ($g in (Get-OmniGroupNames)) { $script:Scanners.Group | Should -Contain $g }
    }
}

Describe 'Repair registrations (contract v1)' {
    It 'discovers all 11 built-in repairs with unique repair.* Ids' {
        $script:Repairs.Count | Should -Be 11
        @($script:Repairs.Id | Select-Object -Unique).Count | Should -Be 11
        foreach ($r in $script:Repairs) {
            $r.Id | Should -Be ("repair.{0}" -f (ConvertTo-TestKebab $r.Name))
            $r.Id | Should -Match $script:IdPattern
        }
    }

    It 'labels network access per the conventions (DISM Internet, IP renew LocalNetwork, the rest None)' {
        foreach ($r in $script:Repairs) {
            $net = if ($script:ExpectedNetwork.ContainsKey($r.Name)) { $script:ExpectedNetwork[$r.Name] } else { 'None' }
            $r.NetworkAccess | Should -Be $net -Because $r.Name
            $r.TimeoutSec | Should -BeGreaterThan 0
            $r.RequiresElevation | Should -Be $r.RequiresAdmin
        }
    }

    It 'declares Id and NetworkAccess explicitly in every manifest' {
        foreach ($r in $script:Repairs) {
            $m = & $r.ModuleInfo { Get-OmniRepairManifest }
            $m.ContainsKey('Id') | Should -BeTrue -Because $r.Name
            $m.ContainsKey('NetworkAccess') | Should -BeTrue -Because $r.Name
        }
    }

    It 'never collides with a scanner Id' {
        foreach ($id in $script:Repairs.Id) { $script:Scanners.Id | Should -Not -Contain $id }
    }
}

Describe 'Derived defaults for manifests without contract v1 fields' {
    It 'derives Id, Group, NetworkAccess, TimeoutSec, and architectures' {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'OldStyle.psm1' -ManifestBody "Name = 'Old Style Check'; Category = 'Custom'"
        $reg = @(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $reg.Count | Should -Be 1
        $reg[0].Id | Should -Be 'extras.old-style-check'
        $reg[0].Group | Should -Be 'extras'
        $reg[0].NetworkAccess | Should -Be 'None'
        $reg[0].TimeoutSec | Should -Be 60
        $reg[0].SupportedArchitectures | Should -Be @('x64', 'arm64')
        $reg[0].RequiresElevation | Should -BeFalse
    }

    It 'derives the Id from a declared Group and honors RequiresElevation as an alias' {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'Grouped.psm1' -ManifestBody "Name = 'Grouped Check'; Category = 'Custom'; Group = 'storage'; RequiresElevation = `$true; TimeoutSec = 15; SupportedArchitectures = @('x64')"
        $reg = @(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $reg[0].Id | Should -Be 'storage.grouped-check'
        $reg[0].RequiresAdmin | Should -BeTrue
        $reg[0].RequiresElevation | Should -BeTrue
        $reg[0].TimeoutSec | Should -Be 15
        @($reg[0].SupportedArchitectures) | Should -Be @('x64')
    }

    It 'derives repair Ids as repair.kebab-name' {
        $dir = New-PluginFolder
        New-RepairPlugin -Folder $dir -File 'OldRepair.psm1' -ManifestBody "Name = 'Fix The Thing (Now)'; Category = 'System'"
        $reg = @(Get-OmniRepair -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $reg[0].Id | Should -Be 'repair.fix-the-thing-now'
        $reg[0].NetworkAccess | Should -Be 'None'
    }
}

Describe 'Contract violations are logged and skipped' {
    It 'rejects a duplicate scanner Id and keeps the first registration' {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'DupA.psm1' -ManifestBody "Name = 'Dup A'; Category = 'Custom'; Id = 'extras.same-id'; Group = 'extras'"
        New-ScannerPlugin -Folder $dir -File 'DupB.psm1' -ManifestBody "Name = 'Dup B'; Category = 'Custom'; Id = 'extras.same-id'; Group = 'extras'"
        $log = New-OmniLogger -MinimumLevel Debug
        $reg = @(Get-OmniModule -Path $dir -Logger $log)
        $reg.Count | Should -Be 1
        $reg[0].Id | Should -Be 'extras.same-id'
        @($log.Buffer | Where-Object { $_.Level -eq 'Error' -and $_.Message -match 'already used' }).Count | Should -Be 1
    }

    It 'rejects a duplicate Id across plugin folders' {
        $a = New-PluginFolder; $b = New-PluginFolder
        New-ScannerPlugin -Folder $a -File 'FolderA.psm1' -ManifestBody "Name = 'Folder A'; Category = 'Custom'; Id = 'extras.shared'"
        New-ScannerPlugin -Folder $b -File 'FolderB.psm1' -ManifestBody "Name = 'Folder B'; Category = 'Custom'; Id = 'extras.shared'"
        @(Get-OmniModule -Path $a, $b -Logger (New-OmniLogger -MinimumLevel Error)).Count | Should -Be 1
    }

    It 'rejects a duplicate repair Id' {
        $dir = New-PluginFolder
        New-RepairPlugin -Folder $dir -File 'RepA.psm1' -ManifestBody "Name = 'Rep A'; Category = 'System'; Id = 'repair.same'"
        New-RepairPlugin -Folder $dir -File 'RepB.psm1' -ManifestBody "Name = 'Rep B'; Category = 'System'; Id = 'repair.same'"
        @(Get-OmniRepair -Path $dir -Logger (New-OmniLogger -MinimumLevel Error)).Count | Should -Be 1
    }

    It 'rejects an invalid <Field>' -ForEach @(
        @{ Field = 'NetworkAccess'; Body = "NetworkAccess = 'Sometimes'" }
        @{ Field = 'Group'; Body = "Group = 'gaming'" }
        @{ Field = 'Id'; Body = "Id = 'Not A Valid Id'" }
        @{ Field = 'TimeoutSec'; Body = 'TimeoutSec = 0' }
        @{ Field = 'SupportedArchitectures'; Body = "SupportedArchitectures = @('mips')" }
    ) {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'Bad.psm1' -ManifestBody "Name = 'Bad Plugin'; Category = 'Custom'; $Body"
        $log = New-OmniLogger -MinimumLevel Error
        @(Get-OmniModule -Path $dir -Logger $log).Count | Should -Be 0
        @($log.Buffer | Where-Object Level -eq 'Error').Count | Should -Be 1
    }

    It 'accepts NetworkAccess case-insensitively and normalizes it' {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'Lan.psm1' -ManifestBody "Name = 'Lan Probe'; Category = 'Custom'; Group = 'network'; NetworkAccess = 'localnetwork'"
        (@(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error)))[0].NetworkAccess | Should -Be 'LocalNetwork'
    }
}

Describe 'Engine stamps contract identity on results' {
    It 'adds ModuleId, Group, and SkippedReason to each result' {
        $dir = New-PluginFolder
        New-ScannerPlugin -Folder $dir -File 'Stamped.psm1' -ManifestBody "Name = 'Stamped'; Category = 'Custom'; Group = 'system'"
        New-ScannerPlugin -Folder $dir -File 'NeedsAdmin.psm1' -ManifestBody "Name = 'Needs Admin'; Category = 'Custom'; RequiresAdmin = `$true"
        $regs = @(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error)
        $session = Invoke-OmniSession -Registration $regs -Context $ctx
        $stamped = $session.Results | Where-Object ModuleName -eq 'Stamped'
        $stamped.ModuleId | Should -Be 'system.stamped'
        $stamped.Group | Should -Be 'system'
        $stamped.SkippedReason | Should -BeNullOrEmpty
        $admin = $session.Results | Where-Object ModuleName -eq 'Needs Admin'
        $admin.ModuleId | Should -Be 'extras.needs-admin'
        if (-not $ctx.IsAdmin) { $admin.SkippedReason | Should -Be 'RequiresElevation' }
    }

    It 'derives identities for registrations without contract fields (older callers)' {
        (Resolve-OmniModuleIdentity -Name 'DNS Resolver').Id | Should -Be 'network.dns-resolver'
        (Resolve-OmniModuleIdentity -Name 'Something New').Id | Should -Be 'extras.something-new'
        (Resolve-OmniModuleIdentity -Name 'X' -ModuleId 'system.x' -Group 'system').Id | Should -Be 'system.x'
    }
}
