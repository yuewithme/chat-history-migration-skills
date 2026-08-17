[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$gitRoot = Join-Path $root '.git'
$skills = @('chatgpt-local-backup', 'doubao-local-backup', 'feishu-local-backup')
$errors = [Collections.Generic.List[string]]::new()

foreach ($skill in $skills) {
    $skillRoot = Join-Path $root $skill
    foreach ($requiredPath in @('SKILL.md', 'README.md', 'agents/openai.yaml', 'scripts', 'references', 'LICENSE', '.gitignore')) {
        if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $requiredPath))) {
            $errors.Add("Missing $skill/$requiredPath")
        }
    }
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        $errors.Add("Missing $skill/SKILL.md")
        continue
    }

    $text = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
    if ($text -notmatch "(?ms)^---\s*\r?\nname:\s*$([regex]::Escape($skill))\s*\r?\ndescription:\s*.+?\r?\n---") {
        $errors.Add("Invalid frontmatter or name mismatch: $skill/SKILL.md")
    }
}

$forbiddenDirectoryNames = @(
    '.git', 'workspace', 'node_modules', 'archive', 'archives', 'data', 'exports',
    'attachments', 'state', 'working', 'final', 'reports', 'logs'
)
Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Where-Object {
    -not $_.FullName.Equals($gitRoot, [StringComparison]::OrdinalIgnoreCase) -and
    -not $_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    if ($forbiddenDirectoryNames -contains $_.Name) {
        $errors.Add("Forbidden directory: $($_.FullName.Substring($root.Length + 1))")
    }
}

$forbiddenFileNames = @('ARCHIVE_MEMORY.md', '.env')
Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object {
    -not $_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    if ($forbiddenFileNames -contains $_.Name -or $_.Name -match '\.(token|cookie|cookies)$') {
        $errors.Add("Forbidden file: $($_.FullName.Substring($root.Length + 1))")
    }
}

$textExtensions = @('.md', '.json', '.yaml', '.yml', '.js', '.ps1', '.txt', '.csv', '.ndjson')
$sensitivePatterns = @(
    @{ Name = 'private workspace path'; Pattern = 'D:\\Codex' },
    @{ Name = 'hardcoded legacy archive root'; Pattern = '(?i)[A-Z]:\\(?:ChatGPT_Backup|Doubao_Backup|Feishu_Backup)(?:\\|`|\s|$)' },
    @{ Name = 'GitHub token'; Pattern = 'gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]+' },
    @{ Name = 'OpenAI-style secret'; Pattern = 'sk-[A-Za-z0-9_-]{20,}' },
    @{ Name = 'persisted bearer credential'; Pattern = '(?i)Authorization\s*:\s*Bearer\s+[A-Za-z0-9._~-]{12,}' }
)

Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object {
    -not $_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
    -not $_.FullName.Equals($PSCommandPath, [StringComparison]::OrdinalIgnoreCase) -and
    $textExtensions -contains $_.Extension.ToLowerInvariant()
} | ForEach-Object {
    $relative = $_.FullName.Substring($root.Length + 1)
    $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    foreach ($entry in $sensitivePatterns) {
        if ($content -match $entry.Pattern) {
            $errors.Add("Potential $($entry.Name): $relative")
        }
    }
}

$parseErrors = $null
Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | ForEach-Object {
    if ($_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    $tokens = $null
    $localErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$localErrors)
    foreach ($error in @($localErrors)) {
        $errors.Add("PowerShell syntax: $($_.FullName.Substring($root.Length + 1)): $($error.Message)")
    }
}

if (Get-Command node -ErrorAction SilentlyContinue) {
    Get-ChildItem -LiteralPath $root -Filter '*.js' -File -Recurse | ForEach-Object {
        if ($_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
        & node --check $_.FullName 2>$null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("JavaScript syntax: $($_.FullName.Substring($root.Length + 1))")
        }
    }
}

if ($errors.Count) {
    $errors | Sort-Object -Unique | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Public release validation failed with $($errors.Count) finding(s)."
}

[ordered]@{
    passed = $true
    skills = $skills
    files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object {
        -not $_.FullName.StartsWith($gitRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    }).Count
    checked_at = (Get-Date).ToString('o')
} | ConvertTo-Json -Depth 4
