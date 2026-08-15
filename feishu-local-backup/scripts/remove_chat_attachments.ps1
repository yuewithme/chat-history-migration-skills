[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [string]$ChatId,
    [string[]]$AttachmentPath,
    [switch]$ConfirmDelete,
    [switch]$SkipRehash,
    [switch]$RepairMetadataOnly
)

$ErrorActionPreference = 'Stop'
$script:Root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if ($directory) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Assert-UnderRoot([string]$Path, [string]$AllowedRoot) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $allowed = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if (-not $resolved.StartsWith($allowed + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Attachment path escapes its chat directory: $resolved"
    }
    return $resolved
}

function Assert-NoReparsePoints([string]$Path, [string]$StopRoot) {
    $resolvedStop = [System.IO.Path]::GetFullPath($StopRoot).TrimEnd('\')
    $current = Get-Item -LiteralPath $Path -Force
    while ($current) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not accepted in attachment paths: $($current.FullName)"
        }
        if ([string]::Equals($current.FullName.TrimEnd('\'), $resolvedStop, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parentPath = [System.IO.Path]::GetDirectoryName($current.FullName.TrimEnd('\'))
        if (-not $parentPath -or -not $parentPath.StartsWith($resolvedStop, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $current = Get-Item -LiteralPath $parentPath -Force
    }
}

function Relative-ArchivePath([string]$Path) {
    return ($Path.Substring($script:Root.Length + 1) -replace '\\', '/')
}

function Get-MessageAttachmentMap([object]$ChatRow) {
    $map = @{}
    $rawRelativePath = if ($ChatRow.raw_path) { [string]$ChatRow.raw_path } else { [string]$ChatRow.raw_json_path }
    if (-not $rawRelativePath) { return $map }
    $rawPath = Join-Path $script:Root ($rawRelativePath -replace '/', '\')
    $envelope = Read-Json $rawPath
    if (-not $envelope) { return $map }
    foreach ($message in @($envelope.data.messages)) {
        $content = [string]$message.content
        $key = $null
        $name = $null
        $type = [string]$message.msg_type
        if ($type -eq 'file') {
            $match = [regex]::Match($content, '<file\s+key="([^"]+)"\s+name="([^"]*)"')
            if ($match.Success) {
                $key = $match.Groups[1].Value
                $name = [System.Net.WebUtility]::HtmlDecode($match.Groups[2].Value)
            }
        }
        elseif ($type -eq 'image') {
            $match = [regex]::Match($content, '\[Image:\s*([^\]]+)\]')
            if ($match.Success) { $key = $match.Groups[1].Value }
        }
        if ($key) {
            $map[$key] = [pscustomobject]@{
                resource_key = $key
                original_name = $name
                message_id = [string]$message.message_id
                message_time = [string]$message.create_time
                sender_name = [string]$message.sender.name
                message_type = $type
            }
        }
    }
    return $map
}

function Update-ChatAttachmentMetadata {
    $allAttachments = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'chats/attachments') -File -Recurse -ErrorAction SilentlyContinue)
    $summaries = @{}
    foreach ($mode in @('p2p', 'group')) {
        $indexPath = Join-Path $script:Root "chats/by_type/$mode/index.json"
        $parsedIndex = Read-Json $indexPath
        $rows = if ($parsedIndex -is [System.Management.Automation.PSCustomObject] -and $parsedIndex.PSObject.Properties['value']) {
            @($parsedIndex.value)
        }
        else {
            @($parsedIndex)
        }
        $modeAttachmentFiles = 0L
        $modeAttachmentBytes = 0L
        foreach ($row in $rows) {
            $directory = if ($row.attachment_root) { Join-Path $script:Root ([string]$row.attachment_root -replace '/', '\') } else { $null }
            $files = if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) { @(Get-ChildItem -LiteralPath $directory -File -Recurse) } else { @() }
            $fileBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
            $row | Add-Member -NotePropertyName attachment_files -NotePropertyValue $files.Count -Force
            $row | Add-Member -NotePropertyName attachment_bytes -NotePropertyValue $fileBytes -Force
            $modeAttachmentFiles += $files.Count
            $modeAttachmentBytes += $fileBytes
        }
        Write-Utf8NoBom $indexPath (ConvertTo-Json -InputObject @($rows) -Depth 20)
        $rows | Export-Csv -LiteralPath (Join-Path $script:Root "chats/by_type/$mode/index.csv") -NoTypeInformation -Encoding UTF8

        $summaryPath = Join-Path $script:Root "chats/by_type/$mode/summary.json"
        $summary = Read-Json $summaryPath
        if ($summary) {
            $summary | Add-Member -NotePropertyName attachment_files -NotePropertyValue $modeAttachmentFiles -Force
            $summary | Add-Member -NotePropertyName attachment_bytes -NotePropertyValue $modeAttachmentBytes -Force
            Write-Utf8NoBom $summaryPath ($summary | ConvertTo-Json -Depth 20)
            $summaries[$mode] = $summary
        }
    }

    $typeManifestPath = Join-Path $script:Root 'chats/by_type/manifest.json'
    $typeManifest = Read-Json $typeManifestPath
    if ($typeManifest) {
        $typeManifest.generated_at = (Get-Date).ToString('o')
        $typeManifest.summary = @($summaries['p2p'], $summaries['group'])
        Write-Utf8NoBom $typeManifestPath ($typeManifest | ConvertTo-Json -Depth 25)
    }

    $completenessPath = Join-Path $script:Root '_meta/completeness.json'
    $completeness = Read-Json $completenessPath
    if ($completeness) {
        $completeness.attachments.files = $allAttachments.Count
        $completeness.attachments.bytes = [long](($allAttachments | Measure-Object -Property Length -Sum).Sum)
        if ($completeness.chat_types) {
            $completeness.chat_types.p2p = $summaries['p2p']
            $completeness.chat_types.group = $summaries['group']
        }
        $completeness.finalized_at = (Get-Date).ToString('o')
        Write-Utf8NoBom $completenessPath ($completeness | ConvertTo-Json -Depth 30)
    }

    $manifestPath = Join-Path $script:Root '_meta/manifest.json'
    $manifest = Read-Json $manifestPath
    if ($manifest) {
        $manifest | Add-Member -NotePropertyName deleted_attachments -NotePropertyValue '_meta/deleted_attachments.json' -Force
        $manifest | Add-Member -NotePropertyName last_local_attachment_deletion_at -NotePropertyValue (Get-Date).ToString('o') -Force
        Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 30)
    }

    $finalizedPath = Join-Path $script:Root '_meta/state/finalized.json'
    $finalized = Read-Json $finalizedPath
    if ($finalized) {
        $finalized.attachments.files = $allAttachments.Count
        $finalized.attachments.bytes = [long](($allAttachments | Measure-Object -Property Length -Sum).Sum)
        $finalized | Add-Member -NotePropertyName deleted_attachments -NotePropertyValue '_meta/deleted_attachments.json' -Force
        Write-Utf8NoBom $finalizedPath ($finalized | ConvertTo-Json -Depth 30)
    }
}

function Remove-TargetsFromUnifiedInventory([object[]]$DeletedTargets) {
    $inventoryPath = Join-Path $script:Root '_meta/inventory.ndjson'
    if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) { return }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (Get-Content -LiteralPath $inventoryPath -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        $row = $line | ConvertFrom-Json
        $remove = $false
        foreach ($target in $DeletedTargets) {
            $sameChatAndKey = ([string]$row.chat_id -eq [string]$target.chat_id -and [string]$row.resource_key -eq [string]$target.resource_key)
            $samePath = ([string]$row.path -eq [string]$target.stored_relative_path -or [string]$row.local_path -eq [string]$target.stored_relative_path -or [string]$row.archive_path -eq [string]$target.stored_relative_path)
            if ($sameChatAndKey -or $samePath) { $remove = $true; break }
        }
        if (-not $remove) { $kept.Add($row) }
    }
    $lines = foreach ($row in $kept) { $row | ConvertTo-Json -Compress -Depth 30 }
    $text = if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-Utf8NoBom $inventoryPath $text
}

if (-not (Test-Path -LiteralPath $script:Root -PathType Container)) { throw "Archive root is missing: $script:Root" }
if ($RepairMetadataOnly) {
    Update-ChatAttachmentMetadata
    $latestRunningRun = Get-ChildItem -LiteralPath (Join-Path $script:Root '_meta/runs') -Directory | Sort-Object Name -Descending | ForEach-Object {
        $candidatePath = Join-Path $_.FullName 'run.json'
        $candidate = Read-Json $candidatePath
        if ($candidate -and [string]$candidate.operation -eq 'delete_chat_attachments' -and [string]$candidate.status -eq 'running') {
            [pscustomobject]@{ path = $candidatePath; run = $candidate }
        }
    } | Select-Object -First 1
    if ($latestRunningRun) {
        $latestRunningRun.run.status = 'complete_after_metadata_repair'
        $latestRunningRun.run | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToString('o') -Force
        $latestRunningRun.run | Add-Member -NotePropertyName repair_note -NotePropertyValue 'Files and tombstones were complete; attachment indexes were rebuilt after a missing-property compatibility error.' -Force
        Write-Utf8NoBom $latestRunningRun.path ($latestRunningRun.run | ConvertTo-Json -Depth 15)
    }
    $repairRehash = $null
    if (-not $SkipRehash) { $repairRehash = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $script:Root | ConvertFrom-Json }
    [ordered]@{ ok = $true; action = 'repair_metadata'; rehash = $repairRehash } | ConvertTo-Json -Depth 10
    exit 0
}
if ($ChatId -notmatch '^oc_[0-9a-f]+$') { throw "Invalid chat ID: $ChatId" }
if (@($AttachmentPath).Count -eq 0) { throw 'No attachment targets were supplied.' }
$chatIndexPath = Join-Path $script:Root 'chats/chat_index.csv'
$chatRow = @(Import-Csv -LiteralPath $chatIndexPath -Encoding UTF8 | Where-Object resource_id -eq $ChatId | Select-Object -First 1)
if ($chatRow.Count -ne 1) { throw "Active chat was not found: $ChatId" }

$chatAttachmentRoot = Join-Path $script:Root "chats/attachments/$ChatId"
$chatAttachmentRoot = Assert-UnderRoot $chatAttachmentRoot (Join-Path $script:Root 'chats/attachments')
if (-not (Test-Path -LiteralPath $chatAttachmentRoot -PathType Container)) { throw "Chat attachment directory is missing: $ChatId" }
Assert-NoReparsePoints $chatAttachmentRoot (Join-Path $script:Root 'chats/attachments')
$activeFiles = @{}
foreach ($file in (Get-ChildItem -LiteralPath $chatAttachmentRoot -File -Recurse)) {
    $relative = ($file.FullName.Substring($chatAttachmentRoot.Length + 1) -replace '\\', '/')
    $activeFiles[$relative] = $file
}
$messageMap = Get-MessageAttachmentMap ($chatRow[0])
$targets = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($requestedPath in $AttachmentPath) {
    if ([string]::IsNullOrWhiteSpace($requestedPath)) { continue }
    if ([System.IO.Path]::IsPathRooted($requestedPath) -or $requestedPath.StartsWith('/') -or $requestedPath.StartsWith('\')) { throw "Absolute attachment paths are not accepted: $requestedPath" }
    $normalizedRequest = ($requestedPath -replace '\\', '/')
    if (-not $activeFiles.ContainsKey($normalizedRequest)) { throw "Attachment is not in the current active inventory: $requestedPath" }
    $fullPath = Assert-UnderRoot $activeFiles[$normalizedRequest].FullName $chatAttachmentRoot
    Assert-NoReparsePoints $fullPath $chatAttachmentRoot
    if (-not $seen.Add($fullPath)) { continue }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Attachment does not exist: $requestedPath" }
    $file = Get-Item -LiteralPath $fullPath
    $resourceKey = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $message = if ($messageMap.ContainsKey($resourceKey)) { $messageMap[$resourceKey] } else { $null }
    $targets.Add([pscustomobject]@{
        chat_id = $ChatId
        resource_key = $resourceKey
        original_name = if ($message -and $message.original_name) { [string]$message.original_name } else { $file.Name }
        stored_relative_path = Relative-ArchivePath $file.FullName
        request_relative_path = ($file.FullName.Substring($chatAttachmentRoot.Length + 1) -replace '\\', '/')
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        message_id = if ($message) { [string]$message.message_id } else { $null }
        message_time = if ($message) { [string]$message.message_time } else { $null }
        sender_name = if ($message) { [string]$message.sender_name } else { $null }
        message_type = if ($message) { [string]$message.message_type } else { $null }
    })
}
if ($targets.Count -eq 0) { throw 'No attachment targets were supplied.' }

$preview = [ordered]@{
    action = if ($ConfirmDelete) { 'delete' } else { 'preview' }
    chat_id = $ChatId
    files = $targets.Count
    bytes = [long](($targets | Measure-Object -Property bytes -Sum).Sum)
    targets = $targets
}
if (-not $ConfirmDelete) { $preview | ConvertTo-Json -Depth 20; exit 0 }

$runId = (Get-Date).ToString('yyyyMMddTHHmmssfffzzz') -replace ':', ''
$runRoot = Join-Path $script:Root "_meta/runs/$runId"
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
$auditPath = Join-Path $runRoot 'attachment_deletion.json'
$audit = [ordered]@{
    schema = 'feishu-local-backup-attachment-deletion-v1'
    run_id = $runId
    created_at = (Get-Date).ToString('o')
    status = 'planned'
    source = 'local_chat_report_or_explicit_user_request'
    targets = $targets
}
Write-Utf8NoBom $auditPath ($audit | ConvertTo-Json -Depth 25)
Write-Utf8NoBom (Join-Path $runRoot 'run.json') ([ordered]@{
    run_id = $runId
    operation = 'delete_chat_attachments'
    started_at = (Get-Date).ToString('o')
    status = 'running'
    network_calls = 0
    chat_id = $ChatId
    requested_files = $targets.Count
} | ConvertTo-Json -Depth 10)

$tombstonePath = Join-Path $script:Root '_meta/deleted_attachments.json'
$tombstone = Read-Json $tombstonePath
if (-not $tombstone) {
    $tombstone = [pscustomobject]@{
        schema = 'feishu-local-backup-deleted-attachments-v1'
        updated_at = (Get-Date).ToString('o')
        entries = @()
    }
}
if (-not $tombstone.PSObject.Properties['schema']) { $tombstone | Add-Member -NotePropertyName schema -NotePropertyValue 'feishu-local-backup-deleted-attachments-v1' }
if (-not $tombstone.PSObject.Properties['entries']) { $tombstone | Add-Member -NotePropertyName entries -NotePropertyValue @() }
if (-not $tombstone.PSObject.Properties['updated_at']) { $tombstone | Add-Member -NotePropertyName updated_at -NotePropertyValue (Get-Date).ToString('o') }
$entries = [System.Collections.Generic.List[object]]::new()
foreach ($entry in @($tombstone.entries)) { $entries.Add($entry) }
foreach ($target in $targets) {
    $entry = @($entries | Where-Object { [string]$_.chat_id -eq $ChatId -and [string]$_.resource_key -eq [string]$target.resource_key } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
        $entryObject = [pscustomobject]@{
            chat_id = $ChatId
            resource_key = [string]$target.resource_key
            original_name = [string]$target.original_name
            stored_relative_path = [string]$target.stored_relative_path
            bytes = [long]$target.bytes
            sha256 = [string]$target.sha256
            message_id = [string]$target.message_id
            message_time = [string]$target.message_time
            status = 'pending'
            prevent_future_download = $true
            first_requested_at = (Get-Date).ToString('o')
            last_deleted_at = $null
            delete_count = 0
        }
        $entries.Add($entryObject)
    }
    else {
        $entry[0].status = 'pending'
        $entry[0].original_name = [string]$target.original_name
        $entry[0].stored_relative_path = [string]$target.stored_relative_path
        $entry[0].bytes = [long]$target.bytes
        $entry[0].sha256 = [string]$target.sha256
    }
}
$tombstone | Add-Member -NotePropertyName entries -NotePropertyValue @($entries) -Force
$tombstone | Add-Member -NotePropertyName updated_at -NotePropertyValue (Get-Date).ToString('o') -Force
Write-Utf8NoBom $tombstonePath ($tombstone | ConvertTo-Json -Depth 25)

foreach ($target in $targets) {
    $fullPath = Assert-UnderRoot (Join-Path $script:Root ([string]$target.stored_relative_path -replace '/', '\')) $chatAttachmentRoot
    Remove-Item -LiteralPath $fullPath -Force
    $entry = @($entries | Where-Object { [string]$_.chat_id -eq $ChatId -and [string]$_.resource_key -eq [string]$target.resource_key } | Select-Object -First 1)[0]
    $entry.status = 'deleted'
    $entry.last_deleted_at = (Get-Date).ToString('o')
    $entry.delete_count = [int]$entry.delete_count + 1
}
$tombstone | Add-Member -NotePropertyName entries -NotePropertyValue @($entries) -Force
$tombstone | Add-Member -NotePropertyName updated_at -NotePropertyValue (Get-Date).ToString('o') -Force
Write-Utf8NoBom $tombstonePath ($tombstone | ConvertTo-Json -Depth 25)

$audit.status = 'complete'
$audit | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToString('o') -Force
Write-Utf8NoBom $auditPath ($audit | ConvertTo-Json -Depth 25)
Remove-TargetsFromUnifiedInventory $targets
Update-ChatAttachmentMetadata

$run = [ordered]@{
    run_id = $runId
    operation = 'delete_chat_attachments'
    completed_at = (Get-Date).ToString('o')
    status = 'complete'
    network_calls = 0
    chat_id = $ChatId
    deleted_files = $targets.Count
    deleted_bytes = [long](($targets | Measure-Object -Property bytes -Sum).Sum)
    tombstone = '_meta/deleted_attachments.json'
}
Write-Utf8NoBom (Join-Path $runRoot 'run.json') ($run | ConvertTo-Json -Depth 10)

$rehash = $null
if (-not $SkipRehash) {
    $rehash = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $script:Root | ConvertFrom-Json
}
[ordered]@{
    ok = $true
    run_id = $runId
    chat_id = $ChatId
    deleted_files = $targets.Count
    deleted_bytes = [long](($targets | Measure-Object -Property bytes -Sum).Sum)
    tombstone = '_meta/deleted_attachments.json'
    rehash = $rehash
    targets = $targets
} | ConvertTo-Json -Depth 25
