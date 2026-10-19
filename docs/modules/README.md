# Module groups

OmniDiag's scanners are organized into the ten v1.0 groups plus `extras`. Every group can be
run on its own from the command line (`omnidiag <group>`), from PowerShell
(`Get-OmniDiag<Group>` or `Invoke-OmniDiagScan -Group <group>`), and from the GUI. A default
scan contacts no other machine; connectivity probes run only with `--network-probes` /
`-NetworkProbes` (see [CLI.md](../CLI.md)).

| Group | Id | Cmdlet | Page |
|---|---|---|---|
| System | `system` | `Get-OmniDiagSystem` | [system.md](system.md) |
| Performance | `performance` | `Get-OmniDiagPerformance` | [performance.md](performance.md) |
| Services and drivers | `services` | `Get-OmniDiagServices` | [services.md](services.md) |
| Startup and persistence | `startup` | `Get-OmniDiagStartup` | [startup.md](startup.md) |
| Event logs | `events` | `Get-OmniDiagEvents` | [events.md](events.md) |
| Reliability | `reliability` | `Get-OmniDiagReliability` | [reliability.md](reliability.md) |
| Storage | `storage` | `Get-OmniDiagStorage` | [storage.md](storage.md) |
| Network | `network` | `Get-OmniDiagNetwork` | [network.md](network.md) |
| Windows Update and health | `updates` | `Get-OmniDiagUpdates` | [updates.md](updates.md) |
| Security | `security` | `Get-OmniDiagSecurity` | [security.md](security.md) |
| Extras | `extras` | `Get-OmniDiagExtras` | [extras.md](extras.md) |

`omnidiag list groups` and `Get-OmniDiagGroup` list the groups with their scanner counts;
`omnidiag list modules` and `Get-OmniDiagModule` list every scanner with its id, group,
elevation, and network access.

## Group page template

Each group page has the same sections, in this order. When you add or change a scanner,
update its group's page in the same pull request (and its entry in
`Tests/data/scanner-groups/<group>.psd1`).

1. **Title and summary.** `# <Group name> (`<id>`)`, then one paragraph on what the group
   answers for a technician.
2. **Run it.** CLI and PowerShell examples: `omnidiag <id>`, `omnidiag <id> --format json`,
   `Get-OmniDiag<Group>`, and `Get-OmniDiag<Group> -IncludePassed` (plus `--network-probes` /
   `-NetworkProbes` when the group has a connectivity probe).
3. **Scanners.** A table: scanner name, id, what it checks (one line), elevation (whether the
   scanner, or part of it, needs administrator rights and what is skipped without them), and
   network access (`None`, or what the opt-in probe contacts).
4. **What it checks.** Per scanner: the checks it makes and the thresholds it uses.
5. **Data sources.** Per scanner: the APIs, CIM classes, registry keys, event channels, or
   files it reads, and why tool-output parsing is used where it is (language independence).
6. **Elevation.** What runs as a standard user, what needs elevation, and the structured skip
   (`SkippedReason` = `RequiresElevation`) or partial result a standard user gets.
7. **Network access.** `None` for local-only scanners; for probe-capable scanners, the exact
   traffic with `--network-probes` and the "Connectivity probe not run" Information finding
   without it.
8. **Findings it can emit.** A table: finding title, native severity
   (Pass / Information / Warning / Error / Critical), and when it is raised.
9. **Platforms.** Windows 10 22H2 x64, Windows 11 x64 and ARM64; data that is not available
   on a platform is reported as "not available", never as a failure.

The pages were first generated from the scanner manifests (sections 1-3 and 7) and were
checked against each scanner's source for 1.0 (manifest values and every finding it can emit).
`Tests/Docs.Modules.Tests.ps1` fails when a scanner in `src/Modules` is missing from its
group's page.
