# Event logs (`events`)

Windows event logs: errors and warnings across the key channels, grouped, translated into
plain English, and placed on a timeline for the selected range (`--range`, default the last
7 days).

## Run it

```bat
omnidiag events
omnidiag events --range 24h --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagEvents
Get-OmniDiagEvents -Range Last24Hours -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Error Summary | `events.error-summary` | Summarizes recent critical/error events from System and Application logs. | Not required | None |
| Event Logs | `events.event-logs` | Collects, groups, and interprets Windows event logs across key channels. | Not required (the Security and Defender channels are skipped without it) | None |

## What it checks

- **Event Logs** - collects Critical, Error, and Warning events (Information too with
  `IncludeInformation`) from 15 channels for the selected range, then:
  - **groups and de-duplicates** them by provider + event id + level: identical events become
    one group with a count and first/last-seen times, and each group yields at most one
    finding (title suffixed `(xN)`);
  - **translates** known event ids through the catalog in `src/EventLog/EventLogCatalog.psm1`
    into a plain-English title, likely cause, and recommendation, with a severity override
    where Windows logs an important event at a low level (e.g. 4625);
  - raises a finding for every Critical/Error group and for Warning groups seen at least
    `RecurringThreshold` (default 5) times, capped at 50 group findings;
  - detects cross-event patterns: 10+ failed logons, repeated service crashes (7031/7034),
    two or more unexpected shutdowns (41/6008);
  - builds a boot/shutdown/crash timeline (`Timeline` metric).
- **Error Summary** - a quick count of Critical/Error events in System and Application (at
  most 500), the top 5 sources, and the number of Kernel-Power 41 and application crash events.

Known-bad hints in the catalog include:

| Area | Provider / event id | Catalog severity |
|---|---|---|
| Unexpected shutdown | Kernel-Power 41; EventLog 6008 | Critical; Error |
| Bug check (BSOD) | WER-SystemErrorReporting (BugCheck) 1001 | Critical |
| Windows Error Reporting | Windows Error Reporting 1001 (fault bucket) | Information |
| Disk | disk 7 (bad block), 11 (controller error), 51 (paging error), 153 (I/O retried) | Critical, Error, Warning, Warning |
| File system | Ntfs 55 (corruption), 98 (volume health; keeps the event's own level), 137 (transaction resource manager failed), 140 (write failure) | Critical, -, Error, Error |
| Services, network, authentication, updates, Defender, profiles, Group Policy | see the catalog | |

## Data sources

`Get-WinEvent -FilterHashtable` with `StartTime`/`EndTime` from the selected range and
`MaxEvents` on every query. Events are matched by provider name and numeric event id, never
by message text, so the analysis does not depend on the display language; only the first
line of the message is kept as a sample. Collection is bounded: the Event Logs scanner reads
at most `MaxEventsPerChannel` (default 2000) events per channel and `MaxEventsTotal` (default
20000) in all (metric `EventsTruncated`), and has a 120-second time budget (`TimeoutSec`).

## Elevation

No scanner in this group requires administrator rights at the module level. Without them the
Event Logs scanner skips the Security and Defender channels and says so in an Information
finding.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

| Scanner | Finding (Id) | Severity | When |
|---|---|---|---|
| Event Logs | Catalog title or "Event ID n from provider", plus `(xN)` when seen more than once (`events.group.<provider>-<id>-<level>`) | Catalog severity, else the event level | Critical/Error group, or a Warning group seen `RecurringThreshold`+ times |
| Event Logs | N failed logon attempts detected (`events.pattern.failed-logons`) | Critical | 10+ events 4625 |
| Event Logs | Repeated service crashes (`events.pattern.service-crashes`) | Error | `RecurringThreshold`+ events 7031/7034 |
| Event Logs | N unexpected shutdowns (`events.pattern.unexpected-shutdowns`) | Critical | 2+ events 41/6008 |
| Event Logs | N channel(s) skipped (require administrator) | Information | Not elevated |
| Event Logs | No notable events in the selected window | Pass | Nothing collected |
| Event Logs | Windows Event Logs are unavailable on this platform | Information | Not running on Windows |
| Error Summary | N error/critical event(s) in range | Information | Any error events |
| Error Summary | N unexpected shutdown/bugcheck event(s) | Warning | Kernel-Power 41 present |
| Error Summary | Elevated error volume (N events) | Warning | More than 25 error events |
| Error Summary | No significant error activity | Pass | No Warning-or-higher finding was raised (can accompany the Information count) |

The Event Logs group and pattern finding Ids never contain counts or other live values, so the
same problem keeps the same Id across scans. Findings listed without an Id have none set
explicitly; their Id is derived from the component and title, so a title that carries a
count (for example the Error Summary findings) yields an Id that changes with the count.

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. A channel that does not exist on a machine is
skipped silently (logged at Debug). On other operating systems the Event Logs scanner returns
an Information finding.
