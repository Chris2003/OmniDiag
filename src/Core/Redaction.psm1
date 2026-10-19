<#
.SYNOPSIS
    OmniDiag redaction: replace identifying values with stable pseudonyms before sharing.

.DESCRIPTION
    A redaction context (New-OmniRedactionContext) collects the identifiers that can be
    derived from a session - computer name (NetBIOS and FQDN), user name(s), domain
    names, user profile paths - and adds pattern detectors for SIDs, IPv4 and IPv6
    addresses, and MAC addresses. ConvertTo-OmniRedacted returns a deep copy of any
    object graph with every string, property name, and dictionary key rewritten; the
    input is never modified. Pseudonyms are stable within one context (HOST-1, USER-1,
    DOMAIN-1, PATH-1, SID-1, IP-1, IPV6-1, MAC-1, TERM-1), so the same value maps to
    the same pseudonym in every file of a report bundle and correlation survives.
    Get-OmniRedactionMap returns the original -> pseudonym table for an optional,
    local-only mapping file.

    What is and is not redacted, the pseudonym scheme, and the limitations are
    documented in docs/REDACTION.md.
#>

Set-StrictMode -Version Latest

# Graph depth limit for copies and discovery walks (defensive against cycles).
$script:OmniRedactMaxDepth = 24
# Other .NET objects (CIM instances, process objects, ...) are expanded only this deep; below,
# they are rendered as redacted text (their graphs can be huge).
$script:OmniRedactMaxForeignDepth = 12

# Derived names shorter than this are ignored (they would match ordinary words).
$script:OmniRedactMinTermLength = 3

$script:OmniRedactRegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
    [System.Text.RegularExpressions.RegexOptions]::Compiled

# A value that already is a pseudonym (never redacted again, never registered as a term).
# Case-sensitive and strict (HOST-1, HOST-1A2B3C4D), so a real name like 'host-01' is still redacted.
$script:OmniRedactPseudonymRegex = [regex]::new(
    '^(?:HOST|USER|DOMAIN|PATH|SID|IP|IPV6|MAC|TERM)-(?:[1-9][0-9]*|[0-9A-F]{8})(?![0-9A-Za-z])',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

# An identifier glued to an escape sequence is still an identifier: '%5Cjdoe' (URL-encoded),
# '\u0022jdoe' or '\njdoe' (JSON-escaped text kept as a string, e.g. raw tool output or a log
# line). The detectors below accept a match start right after %XX, \uXXXX, \n, \r, or \t, where
# the plain 'no letter or digit before' boundary would otherwise reject it.
$script:OmniRedactEscapeBoundary = '(?<=%[0-9A-Fa-f]{2}|\\u[0-9A-Fa-f]{4}|\\[nrt])'

# Profile folders: \Users\<name>\, /home/<name>/, \Documents and Settings\<name>\.
# The separators allow doubled backslashes, so JSON-escaped text (log lines) matches too.
# A backslash prefix matches anywhere (\Device\HarddiskVolume3\Users\x, \\fs01\Users\x);
# a forward slash only at a path start or after /mnt/<drive> (WSL), so URL paths such as
# https://example.com/home/index.html are kept.
$script:OmniRedactProfileRegex = [regex]::new(
    '(?<prefix>(?:\\+|(?<![A-Za-z0-9._-])/+|(?<=/mnt/[A-Za-z])/+)(?:Users|home|Documents and Settings)[\\/]+)(?<name>[^\\/:*?"<>|\r\n\t]+(?=[\\/])|[^\\/:*?"<>|\s,;''()\[\]{}]+)',
    $script:OmniRedactRegexOptions)

# Machine / domain / Entra ID account SIDs. Other well-known SIDs (S-1-5-18, S-1-5-32-544,
# service SIDs S-1-5-80-...) do not match.
$script:OmniRedactSidRegex = [regex]::new(
    ('(?:(?<![A-Za-z0-9-])|' + $script:OmniRedactEscapeBoundary + ')S-1-(?:5-21|12-1)(?:-\d+){3,4}(?!\d)'), $script:OmniRedactRegexOptions)

# MAC addresses: six hex pairs with a consistent ':' or '-' separator. A label glued on with
# ':' (MAC:00-11-..., BSSID:aa:bb:...) or a trailing ':' still matches; a seventh standalone
# hex pair before or after (EUI-64, IPv6 with two-digit groups) does not.
$script:OmniRedactMacRegex = [regex]::new(
    ('(?:(?<![0-9A-Za-z])|' + $script:OmniRedactEscapeBoundary + ')(?<!(?<![0-9A-Za-z])[0-9A-F]{2}[:-])[0-9A-F]{2}([:-])(?:[0-9A-F]{2}\1){4}[0-9A-F]{2}(?![0-9A-Za-z])(?![:-][0-9A-F]{2}(?![0-9A-Za-z]))'),
    $script:OmniRedactRegexOptions)

# IPv6 candidates (at least two colons); every candidate is validated by IPAddress.TryParse
# and must contain '::' or eight groups, so times like 12:30 or 12:30:45 never match.
# A candidate may follow a word label and a colon (Address:fe80::1, Source:2001:db8::5) but
# never starts inside a colon chain (after a standalone 1-4 digit hex group and ':').
# A trailing ':' (Pinging 2001:db8::5: ...) is split off in Get-OmniRedactionMatchReplacement.
$script:OmniRedactIPv6Regex = [regex]::new(
    ('(?:(?<![0-9A-Za-z.\])])|' + $script:OmniRedactEscapeBoundary + ')(?<!(?<![0-9A-Za-z])[0-9A-F]{1,4}:)(?=[0-9A-F]*:[0-9A-F]*:)[0-9A-F:]+(?:(?<=:)(?:\d{1,3}\.){3}\d{1,3})?(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:]|\.\d)'),
    $script:OmniRedactRegexOptions)

# IPv4 dotted quads (no leading/trailing dotted digits, so 10.0.19045.1 is not an address).
$script:OmniRedactIPv4Regex = [regex]::new(
    ('(?:(?<![0-9A-Za-z.])|' + $script:OmniRedactEscapeBoundary + ')(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![0-9A-Za-z]|\.\d)'),
    $script:OmniRedactRegexOptions)

# Well-known, non-identifying names that are never registered as terms (documented).
$script:OmniRedactNeverTerm = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'administrator', 'admin', 'guest', 'system', 'localsystem', 'local service', 'network service',
        'localservice', 'networkservice', 'nt authority', 'builtin', 'workgroup', 'localhost',
        'public', 'default', 'default user', 'all users', 'defaultuser0', 'defaultapppool',
        'user', 'users', 'root', 'host', 'domain', 'path', 'sid', 'mac', 'term', 'unknown', 'none', 'null', 'n/a'
    ), [System.StringComparer]::OrdinalIgnoreCase)

