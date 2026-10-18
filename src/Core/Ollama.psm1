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

function New-OmniAssistantConversation {
    <#
    .SYNOPSIS
        Starts a multi-turn, evidence-grounded conversation about a session.

    .DESCRIPTION
        Each turn retrieves the findings and approved runbooks most relevant to the
        question (Search-OmniEvidence), sends them with the prior turns to a local
        Ollama model, and validates every cited finding/runbook ID against the
        evidence that was actually supplied. Advisory only: no tool or repair path.

    .PARAMETER Session
        A live session or one loaded with Import-OmniSession.

    .PARAMETER Runbook
        Approved runbooks the assistant may cite. Defaults to Get-OmniRunbook.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Session,
        [object[]] $Runbook,
        [string] $Model = 'gemma4:e2b',
        [string] $Endpoint = 'http://127.0.0.1:11434',
        [ValidateRange(1, 40)][int] $EvidencePerTurn = 12,
        [ValidateRange(1, 20)][int] $MaxHistoryTurns = 6,
        [scriptblock] $Transport
    )
    $base = Assert-OmniLocalOllamaEndpoint -Endpoint $Endpoint
    if ($Model -match '(^|[:-])cloud($|[:-])') { throw 'Cloud-tag Ollama models are disabled; choose a locally installed model.' }
    if (-not $PSBoundParameters.ContainsKey('Runbook')) { $Runbook = @(Get-OmniRunbook) }
    return [pscustomobject]@{
        PSTypeName      = 'OmniDiag.AssistantConversation'
        Session         = $Session
        Runbooks        = @($Runbook | Where-Object { $_ -and $_.Approved })
        Model           = $Model
        Endpoint        = $base
        EvidencePerTurn = $EvidencePerTurn
        MaxHistoryTurns = $MaxHistoryTurns
        Transport       = $Transport
        Turns           = [System.Collections.Generic.List[object]]::new()
        SeenFindingIds  = [System.Collections.Generic.HashSet[string]]::new()
        SeenRunbookIds  = [System.Collections.Generic.HashSet[string]]::new()
    }
}

