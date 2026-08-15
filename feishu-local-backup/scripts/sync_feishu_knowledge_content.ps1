[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [ValidateSet('Knowledge', 'KnowledgeAndBinaries')]
    [string]$ContentMode = 'Knowledge',
    [string]$LarkCliPath,
    [int]$MaxItems = 0,
    [long]$MaxBinaryBytes = 104857600,
    [switch]$DownloadUnknownSize,
    [switch]$SkipFinalize
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
$script:RunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$script:RunRoot = Join-Path $script:Root "_meta\runs\$($script:RunId)"
$script:Gaps = [System.Collections.Generic.List[object]]::new()
$script:ExcludedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

if ($script:Root -match '^[A-Za-z]:\\?$') { throw "Refusing drive root as archive: $script:Root" }
if ($MaxItems -lt 0) { throw 'MaxItems cannot be negative.' }
if ($MaxBinaryBytes -lt 0) { throw 'MaxBinaryBytes cannot be negative.' }

function New-Directory([string]$Path) { [System.IO.Directory]::CreateDirectory($Path) | Out-Null }
function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-Directory $parent }
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}
function Write-Json([string]$Path, [object]$Value, [int]$Depth = 60) { Write-Utf8 $Path ($Value | ConvertTo-Json -Depth $Depth) }
function Write-Ndjson([string]$Path, [object[]]$Rows) {
    $lines = foreach ($row in $Rows) { $row | ConvertTo-Json -Depth 60 -Compress }
    Write-Utf8 $Path $(if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' })
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}
function Read-Ndjson([string]$Path) {
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        $rows.Add(($line | ConvertFrom-Json))
    }
    return @($rows)
}
function Safe-Name([string]$Name, [int]$MaxLength = 80) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'untitled' }
    $value = $Name.Normalize([System.Text.NormalizationForm]::FormKC)
    $value = [regex]::Replace($value, '[\\/:*?""<>|\x00-\x1F]', '_')
    $value = [regex]::Replace($value, '\s+', ' ').Trim().TrimEnd('.')
    if ($value.Length -gt $MaxLength) { $value = $value.Substring(0, $MaxLength).Trim() }
    if (-not $value) { return 'untitled' }
    return $value
}
function Relative-Path([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($script:Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes archive: $full" }
    return ($full.Substring($script:Root.Length + 1) -replace '\\', '/')
}
function Set-Field([object]$Object, [string]$Name, [object]$Value) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Refresh-Exclusions {
    $script:ExcludedIds.Clear()
    foreach ($relative in @('_meta\policies\personal_data_exclusions.ndjson','_meta\policies\excluded_documents.ndjson','_meta\policies\excluded_resources.ndjson','_meta\policies\excluded_files.ndjson')) {
        $path = Join-Path $script:Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if (-not $line.Trim()) { continue }
            try {
                $row = $line | ConvertFrom-Json
                if ($row.prevent_future_download -ne $true -and [string]$row.action -ne 'exclude' -and [string]$row.status -ne 'excluded') { continue }
                foreach ($name in @('stable_id','resource_id','obj_token','file_token','token','resource_token','wiki_token')) {
                    if ($row.PSObject.Properties[$name] -and [string]$row.$name) { [void]$script:ExcludedIds.Add([string]$row.$name) }
                }
            }
            catch { }
        }
    }
    $deleted = Read-Json (Join-Path $script:Root '_meta\deleted_attachments.json')
    $deletedRows = if ($deleted -and $deleted.PSObject.Properties['deleted_attachments']) { @($deleted.deleted_attachments) } else { @($deleted) }
    foreach ($row in $deletedRows) {
        if ($null -eq $row -or $row.prevent_future_download -ne $true) { continue }
        foreach ($name in @('stable_id','resource_id','resource_key','file_token','token')) {
            if ($row.PSObject.Properties[$name] -and [string]$row.$name) { [void]$script:ExcludedIds.Add([string]$row.$name) }
        }
    }
}
function Is-Excluded([object]$Record) {
    return $script:ExcludedIds.Contains([string]$Record.resource_id) -or $script:ExcludedIds.Contains([string]$Record.obj_token) -or $script:ExcludedIds.Contains([string]$Record.wiki_token)
}

if (-not $LarkCliPath) { $LarkCliPath = (Get-Command 'lark-cli' -ErrorAction Stop).Source }
$LarkCliPath = [System.IO.Path]::GetFullPath($LarkCliPath)
if (-not (Test-Path -LiteralPath $LarkCliPath -PathType Leaf)) { throw "lark-cli is missing: $LarkCliPath" }

function Invoke-Lark([string[]]$Arguments) {
    $stderrPath = Join-Path $env:TEMP ("lark-content-err-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        Push-Location $script:Root
        try {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if ([System.IO.Path]::GetExtension($LarkCliPath) -ieq '.ps1') {
                    $effectiveArguments = @($Arguments)
                    for ($i = 0; $i -lt $effectiveArguments.Count; $i++) {
                        if ($i -gt 0 -and $effectiveArguments[$i - 1] -in @('--params','--data') -and $effectiveArguments[$i] -match '^\s*[\[{]') {
                            $effectiveArguments[$i] = $effectiveArguments[$i].Replace('"','\"')
                        }
                    }
                    $output = @(& $LarkCliPath @effectiveArguments 2> $stderrPath)
                }
                else { $output = @(& $LarkCliPath @Arguments 2> $stderrPath) }
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $oldPreference }
        }
        finally { Pop-Location }
        $stdout = ($output -join [Environment]::NewLine)
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Encoding UTF8 -Raw } else { '' }
        $json = $null
        $errorJson = $null
        if ($stdout -and $stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json } catch { } }
        if ($stderr -and $stderr.Trim()) { try { $errorJson = $stderr | ConvertFrom-Json } catch { } }
        return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; ErrorJson = $errorJson; Stdout = $stdout; Stderr = $stderr }
    }
    finally { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
}
function Get-ErrorText([object]$Result, [string]$Fallback) {
    if ($Result.ErrorJson -and $Result.ErrorJson.error -and $Result.ErrorJson.error.message) { return [string]$Result.ErrorJson.error.message }
    if ($Result.Json -and $Result.Json.error -and $Result.Json.error.message) { return [string]$Result.Json.error.message }
    if ($Result.Stderr -and $Result.Stderr.Trim()) { return $Result.Stderr.Trim() }
    return $Fallback
}
function Add-Gap([object]$Record, [string]$Stage, [string]$Reason, [bool]$Retryable = $true) {
    $script:Gaps.Add([pscustomobject][ordered]@{
        domain = [string]$Record.source_domain; stage = $Stage; resource_id = [string]$Record.resource_id
        reason = $Reason; status = 'sync_failed'; retryable = $Retryable
        first_seen_at = (Get-Date).ToString('o'); last_attempt_at = (Get-Date).ToString('o'); resolved_at = $null
    })
    Set-Field $Record 'content_status' 'gap'
}
function Save-ResultMetadata([object]$Record, [string]$Kind, [object]$Value) {
    $domain = [string]$Record.source_domain
    $name = "$(Safe-Name ([string]$Record.title))--$([string]$Record.obj_token).$Kind.json"
    $path = Join-Path $script:Root "$domain\metadata\$name"
    Write-Json $path $Value 60
    Set-Field $Record 'metadata_path' (Relative-Path $path)
    return $path
}

