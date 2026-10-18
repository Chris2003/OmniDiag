#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the redaction engine (src/Core/Redaction.psm1): every identifier
    class, the values that are deliberately kept, longest-first matching, stable
    pseudonyms, salted pseudonyms, the mapping, shape preservation, and the guarantee
    that the input is never modified. OS-independent: contexts are built with
    -ExcludeEnvironment so the runner's own user and computer names don't shift the
    numbering.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    if (-not (Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $script:Root 'src/Core/Redaction.psm1') -Force -DisableNameChecking -Global
    }

    $script:Session = [pscustomobject]@{
        PSTypeName = 'OmniDiag.Session'
        Host       = [pscustomobject]@{ ComputerName = 'ACME-WS-042'; UserName = 'CONTOSO\jdoe'; PSVersion = '5.1' }
        Notes      = @('Joined acme-ws-042.corp.contoso.com', 'C:\Users\msmith\Desktop\notes.txt')
    }

    # A fresh context per test keeps the numbering independent of test order:
    # HOST-1 = ACME-WS-042, DOMAIN-1 = CONTOSO, USER-1 = jdoe, DOMAIN-2 = corp.contoso.com,
    # DOMAIN-3 = contoso.com, USER-2 = msmith (profile folder found in the session).
    function New-TestContext { New-OmniRedactionContext -Session $script:Session -ExcludeEnvironment }
    function Invoke-Redact([string] $Text, $Context) {
        if (-not $Context) { $Context = New-TestContext }
        return (ConvertTo-OmniRedacted -InputObject $Text -Context $Context)
    }
}

Describe 'Names derived from the session' {
    It 'replaces the computer name case-insensitively' {
        Invoke-Redact 'Host ACME-WS-042 / acme-ws-042 is slow' | Should -BeExactly 'Host HOST-1 / HOST-1 is slow'
    }

    It 'splits DOMAIN\user into a domain and a user pseudonym' {
        Invoke-Redact 'Signed in as CONTOSO\jdoe' | Should -BeExactly 'Signed in as DOMAIN-1\USER-1'
    }

    It 'matches longest first, so an FQDN wins over the host name' {
        Invoke-Redact 'Ping acme-ws-042.CORP.contoso.com failed' | Should -BeExactly 'Ping HOST-1.DOMAIN-2 failed'
    }

    It 'redacts the DNS domain and its parent suffix' {
        Invoke-Redact 'GPO from corp.contoso.com; mail jdoe@contoso.com' | Should -BeExactly 'GPO from DOMAIN-2; mail USER-1@DOMAIN-3'
    }

    It 'respects word boundaries' {
        Invoke-Redact 'jdoes and xACME-WS-0420 stay' | Should -BeExactly 'jdoes and xACME-WS-0420 stay'
    }

    It 'registers -AdditionalTerm values as TERM-n' {
        $ctx = New-OmniRedactionContext -Session $script:Session -ExcludeEnvironment -AdditionalTerm 'Project Falcon', 'TICKET-4711'
        Invoke-Redact 'Project Falcon (ticket-4711)' $ctx | Should -BeExactly 'TERM-1 (TERM-2)'
    }

    It 'never registers well-known account and group names' {
        $s = [pscustomobject]@{ Host = [pscustomobject]@{ ComputerName = 'localhost'; UserName = 'NT AUTHORITY\SYSTEM' } }
        $ctx = New-OmniRedactionContext -Session $s -ExcludeEnvironment -AdditionalTerm 'x'
        Invoke-Redact 'Run as Administrator; SYSTEM on localhost (NT AUTHORITY)' $ctx | Should -BeExactly 'Run as Administrator; SYSTEM on localhost (NT AUTHORITY)'
        (Get-OmniRedactionMap -Context $ctx).Count | Should -Be 0
    }

    It 'accepts a v1 report document as the session' {
        $doc = [pscustomobject]@{ schemaVersion = '1.1.0'; host = [pscustomobject]@{ computerName = 'FIN-LT-7'; userName = 'agarcia' } }
        $ctx = New-OmniRedactionContext -Session $doc -ExcludeEnvironment
        Invoke-Redact 'FIN-LT-7 user agarcia' $ctx | Should -BeExactly 'HOST-1 user USER-1'
    }
}

