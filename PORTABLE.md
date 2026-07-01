# OmniDiag — Portable Edition

OmniDiag runs **fully locally** on the machine being diagnosed. There is no
installer, no service, no remoting, and no network calls. This portable package
is a self-contained folder you can copy to a USB stick, a network share, or push
through your existing management tooling — then run in place.

> **Local-only by design.** OmniDiag never reaches out to other machines
> (WinRM / PowerShell Remoting is disabled or firewalled on most enterprise
> endpoints). To diagnose many machines, run the portable tool on each one and
> collect the reports it produces.

## Requirements

- Windows 10 / 11 / Server 2019+ (x64)
- Windows PowerShell 5.1 (built in on every supported Windows) **or** PowerShell 7+
- Administrator rights are **optional** — without them, admin-only checks and
  repairs are skipped gracefully and everything else still runs.

Nothing else is bundled or required. Every report format — including **PDF** — is
generated natively in PowerShell, with no browser, no .NET PDF library, and no
network access, so PDF works even on locked-down machines.

## Quick start

1. Extract the whole package folder anywhere (e.g. `C:\Tools\OmniDiag`).
2. Run it:
   - **Console scan** — double-click **`OmniDiag.cmd`**
   - **Graphical interface** — double-click **`OmniDiag-GUI.cmd`**
   - **From PowerShell** — `./OmniDiag.ps1`

The `.cmd` launchers run OmniDiag with the execution policy bypassed **for that
process only** — no machine-wide change. This is what lets an extracted-from-zip
copy run on a locked-down host where script execution is otherwise blocked
(Mark-of-the-Web / RemoteSigned). If you prefer to run `OmniDiag.ps1` directly
and Windows blocks it, unblock the files once:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## Common commands

```powershell
# Full local scan, console dashboard
./OmniDiag.ps1

# Last 24 hours, System modules only
./OmniDiag.ps1 -Range Last24Hours -IncludeCategory System

# Scan and write reports (no interactive privacy prompt)
./OmniDiag.ps1 -Report -ReportFormat Html,Json,Pdf -AcceptPrivacyNotice

# Scan then open the Repair Center (dry-run: describes, changes nothing)
./OmniDiag.ps1 -Repair -RepairDryRun
```

All the same switches work through `OmniDiag.cmd`, e.g.
`OmniDiag.cmd -Report -AcceptPrivacyNotice`.

## Deploying across a fleet

Because OmniDiag is a plain folder that runs locally, deploy it with whatever you
already use — no remoting required:

- **Intune / ConfigMgr (SCCM)** — package as a Win32 app or script and run
  `OmniDiag.ps1 -Report -AcceptPrivacyNotice -ReportPath \\server\share\OmniDiag`.
- **GPO scheduled task / logon script** — same command line.
- **RMM** (NinjaOne, ConnectWise, Datto, …) — run as a PowerShell script step.

Point `-ReportPath` at a share and collect the per-machine reports centrally.

## Privacy

All collection and analysis happen **on the local machine**. OmniDiag never
uploads anything. Reports may contain usernames, device names, file paths, and
domain information — review them before sharing.
