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
    # No redirects: a 30x from whatever listens on the loopback port must not move evidence off the machine.
    if ($Method -eq 'GET') { return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop }
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    # Send UTF-8 bytes: Windows PowerShell 5.1 encodes a string body as ISO-8859-1.
    return Invoke-RestMethod -Method Post -Uri $Uri -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -TimeoutSec 180 -MaximumRedirection 0 -ErrorAction Stop
}

function Protect-OmniPromptText {
    <#
    .SYNOPSIS
        Internal: minimize identity data in text sent to the model.

    .DESCRIPTION
        Finding titles can embed certificate subjects, e-mail addresses, and the local
        user or computer name. These are replaced with neutral placeholders before the
        text is projected into a prompt. With -Context (a redaction context) the text is
        then redacted like a shared report. Finding IDs are redacted separately
        (Get-OmniPromptFindingId) and mapped back, so citations still resolve against
        the local session.
    #>
    param([string] $Text, [string[]] $Identity = @(), $Context)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text -replace '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>'
    $out = $out -replace '(?i)\b(CN|E|OU|O|DC|UID)=([^,;)]+)', '$1=<redacted>'
    foreach ($name in @($Identity | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending)) {
        $out = $out -replace [regex]::Escape($name), '<host-identity>'
    }
    # The report redaction (docs/REDACTION.md) on top: host, user, and domain names,
    # profile paths, SIDs, and IPv4/IPv6/MAC addresses become stable pseudonyms.
    if ($null -ne $Context) { $out = [string](ConvertTo-OmniRedacted -InputObject $out -Context $Context) }
    return $out
}

function New-OmniPromptRedactionContext {
    <#
    .SYNOPSIS
        Internal: the redaction context for everything sent to the model about a session
        (built from the session and this machine's environment, as Export-OmniReport
        -Redact does).
    #>
    param([pscustomobject] $Session)
    return (New-OmniRedactionContext -Session $Session)
}

function ConvertTo-OmniPromptAutoId {
    <# .SYNOPSIS Internal: the id New-OmniFinding generates from a component and a title. #>
    param([AllowEmptyString()][string] $Component, [AllowEmptyString()][string] $Title)
    # One rule for auto ids: Get-OmniFindingAutoId (Models.psm1) when loaded; the same formula otherwise.
    if (Get-Command -Name Get-OmniFindingAutoId -ErrorAction SilentlyContinue) { return (Get-OmniFindingAutoId -Component $Component -Title $Title) }
    return ((('{0}|{1}' -f $Component, $Title).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Get-OmniPromptFindingId {
    <#
    .SYNOPSIS
        Internal: the finding id as sent to the model; IdMap remembers the original for
        citations.

    .DESCRIPTION
        An id generated from the component and title (New-OmniFinding) holds that text in
        kebab case, where an address or name is no longer delimited (10.1.2.3 reads
        10-1-2-3). Such an id is rebuilt from the redacted component and title - the same
        id the redacted report shows (Redaction.psm1). Any other id is redacted as text.
        An id that was already sent keeps the form it was sent in.
    #>
    param([string] $Id, [string] $Component, [string] $Title, $Context, [System.Collections.IDictionary] $IdMap)
    if ([string]::IsNullOrEmpty($Id)) { return $Id }
    if ($null -ne $IdMap) {
        foreach ($k in @($IdMap.Keys)) { if ([string]$IdMap[$k] -ceq $Id) { return [string]$k } }
    }
    $sent = $Id
    if ($null -ne $Context) {
        if ($PSBoundParameters.ContainsKey('Title') -and $Id -ceq (ConvertTo-OmniPromptAutoId -Component $Component -Title $Title)) {
            $sent = ConvertTo-OmniPromptAutoId -Component ([string](ConvertTo-OmniRedacted -InputObject $Component -Context $Context)) `
                -Title ([string](ConvertTo-OmniRedacted -InputObject $Title -Context $Context))
        } else {
            $sent = [string](ConvertTo-OmniRedacted -InputObject $Id -Context $Context)
        }
    }
    if ($null -ne $IdMap -and -not [string]::IsNullOrEmpty($sent) -and -not $IdMap.Contains($sent)) { $IdMap[$sent] = $Id }
    return $sent
}

function ConvertTo-OmniSafeDisplayText {
    <#
    .SYNOPSIS
        Internal: model output made safe to show in a console or the GUI.

    .DESCRIPTION
        A local model can echo or invent terminal control sequences. This removes ANSI /
        VT escape sequences (CSI, OSC such as window-title or hyperlink sequences, DCS and
        other string controls, and the 8-bit C1 forms), every other C0 / C1 control
        character except TAB and LF, DEL, and the Unicode bidirectional-override and
        invisible formatting characters that can disguise text. CRLF and the Unicode line
        and paragraph separators become LF, so a lone CR cannot overwrite a line.
    #>
    param([AllowNull()] $Text)
    if ($null -eq $Text) { return $null }
    $s = [string]$Text
    if ($s.Length -eq 0) { return $s }
    $s = [regex]::Replace($s, '(?:\x1B\[|\x9B)[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]?', '')
    $s = [regex]::Replace($s, '(?:\x1B[\]PX^_]|[\x90\x98\x9D\x9E\x9F])[\s\S]*?(?:\x07|\x1B\\|\x9C|$)', '')
    $s = [regex]::Replace($s, '\x1B[\s\S]?', '')
    $s = $s.Replace("`r`n", "`n")
    $s = [regex]::Replace($s, '[\u0085\u2028\u2029]', "`n")
    $s = [regex]::Replace($s, '[\x00-\x08\x0B-\x1F\x7F-\x9F\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]', '')
    return $s
}

function ConvertTo-OmniSafeModelOutput {
    <#
    .SYNOPSIS
        Internal: applies ConvertTo-OmniSafeDisplayText to every string in parsed model
        output (objects and arrays from ConvertFrom-Json), in place; returns the value.
    #>
    param([AllowNull()] $Value, [int] $Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (ConvertTo-OmniSafeDisplayText $Value) }
    if ($Depth -gt 16) { return $Value }
    if ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Length; $i++) { $Value[$i] = ConvertTo-OmniSafeModelOutput -Value $Value[$i] -Depth ($Depth + 1) }
        return , $Value
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })) {
            $p.Value = ConvertTo-OmniSafeModelOutput -Value $p.Value -Depth ($Depth + 1)
        }
    }
    return $Value
}

