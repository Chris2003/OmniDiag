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

    It 'rejects remote endpoints and cloud model tags' {
        { Test-OmniOllama -Endpoint 'https://example.com' -Transport $script:Transport } | Should -Throw '*loopback*'
        { Test-OmniOllama -Model 'gemma4:cloud' -Transport $script:Transport } | Should -Throw '*Cloud-tag*'
    }

    It 'fails with an actionable pull command when the model is absent' {
        $missing = { param($method,$uri,$body) [pscustomobject]@{ models=@() } }
        { Invoke-OmniOllamaAnalysis -Session $script:Session -Model 'gemma4:e2b' -Transport $missing } | Should -Throw '*ollama pull gemma4:e2b*'
    }
}