Describe 'Profile paths' {
    It 'keeps the structure of the user profile path' {
        Invoke-Redact 'C:\Users\jdoe\AppData\Local\Temp' | Should -BeExactly 'C:\Users\USER-1\AppData\Local\Temp'
    }

    It 'redacts profile folders found anywhere in the session, also in free text' {
        Invoke-Redact 'Profile msmith uses C:\Users\msmith' | Should -BeExactly 'Profile USER-2 uses C:\Users\USER-2'
    }

    It 'redacts profile folders first seen while redacting, including JSON-escaped paths' {
        $ctx = New-TestContext
        $out = Invoke-Redact '{"p":"C:\\Users\\lwhite\\x.txt","q":"/home/kbrown/.ssh"}' $ctx
        $out | Should -Not -Match 'lwhite|kbrown'
        $out | Should -BeExactly '{"p":"C:\\Users\\USER-3\\x.txt","q":"/home/USER-4/.ssh"}'
        Invoke-Redact 'owner lwhite' $ctx | Should -BeExactly 'owner USER-3'
    }

    It 'keeps well-known profile folders and URLs' {
        Invoke-Redact 'C:\Users\Public\Documents and C:\Users\Default\NTUSER.DAT' | Should -BeExactly 'C:\Users\Public\Documents and C:\Users\Default\NTUSER.DAT'
        Invoke-Redact 'see https://example.com/home/index.html' | Should -BeExactly 'see https://example.com/home/index.html'
    }
}

Describe 'Pattern detectors' {
    It 'redacts account SIDs and keeps well-known SIDs' {
        $ctx = New-TestContext
        Invoke-Redact 'S-1-5-21-1004336348-1177238915-682003330-1001 and S-1-5-21-1004336348-1177238915-682003330-1001' $ctx | Should -BeExactly 'SID-1 and SID-1'
        Invoke-Redact 'S-1-12-1-1111111111-2222222222-3333333333-4444444444' $ctx | Should -BeExactly 'SID-2'
        Invoke-Redact 'S-1-5-18, S-1-5-32-544, S-1-5-80-0' $ctx | Should -BeExactly 'S-1-5-18, S-1-5-32-544, S-1-5-80-0'
    }

    It 'redacts IPv4 addresses with stable pseudonyms' {
        $ctx = New-TestContext
        Invoke-Redact 'Gateway 10.20.30.40, DNS 10.20.30.41, again 10.20.30.40' $ctx | Should -BeExactly 'Gateway IP-1, DNS IP-2, again IP-1'
        Invoke-Redact 'route 192.168.1.0/24' $ctx | Should -BeExactly 'route IP-3/24'
    }

    It 'keeps loopback, unspecified, masks, multicast, broadcast, public resolvers, and versions' {
        $text = '127.0.0.1 0.0.0.0 255.255.255.0 255.255.0.0 255.255.255.255 224.0.0.251 8.8.8.8 1.1.1.1 build 10.0.19045.1'
        Invoke-Redact $text | Should -BeExactly $text
    }

    It 'redacts IPv6 addresses, compressed and expanded forms alike' {
        $ctx = New-TestContext
        Invoke-Redact '2001:db8::ff00:42:8329 = 2001:0db8:0000:0000:0000:ff00:0042:8329' $ctx | Should -BeExactly 'IPV6-1 = IPV6-1'
        Invoke-Redact 'link fe80::1c2d:3e4f:5a6b:7c8d%12' $ctx | Should -BeExactly 'link IPV6-2%12'
        Invoke-Redact 'mapped ::ffff:10.9.8.7' $ctx | Should -BeExactly 'mapped IPV6-3'
    }

    It 'does not over-match times, loopback, unspecified, multicast, or code' {
        $text = 'at 12:30 and 12:30:45 on 2026-06-01T08:00:00.000Z; listen [::]:445 [::1]:80 ff02::1:2; [System.IO.Path]::Combine Class::Add'
        Invoke-Redact $text | Should -BeExactly $text
    }

    It 'redacts MAC addresses in either notation to one pseudonym' {
        $ctx = New-TestContext
        Invoke-Redact 'NIC 00-15-5D-AA-BB-CC aka 00:15:5d:aa:bb:cc' $ctx | Should -BeExactly 'NIC MAC-1 aka MAC-1'
    }

    It 'keeps broadcast/zero MACs, dates, and GUIDs' {
        $text = 'FF-FF-FF-FF-FF-FF 00:00:00:00:00:00 2026-06-01 {6B29FC40-CA47-1067-B31D-00DD010662DA}'
        Invoke-Redact $text | Should -BeExactly $text
    }
}

