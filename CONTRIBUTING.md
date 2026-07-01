# Contributing to OmniDiag

Thanks for your interest in improving OmniDiag! This guide covers how to set up,
test, and contribute — especially how to add a new diagnostic module.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.

## Getting started

```powershell
git clone https://github.com/OWNER/OmniDiag.git
cd OmniDiag
Import-Module .\src\OmniDiag.psd1 -Force
.\OmniDiag.ps1
```

Requirements: Windows PowerShell 5.1 or PowerShell 7+, and Pester 5.5+ for tests.

## Development workflow

1. Create a branch: `git checkout -b feature/my-change`.
2. Make your change with tests.
3. Run the analyzer and tests locally (see below). Both must pass.
4. Update `CHANGELOG.md` under **Unreleased**.
5. Open a pull request describing the change and how you verified it.

## Linting & tests

```powershell
# Lint
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning

# Tests
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\Tests
```

CI runs both on `windows-latest` for every pull request.

## Adding a diagnostic module

1. Create `src/Modules/MyScanner.psm1`.
2. Implement the two contract functions (`Get-OmniModuleManifest`,
   `Invoke-OmniModuleScan`) — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
   full template and any existing scanner (e.g. `System.psm1`, `Cpu.psm1`) as a reference.
3. `Tests/Modules.All.Tests.ps1` discovers every scanner and runs it through the engine
   automatically, so a new scanner is covered on discovery/contract/clean-execution with no
   extra work. Add a dedicated `Tests/Modules.<Name>.Tests.ps1` only for scanner-specific
   behavior worth asserting.
4. That's it — the engine discovers it automatically. **Do not modify the core** to
   add a scanner.

### Module guidelines

- **Diagnose, don't dump.** Every finding should carry a severity and, where
  possible, a `LikelyCause`, `Confidence`, and `Recommendation`.
- **Fail soft.** Wrap data collection in `try/catch`; log failures via
  `$Context.Logger` and continue. Never let one query abort the module.
- **Respect privacy.** Don't transmit anything. Be mindful that findings may contain
  sensitive values.
- **Honor cancellation.** For long loops, check `$Context.CancellationToken.IsCancellationRequested`.
- **Declare admin needs.** Set `RequiresAdmin = $true` if you read an elevated-only
  source; the engine will skip gracefully when not elevated.

## Style

- `Set-StrictMode -Version Latest` at the top of every file.
- Comment-based help on public functions; XML/comment docs on non-trivial logic.
- Approved PowerShell verbs (`Get-`, `New-`, `Invoke-`, …) and `Verb-OmniNoun` naming
  for shared functions.
- No `Write-Host` outside the `Cli`/`UI` presentation layers.
