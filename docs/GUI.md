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

Shortcuts are `KeyBinding`s declared in `src/UI/MainWindow.xaml` (the window shell) and moved onto the window when it loads; each raises
`NavigationCommands.GoToPage` with a parameter that `Invoke-OmniShortcut` dispatches.

## Export

Export (Ctrl+E) opens a dialog with HTML, JSON, CSV (default), Markdown, PDF, and
**Bundle (.zip)**, plus **Redact identifiers for sharing** (off by default), which
replaces host names, user names, domains, SIDs, profile paths, and IP/MAC addresses
with stable pseudonyms. The redaction option is disabled, with a tooltip, when the
installed reporting module cannot redact (`Export-OmniDiagReport -Redact`). Reports are written in
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

Target: under 2 s. There are **two numbers, and they are not the same thing**:

- **First paint** (`StartupMs`): the window is on screen with the OmniDiag title, the
  theme background, and a "Loading OmniDiag..." status. Nothing is clickable yet.
- **Shell ready** (`ShellReadyMs`): the full window (top bar, navigation, Dashboard,
  status bar) is in place, rendered, and interactive.

Both are measured from `Show-OmniDiagGui` (internally `Start-OmniGuiWindow`), logged at
Info to `OmniDiagData\logs\omnidiag-gui-*.jsonl` (with a Warn line for each one over
2000 ms), and exposed as the window's UI Automation ItemStatus: `StartupMs=<n>` at first
paint, then `StartupMs=<n>;ShellReadyMs=<m>`.

Why two: CI measurements showed about 0.9 to 1.1 s of the startup is the XAML engine's
cold start (the first `XamlReader.Parse` of anything), about 1.1 s the shell itself, and
about 0.5 s the first layout and render. Shrinking the XAML cannot bring the total under
2 s. So the window is first built **in code** (no XAML): first paint does not wait for
the XAML engine, and the shell follows. The time to a fully interactive window is about
the same as before (it is reported honestly as `ShellReadyMs`); what improves is how
soon the user sees a responsive window instead of nothing.

### What loads when

1. **Frame window** (`New-OmniFrameWindow`, code only): title, size, font,
   `AutomationProperties` (Name "OmniDiag", AutomationId `OmniDiagMainWindow`), the theme
   brushes (or the Windows high-contrast colors), and a centered "OmniDiag" plus a
   "Loading OmniDiag..." status, a polite live region with its own accessible name.
   Shown; its `ContentRendered` is first paint.