# Well-known public resolvers (documented): shown as-is, they identify nothing.
$script:OmniRedactPublicIPv4 = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220'
))

$script:OmniRedactPrefix = @{
    Host = 'HOST'; User = 'USER'; Domain = 'DOMAIN'; Path = 'PATH'; Sid = 'SID'
    IPv4 = 'IP'; IPv6 = 'IPV6'; Mac = 'MAC'; Term = 'TERM'
}

# ---------------------------------------------------------------------------
# Context internals
# ---------------------------------------------------------------------------

function Assert-OmniRedactionContext {
    <# .SYNOPSIS Internal: throws unless the value is an OmniDiag.RedactionContext. #>
    param($Context)
    if ($null -eq $Context -or -not ($Context.PSObject.TypeNames -contains 'OmniDiag.RedactionContext')) {
        throw 'Context must be an OmniDiag.RedactionContext (see New-OmniRedactionContext).'
    }
}

function Get-OmniRedactionPseudonym {
    <#
    .SYNOPSIS
        Internal: the stable pseudonym for (Category, Key), allocating one on first use.

    .DESCRIPTION
        Without a salt, pseudonyms are numbered per category in first-seen order
        (HOST-1, HOST-2, ...). With a salt they are HOST-<8 hex of HMAC-SHA256(salt,
        category|key)>, so separate bundles redacted with the same salt correlate.
    #>
    param($Context, [string] $Category, [string] $Key, [string] $Original, [string] $Pseudonym)

    $mapKey = $Category + '|' + $Key
    if ($Context.Pseudonyms.ContainsKey($mapKey)) { return $Context.Pseudonyms[$mapKey] }

    if (-not $Pseudonym) {
        $prefix = $script:OmniRedactPrefix[$Category]
        if ($null -ne $Context.Hmac) {
            $bytes = $Context.Hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($mapKey))
            $hex = -join ($bytes[0..3] | ForEach-Object { $_.ToString('X2') })
            $Pseudonym = '{0}-{1}' -f $prefix, $hex
        } else {
            $n = 1
            if ($Context.Counters.ContainsKey($Category)) { $n = [int]$Context.Counters[$Category] + 1 }
            $Context.Counters[$Category] = $n
            $Pseudonym = '{0}-{1}' -f $prefix, $n
        }
    }
    $Context.Pseudonyms[$mapKey] = $Pseudonym
    $Context.Entries.Add([pscustomobject]@{
        PSTypeName = 'OmniDiag.RedactionMapEntry'
        Category   = $Category
        Original   = $(if ($Original) { $Original } else { $Key })
        Pseudonym  = $Pseudonym
    })
    return $Pseudonym
}

function Test-OmniRedactionTermCandidate {
    <# .SYNOPSIS Internal: $true when a derived name is worth redacting as a literal term. #>
    param([string] $Value, [int] $MinLength = $script:OmniRedactMinTermLength)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    if ($v.Length -lt $MinLength) { return $false }
    if ($script:OmniRedactNeverTerm.Contains($v)) { return $false }
    if ($script:OmniRedactPseudonymRegex.IsMatch($v)) { return $false }
    if ($v -match '^[%$<{]') { return $false }
    return $true
}

function Add-OmniRedactionTerm {
    <#
    .SYNOPSIS
        Internal: registers a literal term (matched case-insensitively, longest first).
        Returns its pseudonym, or $null when the value is not redactable.
    #>
    param($Context, [string] $Category, [string] $Value, [string] $Pseudonym, [int] $MinLength = $script:OmniRedactMinTermLength)
    if (-not (Test-OmniRedactionTermCandidate -Value $Value -MinLength $MinLength)) { return $null }
    $v = $Value.Trim()
    if ($Context.Terms.ContainsKey($v)) { return $Context.Terms[$v] }
    $p = Get-OmniRedactionPseudonym -Context $Context -Category $Category -Key $v.ToLowerInvariant() -Original $v -Pseudonym $Pseudonym
    $Context.Terms[$v] = $p
    $Context.TermRegex = $null
    $Context.Cache.Clear()
    return $p
}

