# OmniDiag GUI

The WPF window (`Show-OmniDiagGui`, `omnidiag gui`, `OmniDiag-GUI.cmd`) has six sections:

| # | Section | What it shows |
|---|---------|---------------|
| 1 | Dashboard | Health score and grade, System Information, top recommendations, module results |
| 2 | Groups | The v1.0 module groups with status, score, worst severity, and counts after a scan. Open a group to see its modules and findings |
| 3 | All Findings | Every finding with a text filter, a severity filter, and a detail panel (title, severity, component, module, group, detail, likely cause, recommendation, evidence summary) |
| 4 | Diagnostics | Turn scanners on or off for Run Scan, or run one scanner now |
| 5 | Repair Center | Pick repairs (recommended ones are pre-selected after a scan), dry run, confirm, run |
| 6 | Local AI | Optional loopback Ollama analysis of the latest scan (advisory only) |

Scans, repairs, exports, Local AI calls, and the startup work (System Information,
repair and scanner catalogs) all run in background runspaces, so the window stays
responsive. Connectivity probes stay off unless you tick "Run connectivity probes".

## Keyboard shortcuts

Press **F1** (or the **?** button) in the window for this list.

| Keys | Action |
|------|--------|
| F5 | Run a scan |
| Esc | Cancel the running scan or repair; with nothing running, leave an open group |
| Ctrl+E | Export reports for the latest scan |
| Ctrl+F | Go to All Findings and focus the filter box |
| Alt+T | Toggle dark / light theme (unavailable while high contrast is on) |
| F1 | Keyboard help |
| Ctrl+1 ... Ctrl+6 | Dashboard, Groups, All Findings, Diagnostics, Repair Center, Local AI |
| Up / Down | Move between sections in the navigation list |
| Enter | On a finding: show and focus its details. On a group: open it |
| Alt+Left or Backspace | Back from a group to the group list |
| Alt + underlined letter | Press that button or focus that field (Alt+S Run Scan, Alt+C Cancel, Alt+E Export, Alt+W time window, Alt+F filter, Alt+V severity, Alt+G open group, Alt+B back, Alt+R run repairs, Alt+Y dry run, ...) |
| Tab / Shift+Tab | Move between controls (top bar, then navigation, then the section). Inside lists and grids use the arrow keys |
| Space | Toggle the checkbox in the focused grid cell (Diagnostics "On", Repair Center "Run") |

Shortcuts are window-level `KeyBinding`s in `src/UI/MainWindow.xaml`; each raises
`NavigationCommands.GoToPage` with a parameter that `Invoke-OmniShortcut` dispatches.

## Export

Export (Ctrl+E) opens a dialog with HTML, JSON, CSV (default), Markdown, PDF, and
**Bundle (.zip)**, plus **Redact identifiers for sharing** (off by default), which
replaces host names, user names, domains, SIDs, profile paths, and IP/MAC addresses
with stable pseudonyms. The redaction option is disabled, with a tooltip, when the
installed reporting module has no `Export-OmniReport -Redact`. Reports are written in
the background to `OmniDiagData\reports` and the folder opens when done. Nothing is
uploaded.

## Accessibility

- Every interactive control has an `AutomationProperties.Name`; grid rows are named
  for screen readers (for example "Critical: Disk almost full (Disk Space)").
- The status bar text, the progress bar, and the findings count are polite live
  regions, so Narrator announces scan progress and results (needs .NET Framework 4.7.1+
  under Windows PowerShell; older frameworks simply don't announce). Under Windows
  PowerShell the GUI turns off WPF's legacy accessibility switches
  (`Switch.UseLegacyAccessibilityFeatures`, `.2`, `.3`) before WPF loads; without that,
  `powershell.exe` keeps them on and live regions stay silent.
- Keyboard focus is shown with a dotted rectangle and a thicker button border in every
  theme.
- Severity is always shown as text (the Severity column, the Worst severity column, the
  dashboard counts), never by color alone.
- **High Contrast:** when Windows high contrast is on, OmniDiag drops its own palette and
  uses the Windows high-contrast colors (SystemColors), including for focus, hover,
  disabled, and severity text. It follows the setting live, and the dark/light toggle
  is disabled while it is on.

### Manual check (Narrator, High Contrast, keyboard only)

Automated tests check names, key bindings, and Tab order (`Tests/UI.Accessibility.Tests.ps1`);
these checks need a person on a Windows desktop:

1. **Keyboard only** (unplug or ignore the mouse): Tab from the top bar through the
   navigation into each section and back; every stop shows a visible focus cue. Run a
   scan with F5, cancel one with Esc, reach every section with Ctrl+1..Ctrl+6, filter
   with Ctrl+F, open a finding's details with Enter, open a group with Enter and go back
   with Alt+Left, export with Ctrl+E (operate the whole dialog with Tab, Space, Enter,
   Esc), run a dry-run repair, and toggle the theme with Alt+T.
2. **Narrator** (Ctrl+Win+Enter): every control is announced with a meaningful name;
   scan progress and "Scan complete ... Score ..." are announced without moving focus
   (check this under both Windows PowerShell 5.1 and PowerShell 7: on 5.1 it depends on
   the legacy accessibility switches being off, see above);
   grid rows read as "Severity: title (module)"; the export dialog's checkboxes and the
   disabled redaction option (with its reason) are announced.
3. **High Contrast** (Left Alt+Left Shift+Print Screen, or Settings > Accessibility >
   Contrast themes): with OmniDiag open, switch high contrast on and off and between
   two contrast themes. All text, borders, focus cues, disabled buttons, and grids use
   the theme colors; no custom colors remain; severity is readable as text; the theme
   button is disabled with an explanation.

Record the result (date, Windows version, pass/fail per item) in `docs/STATUS.md`.

## Startup time

Target: first render under 2 s. The time from `Show-OmniDiagWindow` to the window's
first render is logged at Info to `OmniDiagData\logs\omnidiag-gui-*.jsonl` and exposed
as the window's UI Automation ItemStatus (`StartupMs=<n>`). System Information,
the repair and scanner catalogs, and group scanner counts load after first paint.

The same log has a second Info line with the phase breakdown, in milliseconds since
`Show-OmniDiagWindow` was called (each value is when that phase finished):

| Phase | Meaning |
|---|---|
| `Entry` | `Show-OmniDiagWindow` called (0) |
| `StaRunspaceReady` | PowerShell 7 only: the STA runspace that hosts the window is open |
| `WpfPreloaded` | PowerShell 7 only: WPF assemblies loaded on the calling thread, in parallel with the module import |
| `ModuleImported` | PowerShell 7 only: OmniDiag imported in the STA runspace |
| `InitializeStart` | window construction starts |
| `WpfAssembliesLoaded` | WPF assemblies loaded (already loaded on PowerShell 7) |
| `XamlParsed` | `MainWindow.xaml` parsed into the window |
| `WindowConstructed` | controls looked up, handlers wired, initial state set |
| `ShowCalled` | the window is shown |
| `ContentRendered` | first render (= `StartupMs`) |

The UI Automation test (`Tests/UI.Accessibility.Tests.ps1`) prints the breakdown next to
the first-render time; its clock starts at window construction, after the module import.
Startup work kept small on purpose: `MainWindow.xaml` is read once and parsed from text,
the Light theme the XAML already declares is not applied a second time, and live-region
announcements are skipped until the window is loaded.