function Convert-MindnoteMarkdown([object[]]$Nodes, [string]$Title) {
    $byParent = @{}
    foreach ($node in $Nodes) {
        $parent = [string]$node.parent_id
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$parent].Add($node)
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# $Title")
    $lines.Add('')
    function Add-Children([string]$ParentId, [int]$Depth) {
        if (-not $byParent.ContainsKey($ParentId)) { return }
        foreach ($node in $byParent[$ParentId]) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($element in @($node.texts)) {
                if ($element.text -and $element.text.content) { $parts.Add([string]$element.text.content) }
            }
            foreach ($element in @($node.notes)) {
                if ($element.text -and $element.text.content) { $parts.Add([string]$element.text.content) }
            }
            $text = ($parts -join ' ').Trim()
            if (-not $text) { $text = '[empty node]' }
            $lines.Add((('  ' * $Depth) + '- ' + $text))
            Add-Children ([string]$node.node_id) ($Depth + 1)
        }
    }
    Add-Children '' 0
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Export-Native([object]$Record, [string]$Extension) {
    $domain = [string]$Record.source_domain
    $token = [string]$Record.obj_token
    $relativeDir = "./$domain/structured"
    $fileName = "$token.$Extension"
    $args = @('drive','+export','--as','user','--token',$token,'--doc-type',[string]$Record.resource_type,'--file-extension',$Extension,'--file-name',$fileName,'--output-dir',$relativeDir,'--overwrite','--format','json')
    $result = Invoke-Lark $args
    if ($result.ExitCode -ne 0 -or -not $result.Json.ok) {
        Add-Gap $Record "export_$Extension" (Get-ErrorText $result "Could not export $Extension.")
        return
    }
    $path = Join-Path $script:Root "$domain\structured\$fileName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Gap $Record "export_$Extension" 'CLI reported success but the expected export file is missing.'
        return
    }
    Set-Field $Record 'knowledge_path' (Relative-Path $path)
    Set-Field $Record 'content_status' 'exported'
    Save-ResultMetadata $Record "export-$Extension" ([ordered]@{
        resource_id = $Record.resource_id; obj_token = $token; resource_type = $Record.resource_type
        title = $Record.title; logical_path = $Record.logical_path; source_url = $Record.source_url
        exported_at = (Get-Date).ToString('o'); artifact_path = Relative-Path $path; cli_result = $result.Json.data
    }) | Out-Null
}