function Add-OmniRedactionDnsDomain {
    <#
    .SYNOPSIS
        Internal: registers a DNS domain and its parent suffixes (contoso.com from
        corp.contoso.com); suffixes whose first label is shorter than 3 characters
        (co.uk) are skipped. Returns the pseudonym of the full domain.
    #>
    param($Context, [string] $Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return $null }
    $d = $Domain.Trim().TrimEnd('.')
    $first = Add-OmniRedactionTerm -Context $Context -Category 'Domain' -Value $d
    $labels = $d.Split('.')
    for ($i = 1; $i -le $labels.Count - 2; $i++) {
        if ($labels[$i].Length -ge 3) {
            [void](Add-OmniRedactionTerm -Context $Context -Category 'Domain' -Value ($labels[$i..($labels.Count - 1)] -join '.'))
        }
    }
    return $first
}

function Add-OmniRedactionHostName {
    <# .SYNOPSIS Internal: registers a NetBIOS name or an FQDN (FQDN -> HOST-n.DOMAIN-m). #>
    param($Context, [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $n = $Name.Trim().TrimEnd('.')
    if ($n -match '^[^.]+\.(.+)$' -and $n -notmatch '^\d+(\.\d+){3}$') {
        $suffix = $n.Substring($n.IndexOf('.') + 1)
        $short = $n.Split('.')[0]
        $hostP = Add-OmniRedactionTerm -Context $Context -Category 'Host' -Value $short
        $domP = Add-OmniRedactionDnsDomain -Context $Context -Domain $suffix
        if ($hostP -and $domP) { [void](Add-OmniRedactionTerm -Context $Context -Category 'Host' -Value $n -Pseudonym "$hostP.$domP") }
        elseif ($hostP) { [void](Add-OmniRedactionTerm -Context $Context -Category 'Host' -Value $n) }
    } else {
        [void](Add-OmniRedactionTerm -Context $Context -Category 'Host' -Value $n)
    }
}

function Add-OmniRedactionUserName {
    <# .SYNOPSIS Internal: registers DOMAIN\user, user@dns.domain, or a bare user name. #>
    param($Context, [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $n = $Name.Trim()
    if ($n -match '^([^\\]+)\\(.+)$') {
        $dom = $Matches[1]; $user = $Matches[2]
        if ($dom -match '\.') { [void](Add-OmniRedactionDnsDomain -Context $Context -Domain $dom) }
        else { [void](Add-OmniRedactionTerm -Context $Context -Category 'Domain' -Value $dom) }
        [void](Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $user)
    } elseif ($n -match '^([^@]+)@(.+)$') {
        $user = $Matches[1]; $dom = $Matches[2]
        [void](Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $user)
        [void](Add-OmniRedactionDnsDomain -Context $Context -Domain $dom)
    } else {
        [void](Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $n)
    }
}

function Add-OmniRedactionProfilePath {
    <#
    .SYNOPSIS
        Internal: registers a user profile path. X:\Users\<name> keeps its structure
        (C:\Users\USER-1); any other profile root (redirected or roaming) becomes PATH-n.
    #>
    param($Context, [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $p = $Path.Trim().TrimEnd('\', '/')
    if ($p -match '^([A-Za-z]:\\(?:Users|Documents and Settings)\\)([^\\]+)$' -or $p -match '^(/(?:home|Users)/)([^/]+)$') {
        $prefix = $Matches[1]; $name = $Matches[2]
        $userP = Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $name
        if ($userP) { [void](Add-OmniRedactionTerm -Context $Context -Category 'Path' -Value $p -Pseudonym ($prefix + $userP)) }
    } else {
        [void](Add-OmniRedactionTerm -Context $Context -Category 'Path' -Value $p)
    }
}

function Get-OmniRedactionTermRegex {
    <# .SYNOPSIS Internal: the (cached) alternation of all literal terms, longest first. #>
    param($Context)
    if ($null -ne $Context.TermRegex) { return $Context.TermRegex }
    if ($Context.Terms.Count -eq 0) { return $null }
    $names = [string[]]@($Context.Terms.Keys)
    $sorted = @($names | Sort-Object -Property @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })
    $parts = foreach ($t in $sorted) {
        $pre = if ($t[0] -match '[A-Za-z0-9]') { '(?:(?<![A-Za-z0-9])|' + $script:OmniRedactEscapeBoundary + ')' } else { '' }
        $post = if ($t[$t.Length - 1] -match '[A-Za-z0-9]') { '(?![A-Za-z0-9])' } else { '' }
        $pre + [regex]::Escape($t) + $post
    }
    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $Context.TermRegex = [regex]::new(($parts -join '|'), $opts)
    return $Context.TermRegex
}

function Test-OmniRedactionKeepIPv4 {
    <# .SYNOPSIS Internal: $true for non-identifying IPv4 values (loopback, unspecified, masks, multicast, public resolvers). #>
    param([string] $Value)
    $o = [int[]]($Value.Split('.'))
    if ($o[0] -eq 127) { return $true }
    if ($o[0] -ge 224 -and $o[0] -le 239) { return $true }
    if ($script:OmniRedactPublicIPv4.Contains($Value)) { return $true }
    # Contiguous netmasks (incl. 0.0.0.0 and 255.255.255.255).
    [int64]$m = [int64]$o[0] * 16777216 + [int64]$o[1] * 65536 + [int64]$o[2] * 256 + [int64]$o[3]
    [int64]$inv = [int64]4294967295 - $m
    if ((($inv + 1) -band $inv) -eq 0) { return $true }
    return $false
}

function ConvertTo-OmniRedactionIPv6Address {
    <#
    .SYNOPSIS
        Internal: the IPv6 address a candidate spells, or $null. The candidate must contain
        '::' or eight groups (six plus an embedded IPv4) and parse as InterNetworkV6.
    #>
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $colons = $Text.Length - $Text.Replace(':', '').Length
    $hasV4 = $Text.Contains('.')
    if (-not ($Text.Contains('::') -or $colons -eq 7 -or ($hasV4 -and $colons -eq 6))) { return $null }
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$addr)) { return $null }
    if ([string]$addr.AddressFamily -ne 'InterNetworkV6') { return $null }  # enum compared by name (no socket types referenced)
    return $addr
}

function Resolve-OmniRedactionIPv6Candidate {
    <#
    .SYNOPSIS
        Internal: splits an IPv6 candidate into the address, its zone index ('%12'), and a
        trailing sentence colon; $null when the candidate is no IPv6 address.
    #>
    param([string] $Candidate)
    $zone = ''
    $core = $Candidate
    $pct = $Candidate.IndexOf('%')
    if ($pct -ge 0) { $zone = $Candidate.Substring($pct); $core = $Candidate.Substring(0, $pct) }
    $addr = ConvertTo-OmniRedactionIPv6Address -Text $core
    $tail = ''
    if ($null -eq $addr -and $zone -eq '' -and $core.EndsWith(':') -and -not $core.EndsWith('::')) {
        # 'Pinging 2001:db8::5: Request timed out' - the colon belongs to the sentence.
        $addr = ConvertTo-OmniRedactionIPv6Address -Text $core.Substring(0, $core.Length - 1)
        $tail = ':'
    }
    if ($null -eq $addr) { return $null }
    return @{ Address = $addr; Zone = $zone; Tail = $tail }
}

function Get-OmniRedactionMatchReplacement {
    <# .SYNOPSIS Internal: the replacement text for one pattern match, or $null to keep it. #>
    param($Context, [string] $Kind, [System.Text.RegularExpressions.Match] $Match, [string] $Text = '')
    $v = $Match.Value
    switch ($Kind) {
        'Term' {
            if ($Context.Terms.ContainsKey($v)) { return $Context.Terms[$v] }
            return $null
        }
        'Profile' {
            $name = $Match.Groups['name'].Value
            if (-not (Test-OmniRedactionTermCandidate -Value $name)) { return $null }
            $p = if ($Context.Terms.ContainsKey($name.Trim())) { $Context.Terms[$name.Trim()] } else { Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $name }
            if (-not $p) { return $null }
            return $Match.Groups['prefix'].Value + $p + $name.Substring($name.TrimEnd().Length)
        }
        'Sid' {
            return Get-OmniRedactionPseudonym -Context $Context -Category 'Sid' -Key $v.ToUpperInvariant() -Original $v.ToUpperInvariant()
        }
        'Mac' {
            $norm = $v.ToUpperInvariant().Replace(':', '-')
            if ($norm -eq '00-00-00-00-00-00' -or $norm -eq 'FF-FF-FF-FF-FF-FF') { return $null }
            return Get-OmniRedactionPseudonym -Context $Context -Category 'Mac' -Key $norm -Original $norm
        }
        'IPv6' {
            $lead = ''
            $hit = Resolve-OmniRedactionIPv6Candidate -Candidate $v
            if ($null -eq $hit -and $Match.Index -gt 0 -and $Text.Length -gt $Match.Index -and $Text[$Match.Index - 1] -eq '%' -and
                $v.Length -gt 2 -and $v.Substring(0, 2) -match '^[0-9A-Fa-f]{2}$') {
                # URL-encoded text ('%20fe80::1', '%3A2001:db8::5'): the two hex digits after '%'
                # belong to the escape, not to the address.
                $lead = $v.Substring(0, 2)
                $hit = Resolve-OmniRedactionIPv6Candidate -Candidate $v.Substring(2)
            }
            if ($null -eq $hit) { return $null }
            $addr = $hit.Address
            $bytes = $addr.GetAddressBytes()
            if ($bytes[0] -eq 0xFF) { return $null }                          # multicast
            if ([System.Net.IPAddress]::IsLoopback($addr)) { return $null }     # ::1
            if (@($bytes | Where-Object { $_ -ne 0 }).Count -eq 0) { return $null } # ::
            $key = $addr.ToString().ToLowerInvariant()
            $pi = $key.IndexOf('%'); if ($pi -ge 0) { $key = $key.Substring(0, $pi) }
            return $lead + (Get-OmniRedactionPseudonym -Context $Context -Category 'IPv6' -Key $key -Original $key) + $hit.Zone + $hit.Tail
        }
        'IPv4' {
            if (Test-OmniRedactionKeepIPv4 -Value $v) { return $null }
            return Get-OmniRedactionPseudonym -Context $Context -Category 'IPv4' -Key $v -Original $v
        }
    }
    return $null
}

function Invoke-OmniRedactionPattern {
    <# .SYNOPSIS Internal: rewrites every match of one regex in a string. #>
    param([string] $Text, [regex] $Regex, [string] $Kind, $Context)
    $found = $Regex.Matches($Text)
    if ($found.Count -eq 0) { return $Text }
    $sb = [System.Text.StringBuilder]::new($Text.Length + 16)
    $last = 0
    $changed = $false
    foreach ($m in $found) {
        $rep = Get-OmniRedactionMatchReplacement -Context $Context -Kind $Kind -Match $m -Text $Text
        if ($null -eq $rep) { continue }
        [void]$sb.Append($Text, $last, $m.Index - $last)
        [void]$sb.Append([string]$rep)
        $last = $m.Index + $m.Length
        $changed = $true
    }
    if (-not $changed) { return $Text }
    [void]$sb.Append($Text, $last, $Text.Length - $last)
    return $sb.ToString()
}

function Get-OmniRedactedString {
    <# .SYNOPSIS Internal: redacts one string (terms, profile folders, SIDs, MACs, IPv6, IPv4 - in that order). #>
    param([AllowNull()][AllowEmptyString()][string] $Text, $Context)
    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -lt 2) { return $Text }

    # Sessions repeat many strings (severities, categories, component names): memoize.
    # The cache is cleared whenever a new literal term is registered.
    $cacheable = $Text.Length -le 512
    if ($cacheable) {
        $cached = $null
        if ($Context.Cache.TryGetValue($Text, [ref]$cached)) { return $cached }
    }

    $s = $Text
    $termRegex = Get-OmniRedactionTermRegex -Context $Context
    if ($null -ne $termRegex -and $termRegex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $termRegex -Kind 'Term' -Context $Context
    }
    if ($script:OmniRedactProfileRegex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $script:OmniRedactProfileRegex -Kind 'Profile' -Context $Context
    }
    if ($script:OmniRedactSidRegex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $script:OmniRedactSidRegex -Kind 'Sid' -Context $Context
    }
    if ($script:OmniRedactMacRegex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $script:OmniRedactMacRegex -Kind 'Mac' -Context $Context
    }
    if ($s.Contains(':') -and $script:OmniRedactIPv6Regex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $script:OmniRedactIPv6Regex -Kind 'IPv6' -Context $Context
    }
    if ($s.Contains('.') -and $script:OmniRedactIPv4Regex.IsMatch($s)) {
        $s = Invoke-OmniRedactionPattern -Text $s -Regex $script:OmniRedactIPv4Regex -Kind 'IPv4' -Context $Context
    }
    # A profile folder seen for the first time just now cleared the cache; storing is still correct.
    if ($cacheable) { $Context.Cache[$Text] = $s }
    return $s
}

function Get-OmniRedactionMember {
    <# .SYNOPSIS Internal: case-insensitive, StrictMode-safe read of a property or dictionary key. #>
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in @($InputObject.Keys)) { if ([string]$k -eq $Name) { return $InputObject[$k] } }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { try { return $p.Value } catch { return $null } }
    return $null
}

function Test-OmniRedactionScalar {
    <# .SYNOPSIS Internal: value types copied verbatim (numbers, booleans, dates, enums, ...). #>
    param($Value)
    if ($Value -is [enum]) { return $true }
    if ($Value.GetType().IsPrimitive) { return $true }
    return ($Value -is [decimal] -or $Value -is [datetime] -or $Value -is [System.DateTimeOffset] -or
        $Value -is [timespan] -or $Value -is [guid] -or $Value -is [version])
}

function Find-OmniRedactionProfileName {
    <#
    .SYNOPSIS
        Internal: discovery walk - registers profile folder names, and FQDNs of known
        hosts (<host>.<dns suffix>), found anywhere in the graph.
    #>
    param($Value, $Context, [int] $Depth = 0, [regex] $FqdnRegex)
    if ($null -eq $Value -or $Depth -gt $script:OmniRedactMaxDepth) { return }
    if ($Value -is [System.Management.Automation.PSObject] -and $Value.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $Value = $Value.PSObject.BaseObject
    }
    if ($Value -is [string]) {
        if ($Value.Length -gt 6) {
            foreach ($m in $script:OmniRedactProfileRegex.Matches($Value)) {
                [void](Add-OmniRedactionTerm -Context $Context -Category 'User' -Value $m.Groups['name'].Value)
            }
            if ($null -ne $FqdnRegex) {
                foreach ($m in $FqdnRegex.Matches($Value)) { Add-OmniRedactionHostName -Context $Context -Name $m.Value }
            }
        }
        return
    }
    if (Test-OmniRedactionScalar $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            Find-OmniRedactionProfileName -Value ([string]$k) -Context $Context -Depth ($Depth + 1) -FqdnRegex $FqdnRegex
            Find-OmniRedactionProfileName -Value $Value[$k] -Context $Context -Depth ($Depth + 1) -FqdnRegex $FqdnRegex
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Find-OmniRedactionProfileName -Value $item -Context $Context -Depth ($Depth + 1) -FqdnRegex $FqdnRegex }
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            $mt = [string]$p.MemberType
            if ($mt -ne 'NoteProperty' -and $mt -ne 'Property' -and $mt -ne 'AliasProperty') { continue }
            $v = $null
            try { $v = $p.Value } catch { $v = $null }
            Find-OmniRedactionProfileName -Value $v -Context $Context -Depth ($Depth + 1) -FqdnRegex $FqdnRegex
        }
    }
}

