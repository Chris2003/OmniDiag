<#
    Deterministic fixture session for the report schema v1 tests (golden file,
    Markdown, CLI). Dot-source after importing src/OmniDiag.psd1, then call
    New-OmniReportFixtureSession. Every timestamp is a fixed UTC value, so the v1
    projection is identical in every time zone and culture.

    Regenerate the golden file (only when the v1 projection changes on purpose):
        Import-Module ./src/OmniDiag.psd1 -Force
        . ./Tests/golden/ReportFixture.ps1
        $json = ConvertTo-OmniReportV1 -Session (New-OmniReportFixtureSession) `
            -Option (Get-OmniReportFixtureOption) -GeneratedAt (Get-OmniReportFixtureTime) | ConvertTo-OmniJsonText
        [IO.File]::WriteAllText("$PWD/Tests/golden/report-v1.fixture.json", $json + "`n")
#>

function Get-OmniReportFixtureTime {
    param([int] $Seconds = 0)
    return [datetime]::new(2026, 6, 1, 8, 0, 0, [System.DateTimeKind]::Utc).AddSeconds($Seconds)
}

function Get-OmniReportFixtureOption {
    return @{ range = 'Last7Days'; command = 'scan'; groups = @('system', 'network') }
}

function New-OmniReportFixtureResult {
    param(
        [string] $Name, [string] $Category, [object[]] $Finding = @(), [int] $StartSecond, [int] $DurationMs,
        [string] $ModuleId, [string] $Group, [string] $Status, [bool] $RequiresAdmin = $false,
        [string] $SkippedReason, [string] $ErrorText
    )
    $r = New-OmniResult -ModuleName $Name -Category $Category -RequiresAdmin $RequiresAdmin -HadAdmin $false
    foreach ($f in $Finding) {
        $f.Timestamp = Get-OmniReportFixtureTime -Seconds $StartSecond
        Add-OmniFinding -Result $r -Finding $f
    }
    if ($Status) { Complete-OmniResult -Result $r -Status $Status | Out-Null } else { Complete-OmniResult -Result $r | Out-Null }
    $r.StartTime = Get-OmniReportFixtureTime -Seconds $StartSecond
    $r.EndTime = $r.StartTime.AddMilliseconds($DurationMs)
    $r.DurationMs = $DurationMs
    if ($ErrorText) { $r.Error = $ErrorText }
    if ($ModuleId) {
        Add-Member -InputObject $r -MemberType NoteProperty -Name ModuleId -Value $ModuleId -Force
        Add-Member -InputObject $r -MemberType NoteProperty -Name Group -Value $Group -Force
        Add-Member -InputObject $r -MemberType NoteProperty -Name SkippedReason -Value $(if ($SkippedReason) { $SkippedReason } else { $null }) -Force
    }
    return $r
}

function New-OmniReportFixtureSession {
    $eAcute = [string][char]0x00E9

    $sys = New-OmniReportFixtureResult -Name 'System Information' -Category 'System' -StartSecond 1 -DurationMs 120 `
        -ModuleId 'system.system-information' -Group 'system' -Finding @(
            (New-OmniFinding -Title 'System inventory collected' -Severity 'Pass' -Component 'System' -Detail 'Inventory read.')
        )
    Set-OmniResultMetric -Result $sys -Name 'Manufacturer' -Value 'Contoso'
    Set-OmniResultMetric -Result $sys -Name 'Model' -Value "TestBook 9000 Caf$eAcute"
    Set-OmniResultMetric -Result $sys -Name 'MemoryGB' -Value 15.5
    Set-OmniResultMetric -Result $sys -Name 'InstallDate' -Value (Get-OmniReportFixtureTime -Seconds -86400)
    Set-OmniResultMetric -Result $sys -Name 'Disks' -Value @([ordered]@{ Name = 'C:'; FreeGB = 12 })

    $net = New-OmniReportFixtureResult -Name 'DNS Resolver' -Category 'Network' -StartSecond 2 -DurationMs 340 `
        -ModuleId 'network.dns-resolver' -Group 'network' -Finding @(
            (New-OmniFinding -Id 'network-dns-failure' -Title 'DNS resolution is failing' -Severity 'Critical' -Component 'Network/DNS' `
                -Detail "Lookups for 2 names timed out.`nSecond line | pipe" -LikelyCause 'DNS server unreachable.' -Confidence 80 `
                -Recommendation 'Check the configured DNS servers.' -Data @{ zeta = 1; alpha = 'a'; Servers = @('10.0.0.1', '10.0.0.2') }),
            (New-OmniFinding -Title '<script>alert(1)</script>' -Severity 'Warning' -Component 'Network/Test' -Recommendation 'Ignore "quoted" \ text.'),
            (New-OmniFinding -Title 'Resolver cache size' -Severity 'Information' -Component 'Network/DNS' -Data ([ordered]@{ Entries = 42; Ratio = 0.25 }))
        )

    # A result saved before contract v1: no ModuleId/Group, derived from the built-in table.
    $disk = New-OmniReportFixtureResult -Name 'Disk' -Category 'Storage' -StartSecond 3 -DurationMs 80 -Finding @(
        (New-OmniFinding -Id 'storage-c-low' -Title 'Low free space on C:' -Severity 'Error' -Component 'Storage/C:' -Confidence 90 -Recommendation 'Free up space.')
    )

    $skip = New-OmniReportFixtureResult -Name 'BitLocker' -Category 'Security' -StartSecond 4 -DurationMs 0 -Status 'Skipped' `
        -ModuleId 'security.bitlocker' -Group 'security' -RequiresAdmin $true -SkippedReason 'RequiresElevation' -Finding @(
            (New-OmniFinding -Title 'BitLocker skipped (requires administrator)' -Severity 'Information' -Component 'Security')
        )

    $fail = New-OmniReportFixtureResult -Name 'Custom Plugin' -Category 'Custom' -StartSecond 5 -DurationMs 5 -Status 'Failed' `
        -ModuleId 'extras.custom-plugin' -Group 'extras' -ErrorText 'intentional failure' -Finding @(
            (New-OmniFinding -Title 'Custom Plugin failed to run' -Severity 'Error' -Component 'Custom' -Detail 'intentional failure')
        )

    $results = @($sys, $net, $disk, $skip, $fail)
    return [pscustomobject]@{
        PSTypeName = 'OmniDiag.Session'
        StartTime  = Get-OmniReportFixtureTime
        EndTime    = Get-OmniReportFixtureTime -Seconds 6
        DurationMs = 6000
        Cancelled  = $false
        TimeRange  = [pscustomobject]@{
            PSTypeName = 'OmniDiag.TimeRange'
            Start = Get-OmniReportFixtureTime -Seconds (-7 * 86400); End = Get-OmniReportFixtureTime; Label = 'Last7Days'; Preset = 'Last7Days'
        }
        Host       = [pscustomobject]@{ ComputerName = 'FIXTURE-PC'; UserName = 'fixture'; PSVersion = '5.1.19041.1' }
        IsAdmin    = $false
        Results    = $results
        Summary    = ($results | Get-OmniHealthScore)
    }
}
