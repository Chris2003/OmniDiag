# OmniDiag report schema v1

OmniDiag's JSON report is a versioned, documented projection of a diagnostic session. It is
what `Export-OmniJsonReport`, `Export-OmniReport -Format Json`, `omnidiag scan --format json`,
`omnidiag report`, and the `data.json` inside a report package (`.zip`) contain.

* Schema file: [`schemas/omnidiag-report.v1.json`](../schemas/omnidiag-report.v1.json)
  (JSON Schema draft 2020-12).
* Listings (`omnidiag list --format json`) use
  [`schemas/omnidiag-list.v1.json`](../schemas/omnidiag-list.v1.json).
* PowerShell: `ConvertTo-OmniReportV1 -Session $s [-Option @{...}]` returns the document;
  `ConvertTo-OmniJsonText` serializes it; `ConvertFrom-OmniReportV1` turns a document back
  into a session-shaped object.

The in-memory session and the files saved in `OmniDiagData\sessions` keep OmniDiag's native
internal format (`Save-OmniSession`). `Import-OmniSession` reads both: a file with
`schemaVersion` is a v1 report, anything else is a native session.

## Envelope

```text
{
  schemaVersion: "1.0.0",
  tool:        { name: "OmniDiag", version },
  generatedAt: ISO-8601 UTC,
  host:        { computerName, userName, isAdmin, psVersion },
  options:     { ...free-form run options, keys sorted... },
  scan:        { startedAt, finishedAt, durationMs, cancelled,
                 timeRange: { preset, label, start, end } | null,
                 plan: { type, name } | null },
  summary:     { healthScore: 0-100 | null, grade: Healthy|Warning|Critical | null,
                 counts: { info, warning, critical, passed } },
  modules: [ {
      id, name, group, category,
      status: Healthy|Warning|Critical|Unknown|Skipped|Failed,
      skippedReason: string | null,          // e.g. "RequiresElevation"
      requiresElevation, startedAt, durationMs,
      error: string | null,
      metrics: { ...module-specific... },
      findings: [ {
          id, moduleId, title,
          severity: Info|Warning|Critical,
          severityNative: Pass|Information|Warning|Error|Critical,
          passed, component,
          evidence: { detail, data },
          likelyCause, recommendation, confidence: 0-100
      } ]
  } ]
}
```

Notes:

* **Ids.** `modules[].id` is the module's stable contract-v1 id (`<group>.<kebab-name>`,
  e.g. `network.dns-resolver`). Sessions saved before 0.5.0 have no id; the projection
  derives one from the built-in scanner table (or `extras.<kebab-name>`). `findings[].id` is
  the finding's stable id within its module; `moduleId` + `id` is a global key.
* **Timestamps** are ISO-8601 UTC with milliseconds (`2026-06-01T08:00:00.000Z`).
* **Counts** are disjoint: `passed` counts passing checks; `info` counts the other Info
  findings.
* **healthScore / grade** are `null` when no module completed (for example a scan cancelled
  before the first module finished).
* **host** contains identifying information. Review a report before sharing it (redaction
  arrives in Phase 3).
* **metrics** and **evidence.data** are free-form and module-specific; they are not covered
  by compatibility guarantees beyond being valid JSON.

## Severity mapping

| Native (`severityNative`) | v1 `severity` | `passed` |
|---|---|---|
| Pass | Info | true |
| Information | Info | false |
| Warning | Warning | false |
| Error | Critical | false |
| Critical | Critical | false |

The native five-level scale stays inside OmniDiag (health score, GUI, console), so the score
doesn't change. `ConvertFrom-OmniReportV1` restores the native value from `severityNative`.

## Determinism

The writer (`ConvertTo-OmniJsonText`) produces the same bytes on Windows PowerShell 5.1 and
PowerShell 7 for the same input:

* properties are emitted in a fixed order; hashtables in finding data and metrics are emitted
  with keys in ordinal order;
* the output is ASCII-only (non-ASCII characters are `\u`-escaped), with two-space indentation
  and LF line endings;
* numbers are culture-invariant; `NaN` and infinities become `null`; dates become ISO-8601 UTC.

`Tests/golden/report-v1.fixture.json` is the golden file for a fixed fixture session
(`Tests/golden/ReportFixture.ps1`); the test normalizes only `generatedAt` and `tool.version`.

## Versioning policy

`schemaVersion` follows SemVer.

* **Patch** (1.0.x): documentation or schema-description fixes; no change to documents.
* **Minor** (1.x.0): additive changes only - new optional properties, new enum values in
  free-form areas. The schema file `omnidiag-report.v1.json` is updated in place. Readers
  must ignore properties they don't know.
* **Major** (2.0.0): anything that removes, renames, or changes the meaning or type of a
  property. A new schema file (`omnidiag-report.v2.json`) is added; v1 stays published.

OmniDiag reads any `1.x` document (`Import-OmniSession`, `ConvertFrom-OmniReportV1`) and
refuses other major versions with a clear error. Every change is covered by the golden-file
test, which must be regenerated deliberately (see the header of `ReportFixture.ps1`).