function ConvertTo-OmniRedactedValue {
    <# .SYNOPSIS Internal: recursive deep copy with redaction (see ConvertTo-OmniRedacted). #>
    param($Value, $Context, [int] $Depth = 0)

    if ($null -eq $Value) { return $null }
    $raw = $Value
    if ($raw -is [System.Management.Automation.PSObject] -and $raw.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $raw = $raw.PSObject.BaseObject
    }

    if ($raw -is [string]) { return (Get-OmniRedactedString -Text $raw -Context $Context) }
    if (Test-OmniRedactionScalar $raw) { return $raw }
    if ($raw -is [System.Net.IPAddress] -or $raw -is [uri] -or $raw -is [scriptblock] -or $raw -is [System.Security.SecureString]) {
        if ($raw -is [System.Security.SecureString]) { return $null }
        return (Get-OmniRedactedString -Text $raw.ToString() -Context $Context)
    }
    if ($Depth -ge $script:OmniRedactMaxDepth) {
        return (Get-OmniRedactedString -Text ([string]$raw) -Context $Context)
    }

    if ($raw -is [System.Collections.IDictionary]) {
        $out = if ($raw -is [System.Collections.Hashtable]) { @{} } else { [ordered]@{} }
        foreach ($k in @($raw.Keys)) {
            $newKey = $k
            if ($k -is [string]) {
                $newKey = Get-OmniRedactedString -Text $k -Context $Context
                if ($newKey -ne $k) {
                    $base = $newKey; $i = 2
                    while ($out.Contains($newKey)) { $newKey = '{0} ({1})' -f $base, $i; $i++ }
                }
            }
            $out[$newKey] = ConvertTo-OmniRedactedValue -Value $raw[$k] -Context $Context -Depth ($Depth + 1)
        }
        return $out
    }

    if ($raw -is [System.Collections.IEnumerable]) {
        $isList = $raw -is [System.Collections.IList] -and -not ($raw -is [array])
        # Assign inside the branches: an empty list returned from an if expression unrolls to $null.
        if ($raw -is [System.Collections.ArrayList]) { $list = [System.Collections.ArrayList]::new() } else { $list = [System.Collections.Generic.List[object]]::new() }
        foreach ($item in $raw) { [void]$list.Add((ConvertTo-OmniRedactedValue -Value $item -Context $Context -Depth ($Depth + 1))) }
        if ($isList) { return , $list }
        return , $list.ToArray()
    }

    # PSCustomObject (keeps PSTypeNames) or any other object (gettable properties).
    $ordered = [ordered]@{}
    $isCustom = $raw -is [System.Management.Automation.PSCustomObject]
    if (-not $isCustom -and $Depth -ge $script:OmniRedactMaxForeignDepth) {
        return (Get-OmniRedactedString -Text ([string]$raw) -Context $Context)
    }
    $props = [System.Collections.Generic.List[object]]::new()
    if ($isCustom) {
        foreach ($p in $Value.PSObject.Properties) {
            $mt = [string]$p.MemberType
            if ($mt -eq 'NoteProperty' -or $mt -eq 'Property' -or $mt -eq 'AliasProperty' -or $mt -eq 'ScriptProperty') { $props.Add($p) }
        }
    } else {
        foreach ($p in $raw.PSObject.Properties) {
            if ([string]$p.MemberType -eq 'Property' -and $p.IsGettable) { $props.Add($p) }
        }
    }
    foreach ($p in $props) {
        $v = $null
        try { $v = $p.Value } catch { $v = $null }
        $name = Get-OmniRedactedString -Text ([string]$p.Name) -Context $Context
        if ($ordered.Contains($name)) { $base = $name; $i = 2; while ($ordered.Contains($name)) { $name = '{0} ({1})' -f $base, $i; $i++ } }
        $ordered[$name] = ConvertTo-OmniRedactedValue -Value $v -Context $Context -Depth ($Depth + 1)
    }
    $copy = [pscustomobject]$ordered
    if ($isCustom) {
        $names = @($Value.PSObject.TypeNames)
        for ($i = $names.Count - 1; $i -ge 0; $i--) {
            if (-not ($copy.PSObject.TypeNames -contains $names[$i])) { $copy.PSObject.TypeNames.Insert(0, $names[$i]) }
        }
    }
    return $copy
}