2. **Shell** (`Complete-OmniShellLoad`, Background priority right after first paint):
   `src/UI/MainWindow.xaml` is parsed. Its root is a `Grid`, not a `Window`: its shared
   styles and KeyBindings are moved onto the frame window (the window's theme brushes win
   over the XAML's Light-palette fallbacks), its x:Names are looked up on the shell root,
   the top bar and navigation handlers are wired, and it becomes the window's Content.
   The brushes are not applied again here: only the theme-dependent controls are updated
   (`Sync-OmniThemeControl`); theme toggles and high-contrast changes at runtime apply
   both (`Sync-OmniEffectiveTheme` = `Set-OmniEffectiveBrush` + `Sync-OmniThemeControl`).
   The next Background callback marks `ShellReady` (`Complete-OmniShellReady`).
3. **After the shell is ready** (Background): open the GUI log and record the timings, set
   the help tooltip, register the group names, and load the Dashboard's Module Results
   grid. Then (ApplicationIdle) one background runspace for System Information, the
   repair catalog, and the scanner and group catalogs.
4. **Sections**, on first navigation (click, arrow keys, Ctrl+1..6, Ctrl+F):

| File | Contents | Loaded |
|---|---|---|
| `src/UI/MainWindow.xaml` | Shell: key bindings, brush fallbacks and the few shared styles (buttons, check boxes, combo boxes, list items, labels), top bar, navigation, the Dashboard (score, System Information, recommendations), status bar, and an empty `Border` host per section | Right after first paint (step 2) |
| `src/UI/Sections/DashboardModules.xaml` | The Dashboard's Module Results grid | Step 3 |
| `src/UI/Sections/SectionStyles.xaml` | Data grid, grid row, and detail box styles (a `ResourceDictionary` merged into the window) | With the first section |
| `src/UI/Sections/Groups.xaml`, `Findings.xaml`, `Diagnostics.xaml`, `Repair.xaml`, `LocalAi.xaml` | One section each | On first navigation to it |

Before the shell is ready no shortcut exists yet and any that races the swap is ignored
(`Invoke-OmniShortcut`, the theme toggle, and the busy-state update check `ShellReady`);
closing the window is always safe, and queued shell or startup work does nothing after
close. If the shell XAML fails to load, the frame stays up and says so.

Each section fragment is parsed once (`Import-OmniSection`), inserted into its host, and
cached; its controls are looked up on the fragment and its handlers wired then
(`Initialize-OmniSection`). Fragments are parsed on their own, so they use
`DynamicResource` (never `StaticResource`) for the shell's brushes and styles. To add a
control to a section, add it to the fragment and to that section's `Controls` list in
`$script:OmniSections` (`src/UI/OmniDiagGui.psm1`); `Tests/UI.Xaml.Tests.ps1` checks that
every name the code uses exists in the shell or a fragment. The elevation check for the
Repair Center note runs when that section loads.

### Phase breakdown

The same log has a line with the phase breakdown, in milliseconds since the GUI was
started (each value is when that phase finished), in this order:

| Phase | Meaning |
|---|---|
| `Entry` | `Start-OmniGuiWindow` called (0) |
| `StaRunspaceReady` | PowerShell 7 only: the STA runspace that hosts the window is open |
| `WpfPreloaded` | PowerShell 7 only: WPF assemblies loaded on the calling thread, in parallel with the module import |
| `ModuleImported` | PowerShell 7 only: OmniDiag imported in the STA runspace |
| `InitializeStart` | window construction starts |
| `WpfAssembliesLoaded` | WPF assemblies loaded (already loaded on PowerShell 7) |
| `WindowConstructed` | the code-built frame window is ready to show |
| `ShowCalled` | the window is shown |
| `ContentRendered` | first paint of the frame (= `StartupMs`) |
| `FramePainted` | same moment as `ContentRendered`, named for what it is |
| `XamlEngineReady` | a trivial fragment parsed: the XAML engine's cold-start cost, measured apart from the shell |
| `ShellParsed` | `MainWindow.xaml` (the shell) parsed |
| `XamlParsed` | same moment as `ShellParsed` (kept for older logs) |
| `ShellReady` | the shell is the window's Content, wired, and rendered (= `ShellReadyMs`) |
| `Section<Name>Loaded` | a lazily loaded section finished loading (`SectionDashboardModulesLoaded`, `SectionGroupsLoaded`, ...); each load time is also logged on its own line |

The UI Automation test (`Tests/UI.Accessibility.Tests.ps1`) prints both numbers and the
breakdown (soft gate: a warning when either is over 2 s, never a failure); its clock
starts at window construction, after the module import. It also visits every section
(loading each one) and checks names and Tab order there.

### Measuring (build/Measure-GuiStartup.ps1)

`build/Measure-GuiStartup.ps1` runs fresh processes (PowerShell 7 and Windows PowerShell
5.1, three runs each, median) and compares the current path with alternatives: the shell
parsed synchronously before showing (`XamlShellSync`), a code-built frame alone
(`CodeFrame`), the frame followed by the shell (`CodeFrameThenShell`), and the real
launcher (`OmniDiag.ps1 -Gui`) measured from process start. CI runs it in the
non-blocking `gui-startup` job; the table is in the job summary and `gui-startup.json` in
the artifact.

Test hooks used by it (no effect unless set):

| Variable | Effect |
|---|---|
| `OMNIDIAG_GUI_EXIT_AFTER_RENDER=1` | close the window as soon as the shell is ready (the background startup runspace is not started) |
| `OMNIDIAG_GUI_STARTUP_FILE=<path>` | when the shell is ready, write the timings (StartupMs, ShellReadyMs, process start, first-paint and shell-ready UTC times, all marks) to that file as JSON. The path is checked like every other OmniDiag output (`Resolve-OmniOutputPath`): device paths, named pipes, mailslots, and alternate data streams are refused |

Neither hook is ever silent: when one is honored (or the startup file is refused), the GUI
writes a Warn line to its log (`OmniDiagData\logs\omnidiag-gui-*.jsonl`) and a line to
stderr when a console is attached, so a stray variable cannot make the window quietly
close or write files.

Other startup savings: the shell XAML is read once and parsed from text, and live-region
announcements are skipped until the window is loaded.
