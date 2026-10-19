#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Documentation consistency:
      - every v1.0 group has a page docs/modules/<group>.md, linked from docs/modules/README.md;
      - every scanner in src/Modules appears (by its Id, in backticks) on its group's page,
        in the Scanners table and in the "Findings it can emit" section's page;
      - every relative link in the root Markdown files and under docs/ resolves to an
        existing file. Screenshots under docs/images/*.png may be missing while
        build/New-Screenshots.ps1 exists (CI renders them; maintainers commit them).
    Runs on every platform (no scanner is executed).
#>

BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $script:GroupCases = @('system', 'performance', 'services', 'startup', 'events', 'reliability',
        'storage', 'network', 'updates', 'security', 'extras') | ForEach-Object { @{ Group = $_ } }

    # Scanner manifests, read from source (Id and Group, in either hashtable layout).
    $script:ScannerCases = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'src/Modules') -Filter '*.psm1' | Sort-Object Name) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $body = [regex]::Match($text, '(?s)function\s+Get-OmniModuleManifest\s*\{.*?\n\}').Value
        $id = [regex]::Match($body, "\bId\s*=\s*'([^']+)'").Groups[1].Value
        $group = [regex]::Match($body, "\bGroup\s*=\s*'([^']+)'").Groups[1].Value
        @{ File = $file.Name; Id = $id; Group = $group }
    }

    # Markdown files whose relative links must resolve.
    $mdFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File) + @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' -File -Recurse)
    $script:LinkCases = foreach ($md in $mdFiles | Sort-Object FullName) {
        $rel = $md.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        @{ File = $rel; FullName = $md.FullName }
    }
}

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ScreenshotScript = Join-Path $script:Root 'build/New-Screenshots.ps1'

    function Get-DocRelativeLink {
        <# Relative link targets in a Markdown file (code blocks and inline code ignored). #>
        param([string] $Path)
        $text = Get-Content -LiteralPath $Path -Raw
        if (-not $text) { return @() }
        $text = [regex]::Replace($text, '(?ms)^\s*(```|~~~).*?^\s*\1[^\r\n]*$', '')
        $text = [regex]::Replace($text, '`[^`\r\n]*`', '')
        $targets = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($text, '\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')) { $targets.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, '(?i)<img\s[^>]*src\s*=\s*"([^"]+)"')) { $targets.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, '(?m)^\s*\[[^\]]+\]:\s*(\S+)')) { $targets.Add($m.Groups[1].Value) }
        $targets | Where-Object { $_ -and $_ -notmatch '^(?i)(https?|mailto|ftp):' -and -not $_.StartsWith('#') } |
            ForEach-Object { ($_ -split '#', 2)[0] } |
            Where-Object { $_ } |
            ForEach-Object { [uri]::UnescapeDataString($_) }
    }
}

Describe 'Module group pages' {
    It 'docs/modules/<Group>.md exists and is linked from docs/modules/README.md' -TestCases $script:GroupCases {
        param($Group)
        Join-Path $script:Root "docs/modules/$Group.md" | Should -Exist
        Get-Content -LiteralPath (Join-Path $script:Root 'docs/modules/README.md') -Raw | Should -Match ([regex]::Escape("($Group.md)"))
    }

    It 'every group page has the Scanners and Findings sections' -TestCases $script:GroupCases {
        param($Group)
        $text = Get-Content -LiteralPath (Join-Path $script:Root "docs/modules/$Group.md") -Raw
        $text | Should -Match '(?m)^## Scanners'
        $text | Should -Match '(?m)^## Findings it can emit'
        $text | Should -Match '(?m)^## Network access'
        $text | Should -Match '(?m)^## Elevation'
    }
}

Describe 'Every scanner is documented on its group page' {
    It '<File> declares an Id and a known group' -TestCases $script:ScannerCases {
        param($File, $Id, $Group)
        $Id | Should -Not -BeNullOrEmpty
        $Group | Should -BeIn @('system', 'performance', 'services', 'startup', 'events', 'reliability', 'storage', 'network', 'updates', 'security', 'extras')
    }

    It '<Id> appears on docs/modules/<Group>.md' -TestCases $script:ScannerCases {
        param($File, $Id, $Group)
        $page = Join-Path $script:Root "docs/modules/$Group.md"
        $page | Should -Exist
        $text = Get-Content -LiteralPath $page -Raw
        $text | Should -Match ([regex]::Escape(('`{0}`' -f $Id)))
    }
}

Describe 'Documentation links resolve' {
    It 'every relative link in <File> points to an existing file' -TestCases $script:LinkCases {
        param($File, $FullName)
        $dir = Split-Path -Parent $FullName
        $missing = foreach ($target in @(Get-DocRelativeLink -Path $FullName)) {
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $dir $target))
            if (Test-Path -LiteralPath $resolved) { continue }
            $relToRoot = $resolved.Substring([System.IO.Path]::GetFullPath($script:Root).Length).TrimStart('\', '/') -replace '\\', '/'
            # Screenshots are rendered by CI (build/New-Screenshots.ps1) and committed afterwards.
            if ($relToRoot -like 'docs/images/*.png' -and (Test-Path -LiteralPath $script:ScreenshotScript)) { continue }
            $target
        }
        @($missing) | Should -BeNullOrEmpty -Because "$File links to files that do not exist"
    }
}