function Add-OmniRedactionDomainName {
    <# .SYNOPSIS Internal: registers a DNS domain (with its parent suffixes) or a NetBIOS domain name. #>
    param($Context, [string] $Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return }
    if ($Domain -match '\.') { [void](Add-OmniRedactionDnsDomain -Context $Context -Domain $Domain) }
    else { [void](Add-OmniRedactionTerm -Context $Context -Category 'Domain' -Value $Domain) }
}

function Add-OmniRedactionDomainMetric {
    <#
    .SYNOPSIS
        Internal: registers every Domain / DnsDomain / DomainName metric value found in the
        session results (native Results[].Metrics or v1 modules[].metrics).
    #>
    param($Context, $Session)
    if ($null -eq $Session) { return }
    $results = @(Get-OmniRedactionMember -InputObject $Session -Name 'Results') + @(Get-OmniRedactionMember -InputObject $Session -Name 'modules')
    foreach ($r in $results) {
        if ($null -eq $r) { continue }
        $metrics = Get-OmniRedactionMember -InputObject $r -Name 'Metrics'
        if ($null -eq $metrics) { continue }
        foreach ($n in @('Domain', 'DnsDomain', 'DomainName')) {
            $v = Get-OmniRedactionMember -InputObject $metrics -Name $n
            if ($v -is [string]) { Add-OmniRedactionDomainName -Context $Context -Domain $v }
        }
    }
}

