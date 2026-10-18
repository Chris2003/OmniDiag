#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Static no-network test (principle 1: local-only).

    Parses every .ps1/.psm1 under src (and OmniDiag.ps1) with the PowerShell AST and
    fails on any network-capable API that is not in the explicit allowlist below:

      Commands : Invoke-WebRequest (iwr, curl, wget), Invoke-RestMethod (irm),
                 Test-Connection, Test-NetConnection, Resolve-DnsName,
                 Test-ComputerSecureChannel, Start-BitsTransfer, New-PSSession,
                 Enter-PSSession, New-CimSession, Invoke-Command -ComputerName,
                 Send-MailMessage, WMI/CIM/event/service cmdlets with -ComputerName or
                 -CimSession ('Remote -ComputerName')
      Native   : curl.exe, wget.exe, bitsadmin, ping, nslookup, tracert, pathping,
                 ftp.exe, tftp.exe (bare name or .exe, with or without a path)
      .NET     : System.Net.WebClient, System.Net.Http.HttpClient (and HttpClientHandler,
                 SocketsHttpHandler, HttpMessageInvoker), System.Net.Sockets.*,
                 System.Net.NetworkInformation.Ping, System.Net.Dns,
                 System.Net.WebRequest, System.Net.HttpWebRequest, System.Net.FtpWebRequest,
                 System.Net.Mail.SmtpClient, System.Net.WebSockets.ClientWebSocket
                 (type literals, casts/constraints, generic arguments, and New-Object
                 type-name strings; case-insensitive, with or without 'System.', and
                 resolved through 'using namespace')

    Comments and plain strings (e.g. Get-Command -Name Resolve-DnsName) are not usage.
    Not detected (out of scope for a static check): names built at run time, e.g.
    [type]('System.Net.' + 'Dns') or & ('Invoke-' + 'WebRequest'). Reviewers catch those.

    Adding a network-capable API: add an allowlist entry here (file + api + reason),
    set the plugin's NetworkAccess, apply the NetworkAccess PR label, and get owner
    approval (see CONTRIBUTING.md).

    Outside src, install.ps1 is the only script allowed to download (it fetches the
    release archive); a Describe asserts that. The .cmd launchers are checked with a
    plain-text scan. Not detected: native tools whose network use depends on their
    arguments (ipconfig /renew, dism /RestoreHealth, w32tm /resync); those rely on the
    plugin's NetworkAccess declaration and review. Cross-platform.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent

    # --- Allowlist (data) ----------------------------------------------------------
    # File: repo-relative path with '/'. Api: as reported by the detector (wildcards ok).
    $script:NetworkAllowlist = @(
        @{ File = 'src/Modules/Network.psm1';         Api = 'System.Net.NetworkInformation.Ping'; Reason = 'opt-in connectivity probe (--network-probes): gateway and public-address ping' }
        @{ File = 'src/Modules/Network.psm1';         Api = 'System.Net.Dns';                     Reason = 'opt-in connectivity probe (--network-probes): public-name resolution' }
        @{ File = 'src/Modules/DnsResolver.psm1';     Api = 'Resolve-DnsName';                    Reason = 'opt-in connectivity probe (--network-probes): DNS resolution test' }
        @{ File = 'src/Modules/DnsResolver.psm1';     Api = 'System.Net.Dns';                     Reason = 'opt-in connectivity probe (--network-probes): DNS resolution fallback when Resolve-DnsName is missing' }
        @{ File = 'src/Modules/ActiveDirectory.psm1'; Api = 'Test-ComputerSecureChannel';         Reason = 'opt-in connectivity probe (--network-probes): domain secure-channel check against a domain controller (LocalNetwork), domain-joined only' }
        @{ File = 'src/Core/Ollama.psm1';             Api = 'Invoke-RestMethod';                  Reason = 'local AI assistant: loopback-only Ollama endpoint, opt-in' }
    )

    # Scripts outside src/ that may download (Invoke-WebRequest / Invoke-RestMethod etc.).
    $script:DownloadAllowlist = @('install.ps1')

    # --- Detector ------------------------------------------------------------------
    $script:NetCommands = @{
        'invoke-webrequest'          = 'Invoke-WebRequest'
        'iwr'                        = 'Invoke-WebRequest'
        'curl'                       = 'Invoke-WebRequest'
        'wget'                       = 'Invoke-WebRequest'
        'invoke-restmethod'          = 'Invoke-RestMethod'
        'irm'                        = 'Invoke-RestMethod'
        'test-connection'            = 'Test-Connection'
        'test-netconnection'         = 'Test-NetConnection'
        'tnc'                        = 'Test-NetConnection'
        'resolve-dnsname'            = 'Resolve-DnsName'
        'test-computersecurechannel' = 'Test-ComputerSecureChannel'
        'start-bitstransfer'         = 'Start-BitsTransfer'
        'new-pssession'              = 'New-PSSession'
        'nsn'                        = 'New-PSSession'
        'enter-pssession'            = 'Enter-PSSession'
        'etsn'                       = 'Enter-PSSession'
        'new-cimsession'             = 'New-CimSession'
        'send-mailmessage'           = 'Send-MailMessage'
        # Native network clients (a bare name or name.exe; a path prefix is stripped).
        'curl.exe'                   = 'curl.exe'
        'wget.exe'                   = 'wget.exe'
        'bitsadmin'                  = 'bitsadmin.exe'
        'bitsadmin.exe'              = 'bitsadmin.exe'
        'ping'                       = 'ping.exe'
        'ping.exe'                   = 'ping.exe'
        'nslookup'                   = 'nslookup.exe'
        'nslookup.exe'               = 'nslookup.exe'
        'tracert'                    = 'tracert.exe'
        'tracert.exe'                = 'tracert.exe'
        'pathping'                   = 'pathping.exe'
        'pathping.exe'               = 'pathping.exe'
        'ftp.exe'                    = 'ftp.exe'
        'tftp.exe'                   = 'tftp.exe'
    }

    # Local cmdlets that reach another machine when given a remote target parameter.
    $script:RemoteCapableCommands = @('get-wmiobject', 'gwmi', 'invoke-wmimethod', 'set-wmiinstance', 'remove-wmiobject',
        'get-ciminstance', 'gcim', 'invoke-cimmethod', 'set-ciminstance', 'remove-ciminstance', 'get-winevent',
        'get-eventlog', 'get-hotfix', 'get-service', 'get-process', 'restart-computer', 'stop-computer')

    function Get-NetTypeApi {
        # Canonical 'System.Net....' name if $Name (optionally resolved via using
        # namespaces) is a network-capable type; otherwise $null.
        param([string] $Name, [string[]] $Namespaces)
        if (-not $Name) { return $null }
        $n = $Name.Trim().Trim('[', ']').Trim()
        $candidates = @($n) + @($Namespaces | Where-Object { $_ } | ForEach-Object { "$_.$n" })
        foreach ($c in $candidates) {
            $full = if ($c -match '^(?i)system\.') { $c } else { "System.$c" }
            switch -Regex ($full) {
                '^(?i)System\.Net\.WebClient$'                  { return 'System.Net.WebClient' }
                '^(?i)System\.Net\.Http\.HttpClient$'           { return 'System.Net.Http.HttpClient' }
                '^(?i)System\.Net\.Sockets\.(\w+)$'             { return ('System.Net.Sockets.' + $Matches[1]) }
                '^(?i)System\.Net\.NetworkInformation\.Ping$'   { return 'System.Net.NetworkInformation.Ping' }
                '^(?i)System\.Net\.Dns$'                        { return 'System.Net.Dns' }
                '^(?i)System\.Net\.WebRequest$'                 { return 'System.Net.WebRequest' }
                '^(?i)System\.Net\.HttpWebRequest$'             { return 'System.Net.HttpWebRequest' }
                '^(?i)System\.Net\.FtpWebRequest$'              { return 'System.Net.FtpWebRequest' }
                '^(?i)System\.Net\.Mail\.SmtpClient$'           { return 'System.Net.Mail.SmtpClient' }
                '^(?i)System\.Net\.WebSockets\.ClientWebSocket$' { return 'System.Net.WebSockets.ClientWebSocket' }
                '^(?i)System\.Net\.Http\.(HttpClientHandler|SocketsHttpHandler|HttpMessageInvoker)$' { return ('System.Net.Http.' + $Matches[1]) }
            }
        }
        return $null
    }

    function Get-TypeNameLeaf {
        # Flattens generic arguments and array element types into plain names.
        param($TypeName)
        if ($null -eq $TypeName) { return }
        if ($TypeName -is [System.Management.Automation.Language.GenericTypeName]) {
            Get-TypeNameLeaf $TypeName.TypeName
            foreach ($g in $TypeName.GenericArguments) { Get-TypeNameLeaf $g }
        } elseif ($TypeName -is [System.Management.Automation.Language.ArrayTypeName]) {
            Get-TypeNameLeaf $TypeName.ElementType
        } else {
            $TypeName.FullName
        }
    }

    function Find-NetworkUsage {
        <# Returns @{ Api; Line; Text } for every network-capable usage in the AST. #>
        param([System.Management.Automation.Language.Ast] $Ast)

        $namespaces = @()
        if ($Ast -is [System.Management.Automation.Language.ScriptBlockAst] -and $Ast.UsingStatements) {
            $namespaces = @($Ast.UsingStatements |
                Where-Object { $_.UsingStatementKind -eq [System.Management.Automation.Language.UsingStatementKind]::Namespace } |
                ForEach-Object { $_.Name.Value })
        }

        $hits = [System.Collections.Generic.List[object]]::new()
        $add = { param($api, $node) $hits.Add([pscustomobject]@{ Api = $api; Line = $node.Extent.StartLineNumber; Text = $node.Extent.Text.Split("`n")[0].Trim() }) }

        # Commands
        foreach ($cmd in $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $cmd.GetCommandName()
            if (-not $name) { continue }
            $key = ($name -replace '^.*\\', '').ToLowerInvariant()     # strip a module qualifier
            if ($script:NetCommands.ContainsKey($key)) { & $add $script:NetCommands[$key] $cmd; continue }
            if ($key -eq 'invoke-command' -or $key -eq 'icm') {
                $remote = @($cmd.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -match '^(?i)(ComputerName|Cn|Session|HostName|ConnectionUri|Uri|VMName|VMId|ContainerId)$'
                    })
                if ($remote.Count -gt 0) { & $add 'Invoke-Command -ComputerName' $cmd }
                continue
            }
            if ($key -in $script:RemoteCapableCommands) {
                $remote = @($cmd.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -match '^(?i)(ComputerName|Cn|CimSession)$'
                    })
                if ($remote.Count -gt 0) { & $add 'Remote -ComputerName' $cmd }
                continue
            }
            if ($key -eq 'new-object') {
                foreach ($el in $cmd.CommandElements | Select-Object -Skip 1) {
                    if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $api = Get-NetTypeApi -Name $el.Value -Namespaces $namespaces
                        if ($api) { & $add $api $cmd }
                    }
                }
            }
        }

        # Type literals ([X]::M(), [X]$v casts, [X]$p constraints, attributes).
        $typeNodes = $Ast.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.TypeExpressionAst] -or
                $a -is [System.Management.Automation.Language.TypeConstraintAst] -or
                $a -is [System.Management.Automation.Language.ConvertExpressionAst]
            }, $true)
        foreach ($node in $typeNodes) {
            $tn = if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node.Type.TypeName } else { $node.TypeName }
            foreach ($leaf in (Get-TypeNameLeaf $tn)) {
                $api = Get-NetTypeApi -Name $leaf -Namespaces $namespaces
                if ($api) { & $add $api $node }
            }
        }
        # A ConvertExpressionAst also contains its TypeConstraintAst; report each site once.
        return @($hits | Sort-Object Line, Api, Text -Unique)
    }

    function Find-NetworkUsageInFile {
        param([string] $Path)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return Find-NetworkUsage -Ast $ast
    }

    function Find-NetworkUsageInText {
        param([string] $Text)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        return Find-NetworkUsage -Ast $ast
    }

    function Get-RelativePath {
        param([string] $Path)
        $full = [System.IO.Path]::GetFullPath($Path)
        $rootFull = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\', '/')
        return $full.Substring($rootFull.Length + 1).Replace('\', '/')
    }

    $script:ProductFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }
        Get-Item -LiteralPath (Join-Path $script:RepoRoot 'OmniDiag.ps1')
    )

    $script:ProductHits = foreach ($f in $script:ProductFiles) {
        $rel = Get-RelativePath $f.FullName
        foreach ($h in (Find-NetworkUsageInFile -Path $f.FullName)) {
            [pscustomobject]@{ File = $rel; Api = $h.Api; Line = $h.Line; Text = $h.Text }
        }
    }
    $script:ProductHits = @($script:ProductHits)

    function Get-NetworkViolation {
        # Hits (File, Api, ...) that no allowlist entry covers.
        param([object[]] $Hit, [object[]] $Allowlist = $script:NetworkAllowlist)
        @($Hit | Where-Object { $null -ne $_ } | Where-Object {
                $h = $_
                -not ($Allowlist | Where-Object { $h.File -eq $_.File -and $h.Api -like $_.Api })
            })
    }
}

