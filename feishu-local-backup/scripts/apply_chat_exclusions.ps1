[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [string]$ExclusionsPath,
    [switch]$ConfirmPurge
)

$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if ($directory) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Relative-Path([string]$Path) {
    return ($Path.Substring($script:ResolvedArchiveRoot.Length + 1) -replace '\\', '/')
}

function Assert-InArchive([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $prefix = $script:ResolvedArchiveRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing filesystem operation outside archive root: $resolved"
    }
    return $resolved
}

function Write-Ndjson([string]$Path, [object[]]$Rows) {
    $lines = foreach ($row in $Rows) { $row | ConvertTo-Json -Compress -Depth 30 }
    $text = if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-Utf8NoBom $Path $text
}

$script:ResolvedArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $script:ResolvedArchiveRoot -PathType Container)) { throw "Archive root is missing: $script:ResolvedArchiveRoot" }
if (-not $ExclusionsPath) {
    $archiveExclusions = Join-Path $script:ResolvedArchiveRoot '_meta\exclusions.json'
    $legacy = if (Test-Path -LiteralPath $archiveExclusions -PathType Leaf) { Get-Content -LiteralPath $archiveExclusions -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $accountKey = if ($legacy -and $legacy.account_scope.open_id) { [string]$legacy.account_scope.open_id } else { $null }
    if (-not $accountKey) {
        $manifestPath = Join-Path $script:ResolvedArchiveRoot '_meta\manifest.json'
        $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        if ($manifest -and $manifest.identity.open_id) { $accountKey = [string]$manifest.identity.open_id }
    }
    if (-not $accountKey) {
        $accountRoots = @(Get-ChildItem -LiteralPath (Join-Path $script:ResolvedArchiveRoot '_meta\policies\accounts') -Directory -ErrorAction SilentlyContinue)
        if ($accountRoots.Count -eq 1) { $accountKey = $accountRoots[0].Name }
        elseif ($accountRoots.Count -gt 1) { throw 'Multiple account policy directories exist; provide -ExclusionsPath explicitly.' }
    }
    $accountExclusions = if ($accountKey) { Join-Path $script:ResolvedArchiveRoot "_meta\policies\accounts\$accountKey\chat_exclusions.json" } else { $null }
    $ExclusionsPath = if ($accountExclusions -and (Test-Path -LiteralPath $accountExclusions -PathType Leaf)) { $accountExclusions } elseif ($legacy) { $archiveExclusions } else { Join-Path $PSScriptRoot '../references/exclusions.json' }
}
if (-not (Test-Path -LiteralPath $ExclusionsPath -PathType Leaf)) { throw "Exclusions file is missing: $ExclusionsPath" }

$config = Get-Content -LiteralPath $ExclusionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$exclusions = @()
foreach ($policy in @($config.chat_exclusions)) {
    if ([string]$policy.disposition -eq 'purge' -and (@($policy.scope) -contains 'messages')) { $exclusions += $policy }
}
if (-not $exclusions.Count) { throw 'Exclusions list is empty.' }
$excludedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $exclusions) {
    $id = [string]$entry.chat_id
    if ($id -notmatch '^oc_[0-9a-f]+$') { throw "Invalid chat_id in exclusions: $id" }
    if (-not $excludedIds.Add($id)) { throw "Duplicate chat_id in exclusions: $id" }
}