function Get-OmniRedactionMachineDnsDomain {
    <#
    .SYNOPSIS
        Internal: the local machine's primary DNS domain from the TCP/IP parameters in the
        registry (Domain, then NV Domain), or ''. A local registry read: no network I/O.
    #>
    [OutputType([string])]
    param()
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    try {
        if (Test-Path -LiteralPath $key) {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($n in @('Domain', 'NV Domain')) {
                $p = $props.PSObject.Properties[$n]
                if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { return ([string]$p.Value).Trim() }
            }
        }
    } catch {
        Write-Verbose "DNS domain not readable from the registry: $($_.Exception.Message)"
    }
    return ''
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function New-OmniRedactionContext {
    <#
    .SYNOPSIS
        Builds a redaction context: the identifiers to replace and their stable pseudonyms.

    .DESCRIPTION
        Collects, longest-first and case-insensitively matched:
          * the computer name - NetBIOS and FQDN (the FQDN maps to HOST-n.DOMAIN-m) -
            from the session host and $env:COMPUTERNAME / $env:USERDNSDOMAIN,
          * user names from the session host (DOMAIN\user and user@domain are split)
            and $env:USERNAME,
          * domain names (session Host.Domain / Host.DnsDomain, Domain / DnsDomain /
            DomainName metrics in the results, $env:USERDOMAIN, $env:USERDNSDOMAIN, the
            machine's primary DNS domain from the registry, and their parent suffixes),
          * user profile paths ($env:USERPROFILE and every \Users\<name>\ folder found
            anywhere in the session),
          * any -AdditionalTerm values,
        plus pattern detectors for SIDs (S-1-5-21-..., S-1-12-1-...), IPv4, IPv6
        (including compressed forms), and MAC addresses. Loopback, unspecified,
        multicast, netmask, and other well-known values are kept; see docs/REDACTION.md.

        The context is mutable: identifiers first seen while redacting (an IP address,
        a profile folder in a log line) get the next pseudonym, so redact every file of
        one bundle with the same context.

    .PARAMETER Session
        An OmniDiag.Session, or a v1 report document (from ConvertTo-OmniReportV1 or
        ConvertFrom-Json). Optional: without it only the environment is used.

    .PARAMETER Salt
        Optional secret. When given, pseudonyms are HOST-<8 hex> derived from an
        HMAC-SHA256 of the value, so bundles redacted with the same salt correlate
        across runs. Without it pseudonyms are numbered (HOST-1, HOST-2, ...).

    .PARAMETER AdditionalTerm
        Extra literal values to redact (customer names, ticket ids, ...). Each becomes
        TERM-n. Terms shorter than 2 characters are ignored.

    .PARAMETER ExcludeEnvironment
        Do not read $env:COMPUTERNAME, USERNAME, USERDOMAIN, USERDNSDOMAIN, USERPROFILE or
        the machine's DNS domain (useful when redacting a session imported from another
        machine, and in tests). Names recorded in the session itself are still used.

    .OUTPUTS
        OmniDiag.RedactionContext

    .EXAMPLE
        $ctx = New-OmniRedactionContext -Session $session
        $safe = ConvertTo-OmniRedacted -InputObject $session -Context $ctx

    .EXAMPLE
        New-OmniRedactionContext -Session (Import-OmniSession .\report.json) -AdditionalTerm 'Contoso Ltd', 'TICKET-4711'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory: returns a new in-memory object and changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [object] $Session,
        [string] $Salt,
        [string[]] $AdditionalTerm = @(),
        [switch] $ExcludeEnvironment
    )

    $hmac = $null
    if (-not [string]::IsNullOrEmpty($Salt)) {
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Salt))
    }
    $ctx = [pscustomobject]@{
        PSTypeName = 'OmniDiag.RedactionContext'
        Salted     = ($null -ne $hmac)
        Terms      = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Pseudonyms = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        Counters   = @{}
        Entries    = [System.Collections.Generic.List[object]]::new()
        TermRegex  = $null
        Cache      = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        Hmac       = $hmac
        CreatedAt  = (Get-Date)
    }

    # 1. The session host (native session: Host.ComputerName/UserName; v1: host.computerName/userName).
    $sessionHost = Get-OmniRedactionMember -InputObject $Session -Name 'Host'
    if ($null -ne $sessionHost) {
        foreach ($n in @('DnsHostName', 'Fqdn', 'ComputerName')) {
            Add-OmniRedactionHostName -Context $ctx -Name ([string](Get-OmniRedactionMember -InputObject $sessionHost -Name $n))
        }
        foreach ($n in @('DnsDomain', 'Domain')) {
            Add-OmniRedactionDomainName -Context $ctx -Domain ([string](Get-OmniRedactionMember -InputObject $sessionHost -Name $n))
        }
        Add-OmniRedactionUserName -Context $ctx -Name ([string](Get-OmniRedactionMember -InputObject $sessionHost -Name 'UserName'))
    }

    # 1b. Domain metrics in the results (ActiveDirectory / SystemInformation 'Domain' =
    #     Win32_ComputerSystem.Domain): covers sessions saved before Host.DnsDomain existed.
    Add-OmniRedactionDomainMetric -Context $ctx -Session $Session

    # 2. The local environment.
    if (-not $ExcludeEnvironment) {
        if ($env:USERDNSDOMAIN) { [void](Add-OmniRedactionDnsDomain -Context $ctx -Domain $env:USERDNSDOMAIN) }
        # The machine's DNS domain is set even when $env:USERDNSDOMAIN is not (SYSTEM, local accounts).
        $machineDns = Get-OmniRedactionMachineDnsDomain
        if ($machineDns) { [void](Add-OmniRedactionDnsDomain -Context $ctx -Domain $machineDns) }
        if ($env:COMPUTERNAME) {
            Add-OmniRedactionHostName -Context $ctx -Name $env:COMPUTERNAME
            if ($env:USERDNSDOMAIN) { Add-OmniRedactionHostName -Context $ctx -Name ('{0}.{1}' -f $env:COMPUTERNAME, $env:USERDNSDOMAIN) }
            if ($machineDns -and $machineDns -ne $env:USERDNSDOMAIN) { Add-OmniRedactionHostName -Context $ctx -Name ('{0}.{1}' -f $env:COMPUTERNAME, $machineDns) }
        }
        if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { [void](Add-OmniRedactionTerm -Context $ctx -Category 'Domain' -Value $env:USERDOMAIN) }
        if ($env:USERNAME) { Add-OmniRedactionUserName -Context $ctx -Name $env:USERNAME }
        if ($env:USERPROFILE) { Add-OmniRedactionProfilePath -Context $ctx -Path $env:USERPROFILE }
    }

    # 3. Profile folders and FQDNs of the known hosts anywhere in the session (other
    #    users' profiles, redirected paths, DNS names of an imported session's host).
    if ($null -ne $Session) {
        $hostNames = @(foreach ($e in $ctx.Entries) { if ($e.Category -eq 'Host' -and -not $e.Original.Contains('.')) { [regex]::Escape($e.Original) } })
        $fqdnRegex = $null
        if ($hostNames.Count -gt 0) {
            $fqdnRegex = [regex]::new(
                '(?<![A-Za-z0-9-])(?:' + ($hostNames -join '|') + ')\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z0-9-]*[A-Za-z](?![A-Za-z0-9-])',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        }
        Find-OmniRedactionProfileName -Value $Session -Context $ctx -FqdnRegex $fqdnRegex
    }

    # 4. Caller-supplied terms.
    foreach ($t in @($AdditionalTerm)) {
        if ($t) { [void](Add-OmniRedactionTerm -Context $ctx -Category 'Term' -Value $t -MinLength 2) }
    }

    return $ctx
}