Describe 'ConvertTo-OmniRedacted on object graphs' {
    BeforeAll {
        $script:When = [datetime]::new(2026, 6, 1, 8, 0, 0, [System.DateTimeKind]::Utc)
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add('C:\Users\jdoe\file.txt')
        $script:Graph = [pscustomobject]@{
            PSTypeName = 'OmniDiag.Finding'
            Title      = 'ACME-WS-042 cannot reach 10.20.30.40'
            Count      = 3
            When       = $script:When
            Passed     = $true
            Data       = [ordered]@{
                'ACME-WS-042' = 'key with host'
                Nested        = @{ Owner = 'CONTOSO\jdoe'; Macs = @('00-15-5D-AA-BB-CC') }
                Paths         = $list
                Obj           = [pscustomobject]@{ 'jdoe' = 'property name with user' }
            }
        }
        $script:Before = ConvertTo-OmniJsonText -InputObject $script:Graph
        $script:Copy = ConvertTo-OmniRedacted -InputObject $script:Graph -Context (New-TestContext)
    }

    It 'never modifies the input' {
        ConvertTo-OmniJsonText -InputObject $script:Graph | Should -BeExactly $script:Before
        $script:Graph.Title | Should -BeExactly 'ACME-WS-042 cannot reach 10.20.30.40'
    }

    It 'redacts strings, property names, and dictionary keys at any depth' {
        $json = ConvertTo-OmniJsonText -InputObject $script:Copy
        foreach ($id in @('ACME-WS-042', 'jdoe', 'CONTOSO', '10.20.30.40', '00-15-5D-AA-BB-CC')) {
            $json.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must be redacted"
        }
        $script:Copy.Title | Should -BeExactly 'HOST-1 cannot reach IP-1'
        $script:Copy.Data['HOST-1'] | Should -BeExactly 'key with host'
        $script:Copy.Data.Nested['Owner'] | Should -BeExactly 'DOMAIN-1\USER-1'
        $script:Copy.Data.Obj.'USER-1' | Should -BeExactly 'property name with user'
    }

    It 'keeps types and shapes (type names, dates, numbers, ordered dictionaries, lists)' {
        $script:Copy.PSObject.TypeNames[0] | Should -Be 'OmniDiag.Finding'
        $script:Copy.When | Should -BeOfType [datetime]
        $script:Copy.When | Should -Be $script:When
        $script:Copy.Count | Should -BeOfType [int]
        $script:Copy.Passed | Should -BeTrue
        $script:Copy.Data | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        @($script:Copy.Data.Keys)[0] | Should -Be 'HOST-1'
        $script:Copy.Data.Nested | Should -BeOfType [hashtable]
        ($script:Copy.Data.Paths -is [System.Collections.Generic.List[object]]) | Should -BeTrue
        $script:Copy.Data.Paths[0] | Should -BeExactly 'C:\Users\USER-1\file.txt'
        @($script:Copy.Data.Nested.Macs).Count | Should -Be 1
    }

    It 'returns copies, not the original containers' {
        [object]::ReferenceEquals($script:Copy.Data, $script:Graph.Data) | Should -BeFalse
        [object]::ReferenceEquals($script:Copy.Data.Paths, $script:Graph.Data.Paths) | Should -BeFalse
    }

    It 'survives reference cycles (depth cap)' {
        $h = @{ Name = 'ACME-WS-042' }
        $h['Self'] = $h
        $copy = ConvertTo-OmniRedacted -InputObject $h -Context (New-TestContext)
        $copy['Name'] | Should -BeExactly 'HOST-1'
        $copy['Self']['Self']['Name'] | Should -BeExactly 'HOST-1'
    }

    It 'accepts pipeline input and passes null and empty strings through' {
        $ctx = New-TestContext
        @('jdoe', '') | ConvertTo-OmniRedacted -Context $ctx | Should -Be @('USER-1', '')
        ConvertTo-OmniRedacted -InputObject $null -Context $ctx | Should -BeNullOrEmpty
    }

    It 'rejects a context that is not an OmniDiag.RedactionContext' {
        { ConvertTo-OmniRedacted -InputObject 'x' -Context ([pscustomobject]@{ Terms = @{} }) } | Should -Throw '*RedactionContext*'
    }

    It 'redacts a few hundred findings quickly (precompiled patterns, memoized strings)' {
        $ctx = New-TestContext
        $many = foreach ($i in 1..400) {
            [pscustomobject]@{ Title = "Finding $i on ACME-WS-042"; Detail = "Peer 10.1.$([int]($i / 200)).$($i % 200 + 1) from CONTOSO\jdoe"; Severity = 'Warning'; Rank = 2 }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $copy = ConvertTo-OmniRedacted -InputObject @($many) -Context $ctx
        $sw.Stop()
        @($copy).Count | Should -Be 400
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
    }
}

Describe 'Pseudonym scheme and map' {
    It 'maps the same value to the same pseudonym across calls of one context' {
        $ctx = New-TestContext
        $a = Invoke-Redact 'first 172.16.5.9' $ctx
        $b = Invoke-Redact '172.16.5.9 again' $ctx
        $a | Should -BeExactly 'first IP-1'
        $b | Should -BeExactly 'IP-1 again'
    }

    It 'returns the original -> pseudonym map, grouped by category' {
        $ctx = New-TestContext
        [void](Invoke-Redact 'ip 10.20.30.40 mac 00-15-5D-AA-BB-CC' $ctx)
        $map = Get-OmniRedactionMap -Context $ctx
        ($map | Where-Object { $_.Original -eq 'ACME-WS-042' }).Pseudonym | Should -Be 'HOST-1'
        ($map | Where-Object { $_.Original -eq 'jdoe' }).Pseudonym | Should -Be 'USER-1'
        ($map | Where-Object { $_.Original -eq 'CONTOSO' }).Category | Should -Be 'Domain'
        ($map | Where-Object { $_.Original -eq '10.20.30.40' }).Pseudonym | Should -Be 'IP-1'
        ($map | Where-Object { $_.Original -eq '00-15-5D-AA-BB-CC' }).Pseudonym | Should -Be 'MAC-1'
        $map[0].Category | Should -Be 'Host'
        $map[0].PSObject.TypeNames[0] | Should -Be 'OmniDiag.RedactionMapEntry'
    }

    It 'derives salted pseudonyms that correlate across contexts with the same salt' {
        $a = New-OmniRedactionContext -Session $script:Session -ExcludeEnvironment -Salt 's3cret'
        $b = New-OmniRedactionContext -Session $script:Session -ExcludeEnvironment -Salt 's3cret'
        $c = New-OmniRedactionContext -Session $script:Session -ExcludeEnvironment -Salt 'other'
        $ra = Invoke-Redact '10.20.30.40 on ACME-WS-042' $a
        $ra | Should -Match '^IP-[0-9A-F]{8} on HOST-[0-9A-F]{8}$'
        Invoke-Redact '10.20.30.40 on ACME-WS-042' $b | Should -BeExactly $ra
        Invoke-Redact '10.20.30.40 on ACME-WS-042' $c | Should -Not -BeExactly $ra
    }
}
