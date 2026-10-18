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

_To be completed by the group owner._

## Data sources

_To be completed by the group owner._ Collection is bounded: the Event Logs scanner reads at
most `MaxEventsPerChannel` (default 2000) events per channel and `MaxEventsTotal` (default
20000) in all (metric `EventsTruncated`), and has a 120-second time budget (`TimeoutSec`).

## Elevation

No scanner in this group requires administrator rights at the module level. Without them the
Event Logs scanner skips the Security and Defender channels and says so in an Information
finding.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

_To be completed by the group owner._

## Platforms

_To be completed by the group owner._