Describe 'Network-API detector (self-test)' {
    It 'flags <Api> in: <Code>' -ForEach @(
        @{ Code = 'Invoke-WebRequest -Uri https://example.test';            Api = 'Invoke-WebRequest' }
        @{ Code = 'iwr https://example.test -OutFile x';                    Api = 'Invoke-WebRequest' }
        @{ Code = 'Microsoft.PowerShell.Utility\Invoke-WebRequest x';       Api = 'Invoke-WebRequest' }
        @{ Code = '& ''Invoke-WebRequest'' -Uri x';                         Api = 'Invoke-WebRequest' }
        @{ Code = 'Invoke-RestMethod -Uri http://localhost:1';              Api = 'Invoke-RestMethod' }
        @{ Code = 'irm http://x';                                           Api = 'Invoke-RestMethod' }
        @{ Code = 'Test-Connection 1.1.1.1 -Count 1';                       Api = 'Test-Connection' }
        @{ Code = 'test-netconnection example.test -Port 443';              Api = 'Test-NetConnection' }
        @{ Code = 'Resolve-DnsName example.test';                           Api = 'Resolve-DnsName' }
        @{ Code = 'Test-ComputerSecureChannel';                             Api = 'Test-ComputerSecureChannel' }
        @{ Code = 'Start-BitsTransfer -Source http://x -Destination y';     Api = 'Start-BitsTransfer' }
        @{ Code = '$s = New-PSSession -ComputerName srv';                   Api = 'New-PSSession' }
        @{ Code = 'Enter-PSSession srv';                                    Api = 'Enter-PSSession' }
        @{ Code = 'New-CimSession -ComputerName srv';                       Api = 'New-CimSession' }
        @{ Code = 'Invoke-Command -ComputerName srv -ScriptBlock { 1 }';    Api = 'Invoke-Command -ComputerName' }
        @{ Code = '[System.Net.WebClient]::new().DownloadString(''x'')';    Api = 'System.Net.WebClient' }
        @{ Code = '$c = New-Object Net.WebClient';                          Api = 'System.Net.WebClient' }
        @{ Code = 'New-Object -TypeName ''System.Net.Http.HttpClient''';    Api = 'System.Net.Http.HttpClient' }
        @{ Code = '[Net.Http.HttpClient]$h = $null';                        Api = 'System.Net.Http.HttpClient' }
        @{ Code = '[System.Net.Sockets.TcpClient]::new(''h'', 1)';          Api = 'System.Net.Sockets.TcpClient' }
        @{ Code = 'function f([Net.Sockets.UdpClient] $u) { }';             Api = 'System.Net.Sockets.UdpClient' }
        @{ Code = '$l = [Collections.Generic.List[System.Net.Sockets.Socket]]::new()'; Api = 'System.Net.Sockets.Socket' }
        @{ Code = '[system.net.networkinformation.ping]::new().Send(''x'')'; Api = 'System.Net.NetworkInformation.Ping' }
        @{ Code = '[Net.Dns]::GetHostEntry(''x'')';                         Api = 'System.Net.Dns' }
        @{ Code = "using namespace System.Net`n[Dns]::GetHostAddresses('x')"; Api = 'System.Net.Dns' }
        @{ Code = '[System.Net.WebRequest]::Create(''http://x'')';          Api = 'System.Net.WebRequest' }
        @{ Code = '$r = [Net.HttpWebRequest]$req';                          Api = 'System.Net.HttpWebRequest' }
        @{ Code = '[System.Net.FtpWebRequest]::Create(''ftp://x'')';        Api = 'System.Net.FtpWebRequest' }
        @{ Code = '$m = New-Object Net.Mail.SmtpClient ''smtp.example.test'''; Api = 'System.Net.Mail.SmtpClient' }
        @{ Code = '[System.Net.WebSockets.ClientWebSocket]::new()';         Api = 'System.Net.WebSockets.ClientWebSocket' }
        @{ Code = '[System.Net.Http.SocketsHttpHandler]::new()';            Api = 'System.Net.Http.SocketsHttpHandler' }
        @{ Code = 'Send-MailMessage -To a@example.test -SmtpServer smtp';   Api = 'Send-MailMessage' }
        @{ Code = 'curl.exe -s https://example.test';                       Api = 'curl.exe' }
        @{ Code = '& C:\Windows\System32\curl.exe https://example.test';    Api = 'curl.exe' }
        @{ Code = 'ping -n 1 1.1.1.1';                                      Api = 'ping.exe' }
        @{ Code = 'nslookup.exe example.test';                              Api = 'nslookup.exe' }
        @{ Code = 'bitsadmin /transfer j http://x C:\y';                    Api = 'bitsadmin.exe' }
        @{ Code = 'tracert example.test';                                   Api = 'tracert.exe' }
        @{ Code = 'Get-CimInstance Win32_OperatingSystem -ComputerName srv'; Api = 'Remote -ComputerName' }
        @{ Code = 'Get-WmiObject Win32_Bios -ComputerName srv';             Api = 'Remote -ComputerName' }
        @{ Code = 'Get-WinEvent -LogName System -ComputerName srv';         Api = 'Remote -ComputerName' }
    ) {
        $hits = @(Find-NetworkUsageInText -Text $Code)
        $hits.Api | Should -Contain $Api
    }

    It 'does not flag local-only or non-usage code: <Code>' -ForEach @(
        @{ Code = '# Invoke-WebRequest in a comment' }
        @{ Code = 'Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue' }
        @{ Code = 'Write-Output ''Test-Connection is not called here''' }
        @{ Code = 'Invoke-Command -ScriptBlock { 1 }' }
        @{ Code = '[System.Net.IPAddress]::Parse(''10.0.0.1'')' }
        @{ Code = '[System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()' }
        @{ Code = 'Get-NetIPConfiguration; Get-DnsClientServerAddress' }
        @{ Code = 'Get-CimInstance -ClassName Win32_OperatingSystem' }
        @{ Code = 'Get-WinEvent -LogName System -MaxEvents 5' }
        @{ Code = '& $ping $gateway' }
    ) {
        @(Find-NetworkUsageInText -Text $Code).Count | Should -Be 0
    }
}