$chatList = Get-Content -LiteralPath (Join-Path $script:ResolvedArchiveRoot 'chats/raw/_chat_list.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$visibleMap = @{}
foreach ($chat in @($chatList.data.chats)) { $visibleMap[[string]$chat.chat_id] = $chat }
foreach ($entry in $exclusions) {
    if (-not $visibleMap.ContainsKey([string]$entry.chat_id)) { throw "Excluded chat is not present in the visible chat catalog: $($entry.chat_id)" }
    if ([string]$visibleMap[[string]$entry.chat_id].chat_mode -ne 'group') { throw "Excluded chat is not a group: $($entry.chat_id)" }
}

$checksumMap = @{}
$checksumPath = Join-Path $script:ResolvedArchiveRoot '_meta/checksums.sha256'
if (Test-Path -LiteralPath $checksumPath) {
    foreach ($line in (Get-Content -LiteralPath $checksumPath -Encoding UTF8)) {
        if ($line -match '^([0-9a-fA-F]{64})  (.+)$') { $checksumMap[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
}

$targetFiles = [System.Collections.Generic.List[object]]::new()
$targetDirectories = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $exclusions) {
    $id = [string]$entry.chat_id
    foreach ($directoryName in @('chats/raw', 'chats/members')) {
        $directory = Join-Path $script:ResolvedArchiveRoot $directoryName
        foreach ($file in (Get-ChildItem -LiteralPath $directory -File -Filter "*--$id.json" -ErrorAction SilentlyContinue)) {
            $relative = Relative-Path $file.FullName
            $hash = if ($checksumMap.ContainsKey($relative)) { $checksumMap[$relative] } else { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $targetFiles.Add([pscustomobject]@{ chat_id = $id; path = $relative; bytes = [long]$file.Length; sha256 = $hash })
        }
    }
    $attachmentDirectory = Assert-InArchive (Join-Path $script:ResolvedArchiveRoot "chats/attachments/$id")
    if (Test-Path -LiteralPath $attachmentDirectory -PathType Container) {
        $targetDirectories.Add($attachmentDirectory)
        foreach ($file in (Get-ChildItem -LiteralPath $attachmentDirectory -File -Recurse)) {
            $relative = Relative-Path $file.FullName
            $hash = if ($checksumMap.ContainsKey($relative)) { $checksumMap[$relative] } else { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $targetFiles.Add([pscustomobject]@{ chat_id = $id; path = $relative; bytes = [long]$file.Length; sha256 = $hash })
        }
    }
}

$preview = [ordered]@{
    action = if ($ConfirmPurge) { 'purge' } else { 'preview' }
    archive_root = $script:ResolvedArchiveRoot
    excluded_groups = $exclusions.Count
    files = $targetFiles.Count
    bytes = [long](($targetFiles | Measure-Object -Property bytes -Sum).Sum)
    groups = foreach ($entry in $exclusions) {
        $groupFiles = @($targetFiles | Where-Object chat_id -eq ([string]$entry.chat_id))
        [ordered]@{
            chat_id = [string]$entry.chat_id
            title = [string]$entry.title
            files = $groupFiles.Count
            bytes = [long](($groupFiles | Measure-Object -Property bytes -Sum).Sum)
        }
    }
}
if (-not $ConfirmPurge) { $preview | ConvertTo-Json -Depth 10; exit 0 }

$runId = (Get-Date).ToString('yyyyMMddTHHmmsszzz') -replace ':', ''
$runRoot = Assert-InArchive (Join-Path $script:ResolvedArchiveRoot "_meta/runs/$runId")
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
$deletionManifest = [ordered]@{
    schema = 'feishu-local-backup-deletion-v1'
    run_id = $runId
    created_at = (Get-Date).ToString('o')
    reason = 'Explicit user request to remove and permanently exclude selected group chat content.'
    recoverability = 'Deleted local files are not retained. Re-download is possible only if Feishu still exposes the resources.'
    summary = $preview
    files = $targetFiles
}
Write-Utf8NoBom (Join-Path $runRoot 'deletion_manifest.json') ($deletionManifest | ConvertTo-Json -Depth 15)

foreach ($file in $targetFiles) {
    $fullPath = Assert-InArchive (Join-Path $script:ResolvedArchiveRoot ($file.path -replace '/', '\\'))
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) { Remove-Item -LiteralPath $fullPath -Force }
}
foreach ($directory in $targetDirectories) {
    $validated = Assert-InArchive $directory
    if (Test-Path -LiteralPath $validated -PathType Container) { Remove-Item -LiteralPath $validated -Recurse -Force }
}

$archiveExclusions = [ordered]@{
    schema = [string]$config.schema
    applied_at = (Get-Date).ToString('o')
    source = 'feishu-local-backup/references/exclusions.json'
    chat_exclusions = $exclusions
}
Write-Utf8NoBom (Join-Path $script:ResolvedArchiveRoot '_meta/exclusions.json') ($archiveExclusions | ConvertTo-Json -Depth 15)

$chatIndexPath = Join-Path $script:ResolvedArchiveRoot 'chats/chat_index.csv'
$chatIndex = @(Import-Csv -LiteralPath $chatIndexPath | Where-Object { -not $excludedIds.Contains([string]$_.resource_id) })
$chatIndex | Export-Csv -LiteralPath $chatIndexPath -NoTypeInformation -Encoding UTF8

$stageInventoryPath = Join-Path $script:ResolvedArchiveRoot '_meta/state/chat_inventory.ndjson'
if (Test-Path -LiteralPath $stageInventoryPath) {
    $rows = @(Get-Content -LiteralPath $stageInventoryPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { -not $excludedIds.Contains([string]$_.resource_id) })
    Write-Ndjson $stageInventoryPath $rows
}

$inventoryPath = Join-Path $script:ResolvedArchiveRoot '_meta/inventory.ndjson'
if (Test-Path -LiteralPath $inventoryPath) {
    $rows = @(Get-Content -LiteralPath $inventoryPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { -not $excludedIds.Contains([string]$_.resource_id) })
    Write-Ndjson $inventoryPath $rows
}

$relationshipsPath = Join-Path $script:ResolvedArchiveRoot '_meta/relationships.ndjson'
if (Test-Path -LiteralPath $relationshipsPath) {
    $remainingLines = foreach ($line in (Get-Content -LiteralPath $relationshipsPath -Encoding UTF8)) {
        $keep = $true
        foreach ($id in $excludedIds) { if ($line.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $keep = $false; break } }
        if ($keep -and $line.Trim()) { $line }
    }
    $relationshipText = if (@($remainingLines).Count) { ($remainingLines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-Utf8NoBom $relationshipsPath $relationshipText
}

$gapsPath = Join-Path $script:ResolvedArchiveRoot '_meta/gaps.json'
if (Test-Path -LiteralPath $gapsPath) {
    $gapJson = Get-Content -LiteralPath $gapsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $gaps = @($gapJson | Where-Object { -not $excludedIds.Contains([string]$_.resource_id) })
    Write-Utf8NoBom $gapsPath ($gaps | ConvertTo-Json -Depth 15)
    $gaps | Export-Csv -LiteralPath (Join-Path $script:ResolvedArchiveRoot '_meta/gaps.csv') -NoTypeInformation -Encoding UTF8
}

$groupIndexPath = Join-Path $script:ResolvedArchiveRoot 'chats/by_type/group/index.json'
$chatIndexMap = @{}
foreach ($row in $chatIndex) { $chatIndexMap[[string]$row.resource_id] = $row }
$groupIndexList = [System.Collections.Generic.List[object]]::new()
foreach ($chat in @($chatList.data.chats)) {
    $chatId = [string]$chat.chat_id
    if ([string]$chat.chat_mode -ne 'group' -or $excludedIds.Contains($chatId)) { continue }
    $index = $chatIndexMap[$chatId]
    if (-not $index) { continue }
    $attachmentRoot = Join-Path $script:ResolvedArchiveRoot "chats/attachments/$chatId"
    $attachments = if (Test-Path -LiteralPath $attachmentRoot) { @(Get-ChildItem -LiteralPath $attachmentRoot -File -Recurse) } else { @() }
    $rawFullPath = Join-Path $script:ResolvedArchiveRoot ([string]$index.raw_path -replace '/', '\\')
    $memberFile = Get-ChildItem -LiteralPath (Join-Path $script:ResolvedArchiveRoot 'chats/members') -File -Filter "*--$chatId.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    $groupIndexList.Add([pscustomobject]@{
        chat_id = $chatId
        chat_mode = 'group'
        title = [string]$chat.name
        status = [string]$chat.chat_status
        external = [bool]$chat.external
        tenant_key = [string]$chat.tenant_key
        owner_id = [string]$chat.owner_id
        message_count = if ($index.message_count -ne '') { [int]$index.message_count } else { 0 }
        complete = [System.Convert]::ToBoolean($index.complete)
        raw_json_path = [string]$index.raw_path
        raw_json_bytes = if (Test-Path -LiteralPath $rawFullPath) { [long](Get-Item -LiteralPath $rawFullPath).Length } else { 0L }
        members_json_path = if ($memberFile) { Relative-Path $memberFile.FullName } else { $null }
        attachment_root = "chats/attachments/$chatId"
        attachment_files = $attachments.Count
        attachment_bytes = [long](($attachments | Measure-Object -Property Length -Sum).Sum)
    })
}
$groupIndex = @($groupIndexList | Sort-Object title, chat_id)
Write-Utf8NoBom $groupIndexPath ($groupIndex | ConvertTo-Json -Depth 15)
$groupIndex | Export-Csv -LiteralPath (Join-Path $script:ResolvedArchiveRoot 'chats/by_type/group/index.csv') -NoTypeInformation -Encoding UTF8

$groupSummary = [ordered]@{
    chat_mode = 'group'
    meaning = 'multi-member group conversation'
    visible_chats = @($chatList.data.chats | Where-Object chat_mode -eq 'group').Count
    excluded_chats = @($exclusions).Count
    chats = $groupIndex.Count
    complete_chats = @($groupIndex | Where-Object complete).Count
    incomplete_chats = @($groupIndex | Where-Object { -not $_.complete }).Count
    messages = [long](($groupIndex | Measure-Object -Property message_count -Sum).Sum)
    attachment_files = [long](($groupIndex | Measure-Object -Property attachment_files -Sum).Sum)
    attachment_bytes = [long](($groupIndex | Measure-Object -Property attachment_bytes -Sum).Sum)
    raw_json_bytes = [long](($groupIndex | Measure-Object -Property raw_json_bytes -Sum).Sum)
    index_json = 'chats/by_type/group/index.json'
    index_csv = 'chats/by_type/group/index.csv'
}
Write-Utf8NoBom (Join-Path $script:ResolvedArchiveRoot 'chats/by_type/group/summary.json') ($groupSummary | ConvertTo-Json -Depth 15)

$p2pSummary = Get-Content -LiteralPath (Join-Path $script:ResolvedArchiveRoot 'chats/by_type/p2p/summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$typeManifestPath = Join-Path $script:ResolvedArchiveRoot 'chats/by_type/manifest.json'
$typeManifest = Get-Content -LiteralPath $typeManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$typeManifest.generated_at = (Get-Date).ToString('o')
$typeManifest | Add-Member -NotePropertyName exclusions -NotePropertyValue '_meta/exclusions.json' -Force
$typeManifest.summary = @($p2pSummary, $groupSummary)
Write-Utf8NoBom $typeManifestPath ($typeManifest | ConvertTo-Json -Depth 20)

$activeAttachments = @(Get-ChildItem -LiteralPath (Join-Path $script:ResolvedArchiveRoot 'chats/attachments') -File -Recurse)
$activeComplete = @($chatIndex | Where-Object { [System.Convert]::ToBoolean($_.complete) }).Count
$activeIncomplete = $chatIndex.Count - $activeComplete
$activeMessages = [long](($chatIndex | Measure-Object -Property message_count -Sum).Sum)

$chatStatePath = Join-Path $script:ResolvedArchiveRoot '_meta/state/chats_complete.json'
$chatState = Get-Content -LiteralPath $chatStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$chatState | Add-Member -NotePropertyName visible_chats_total -NotePropertyValue @($chatList.data.chats).Count -Force
$chatState.chats_total = $chatIndex.Count
$chatState.failed = $activeIncomplete
$chatState.messages_exported = $activeMessages
$chatState.incomplete_paginations = $activeIncomplete
$chatState | Add-Member -NotePropertyName excluded_chats -NotePropertyValue $exclusions.Count -Force
$chatState.completed_at = (Get-Date).ToString('o')
Write-Utf8NoBom $chatStatePath ($chatState | ConvertTo-Json -Depth 15)

$completenessPath = Join-Path $script:ResolvedArchiveRoot '_meta/completeness.json'
$completeness = Get-Content -LiteralPath $completenessPath -Raw -Encoding UTF8 | ConvertFrom-Json
$completeness.chats.enumerated = $chatIndex.Count
$completeness.chats.complete = $activeComplete
$completeness.chats.incomplete = $activeIncomplete
$completeness.chats.messages_exported = $activeMessages
$completeness.chats | Add-Member -NotePropertyName visible_enumerated -NotePropertyValue @($chatList.data.chats).Count -Force
$completeness.chats | Add-Member -NotePropertyName excluded -NotePropertyValue $exclusions.Count -Force
$completeness.attachments.files = $activeAttachments.Count
$completeness.attachments.bytes = [long](($activeAttachments | Measure-Object -Property Length -Sum).Sum)
$completeness.chat_types = [ordered]@{ p2p = $p2pSummary; group = $groupSummary }
$completeness.known_gaps = @((Get-Content -LiteralPath $gapsPath -Raw -Encoding UTF8 | ConvertFrom-Json)).Count
$completeness.finalized_at = (Get-Date).ToString('o')
Write-Utf8NoBom $completenessPath ($completeness | ConvertTo-Json -Depth 30)

$manifestPath = Join-Path $script:ResolvedArchiveRoot '_meta/manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest | Add-Member -NotePropertyName exclusions -NotePropertyValue '_meta/exclusions.json' -Force
$manifest | Add-Member -NotePropertyName excluded_chat_count -NotePropertyValue $exclusions.Count -Force
$manifest.export_completed_at = (Get-Date).ToString('o')
Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 30)

$readmePath = Join-Path $script:ResolvedArchiveRoot 'README_FOR_AI.md'
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
if ($readme -notmatch '_meta/exclusions\.json') {
    $readme = $readme.TrimEnd() + @'

## Exclusions

- `_meta/exclusions.json` is the authoritative stable-ID denylist.
- Excluded chats remain only as minimal metadata in the untouched raw chat catalog and deletion audit.
- Their message JSON, member snapshots, attachments, active indexes, and future downloads are intentionally absent.
'@ + [Environment]::NewLine
    Write-Utf8NoBom $readmePath $readme
}

$run = [ordered]@{
    run_id = $runId
    operation = 'apply_chat_exclusions'
    started_at = $deletionManifest.created_at
    completed_at = (Get-Date).ToString('o')
    status = 'complete_pending_rehash'
    network_calls = 0
    excluded_groups = $exclusions.Count
    deleted_files = $targetFiles.Count
    deleted_bytes = [long](($targetFiles | Measure-Object -Property bytes -Sum).Sum)
    active_chats = $chatIndex.Count
    active_messages = $activeMessages
    remaining_attachments = $activeAttachments.Count
    remaining_attachment_bytes = [long](($activeAttachments | Measure-Object -Property Length -Sum).Sum)
}
Write-Utf8NoBom (Join-Path $runRoot 'run.json') ($run | ConvertTo-Json -Depth 15)

$run | ConvertTo-Json -Depth 15
