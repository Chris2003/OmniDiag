# Local Ollama Assistant

OmniDiag can optionally ask a locally running Ollama model to correlate findings and
suggest the next diagnostic steps. The assistant is advisory: it cannot call the
Repair Center, run commands, or change the device.

## Model choice

The default is `gemma4:e2b`, the smallest local Gemma 4 tag currently published in
the Ollama library. Its download is roughly 7.2 GB, so allow additional memory and
disk headroom. For older technician laptops, use `gemma3:1b`, which is roughly
815 MB but provides less capable correlation and instruction following.

```powershell
ollama pull gemma4:e2b
# Low-memory alternative:
ollama pull gemma3:1b
```

Official references:

- [Ollama Gemma 4 library](https://ollama.com/library/gemma4)
- [Ollama generate API](https://docs.ollama.com/api/generate)
- [Ollama model-list API](https://docs.ollama.com/api/tags)
- [Google Gemma 4 model overview](https://ai.google.dev/gemma/docs/core/model_card_4)

## Run it

Start Ollama, then run a scan with analysis:

```powershell
.\OmniDiag.ps1 -Workflow QuickTriage -AiAnalysis
.\OmniDiag.ps1 -Profile CloudAdmin -AiAnalysis -AiModel gemma4:e2b
.\OmniDiag.ps1 -Workflow SlowComputer -AiAnalysis -AiModel gemma3:1b `
    -AiQuestion 'What evidence best explains the reported freezes?'
```

Automation uses the same API:

```powershell
Import-Module .\src\OmniDiag.psd1
$session = Invoke-OmniDiag -Workflow LoginAndIdentity -Quiet
$analysis = Invoke-OmniOllamaAnalysis -Session $session -Model gemma4:e2b
$analysis.Priorities
$analysis.Correlations
$analysis.NextSteps
```

Check readiness without generating anything:

```powershell
Test-OmniOllama -Model gemma4:e2b
```

## Privacy and safety boundaries

- Only loopback HTTP endpoints (`localhost`, `127.0.0.1`, or `::1`) are accepted.
- Ollama cloud-tag models are rejected.
- The selected model must already be installed; OmniDiag never downloads one.
- Pass findings, raw report files, logs, host identity, and scanner metrics are not
  sent. The prompt contains only the health score, plan name, and a bounded list of
  non-pass finding IDs, titles, components, likely causes, and recommendations.
- Output must cite finding IDs and distinguish uncertainty.
- The assistant has no tool or repair execution path. Any mutating suggestion is
  labeled as requiring approval and must be validated against organizational policy.

Ollama's local API does not require authentication, which is why OmniDiag refuses
non-loopback endpoints. Do not expose port 11434 to untrusted networks.

## Troubleshooting

**Ollama is not available:** start the Ollama service and verify
`http://127.0.0.1:11434/api/tags` responds locally.

**Model is not installed:** run the exact `ollama pull` command shown in the error.

**Out of memory:** close other GPU-heavy applications or select `gemma3:1b`. The
model name is configuration, so a future smaller Gemma 4 quantization can be used
without changing OmniDiag.

**Invalid structured JSON:** retry once. Small models can occasionally fail strict
formatting; use `gemma4:e2b` rather than the 1B fallback when resources permit.