Describe 'Product code uses no network API outside the allowlist' {
    It 'scans a non-trivial number of product scripts' {
        $script:ProductFiles.Count | Should -BeGreaterThan 20
    }

    It 'has no unapproved network-capable usage' {
        $violations = @(Get-NetworkViolation -Hit $script:ProductHits)
        $report = ($violations | ForEach-Object { '{0}:{1}  {2}  ->  {3}' -f $_.File, $_.Line, $_.Api, $_.Text }) -join [Environment]::NewLine
        $because = "these need an allowlist entry in Tests/NoNetwork.Tests.ps1, a NetworkAccess declaration, the NetworkAccess label, and owner approval:$([Environment]::NewLine)$report"
        $violations.Count | Should -Be 0 -Because $because
    }

    It 'has no stale allowlist entries (each still matches real usage)' {
        $stale = @($script:NetworkAllowlist | Where-Object {
                $entry = $_
                -not ($script:ProductHits | Where-Object { $_.File -eq $entry.File -and $_.Api -like $entry.Api })
            } | ForEach-Object { '{0} ({1})' -f $_.File, $_.Api })
        $stale.Count | Should -Be 0 -Because "remove allowlist entries that no longer match: $($stale -join ', ')"
    }

    It 'gives every allowlist entry a reason' {
        foreach ($e in $script:NetworkAllowlist) { $e.Reason | Should -Not -BeNullOrEmpty }
    }

    It 'flags an unapproved call injected into a copy of an allowlisted product file (mutation check)' {
        # Network.psm1 is allowlisted for Ping and Dns only: a web request added to it must
        # still be a violation, and the untouched copy must not be.
        $source = Join-Path $script:RepoRoot 'src/Modules/Network.psm1'
        $copy = Join-Path $TestDrive 'Network.mutated.psm1'
        $text = [System.IO.File]::ReadAllText($source)
        [System.IO.File]::WriteAllText($copy, $text + "`nfunction Get-Leak { Invoke-WebRequest -Uri 'https://example.test' -UseBasicParsing }`n")

        $asProduct = { param($Path) @(Find-NetworkUsageInFile -Path $Path | ForEach-Object {
                    [pscustomobject]@{ File = 'src/Modules/Network.psm1'; Api = $_.Api; Line = $_.Line; Text = $_.Text } }) }
        @(Get-NetworkViolation -Hit (& $asProduct $source)).Count | Should -Be 0
        $violations = @(Get-NetworkViolation -Hit (& $asProduct $copy))
        $violations.Count | Should -Be 1
        $violations[0].Api | Should -Be 'Invoke-WebRequest'
    }
}

