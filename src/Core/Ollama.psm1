<#
.SYNOPSIS
    Optional local Ollama analysis for completed OmniDiag sessions.

.DESCRIPTION
    Sends a minimized evidence projection to an Ollama API on the loopback
    interface and requests structured, evidence-linked troubleshooting guidance.
    It is advisory only and has no path to the repair engine.
#>

Set-StrictMode -Version Latest

function Assert-OmniLocalOllamaEndpoint {
    param([Parameter(Mandatory)][string] $Endpoint)
    try { $uri = [uri]$Endpoint } catch { throw "Invalid Ollama endpoint '$Endpoint'." }
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost','127.0.0.1','::1','[::1]')) {
        throw 'Ollama must use a local loopback HTTP endpoint (localhost, 127.0.0.1, or ::1).'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Invoke-OmniOllamaRequest {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body,
        [scriptblock] $Transport
    )
    if ($Transport) { return (& $Transport $Method $Uri $Body) }
    if ($Method -eq 'GET') { return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 10 -ErrorAction Stop }
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Method Post -Uri $Uri -ContentType 'application/json' -Body $json -TimeoutSec 180 -ErrorAction Stop
}

function Test-OmniOllama {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Endpoint = 'http://127.0.0.1:11434',
        [string] $Model = 'gemma4:e2b',
        [scriptblock] $Transport
    )
    $base = Assert-OmniLocalOllamaEndpoint -Endpoint $Endpoint
    if ($Model -match '(^|[:-])cloud($|[:-])') { throw 'Cloud-tag Ollama models are disabled; choose a locally installed model.' }
    try {
        $response = Invoke-OmniOllamaRequest -Method GET -Uri "$base/api/tags" -Transport $Transport
        $models = @($response.models | ForEach-Object { if ($_.model) { [string]$_.model } else { [string]$_.name } })
        return [pscustomobject]@{ PSTypeName='OmniDiag.OllamaStatus'; Available=$true; Endpoint=$base; Model=$Model; ModelPresent=($models -contains $Model); Models=$models; Error=$null }
    } catch {
        return [pscustomobject]@{ PSTypeName='OmniDiag.OllamaStatus'; Available=$false; Endpoint=$base; Model=$Model; ModelPresent=$false; Models=@(); Error=$_.Exception.Message }
    }
}

function Invoke-OmniOllamaAnalysis {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Session,
        [string] $Question = 'What are the most likely root causes and safest next diagnostic steps?',
        [string] $Model = 'gemma4:e2b',
        [string] $Endpoint = 'http://127.0.0.1:11434',
        [ValidateRange(1, 100)][int] $MaxFindings = 60,
        [scriptblock] $Transport
    )

    $status = Test-OmniOllama -Endpoint $Endpoint -Model $Model -Transport $Transport
    if (-not $status.Available) { throw "Ollama is not available at $($status.Endpoint): $($status.Error)" }
    if (-not $status.ModelPresent) { throw "Model '$Model' is not installed locally. Run: ollama pull $Model" }

    $findings = @(
        foreach ($result in @($Session.Results)) {
            foreach ($finding in @($result.Findings)) {
                if ($finding.Severity -eq 'Pass') { continue }
                [ordered]@{
                    id = [string]$finding.Id
                    severity = [string]$finding.Severity
                    component = [string]$finding.Component
                    title = [string]$finding.Title
                    likelyCause = [string]$finding.LikelyCause
                    recommendation = [string]$finding.Recommendation
                }
            }
        }
    ) | Sort-Object @{ Expression={ Get-OmniSeverityRank $_.severity }; Descending=$true } | Select-Object -First $MaxFindings

    $evidence = [ordered]@{
        healthScore = if ($Session.Summary) { $Session.Summary.Score } else { $null }
        grade = if ($Session.Summary) { $Session.Summary.Grade } else { $null }
        scanPlan = if ($Session.PSObject.Properties['ScanPlan']) { $Session.ScanPlan.Name } else { $null }
        findings = @($findings)
    }
    $schema = [ordered]@{
        type='object'
        properties=[ordered]@{
            summary=@{ type='string' }
            priorities=@{ type='array'; items=@{ type='object'; properties=@{ title=@{type='string'}; urgency=@{type='string'}; evidenceIds=@{type='array';items=@{type='string'}} }; required=@('title','urgency','evidenceIds') } }
            correlations=@{ type='array'; items=@{ type='object'; properties=@{ hypothesis=@{type='string'}; confidence=@{type='integer'}; evidenceIds=@{type='array';items=@{type='string'}} }; required=@('hypothesis','confidence','evidenceIds') } }
            nextSteps=@{ type='array'; items=@{ type='object'; properties=@{ step=@{type='string'}; evidenceIds=@{type='array';items=@{type='string'}}; requiresApproval=@{type='boolean'} }; required=@('step','evidenceIds','requiresApproval') } }
            limitations=@{ type='array'; items=@{type='string'} }
        }
        required=@('summary','priorities','correlations','nextSteps','limitations')
    }
    $system = 'You are an evidence-grounded IT troubleshooting assistant. Use only the supplied OmniDiag evidence. Cite finding IDs for every priority, correlation, and next step. Clearly state uncertainty. Never claim a repair ran, never invent missing facts, never request secrets, and never recommend bypassing security controls. Mutating steps must set requiresApproval=true.'
    $prompt = "Technician question:`n$Question`n`nOmniDiag evidence JSON:`n$($evidence | ConvertTo-Json -Depth 8 -Compress)"
    $body = [ordered]@{ model=$Model; system=$system; prompt=$prompt; stream=$false; think=$false; format=$schema; keep_alive='5m'; options=@{ temperature=0.1; num_predict=900 } }
    $response = Invoke-OmniOllamaRequest -Method POST -Uri "$($status.Endpoint)/api/generate" -Body $body -Transport $Transport
    if (-not $response.response) { throw 'Ollama returned no analysis content.' }
    try { $analysis = $response.response | ConvertFrom-Json -ErrorAction Stop } catch { throw "Ollama returned invalid structured JSON: $($_.Exception.Message)" }
    foreach ($required in @('summary','priorities','correlations','nextSteps','limitations')) {
        if (-not $analysis.PSObject.Properties[$required]) { throw "Ollama response is missing required property '$required'." }
    }
    return [pscustomobject]@{
        PSTypeName='OmniDiag.OllamaAnalysis'; Model=$Model; Endpoint=$status.Endpoint
        Question=$Question; GeneratedAt=(Get-Date); EvidenceCount=@($findings).Count
        Summary=[string]$analysis.summary; Priorities=@($analysis.priorities)
        Correlations=@($analysis.correlations); NextSteps=@($analysis.nextSteps)
        Limitations=@($analysis.limitations); Usage=[pscustomobject]@{
            PromptTokens=if ($response.PSObject.Properties['prompt_eval_count']) { $response.prompt_eval_count } else { $null }
            OutputTokens=if ($response.PSObject.Properties['eval_count']) { $response.eval_count } else { $null }
            TotalDurationNs=if ($response.PSObject.Properties['total_duration']) { $response.total_duration } else { $null }
        }
    }
}

Export-ModuleMember -Function @('Test-OmniOllama','Invoke-OmniOllamaAnalysis')