function Fetch-Document([object]$Record) {
    $token = [string]$Record.obj_token
    $result = Invoke-Lark @('docs','+fetch','--as','user','--doc',$token,'--doc-format','markdown','--detail','simple','--format','json')
    if ($result.ExitCode -ne 0 -or -not $result.Json.ok -or -not $result.Json.data.document) {
        Add-Gap $Record 'document_fetch' (Get-ErrorText $result 'Could not fetch document Markdown.')
        return
    }
    $markdown = [string]$result.Json.data.document.content
    if ([string]::IsNullOrWhiteSpace($markdown)) {
        Add-Gap $Record 'document_fetch' 'Document response contained no Markdown body.'
        return
    }
    $domain = [string]$Record.source_domain
    $path = Join-Path $script:Root "$domain\documents\$(Safe-Name ([string]$Record.title))--$token.md"
    Write-Utf8 $path $markdown
    Set-Field $Record 'knowledge_path' (Relative-Path $path)
    Set-Field $Record 'content_status' 'markdown'
    Save-ResultMetadata $Record 'document' ([ordered]@{
        resource_id = $Record.resource_id; obj_token = $token; wiki_token = $Record.wiki_token
        resource_type = $Record.resource_type; title = $Record.title; logical_path = $Record.logical_path
        source_url = $Record.source_url; fetched_at = (Get-Date).ToString('o')
        revision_id = $result.Json.data.document.revision_id; reference_map = $result.Json.data.document.reference_map
        tips = $result.Json.data.document.tips; markdown_path = Relative-Path $path
    }) | Out-Null
}