Describe 'Launchers start no network tools' {
    It '<Name> calls no download or network client' -ForEach @(
        Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot -Parent) -Filter '*.cmd' -File | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        # Batch files are outside the PowerShell AST check; scan their non-comment lines.
        $code = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch '^\s*(@?rem\b|::)' })
        $hits = @($code | Where-Object { $_ -match '(?i)\b(curl|wget|bitsadmin|certutil|ftp|tftp|nslookup|ping|tracert|Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|DownloadString|DownloadFile)\b' })
        $hits | Should -BeNullOrEmpty -Because "$Name must not reach the network"
    }
}

Describe 'Only install.ps1 downloads outside src' {
    It 'finds download APIs only in the allowed scripts' {
        $downloadApis = @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
            'System.Net.WebClient', 'System.Net.Http.HttpClient', 'System.Net.WebRequest', 'System.Net.HttpWebRequest')
        $outside = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File | Where-Object {
            $rel = Get-RelativePath $_.FullName
            $_.Extension -in '.ps1', '.psm1' -and $rel -notlike 'src/*' -and $rel -notlike 'Tests/*' -and $rel -notlike '.git/*' -and $rel -notlike '.claude/*' -and
            $rel -notlike 'dist/*' -and $rel -ne 'OmniDiag.ps1'
        }
        $downloaders = @(foreach ($f in $outside) {
                $hits = @(Find-NetworkUsageInFile -Path $f.FullName | Where-Object { $_.Api -in $downloadApis })
                if ($hits.Count -gt 0) { Get-RelativePath $f.FullName }
            }) | Sort-Object -Unique
        @($downloaders | Where-Object { $_ -notin $script:DownloadAllowlist }) | Should -BeNullOrEmpty
    }

    It 'install.ps1 still contains its (documented) release download' {
        $hits = @(Find-NetworkUsageInFile -Path (Join-Path $script:RepoRoot 'install.ps1'))
        $hits.Api | Should -Contain 'Invoke-WebRequest'
    }
}
