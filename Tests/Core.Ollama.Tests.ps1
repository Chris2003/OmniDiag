#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:Finding = New-OmniFinding -Id 'network-dns-failure' -Title 'DNS resolution failed' -Severity Warning -Component 'Network/DNS' -LikelyCause 'Configured resolver is unreachable.' -Recommendation 'Verify DNS configuration.'
    $script:Result = New-OmniResult -ModuleName 'DNS Resolver' -Category Network
    Add-OmniFinding -Result $script:Result -Finding $script:Finding
    Complete-OmniResult -Result $script:Result | Out-Null
    $script:Session = [pscustomobject]@{ Results=@($script:Result); Summary=[pscustomobject]@{ Score=82; Grade='Warning' } }
    $script:Transport = {
        param($method, $uri, $body)
        if ($uri -like '*/api/tags') { return [pscustomobject]@{ models=@([pscustomobject]@{ model='gemma4:e2b' }) } }
        return [pscustomobject]@{
            response = '{"summary":"DNS evidence needs verification.","priorities":[{"title":"Verify DNS","urgency":"high","evidenceIds":["network-dns-failure"]}],"correlations":[],"nextSteps":[{"step":"Inspect configured resolvers.","evidenceIds":["network-dns-failure"],"requiresApproval":false}],"limitations":["No packet capture evidence."]}'
            prompt_eval_count=120; eval_count=45; total_duration=1000
        }
    }
}

Describe 'Local Ollama integration' {
    It 'detects an installed local model' {
        $status = Test-OmniOllama -Model 'gemma4:e2b' -Transport $script:Transport
        $status.Available | Should -BeTrue
        $status.ModelPresent | Should -BeTrue
    }

    It 'returns structured evidence-grounded analysis' {
        $analysis = Invoke-OmniOllamaAnalysis -Session $script:Session -Model 'gemma4:e2b' -Transport $script:Transport
        $analysis.PSTypeNames | Should -Contain 'OmniDiag.OllamaAnalysis'
        $analysis.EvidenceCount | Should -Be 1
        $analysis.Priorities[0].evidenceIds | Should -Contain 'network-dns-failure'
        $analysis.NextSteps[0].requiresApproval | Should -BeFalse
    }

    It 'drops citations to findings that were not supplied' {
        $lying = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            [pscustomobject]@{ response = '{"summary":"s","priorities":[{"title":"t","urgency":"high","evidenceIds":["network-dns-failure","invented-id"]}],"correlations":[],"nextSteps":[],"limitations":[]}' }
        }
        $analysis = Invoke-OmniOllamaAnalysis -Session $script:Session -Model 'gemma4:e2b' -Transport $lying
        $analysis.Priorities[0].evidenceIds | Should -Be @('network-dns-failure')
        $analysis.UnverifiedCitations | Should -Be @('invented-id')
    }

    It 'redacts identity details from finding text sent to the model' {
        $cert = New-OmniFinding -Id 'certificate-expired-abc' -Title 'Expired certificate: CN=Jane Doe, E=jane.doe@contoso.com' -Severity Warning -Component 'Security/Certificates'
        $r = New-OmniResult -ModuleName 'Certificates' -Category Security
        Add-OmniFinding -Result $r -Finding $cert
        Complete-OmniResult -Result $r | Out-Null
        $sent = [System.Collections.Generic.List[object]]::new()
        $capture = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $sent.Add($body.prompt)
            [pscustomobject]@{ response = '{"summary":"s","priorities":[],"correlations":[],"nextSteps":[],"limitations":[]}' }
        }.GetNewClosure()
        Invoke-OmniOllamaAnalysis -Session ([pscustomobject]@{ Results = @($r); Summary = $null }) -Model 'gemma4:e2b' -Transport $capture | Out-Null
        $sent[0] | Should -Not -Match 'jane'
        $sent[0] | Should -Match 'certificate-expired-abc'
    }

    It 'rejects remote endpoints and cloud model tags' {
        { Test-OmniOllama -Endpoint 'https://example.com' -Transport $script:Transport } | Should -Throw '*loopback*'
        { Test-OmniOllama -Model 'gemma4:cloud' -Transport $script:Transport } | Should -Throw '*Cloud-tag*'
    }

    It 'fails with an actionable pull command when the model is absent' {
        $missing = { param($method,$uri,$body) [pscustomobject]@{ models=@() } }
        { Invoke-OmniOllamaAnalysis -Session $script:Session -Model 'gemma4:e2b' -Transport $missing } | Should -Throw '*ollama pull gemma4:e2b*'
    }
}

Describe 'Multi-turn local assistant' {
    BeforeAll {
        $script:Runbook = [pscustomobject]@{ Id = 'rb-dns'; Title = 'DNS resolution failures'; Approved = $true; Owner = 'Net'; AppliesTo = @('network/dns'); Tags = @('dns'); Body = 'Check resolvers.' }
        $script:Requests = [System.Collections.Generic.List[object]]::new()
        $script:ChatTransport = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $script:Requests.Add($body)
            return [pscustomobject]@{ message = [pscustomobject]@{ role = 'assistant'; content = '{"answer":"Follow the DNS runbook.","findingIds":["network-dns-failure","made-up-id"],"runbookIds":["rb-dns"],"requiresApproval":false,"suggestedQuestions":["Which resolvers are configured?"],"limitations":[]}' } }
        }
    }

    It 'grounds each turn in retrieved findings and runbooks and keeps history' {
        $conv = New-OmniAssistantConversation -Session $script:Session -Runbook @($script:Runbook) -Model 'gemma4:e2b' -Transport $script:ChatTransport
        $t1 = Invoke-OmniAssistantTurn -Conversation $conv -Question 'Why is DNS failing?'
        $t1.Answer | Should -Be 'Follow the DNS runbook.'
        $t1.FindingIds | Should -Be @('network-dns-failure')
        $t1.RunbookIds | Should -Be @('rb-dns')
        $t1.UnverifiedCitations | Should -Be @('made-up-id')
        $t1.EvidenceIds | Should -Contain 'rb-dns'
        ,$t1.SuggestedQuestions | Should -BeOfType [object[]]
        ,$t1.Limitations | Should -BeOfType [object[]]

        $t2 = Invoke-OmniAssistantTurn -Conversation $conv -Question 'And what should I check first?'
        $t2.Number | Should -Be 2
        $last = $script:Requests[$script:Requests.Count - 1]
        @($last.messages).Count | Should -Be 4
        $last.messages[1].content | Should -Be 'Why is DNS failing?'
        $last.messages[3].content | Should -Match 'Evidence for this turn'
    }

    It 'ignores unapproved runbooks and rejects remote endpoints' {
        $draft = [pscustomobject]@{ Id = 'rb-x'; Title = 'x'; Approved = $false; AppliesTo = @(); Tags = @(); Body = '' }
        (New-OmniAssistantConversation -Session $script:Session -Runbook @($draft) -Transport $script:ChatTransport).Runbooks.Count | Should -Be 0
        { New-OmniAssistantConversation -Session $script:Session -Endpoint 'http://10.0.0.5:11434' } | Should -Throw '*loopback*'
    }
}