function Invoke-OmniAssistantTurn {
    <#
    .SYNOPSIS
        Asks one question in an assistant conversation and returns the cited answer.

    .OUTPUTS
        OmniDiag.AssistantTurn: Answer, FindingIds, RunbookIds, SuggestedQuestions,
        Limitations, RequiresApproval, UnverifiedCitations (IDs the model cited that
        were never supplied - shown to the technician, never trusted).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Conversation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Question
    )
    $c = $Conversation
    $status = Test-OmniOllama -Endpoint $c.Endpoint -Model $c.Model -Transport $c.Transport
    if (-not $status.Available) { throw "Ollama is not available at $($status.Endpoint): $($status.Error)" }
    if (-not $status.ModelPresent) { throw "Model '$($c.Model)' is not installed locally. Run: ollama pull $($c.Model)" }

    # Follow-ups ("what about the second one?") lean on the previous question for retrieval.
    $retrievalQuery = $Question
    if ($c.Turns.Count -gt 0) { $retrievalQuery = "$Question $($c.Turns[$c.Turns.Count - 1].Question)" }
    $hits = @(Search-OmniEvidence -Query $retrievalQuery -Session $c.Session -Runbook $c.Runbooks -Top $c.EvidencePerTurn)
    if (@($hits | Where-Object Type -eq 'Finding').Count -eq 0) {
        # Nothing matched by keyword: fall back to the most severe findings so the model still has grounding.
        $hits += @(Get-OmniSessionFinding -Session $c.Session | Sort-Object @{ Expression = { Get-OmniSeverityRank $_.Severity }; Descending = $true } |
            Select-Object -First ([math]::Min(6, $c.EvidencePerTurn)) | ForEach-Object { [pscustomobject]@{ Type = 'Finding'; Id = $_.Id; Item = $_ } })
    }

    $evidence = [ordered]@{
        healthScore = if ($c.Session.PSObject.Properties['Summary'] -and $c.Session.Summary) { $c.Session.Summary.Score } else { $null }
        findings = @(foreach ($h in $hits | Where-Object Type -eq 'Finding') {
            [void]$c.SeenFindingIds.Add($h.Id)
            [ordered]@{ id = $h.Id; severity = $h.Item.Severity; component = $h.Item.Component; title = $h.Item.Title; likelyCause = $h.Item.LikelyCause; recommendation = $h.Item.Recommendation }
        })
        runbooks = @(foreach ($h in $hits | Where-Object Type -eq 'Runbook') {
            [void]$c.SeenRunbookIds.Add($h.Id)
            $body = [string]$h.Item.Body
            [ordered]@{ id = $h.Id; title = $h.Item.Title; owner = $h.Item.Owner; steps = $(if ($body.Length -gt 1500) { $body.Substring(0, 1500) + '...' } else { $body }) }
        })
    }

    $system = 'You are an evidence-grounded IT troubleshooting assistant in a multi-turn conversation with a technician. Use only OmniDiag evidence and organization-approved runbooks supplied in this conversation. Cite the finding IDs and runbook IDs you rely on. Prefer the approved runbook procedure when one applies. If the evidence does not answer the question, say so. Never claim a repair ran, never invent facts, never request secrets, never recommend bypassing security controls. Set requiresApproval=true when the answer suggests any change to the device.'
    $messages = [System.Collections.Generic.List[object]]::new()
    $messages.Add([ordered]@{ role = 'system'; content = $system })
    $history = @($c.Turns | Select-Object -Last $c.MaxHistoryTurns)
    foreach ($t in $history) {
        $messages.Add([ordered]@{ role = 'user'; content = $t.Question })
        $messages.Add([ordered]@{ role = 'assistant'; content = ([ordered]@{ answer = $t.Answer; findingIds = @($t.FindingIds); runbookIds = @($t.RunbookIds) } | ConvertTo-Json -Depth 4 -Compress) })
    }
    $messages.Add([ordered]@{ role = 'user'; content = "Technician question:`n$Question`n`nEvidence for this turn (JSON):`n$($evidence | ConvertTo-Json -Depth 8 -Compress)" })

    $schema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
            answer = @{ type = 'string' }
            findingIds = @{ type = 'array'; items = @{ type = 'string' } }
            runbookIds = @{ type = 'array'; items = @{ type = 'string' } }
            requiresApproval = @{ type = 'boolean' }
            suggestedQuestions = @{ type = 'array'; items = @{ type = 'string' } }
            limitations = @{ type = 'array'; items = @{ type = 'string' } }
        }
        required = @('answer', 'findingIds', 'runbookIds', 'requiresApproval', 'suggestedQuestions', 'limitations')
    }
    $body = [ordered]@{ model = $c.Model; messages = @($messages); stream = $false; think = $false; format = $schema; keep_alive = '5m'; options = @{ temperature = 0.1; num_predict = 700 } }
    $response = Invoke-OmniOllamaRequest -Method POST -Uri "$($c.Endpoint)/api/chat" -Body $body -Transport $c.Transport
    $content = if ($response.PSObject.Properties['message'] -and $response.message) { [string]$response.message.content } else { $null }
    if (-not $content) { throw 'Ollama returned no answer content.' }
    try { $reply = $content | ConvertFrom-Json -ErrorAction Stop } catch { throw "Ollama returned invalid structured JSON: $($_.Exception.Message)" }
    if (-not $reply.PSObject.Properties['answer']) { throw "Ollama response is missing required property 'answer'." }

    $prop = { param($name) if ($reply.PSObject.Properties[$name]) { @($reply.$name | Where-Object { $_ } | ForEach-Object { [string]$_ }) } else { @() } }
    $citedFindings = & $prop 'findingIds'
    $citedRunbooks = & $prop 'runbookIds'
    $turn = [pscustomobject]@{
        PSTypeName          = 'OmniDiag.AssistantTurn'
        Number              = $c.Turns.Count + 1
        Question            = $Question
        Answer              = [string]$reply.answer
        FindingIds          = @($citedFindings | Where-Object { $c.SeenFindingIds.Contains($_) } | Select-Object -Unique)
        RunbookIds          = @($citedRunbooks | Where-Object { $c.SeenRunbookIds.Contains($_) } | Select-Object -Unique)
        UnverifiedCitations = @(@($citedFindings | Where-Object { -not $c.SeenFindingIds.Contains($_) }) + @($citedRunbooks | Where-Object { -not $c.SeenRunbookIds.Contains($_) }) | Select-Object -Unique)
        RequiresApproval    = [bool]$(if ($reply.PSObject.Properties['requiresApproval']) { $reply.requiresApproval } else { $true })
        SuggestedQuestions  = & $prop 'suggestedQuestions'
        Limitations         = & $prop 'limitations'
        EvidenceIds         = @($hits | ForEach-Object { $_.Id } | Select-Object -Unique)
        GeneratedAt         = Get-Date
    }
    $c.Turns.Add($turn)
    return $turn
}

Export-ModuleMember -Function @('Test-OmniOllama','Invoke-OmniOllamaAnalysis','New-OmniAssistantConversation','Invoke-OmniAssistantTurn')