function Fetch-Mindnote([object]$Record) {
    $token = [string]$Record.obj_token
    $result = Invoke-Lark @('mindnotes','nodes','list','--as','user','--mindnote-id',$token,'--format','json')
    if ($result.ExitCode -ne 0 -or -not $result.Json.ok) {
        Add-Gap $Record 'mindnote_fetch' (Get-ErrorText $result 'Could not fetch mindnote nodes.')
        return
    }
    $domain = [string]$Record.source_domain
    $jsonPath = Join-Path $script:Root "$domain\structured\mindnote--$token.json"
    Write-Json $jsonPath ([ordered]@{
        resource_id = $Record.resource_id; obj_token = $token; title = $Record.title
        logical_path = $Record.logical_path; fetched_at = (Get-Date).ToString('o'); nodes = @($result.Json.data.nodes)
    }) 60
    $markdownPath = Join-Path $script:Root "$domain\documents\$(Safe-Name ([string]$Record.title))--$token.md"
    Write-Utf8 $markdownPath (Convert-MindnoteMarkdown @($result.Json.data.nodes) ([string]$Record.title))
    Set-Field $Record 'metadata_path' (Relative-Path $jsonPath)
    Set-Field $Record 'knowledge_path' (Relative-Path $markdownPath)
    Set-Field $Record 'content_status' 'structured_json_and_markdown'
}

function Download-File([object]$Record) {
    if ($ContentMode -ne 'KnowledgeAndBinaries') { Set-Field $Record 'content_status' 'metadata_only'; return }
    Refresh-Exclusions
    if (Is-Excluded $Record) { Set-Field $Record 'policy_status' 'excluded'; Set-Field $Record 'content_status' 'excluded'; return }
    $size = 0L
    $hasSize = [long]::TryParse([string]$Record.size, [ref]$size)
    if ((-not $hasSize -or $size -le 0) -and -not $DownloadUnknownSize) { Set-Field $Record 'content_status' 'review_unknown_size'; return }
    if ($hasSize -and $size -gt $MaxBinaryBytes) { Set-Field $Record 'content_status' 'review_size_limit'; return }
    $domain = [string]$Record.source_domain
    $fileName = "$([string]$Record.obj_token)--$(Safe-Name ([string]$Record.title) 120)"
    $relative = "./$domain/files/$fileName"
    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('drive','+download','--as','user')) { $args.Add([string]$arg) }
    if ($domain -eq 'wiki' -and [string]$Record.wiki_token) { $args.Add('--wiki-token'); $args.Add([string]$Record.wiki_token) }
    else { $args.Add('--file-token'); $args.Add([string]$Record.obj_token) }
    foreach ($arg in @('--output',$relative,'--overwrite','--format','json')) { $args.Add([string]$arg) }
    $result = Invoke-Lark $args.ToArray()
    if ($result.ExitCode -ne 0 -or -not $result.Json.ok) {
        Add-Gap $Record 'file_download' (Get-ErrorText $result 'Could not download file.')
        return
    }
    $path = Join-Path $script:Root ($relative.Substring(2) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Gap $Record 'file_download' 'CLI reported success but the expected file is missing.'; return }
    Set-Field $Record 'binary_path' (Relative-Path $path)
    Set-Field $Record 'content_status' 'downloaded'
}

New-Directory $script:RunRoot
Refresh-Exclusions
$records = [System.Collections.Generic.List[object]]::new()
foreach ($domain in @('drive','wiki')) {
    foreach ($row in @(Read-Ndjson (Join-Path $script:Root "$domain\index.ndjson"))) { $records.Add($row) }
}
if (-not $records.Count) { throw 'No Drive/Wiki inventory exists. Run sync_feishu_knowledge.ps1 first.' }

