# Report redaction

OmniDiag reports describe one machine, so they contain its name, the signed-in user, the
domain, profile paths, SIDs, and network addresses. A redacted report replaces those values with
stable pseudonyms, so you can attach it to a vendor ticket or post it in a forum and still follow
the evidence: the same address is `IP-1` in every file of the bundle.

Everything happens locally. Nothing is uploaded, and the session you scanned is never changed:
redaction works on a copy.

## How to produce a redacted report

| Where | How |
|---|---|
| CLI | `omnidiag report --redact` (any format) |
| GUI | Export, then choose the redacted option |
| PowerShell | `Export-OmniReport -Session $s -Format Html, Json, Pdf, Zip -Redact` |
| PowerShell (package only) | `Export-OmniReportPackage -Session $s -Path .\share.zip -Redact` |
| PowerShell (any object) | `$ctx = New-OmniRedactionContext -Session $s; ConvertTo-OmniRedacted -InputObject $obj -Context $ctx` |

`Export-OmniReport -Redact` builds one redaction context from the session, makes one redacted
copy of the session, and hands that copy to every exporter: HTML, JSON (schema v1), CSV
(findings and events), Markdown, PDF, and the ZIP package, including the package README and the
run log. The output file names are redacted too: the default base name
`OmniDiag-<computer>-<timestamp>` becomes `OmniDiag-HOST-1-<timestamp>`, and a base name you
pass with `-BaseName` is redacted the same way. The JSON report records
`"options": { "redacted": true }` (schema 1.1.0), and the HTML, Markdown, PDF, and README privacy
notes say that the report is redacted. The returned report set has `Redacted = $true`.

Options:

* `-AdditionalTerm 'Contoso Ltd', 'TICKET-4711'` redacts extra literal values (customer names,
  ticket numbers, project names) as `TERM-1`, `TERM-2`, ...
* `-RedactionMapPath .\private\map.json` writes the mapping (see below).
* `-RedactionContext $ctx` reuses one context, so several bundles share pseudonyms.
* `New-OmniRedactionContext -Salt <secret>` derives pseudonyms from the value (see below).

## What is redacted