function Get-OmniPromptIdentity {
    <# .SYNOPSIS Internal: user/computer/domain names to redact for a session. #>
    param([pscustomobject] $Session)
    $names = @($env:USERNAME, $env:USER, $env:COMPUTERNAME, $env:USERDOMAIN)
    if ($Session -and $Session.PSObject.Properties['Host'] -and $Session.Host) {
        foreach ($p in @('ComputerName', 'UserName')) {
            if ($Session.Host.PSObject.Properties[$p] -and $Session.Host.$p) { $names += @(([string]$Session.Host.$p) -split '\\') }
        }
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
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
        $models = @($response.models | ForEach-Object { if ($_.model) { ConvertTo-OmniSafeDisplayText ([string]$_.model) } else { ConvertTo-OmniSafeDisplayText ([string]$_.name) } })
        return [pscustomobject]@{ PSTypeName='OmniDiag.OllamaStatus'; Available=$true; Endpoint=$base; Model=$Model; ModelPresent=($models -contains $Model); Models=$models; Error=$null }
    } catch {
        return [pscustomobject]@{ PSTypeName='OmniDiag.OllamaStatus'; Available=$false; Endpoint=$base; Model=$Model; ModelPresent=$false; Models=@(); Error=(ConvertTo-OmniSafeDisplayText $_.Exception.Message) }
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

    $identity = Get-OmniPromptIdentity -Session $Session
    # Everything about the session that reaches the model is redacted (docs/OLLAMA.md).
    $redaction = New-OmniPromptRedactionContext -Session $Session
    $idMap = @{}
    $findings = @(
        foreach ($result in @($Session.Results)) {
            foreach ($finding in @($result.Findings)) {
                if (-not $finding -or $finding.Severity -eq 'Pass') { continue }
                [ordered]@{
                    id = Get-OmniPromptFindingId -Id ([string]$finding.Id) -Component ([string]$finding.Component) -Title ([string]$finding.Title) -Context $redaction -IdMap $idMap
                    severity = [string]$finding.Severity
                    component = Protect-OmniPromptText ([string]$finding.Component) $identity $redaction
                    title = Protect-OmniPromptText ([string]$finding.Title) $identity $redaction
                    likelyCause = Protect-OmniPromptText ([string]$finding.LikelyCause) $identity $redaction
                    recommendation = Protect-OmniPromptText ([string]$finding.Recommendation) $identity $redaction
                }
            }
        }
    ) | Sort-Object @{ Expression={ Get-OmniSeverityRank $_.severity }; Descending=$true } | Select-Object -First $MaxFindings

    $evidence = [ordered]@{
        healthScore = if ($Session.Summary) { $Session.Summary.Score } else { $null }
        grade = if ($Session.Summary) { $Session.Summary.Grade } else { $null }
        scanPlan = if ($Session.PSObject.Properties['ScanPlan'] -and $Session.ScanPlan) { Protect-OmniPromptText ([string]$Session.ScanPlan.Name) $identity $redaction } else { $null }
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
    $prompt = "Technician question:`n$(Protect-OmniPromptText $Question $identity $redaction)`n`nOmniDiag evidence JSON:`n$($evidence | ConvertTo-Json -Depth 8 -Compress)"
    $body = [ordered]@{ model=$Model; system=$system; prompt=$prompt; stream=$false; think=$false; format=$schema; keep_alive='5m'; options=@{ temperature=0.1; num_predict=900 } }
    $response = Invoke-OmniOllamaRequest -Method POST -Uri "$($status.Endpoint)/api/generate" -Body $body -Transport $Transport
    if (-not $response -or -not $response.PSObject.Properties['response'] -or -not $response.response) { throw 'Ollama returned no analysis content.' }
    try { $analysis = $response.response | ConvertFrom-Json -ErrorAction Stop } catch { throw "Ollama returned invalid structured JSON: $(ConvertTo-OmniSafeDisplayText $_.Exception.Message)" }
    if ($analysis -isnot [System.Management.Automation.PSCustomObject]) { throw 'Ollama returned invalid structured JSON: not an object.' }
    # Model output is untrusted text: no terminal control sequences reach the console or GUI.
    $analysis = ConvertTo-OmniSafeModelOutput -Value $analysis
    foreach ($required in @('summary','priorities','correlations','nextSteps','limitations')) {
        if (-not $analysis.PSObject.Properties[$required]) { throw "Ollama response is missing required property '$required'." }
    }
    # Keep only citations to findings that were actually supplied; surface the rest.
    $suppliedIds = @($findings | ForEach-Object { $_.id })
    $unverified = [System.Collections.Generic.List[string]]::new()
    foreach ($section in @('priorities', 'correlations', 'nextSteps')) {
        foreach ($item in @($analysis.$section | Where-Object { $_ })) {
            if (-not $item.PSObject.Properties['evidenceIds']) { continue }
            $ids = @($item.evidenceIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
            foreach ($bad in @($ids | Where-Object { $_ -notin $suppliedIds })) { if (-not $unverified.Contains($bad)) { $unverified.Add($bad) } }
            # Back to the session's own ids (the model saw redacted ones).
            $item.evidenceIds = @($ids | Where-Object { $_ -in $suppliedIds } | ForEach-Object { if ($idMap.Contains($_)) { $idMap[$_] } else { $_ } })
        }
    }
    return [pscustomobject]@{
        PSTypeName='OmniDiag.OllamaAnalysis'; Model=$Model; Endpoint=$status.Endpoint
        Question=$Question; GeneratedAt=(Get-Date); EvidenceCount=@($findings).Count
        Summary=[string]$analysis.summary; Priorities=@($analysis.priorities | Where-Object { $_ })
        Correlations=@($analysis.correlations | Where-Object { $_ }); NextSteps=@($analysis.nextSteps | Where-Object { $_ })
        Limitations=@($analysis.limitations | Where-Object { $_ }); UnverifiedCitations=@($unverified); Usage=[pscustomobject]@{
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
        Identity        = @(Get-OmniPromptIdentity -Session $Session)
        # Redaction of everything sent to the model, and redacted id -> session id.
        RedactionContext = (New-OmniPromptRedactionContext -Session $Session)
        IdMap           = @{}
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
    $redaction = $null
    if ($c.PSObject.Properties['RedactionContext'] -and $c.RedactionContext) { $redaction = $c.RedactionContext } else { $redaction = New-OmniPromptRedactionContext -Session $c.Session }
    $idMap = $null
    if ($c.PSObject.Properties['IdMap'] -and $null -ne $c.IdMap) { $idMap = $c.IdMap } else { $idMap = @{} }
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
            [ordered]@{ id = (Get-OmniPromptFindingId -Id ([string]$h.Id) -Component ([string]$h.Item.Component) -Title ([string]$h.Item.Title) -Context $redaction -IdMap $idMap); severity = $h.Item.Severity
                component = (Protect-OmniPromptText ([string]$h.Item.Component) $c.Identity $redaction)
                title = (Protect-OmniPromptText ([string]$h.Item.Title) $c.Identity $redaction); likelyCause = (Protect-OmniPromptText ([string]$h.Item.LikelyCause) $c.Identity $redaction)
                recommendation = (Protect-OmniPromptText ([string]$h.Item.Recommendation) $c.Identity $redaction) }
        })
        runbooks = @(foreach ($h in $hits | Where-Object Type -eq 'Runbook') {
            [void]$c.SeenRunbookIds.Add($h.Id)
            $body = [string]$h.Item.Body
            if ($body.Length -gt 1500) { $body = $body.Substring(0, 1500) + '...' }
            [ordered]@{ id = $h.Id; title = (Protect-OmniPromptText ([string]$h.Item.Title) $c.Identity $redaction); owner = (Protect-OmniPromptText ([string]$h.Item.Owner) $c.Identity $redaction)
                steps = (Protect-OmniPromptText $body $c.Identity $redaction) }
        })
    }

    $system = 'You are an evidence-grounded IT troubleshooting assistant in a multi-turn conversation with a technician. Use only OmniDiag evidence and organization-approved runbooks supplied in this conversation. Cite the finding IDs and runbook IDs you rely on. Prefer the approved runbook procedure when one applies. If the evidence does not answer the question, say so. Never claim a repair ran, never invent facts, never request secrets, never recommend bypassing security controls. Set requiresApproval=true when the answer suggests any change to the device.'
    $messages = [System.Collections.Generic.List[object]]::new()
    $messages.Add([ordered]@{ role = 'system'; content = $system })
    $history = @($c.Turns | Select-Object -Last $c.MaxHistoryTurns)
    foreach ($t in $history) {
        $messages.Add([ordered]@{ role = 'user'; content = (Protect-OmniPromptText ([string]$t.Question) $c.Identity $redaction) })
        $sentIds = @(foreach ($id in @($t.FindingIds)) { Get-OmniPromptFindingId -Id ([string]$id) -Context $redaction -IdMap $idMap })
        $messages.Add([ordered]@{ role = 'assistant'; content = ([ordered]@{ answer = (Protect-OmniPromptText ([string]$t.Answer) $c.Identity $redaction); findingIds = $sentIds; runbookIds = @($t.RunbookIds) } | ConvertTo-Json -Depth 4 -Compress) })
    }
    $messages.Add([ordered]@{ role = 'user'; content = "Technician question:`n$(Protect-OmniPromptText $Question $c.Identity $redaction)`n`nEvidence for this turn (JSON):`n$($evidence | ConvertTo-Json -Depth 8 -Compress)" })

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
    $content = if ($response -and $response.PSObject.Properties['message'] -and $response.message -and $response.message.PSObject.Properties['content']) { [string]$response.message.content } else { $null }
    if (-not $content) { throw 'Ollama returned no answer content.' }
    try { $reply = $content | ConvertFrom-Json -ErrorAction Stop } catch { throw "Ollama returned invalid structured JSON: $(ConvertTo-OmniSafeDisplayText $_.Exception.Message)" }
    if ($reply -isnot [System.Management.Automation.PSCustomObject]) { throw 'Ollama returned invalid structured JSON: not an object.' }
    # Model output is untrusted text: no terminal control sequences reach the console or GUI.
    $reply = ConvertTo-OmniSafeModelOutput -Value $reply
    if (-not $reply.PSObject.Properties['answer']) { throw "Ollama response is missing required property 'answer'." }

    $prop = { param($name) if ($reply.PSObject.Properties[$name]) { @($reply.$name | Where-Object { $_ } | ForEach-Object { [string]$_ }) } else { @() } }
    # The model saw redacted finding ids: map its citations back to the session's ids.
    $citedFindings = @(foreach ($x in @(& $prop 'findingIds')) { if ($idMap.Contains($x)) { $idMap[$x] } else { $x } })
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
        SuggestedQuestions  = @(& $prop 'suggestedQuestions')
        Limitations         = @(& $prop 'limitations')
        EvidenceIds         = @($hits | ForEach-Object { $_.Id } | Select-Object -Unique)
        GeneratedAt         = Get-Date
    }
    $c.Turns.Add($turn)
    return $turn
}

Export-ModuleMember -Function @('Test-OmniOllama','Invoke-OmniOllamaAnalysis','New-OmniAssistantConversation','Invoke-OmniAssistantTurn')
