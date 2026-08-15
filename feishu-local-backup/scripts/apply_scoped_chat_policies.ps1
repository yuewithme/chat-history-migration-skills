[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [string]$PoliciesPath,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if ($directory) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Relative-Path([string]$Path) {
    return ($Path.Substring($script:Root.Length + 1) -replace '\\', '/')
}

function Assert-InRoot([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($script:Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes archive root: $resolved" }
    return $resolved
}

function Write-Ndjson([string]$Path, [object[]]$Rows) {
    $lines = foreach ($row in $Rows) { $row | ConvertTo-Json -Compress -Depth 30 }
    $text = if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-Utf8NoBom $Path $text
}

function Has-Scope([object]$Policy, [string]$Scope) {
    return (@($Policy.scope) -contains $Scope)
}

$script:Root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $script:Root -PathType Container)) { throw "Archive root is missing: $script:Root" }
if (-not $PoliciesPath) {
    $archivePolicies = Join-Path $script:Root '_meta\exclusions.json'
    $legacy = if (Test-Path -LiteralPath $archivePolicies -PathType Leaf) { Get-Content -LiteralPath $archivePolicies -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $accountKey = if ($legacy -and $legacy.account_scope.open_id) { [string]$legacy.account_scope.open_id } else { $null }
    if (-not $accountKey) {
        $manifestPath = Join-Path $script:Root '_meta\manifest.json'
        $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        if ($manifest -and $manifest.identity.open_id) { $accountKey = [string]$manifest.identity.open_id }
    }
    if (-not $accountKey) {
        $accountRoots = @(Get-ChildItem -LiteralPath (Join-Path $script:Root '_meta\policies\accounts') -Directory -ErrorAction SilentlyContinue)
        if ($accountRoots.Count -eq 1) { $accountKey = $accountRoots[0].Name }
        elseif ($accountRoots.Count -gt 1) { throw 'Multiple account policy directories exist; provide -PoliciesPath explicitly.' }
    }
    $accountPolicies = if ($accountKey) { Join-Path $script:Root "_meta\policies\accounts\$accountKey\chat_exclusions.json" } else { $null }
    $PoliciesPath = if ($accountPolicies -and (Test-Path -LiteralPath $accountPolicies -PathType Leaf)) { $accountPolicies } elseif ($legacy) { $archivePolicies } else { Join-Path $PSScriptRoot '../references/exclusions.json' }
}
$config = Get-Content -LiteralPath $PoliciesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$policies = @($config.chat_exclusions)
$attachmentOnly = @($policies | Where-Object { [string]$_.disposition -eq 'purge' -and (Has-Scope $_ 'attachments') -and -not (Has-Scope $_ 'messages') })
$quarantine = @($policies | Where-Object { [string]$_.disposition -eq 'quarantine' })

$checksumMap = @{}
$checksumPath = Join-Path $script:Root '_meta/checksums.sha256'
if (Test-Path -LiteralPath $checksumPath) {
    foreach ($line in (Get-Content -LiteralPath $checksumPath -Encoding UTF8)) {
        if ($line -match '^([0-9a-fA-F]{64})  (.+)$') { $checksumMap[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
}

$deleteFiles = [System.Collections.Generic.List[object]]::new()
$deleteDirectories = [System.Collections.Generic.List[string]]::new()
foreach ($policy in $attachmentOnly) {
    $directory = Assert-InRoot (Join-Path $script:Root "chats/attachments/$($policy.chat_id)")
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $deleteDirectories.Add($directory)
        foreach ($file in (Get-ChildItem -LiteralPath $directory -File -Recurse)) {
            $relative = Relative-Path $file.FullName
            $hash = if ($checksumMap.ContainsKey($relative)) { $checksumMap[$relative] } else { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $deleteFiles.Add([pscustomobject]@{ chat_id = [string]$policy.chat_id; path = $relative; bytes = [long]$file.Length; sha256 = $hash })
        }
    }
}

$moveFiles = [System.Collections.Generic.List[object]]::new()
foreach ($policy in $quarantine) {
    $id = [string]$policy.chat_id
    foreach ($area in @('raw', 'members')) {
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:Root "chats/$area") -File -Filter "*--$id.json" -ErrorAction SilentlyContinue)) {
            $destination = Assert-InRoot (Join-Path $script:Root "chats/quarantine/$id/$area/$($file.Name)")
            $relative = Relative-Path $file.FullName
            $hash = if ($checksumMap.ContainsKey($relative)) { $checksumMap[$relative] } else { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $moveFiles.Add([pscustomobject]@{ chat_id = $id; source = $relative; destination = Relative-Path $destination; bytes = [long]$file.Length; sha256 = $hash; kind = $area })
        }
    }
    $attachmentDirectory = Assert-InRoot (Join-Path $script:Root "chats/attachments/$id")
    if (Test-Path -LiteralPath $attachmentDirectory -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $attachmentDirectory -File -Recurse)) {
            $suffix = $file.FullName.Substring($attachmentDirectory.Length).TrimStart('\')
            $destination = Assert-InRoot (Join-Path $script:Root "chats/quarantine/$id/attachments/$suffix")
            $relative = Relative-Path $file.FullName
            $hash = if ($checksumMap.ContainsKey($relative)) { $checksumMap[$relative] } else { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $moveFiles.Add([pscustomobject]@{ chat_id = $id; source = $relative; destination = Relative-Path $destination; bytes = [long]$file.Length; sha256 = $hash; kind = 'attachment' })
        }
    }
}

$preview = [ordered]@{
    action = if ($Apply) { 'apply' } else { 'preview' }
    attachment_only_policies = $attachmentOnly.Count
    quarantine_policies = $quarantine.Count
    delete_files = $deleteFiles.Count
    delete_bytes = [long](($deleteFiles | Measure-Object -Property bytes -Sum).Sum)
    quarantine_files = $moveFiles.Count
    quarantine_bytes = [long](($moveFiles | Measure-Object -Property bytes -Sum).Sum)
}
if (-not $Apply) { $preview | ConvertTo-Json -Depth 10; exit 0 }

$runId = (Get-Date).ToString('yyyyMMddTHHmmsszzz') -replace ':', ''
$runRoot = Assert-InRoot (Join-Path $script:Root "_meta/runs/$runId")
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
$audit = [ordered]@{
    schema = 'feishu-local-backup-scoped-policy-audit-v1'
    run_id = $runId
    created_at = (Get-Date).ToString('o')
    summary = $preview
    permanent_deletions = $deleteFiles
    quarantine_moves = $moveFiles
}
Write-Utf8NoBom (Join-Path $runRoot 'policy_audit.json') ($audit | ConvertTo-Json -Depth 20)

foreach ($file in $deleteFiles) {
    $path = Assert-InRoot (Join-Path $script:Root ($file.path -replace '/', '\\'))
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
foreach ($directory in $deleteDirectories) {
    $path = Assert-InRoot $directory
    if (Test-Path -LiteralPath $path -PathType Container) { Remove-Item -LiteralPath $path -Recurse -Force }
}

foreach ($file in $moveFiles) {
    $source = Assert-InRoot (Join-Path $script:Root ($file.source -replace '/', '\\'))
    $destination = Assert-InRoot (Join-Path $script:Root ($file.destination -replace '/', '\\'))
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
        if (Test-Path -LiteralPath $destination) { throw "Quarantine destination already exists: $destination" }
        Move-Item -LiteralPath $source -Destination $destination
    }
}
foreach ($policy in $quarantine) {
    $id = [string]$policy.chat_id
    $manifest = [ordered]@{
        chat_id = $id
        title = [string]$policy.title
        quarantined_at = (Get-Date).ToString('o')
        policy = $policy
        files = @($moveFiles | Where-Object chat_id -eq $id)
    }
    Write-Utf8NoBom (Assert-InRoot (Join-Path $script:Root "chats/quarantine/$id/manifest.json")) ($manifest | ConvertTo-Json -Depth 20)
}

$archivePolicy = [ordered]@{ schema = [string]$config.schema; applied_at = (Get-Date).ToString('o'); source = 'feishu-local-backup/references/exclusions.json'; chat_exclusions = $policies }
Write-Utf8NoBom (Join-Path $script:Root '_meta/exclusions.json') ($archivePolicy | ConvertTo-Json -Depth 20)

$fullIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($policy in $policies) { if (Has-Scope $policy 'messages') { [void]$fullIds.Add([string]$policy.chat_id) } }
$chatIndexPath = Join-Path $script:Root 'chats/chat_index.csv'
$chatIndex = @(Import-Csv -LiteralPath $chatIndexPath | Where-Object { -not $fullIds.Contains([string]$_.resource_id) })
$chatIndex | Export-Csv -LiteralPath $chatIndexPath -NoTypeInformation -Encoding UTF8

foreach ($ndjsonRelative in @('_meta/state/chat_inventory.ndjson', '_meta/inventory.ndjson')) {
    $path = Join-Path $script:Root $ndjsonRelative
    if (Test-Path -LiteralPath $path) {
        $rows = @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { -not $fullIds.Contains([string]$_.resource_id) })
        $lines = foreach ($row in $rows) { $row | ConvertTo-Json -Compress -Depth 30 }
        $text = if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
        Write-Utf8NoBom $path $text
    }
}
$relationshipsPath = Join-Path $script:Root '_meta/relationships.ndjson'
if (Test-Path -LiteralPath $relationshipsPath) {
    $lines = foreach ($line in (Get-Content -LiteralPath $relationshipsPath -Encoding UTF8)) {
        $keep = $true
        foreach ($id in $fullIds) { if ($line.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $keep = $false; break } }
        if ($keep -and $line.Trim()) { $line }
    }
    $relationshipText = if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-Utf8NoBom $relationshipsPath $relationshipText
}

$groupJson = Get-Content -LiteralPath (Join-Path $script:Root 'chats/by_type/group/index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$groupIndex = @()
foreach ($row in $groupJson) { if (-not $fullIds.Contains([string]$row.chat_id)) { $groupIndex += $row } }
$p2pJson = Get-Content -LiteralPath (Join-Path $script:Root 'chats/by_type/p2p/index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$p2pIndex = @()
foreach ($row in $p2pJson) {
    if (-not $fullIds.Contains([string]$row.chat_id)) {
        foreach ($policy in $attachmentOnly) { if ([string]$row.chat_id -eq [string]$policy.chat_id) { $row.attachment_files = 0; $row.attachment_bytes = 0 } }
        $p2pIndex += $row
    }
}
$groupIndex = @($groupIndex | Sort-Object title, chat_id)
$p2pIndex = @($p2pIndex | Sort-Object title, chat_id)
Write-Utf8NoBom (Join-Path $script:Root 'chats/by_type/group/index.json') ($groupIndex | ConvertTo-Json -Depth 15)
$groupIndex | Export-Csv -LiteralPath (Join-Path $script:Root 'chats/by_type/group/index.csv') -NoTypeInformation -Encoding UTF8
Write-Utf8NoBom (Join-Path $script:Root 'chats/by_type/p2p/index.json') ($p2pIndex | ConvertTo-Json -Depth 15)
$p2pIndex | Export-Csv -LiteralPath (Join-Path $script:Root 'chats/by_type/p2p/index.csv') -NoTypeInformation -Encoding UTF8

function New-Summary([string]$Mode, [object[]]$Rows, [int]$Visible, [int]$Excluded) {
    return [ordered]@{
        chat_mode = $Mode
        meaning = if ($Mode -eq 'group') { 'multi-member group conversation' } else { 'one-to-one direct conversation' }
        visible_chats = $Visible
        excluded_chats = $Excluded
        chats = $Rows.Count
        complete_chats = @($Rows | Where-Object complete).Count
        incomplete_chats = @($Rows | Where-Object { -not $_.complete }).Count
        messages = [long](($Rows | Measure-Object -Property message_count -Sum).Sum)
        attachment_files = [long](($Rows | Measure-Object -Property attachment_files -Sum).Sum)
        attachment_bytes = [long](($Rows | Measure-Object -Property attachment_bytes -Sum).Sum)
        raw_json_bytes = [long](($Rows | Measure-Object -Property raw_json_bytes -Sum).Sum)
        index_json = "chats/by_type/$Mode/index.json"
        index_csv = "chats/by_type/$Mode/index.csv"
    }
}
$chatList = Get-Content -LiteralPath (Join-Path $script:Root 'chats/raw/_chat_list.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$groupSummary = New-Summary 'group' $groupIndex @($chatList.data.chats | Where-Object chat_mode -eq 'group').Count @($policies | Where-Object { (Has-Scope $_ 'messages') -and [string]$_.title }).Count
$p2pSummary = New-Summary 'p2p' $p2pIndex @($chatList.data.chats | Where-Object chat_mode -eq 'p2p').Count 0
Write-Utf8NoBom (Join-Path $script:Root 'chats/by_type/group/summary.json') ($groupSummary | ConvertTo-Json -Depth 15)
Write-Utf8NoBom (Join-Path $script:Root 'chats/by_type/p2p/summary.json') ($p2pSummary | ConvertTo-Json -Depth 15)
$typeManifestPath = Join-Path $script:Root 'chats/by_type/manifest.json'
$typeManifest = Get-Content -LiteralPath $typeManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$typeManifest.generated_at = (Get-Date).ToString('o')
$typeManifest.summary = @($p2pSummary, $groupSummary)
$typeManifest | Add-Member -NotePropertyName exclusions -NotePropertyValue '_meta/exclusions.json' -Force
$typeManifest | Add-Member -NotePropertyName quarantine_root -NotePropertyValue 'chats/quarantine' -Force
Write-Utf8NoBom $typeManifestPath ($typeManifest | ConvertTo-Json -Depth 20)

$activeAttachments = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'chats/attachments') -File -Recurse)
$activeComplete = @($chatIndex | Where-Object { [System.Convert]::ToBoolean($_.complete) }).Count
$activeMessages = [long](($chatIndex | Measure-Object -Property message_count -Sum).Sum)
$chatStatePath = Join-Path $script:Root '_meta/state/chats_complete.json'
$chatState = Get-Content -LiteralPath $chatStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$chatState.chats_total = $chatIndex.Count
$chatState.failed = $chatIndex.Count - $activeComplete
$chatState.messages_exported = $activeMessages
$chatState.incomplete_paginations = $chatIndex.Count - $activeComplete
$chatState.excluded_chats = $fullIds.Count
$chatState.completed_at = (Get-Date).ToString('o')
Write-Utf8NoBom $chatStatePath ($chatState | ConvertTo-Json -Depth 15)

$completenessPath = Join-Path $script:Root '_meta/completeness.json'
$completeness = Get-Content -LiteralPath $completenessPath -Raw -Encoding UTF8 | ConvertFrom-Json
$completeness.chats.enumerated = $chatIndex.Count
$completeness.chats.complete = $activeComplete
$completeness.chats.incomplete = $chatIndex.Count - $activeComplete
$completeness.chats.messages_exported = $activeMessages
$completeness.chats.excluded = $fullIds.Count
$completeness.attachments.files = $activeAttachments.Count
$completeness.attachments.bytes = [long](($activeAttachments | Measure-Object -Property Length -Sum).Sum)
$completeness.chat_types = [ordered]@{ p2p = $p2pSummary; group = $groupSummary }
$completeness.finalized_at = (Get-Date).ToString('o')
Write-Utf8NoBom $completenessPath ($completeness | ConvertTo-Json -Depth 30)

$manifestPath = Join-Path $script:Root '_meta/manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.excluded_chat_count = $fullIds.Count
$manifest | Add-Member -NotePropertyName attachment_only_exclusion_count -NotePropertyValue $attachmentOnly.Count -Force
$manifest | Add-Member -NotePropertyName quarantined_chat_count -NotePropertyValue $quarantine.Count -Force
$manifest.export_completed_at = (Get-Date).ToString('o')
Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 30)

$run = [ordered]@{
    run_id = $runId
    operation = 'apply_scoped_chat_policies'
    completed_at = (Get-Date).ToString('o')
    status = 'complete'
    network_calls = 0
    deleted_attachment_files = $deleteFiles.Count
    deleted_attachment_bytes = [long](($deleteFiles | Measure-Object -Property bytes -Sum).Sum)
    quarantined_files = $moveFiles.Count
    quarantined_bytes = [long](($moveFiles | Measure-Object -Property bytes -Sum).Sum)
    active_chats = $chatIndex.Count
    active_messages = $activeMessages
}
Write-Utf8NoBom (Join-Path $runRoot 'run.json') ($run | ConvertTo-Json -Depth 15)
$run | ConvertTo-Json -Depth 15