$processed = 0
foreach ($record in $records) {
    if ($MaxItems -gt 0 -and $processed -ge $MaxItems) { break }
    if ([string]$record.policy_status -eq 'excluded' -or (Is-Excluded $record)) { Set-Field $record 'policy_status' 'excluded'; Set-Field $record 'content_status' 'excluded'; continue }
    $type = ([string]$record.resource_type).ToLowerInvariant()
    switch ($type) {
        { $_ -in @('doc','docx') } { Fetch-Document $record; break }
        'sheet' { Export-Native $record 'xlsx'; break }
        'bitable' { Export-Native $record 'base'; break }
        'base' { Set-Field $record 'resource_type' 'bitable'; Export-Native $record 'base'; break }
        'slides' { Export-Native $record 'pptx'; break }
        'mindnote' { Fetch-Mindnote $record; break }
        'file' { Download-File $record; break }
        'folder' { Set-Field $record 'content_status' 'inventory_only'; break }
        'shortcut' { Set-Field $record 'content_status' 'inventory_only'; break }
        default { Set-Field $record 'content_status' 'metadata_only' }
    }
    $processed++
}

Write-Ndjson (Join-Path $script:Root 'drive\index.ndjson') @($records | Where-Object source_domain -eq 'drive')
Write-Ndjson (Join-Path $script:Root 'wiki\index.ndjson') @($records | Where-Object source_domain -eq 'wiki')

$unified = [System.Collections.Generic.List[object]]::new()
$inventoryPath = Join-Path $script:Root '_meta\inventory.ndjson'
foreach ($row in @(Read-Ndjson $inventoryPath)) {
    if ([string]$row.source_domain -notin @('drive','wiki')) { $unified.Add($row) }
}
foreach ($record in $records) { $unified.Add($record) }
Write-Ndjson $inventoryPath @($unified)

if ($script:Gaps.Count) {
    $gapPath = Join-Path $script:Root '_meta\gaps.json'
    $existing = Read-Json $gapPath
    $rows = [System.Collections.Generic.List[object]]::new()
    $existingRows = if ($existing -and $existing.PSObject.Properties['gaps']) { @($existing.gaps) } else { @($existing) }
    foreach ($row in $existingRows) { if ($null -ne $row) { $rows.Add($row) } }
    foreach ($gap in $script:Gaps) { $rows.Add($gap) }
    Write-Json $gapPath @($rows) 60
}

$summary = [ordered]@{
    schema = 'feishu-knowledge-content-summary-v1'; run_id = $script:RunId; content_mode = $ContentMode
    status = if ($script:Gaps.Count) { 'complete_with_gaps' } else { 'complete' }
    completed_at = (Get-Date).ToString('o'); discovered = $records.Count; processed = $processed
    markdown = @($records | Where-Object content_status -in @('markdown','structured_json_and_markdown')).Count
    structured_exports = @($records | Where-Object content_status -eq 'exported').Count
    binaries_downloaded = @($records | Where-Object content_status -eq 'downloaded').Count
    metadata_only = @($records | Where-Object content_status -match '^(metadata_only|inventory_only|review_)').Count
    excluded = @($records | Where-Object content_status -eq 'excluded').Count; gaps = $script:Gaps.Count
}
Write-Json (Join-Path $script:RunRoot 'run.json') $summary
Write-Json (Join-Path $script:Root '_meta\state\knowledge_content_latest.json') $summary

$completenessPath = Join-Path $script:Root '_meta\completeness.json'
$completeness = Read-Json $completenessPath
if (-not $completeness) { $completeness = [pscustomobject]@{} }
$completeness | Add-Member -NotePropertyName knowledge -NotePropertyValue $summary -Force
Write-Json $completenessPath $completeness

if (-not $SkipFinalize) {
    $validation = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action ValidateJson -ArchiveRoot $script:Root | ConvertFrom-Json
    if (-not $validation.valid) { throw 'Knowledge content JSON validation failed.' }
    & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $script:Root | Out-Null
    $verify = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $script:Root -FullHash | ConvertFrom-Json
    if (-not $verify.valid -or -not $verify.cardinality_ok) { throw 'Knowledge content checksum verification failed.' }
    $summary['validation'] = $validation
    $summary['verify'] = $verify
}

$summary | ConvertTo-Json -Depth 50