function ConvertTo-OmniRedacted {
    <#
    .SYNOPSIS
        Returns a redacted deep copy of any object (session, report document, string, ...).

    .DESCRIPTION
        Every string - in PSCustomObjects, hashtables, ordered dictionaries, arrays, and
        lists - and every property name and dictionary key is rewritten with the
        context's pseudonyms. Numbers, booleans, dates, and other value types are copied
        unchanged; PSTypeNames, ordered dictionaries, and lists keep their shape so the
        report exporters render the copy like the original. Other .NET objects become
        PSCustomObjects of their readable properties. The input is never modified.
        Depth is capped (deeper values are rendered as redacted text), which also stops
        reference cycles.

    .PARAMETER InputObject
        The object to copy. Pipeline input is accepted.

    .PARAMETER Context
        An OmniDiag.RedactionContext from New-OmniRedactionContext.

    .OUTPUTS
        The redacted copy (same shape as the input).

    .EXAMPLE
        $ctx = New-OmniRedactionContext -Session $session
        $safe = ConvertTo-OmniRedacted -InputObject $session -Context $ctx
        Export-OmniHtmlReport -Session $safe -Path .\shareable.html

    .EXAMPLE
        'Ping from 10.1.2.3 failed' | ConvertTo-OmniRedacted -Context $ctx   # 'Ping from IP-1 failed'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)] [AllowNull()] [AllowEmptyString()] [AllowEmptyCollection()] [object] $InputObject,
        [Parameter(Mandatory)] [object] $Context
    )
    begin { Assert-OmniRedactionContext -Context $Context }
    process {
        $copy = ConvertTo-OmniRedactedValue -Value $InputObject -Context $Context -Depth 0
        return , $copy
    }
}

function Get-OmniRedactionMap {
    <#
    .SYNOPSIS
        Returns the original -> pseudonym mapping of a redaction context.

    .DESCRIPTION
        One OmniDiag.RedactionMapEntry (Category, Original, Pseudonym) per identifier,
        grouped by category in first-seen order. The map UN-REDACTS a report: keep it
        on the local machine and never share it with the redacted files.

    .PARAMETER Context
        An OmniDiag.RedactionContext.

    .OUTPUTS
        OmniDiag.RedactionMapEntry[]

    .EXAMPLE
        Get-OmniRedactionMap -Context $ctx | Format-Table Category, Pseudonym, Original
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object] $Context)
    Assert-OmniRedactionContext -Context $Context
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($category in @('Host', 'Domain', 'User', 'Path', 'Sid', 'IPv4', 'IPv6', 'Mac', 'Term')) {
        foreach ($e in $Context.Entries) { if ($e.Category -eq $category) { $sorted.Add($e) } }
    }
    return , $sorted.ToArray()
}

Export-ModuleMember -Function @('New-OmniRedactionContext', 'ConvertTo-OmniRedacted', 'Get-OmniRedactionMap')