| Identifier | Source | Pseudonym |
|---|---|---|
| Computer name (NetBIOS) | session `Host.ComputerName`, `$env:COMPUTERNAME` | `HOST-1` |
| Computer FQDN | `<host>.<dns domain>` found anywhere in the session; `$env:COMPUTERNAME` + `$env:USERDNSDOMAIN` or the machine's DNS domain | `HOST-1.DOMAIN-2` |
| User name | session `Host.UserName` (`DOMAIN\user` and `user@domain` are split), `$env:USERNAME` | `USER-1` |
| NetBIOS domain | the `DOMAIN` part of `DOMAIN\user`, session `Host.Domain`, `Domain` / `DomainName` metrics, `$env:USERDOMAIN` | `DOMAIN-1` |
| DNS domain | session `Host.DnsDomain` (recorded at scan time), `Domain` / `DnsDomain` / `DomainName` metrics in the results (for example the Active Directory scanner's `Domain`), `$env:USERDNSDOMAIN`, the machine's primary DNS domain (registry `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`, so it is found when running as SYSTEM or a local account), the domain of an FQDN or a UPN, and its parent suffixes (`contoso.com` from `corp.contoso.com`) | `DOMAIN-2` |
| Profile folders | `$env:USERPROFILE`, and every `\Users\<name>\`, `/home/<name>/`, `\Documents and Settings\<name>\` folder anywhere in the session or a log line, including device paths (`\Device\HarddiskVolume3\Users\<name>`), UNC shares (`\\fs01\Users\<name>`), WSL mounts (`/mnt/c/Users/<name>`), and JSON-escaped `\\Users\\<name>` | `C:\Users\USER-2\...` |
| Other profile roots | `$env:USERPROFILE` outside `X:\Users` (redirected or roaming profiles) | `PATH-1` |
| Account SIDs | `S-1-5-21-...` (machine and domain accounts), `S-1-12-1-...` (Entra ID) | `SID-1` |
| IPv4 addresses | any dotted quad | `IP-1` (`IP-1/24` for a CIDR) |
| IPv6 addresses | full and compressed forms, IPv4-mapped, with a zone index, also glued to a label (`Address:fe80::1`) or followed by a colon (`Pinging 2001:db8::5: ...`) | `IPV6-1` (`IPV6-1%12`) |
| MAC addresses | `AA-BB-CC-DD-EE-FF` and `AA:BB:CC:DD:EE:FF`, also glued to a label (`BSSID:aa:bb:...`) or followed by a colon | `MAC-1` |
| Extra terms | `-AdditionalTerm` | `TERM-1` |

Names are matched case-insensitively and longest first, so `acme-ws-042.corp.contoso.com`
becomes `HOST-1.DOMAIN-2` instead of `HOST-1.corp.contoso.com`, and `jdoe@contoso.com` becomes
`USER-1@DOMAIN-3`. A name only matches as a whole word (`jdoe` is redacted in `CONTOSO\jdoe`,
`jdoe_backup`, and `C:\Users\jdoe`, but not inside `jdoes`).

An identifier glued to an escape sequence is still found: right after a URL escape
(`%5Cjdoe`, `jdoe%40contoso.com`, `%2010.20.30.40`, `%20fe80::1`) or after a JSON escape that
was kept as text (`\njdoe`, `\tS-1-5-21-...`, `\u0022ACME-WS-042`), as in raw tool output or a
JSON fragment inside a finding. The escape itself is kept (`%5CUSER-1`, `%20IP-1%20`).

Redaction covers every string in the session: finding titles, details, likely causes,
recommendations, components, evidence data at any depth, module metrics and their keys, event
groups and the timeline, the host block, and the run options. Property names and dictionary keys
are redacted too (a metric named `Last user on ACME-WS-042` becomes `Last user on HOST-1`).
Numbers, booleans, and dates are copied unchanged.

## What is not redacted

These values identify nothing about the machine and are kept so the report stays useful:

* **Addresses:** IPv4 loopback (`127.0.0.0/8`), unspecified (`0.0.0.0`), broadcast
  (`255.255.255.255`), subnet masks (any contiguous mask such as `255.255.255.0`), multicast
  (`224.0.0.0/4`), and the public resolvers `8.8.8.8`, `8.8.4.4`, `1.1.1.1`, `1.0.0.1`, `9.9.9.9`,
  `149.112.112.112`, `208.67.222.222`, `208.67.220.220`. IPv6 loopback (`::1`), unspecified
  (`::`), and multicast (`ff00::/8`).
* **MACs:** `00-00-00-00-00-00` and `FF-FF-FF-FF-FF-FF`.
* **SIDs:** well-known SIDs such as `S-1-5-18` (LocalSystem), `S-1-5-19`, `S-1-5-20`,
  `S-1-5-32-544` (Administrators), and service SIDs (`S-1-5-80-...`, derived from the service
  name). Domain-relative well-known accounts (`S-1-5-21-...-500`) **are** redacted, because the
  domain part identifies the domain.
* **Names:** built-in account, group, and folder names are never treated as identifiers, even
  when they are the session's user or computer name: `Administrator`, `Admin`, `Guest`, `SYSTEM`,
  `LocalSystem`, `Local Service`, `Network Service`, `NT AUTHORITY`, `BUILTIN`, `WORKGROUP`,
  `localhost`, `Public`, `Default`, `Default User`, `All Users`, `defaultuser0`,
  `DefaultAppPool`, `root`, and the words `user`, `users`, `host`, `domain`, `path`, `sid`, `mac`,
  `term`. Names shorter than 3 characters are ignored (`-AdditionalTerm` accepts 2).
* **Text that is not an identifier:** times (`12:30`, `12:30:45`), ISO timestamps, dates, GUIDs,
  version numbers with more than four parts or a part above 255 (`10.0.19045.1`), code such
  as `[System.IO.Path]::Combine`, and hex chains longer than a MAC (`00-11-22-33-44-55-66-77`).
* **URL paths:** `/home/` or `/Users/` inside a URL (`https://example.com/home/index.html`).
* **Branding** you pass (`-BrandName`, `-BrandLogo`) and the output folder.

## Pseudonym scheme

* One counter per category, in the order values are first seen: `HOST-1`, `HOST-2`, `USER-1`,
  `DOMAIN-1`, `PATH-1`, `SID-1`, `IP-1`, `IPV6-1`, `MAC-1`, `TERM-1`. The session's own host and
  user are registered first, so they are normally `HOST-1` and `USER-1`.
* The same value always gets the same pseudonym within a context, and `Export-OmniReport` uses
  one context for the whole bundle, so `IP-1` in the HTML is `IP-1` in the JSON, the CSV, the
  PDF, and the run log. Equivalent spellings share a pseudonym: both MAC notations, and the
  compressed and expanded forms of an IPv6 address.
* Structure is kept where it helps: `C:\Users\jdoe\AppData` becomes `C:\Users\USER-1\AppData`,
  an FQDN becomes `HOST-1.DOMAIN-2`, `CONTOSO\jdoe` becomes `DOMAIN-1\USER-1`, a CIDR keeps its
  prefix length, and an IPv6 zone index is kept.
* Numbers are per bundle: `IP-1` in today's bundle and `IP-1` in yesterday's are unrelated. To
  correlate across bundles, pass the same `-Salt` to `New-OmniRedactionContext` (and that context
  to `Export-OmniReport -RedactionContext`): pseudonyms become `HOST-<8 hex>`, the first 32 bits
  of an HMAC-SHA256 of the value keyed by the salt. Keep the salt secret; anyone who has it can
  confirm a guessed value.

## The mapping file

`-RedactionMapPath <path>` writes the original-to-pseudonym table as JSON
(`kind: omnidiag-redaction-map`, one entry per value with `category`, `pseudonym`,
`original`). `Get-OmniRedactionMap -Context $ctx` returns the same table in PowerShell.

The mapping file **un-redacts** the report. OmniDiag writes a warning when it creates one, never
lists it in the report set's `Files`, and never puts it in the ZIP package. Keep it on the
technician's machine, outside the folder you share.

## The run log in the package

The ZIP package includes the run log (`omnidiag-log.jsonl`). In a redacted package the log is
redacted line by line with the same context, so pseudonyms match the rest of the bundle. Each
line is redacted as text: names, profile folders (also the JSON-escaped `C:\\Users\\name` form),
SIDs, and addresses are replaced; the JSON structure and timestamps are untouched. Printable
`\uXXXX` escapes are decoded first (Windows PowerShell 5.1 writes `'` and `&` as `\u0027` and
`\u0026`), so names such as `o'brien` or `R&D` are found; the line stays valid JSON. The log was kept rather than
omitted because timings and errors in it are often what a vendor needs.

## Limitations

* **Free text that cannot be derived from the session is not caught.** A colleague's name in an
  event message, a server name in a scheduled task, a customer name in a file path, an e-mail
  address of someone other than the signed-in user, or a host name that only appears without the
  scanned machine's domain is left as is. Use `-AdditionalTerm` for values you know about, and
  review the report before sharing it.
* Other accounts are recognized through their profile folders (`C:\Users\<name>`), not through
  `DOMAIN\name` references in free text.
* A profile folder first seen while redacting (for example only in a run-log line) is redacted
  from that point on; text that was already redacted before it was seen is not revisited.
  Folders anywhere in the session are found up front, so this only affects the log.
* Any `\Users\<x>\` or `\home\<x>\` segment after a backslash is treated as a profile folder,
  so a registry path such as `SAM\Domains\Account\Users\000001F4` is (harmlessly) over-redacted.
* A four-part version number whose parts are all 0-255 (`1.2.3.4`) is indistinguishable from an
  IPv4 address and is redacted.
* A real name that already looks like a pseudonym in upper case (a computer named `HOST-12`) is
  not redacted again.
* An identifier whose own characters are escaped (`10%2E20%2E30%2E40`, `fe80%3A%3A1`,
  `\u006adoe`) is not recognized; only escapes before or after it are.
* Because `\n`, `\r`, and `\t` are treated as JSON escapes, a name that is the rest of a path
  segment after one of them is redacted there too: for a user named `emp`, `C:\temp` becomes
  `C:\tUSER-1`. This over-redacts, it never leaks.
* Binary content is not inspected: a brand logo embedded in the HTML or PDF is copied as is.
* Values nested deeper than 24 levels are rendered as (redacted) text; this also stops reference
  cycles.
